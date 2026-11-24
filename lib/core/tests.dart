import 'dart:convert';

import '../models/models.dart';

class _NoValue {
  const _NoValue();
}

const noValue = _NoValue();

/// Minimal JSONPath: `$.a.b[0].c`, `a.b[0]`, `$['key with space']`, `[*]`, `..name`, `.length`.
dynamic jsonPathQuery(dynamic root, String path) {
  final results = jsonPathAll(root, path);
  if (results.isEmpty) return noValue;
  final wildcard = path.contains('*') || path.contains('..');
  return wildcard ? results : results.first;
}

List<dynamic> jsonPathAll(dynamic root, String path) {
  var p = path.trim();
  if (p.startsWith(r'$')) p = p.substring(1);
  final tokens = <String>[];
  final re = RegExp(r"""\.\.([A-Za-z0-9_\-$]+|\*)|\.([A-Za-z0-9_\-$]+|\*)|\[\s*(-?\d+|\*)\s*\]|\[\s*['"]([^'"]*)['"]\s*\]|^([A-Za-z0-9_\-$]+)""");
  var idx = 0;
  while (idx < p.length) {
    final m = re.matchAsPrefix(p, idx);
    if (m == null) throw FormatException('Invalid JSON path near "${p.substring(idx)}"');
    if (m.group(1) != null) {
      tokens.add('..${m.group(1)}');
    } else {
      tokens.add(m.group(2) ?? m.group(3) ?? m.group(4) ?? m.group(5)!);
    }
    idx = m.end;
  }
  var current = <dynamic>[root];
  for (final t in tokens) {
    final next = <dynamic>[];
    for (final node in current) {
      if (t.startsWith('..')) {
        final key = t.substring(2);
        void walk(dynamic n) {
          if (n is Map) {
            if (key == '*') {
              next.addAll(n.values);
            } else if (n.containsKey(key)) {
              next.add(n[key]);
            }
            n.values.forEach(walk);
          } else if (n is List) {
            if (key == '*') next.addAll(n);
            n.forEach(walk);
          }
        }

        walk(node);
      } else if (t == '*') {
        if (node is Map) next.addAll(node.values);
        if (node is List) next.addAll(node);
      } else if (node is List) {
        final i = int.tryParse(t);
        if (i != null) {
          final ix = i < 0 ? node.length + i : i;
          if (ix >= 0 && ix < node.length) next.add(node[ix]);
        } else if (t == 'length') {
          next.add(node.length);
        }
      } else if (node is Map) {
        if (node.containsKey(t)) {
          next.add(node[t]);
        } else if (t == 'length') {
          next.add(node.length);
        }
      } else if (node is String && t == 'length') {
        next.add(node.length);
      }
    }
    current = next;
  }
  return current;
}

String stringify(dynamic v) {
  if (v is String) return v;
  if (identical(v, noValue)) return '';
  return jsonEncode(v);
}

dynamic tryJson(String s) {
  try {
    return jsonDecode(s);
  } catch (_) {
    return noValue;
  }
}

const testOps = {
  'eq': 'equals',
  'neq': 'not equals',
  'contains': 'contains',
  'notContains': 'does not contain',
  'exists': 'exists',
  'notExists': 'does not exist',
  'lt': 'less than',
  'gt': 'greater than',
  'matches': 'matches regex',
  'isType': 'is type',
};

const testSources = {
  'status': 'Status code',
  'responseTime': 'Response time (ms)',
  'header': 'Header',
  'body': 'Body text',
  'jsonPath': 'JSON body path',
};

List<TestResult> runTests(List<TestRule> rules, ResponseData r) {
  final out = <TestResult>[];
  dynamic json = noValue;
  var jsonParsed = false;
  for (final t in rules.where((e) => e.enabled)) {
    dynamic actual;
    String label;
    switch (t.source) {
      case 'status':
        actual = r.status;
        label = 'Status code';
      case 'responseTime':
        actual = r.timeMs;
        label = 'Response time';
      case 'header':
        final h = r.headers.where((e) => e.key.toLowerCase() == t.property.toLowerCase());
        actual = h.isEmpty ? noValue : h.first.value;
        label = 'Header "${t.property}"';
      case 'body':
        actual = r.bodyText;
        label = 'Body';
      default:
        if (!jsonParsed) {
          json = tryJson(r.bodyText);
          jsonParsed = true;
        }
        try {
          actual = identical(json, noValue) ? noValue : jsonPathQuery(json, t.property);
        } catch (e) {
          out.add(TestResult('JSON ${t.property}', false, e.toString()));
          continue;
        }
        label = 'JSON ${t.property}';
    }
    final name = '$label ${testOps[t.op] ?? t.op}${t.op == 'exists' || t.op == 'notExists' ? '' : ' ${t.expected}'}';
    out.add(_evaluate(name, actual, t.op, t.expected));
  }
  return out;
}

TestResult _evaluate(String name, dynamic actual, String op, String expected) {
  final missing = identical(actual, noValue) || actual == null;
  final a = stringify(actual);
  bool pass;
  String msg = '';
  switch (op) {
    case 'exists':
      pass = !identical(actual, noValue);
    case 'notExists':
      pass = identical(actual, noValue);
    case 'eq':
      final ej = tryJson(expected);
      pass = !missing && (a == expected || (!identical(ej, noValue) && jsonEncode(ej) == jsonEncode(actual)));
    case 'neq':
      final ej = tryJson(expected);
      pass = a != expected && (identical(ej, noValue) || jsonEncode(ej) != jsonEncode(actual));
    case 'contains':
      pass = !missing && (actual is List ? actual.map(stringify).contains(expected) : a.contains(expected));
    case 'notContains':
      pass = missing || (actual is List ? !actual.map(stringify).contains(expected) : !a.contains(expected));
    case 'lt':
    case 'gt':
      final x = num.tryParse(a), y = num.tryParse(expected);
      pass = x != null && y != null && (op == 'lt' ? x < y : x > y);
    case 'matches':
      try {
        pass = !missing && RegExp(expected).hasMatch(a);
      } catch (e) {
        pass = false;
        msg = 'Invalid regex: $e';
      }
    case 'isType':
      final t = actual is String
          ? 'string'
          : actual is num
              ? 'number'
              : actual is bool
                  ? 'boolean'
                  : actual is List
                      ? 'array'
                      : actual is Map
                          ? 'object'
                          : 'null';
      pass = !identical(actual, noValue) && t == expected.toLowerCase();
      if (!pass) msg = 'actual type: $t';
    default:
      pass = false;
  }
  if (!pass && msg.isEmpty) msg = missing && op != 'notExists' ? 'value not found' : 'actual: ${a.length > 200 ? '${a.substring(0, 200)}…' : a}';
  return TestResult(name, pass, pass ? '' : msg);
}

/// Evaluates extraction rules. Returns scope -> {var: value}.
Map<String, Map<String, String>> runExtracts(List<VarExtract> rules, ResponseData r) {
  final out = <String, Map<String, String>>{};
  dynamic json = noValue;
  var parsed = false;
  for (final x in rules.where((e) => e.enabled && e.variable.isNotEmpty)) {
    String? value;
    switch (x.source) {
      case 'header':
        final h = r.headers.where((e) => e.key.toLowerCase() == x.path.toLowerCase());
        if (h.isNotEmpty) value = h.first.value;
      case 'regex':
        try {
          final m = RegExp(x.path).firstMatch(r.bodyText);
          if (m != null) value = m.groupCount >= 1 ? m.group(1) : m.group(0);
        } catch (_) {}
      case 'status':
        value = r.status.toString();
      default:
        if (!parsed) {
          json = tryJson(r.bodyText);
          parsed = true;
        }
        if (!identical(json, noValue)) {
          try {
            final v = jsonPathQuery(json, x.path);
            if (!identical(v, noValue)) value = stringify(v);
          } catch (_) {}
        }
    }
    if (value != null) (out[x.scope] ??= {})[x.variable] = value;
  }
  return out;
}
