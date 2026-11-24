import 'dart:convert';

import '../models/models.dart';

class ImportResult {
  final List<Folder> collections;
  final List<Environment> environments;
  final List<ApiRequest> requests;
  ImportResult({this.collections = const [], this.environments = const [], this.requests = const []});
  bool get isEmpty => collections.isEmpty && environments.isEmpty && requests.isEmpty;
}

/// Detects the format of [text] and imports it.
ImportResult importAny(String text) {
  final t = text.trim();
  if (t.startsWith('curl ') || t.startsWith('curl\t') || t.startsWith('curl\n')) {
    return ImportResult(requests: [parseCurl(t)]);
  }
  final dynamic j;
  try {
    j = jsonDecode(t);
  } catch (_) {
    throw const FormatException('Unrecognised format. Paste a cURL command or a Postman / Courier JSON export.');
  }
  if (j is! Map) throw const FormatException('Expected a JSON object');
  if (j['courierExport'] != null) return importCourier(Map<String, dynamic>.from(j));
  if (j['info'] is Map && j['item'] is List) return ImportResult(collections: [importPostmanCollection(Map<String, dynamic>.from(j))]);
  if (j['collection'] is Map) {
    return ImportResult(collections: [importPostmanCollection(Map<String, dynamic>.from(j['collection'] as Map))]);
  }
  if (j['values'] is List && j['name'] != null) return ImportResult(environments: [importPostmanEnvironment(j)]);
  if (j['environment'] is Map) return ImportResult(environments: [importPostmanEnvironment(j['environment'] as Map)]);
  throw const FormatException('Unrecognised JSON. Supported: Postman Collection v2.0/v2.1, Postman Environment, Courier export.');
}

// ---------------------------------------------------------------------------- Courier native

Map<String, dynamic> exportCourier({List<Folder> collections = const [], List<Environment> environments = const []}) => {
      'courierExport': 1,
      'exportedAt': DateTime.now().toIso8601String(),
      'collections': collections.map((c) => c.toJson()).toList(),
      'environments': environments.map((e) => e.toJson()).toList(),
    };

ImportResult importCourier(Map<String, dynamic> j) {
  final cols = (j['collections'] as List? ?? []).map((e) => Folder.fromJson(Map<String, dynamic>.from(e as Map)).duplicate()).toList();
  final envs = (j['environments'] as List? ?? []).map((e) => Environment.fromJson(e as Map)..id = newId()).toList();
  return ImportResult(collections: cols, environments: envs);
}

// ---------------------------------------------------------------------------- Postman

String _desc(dynamic d) => d is String ? d : (d is Map ? d['content']?.toString() ?? '' : '');

const _pmAuthToOurs = {'noauth': 'none', 'edgegrid': 'akamai'};
const _oursToPm = {'none': 'noauth', 'akamai': 'edgegrid'};
const _pmGrant = {
  'authorization_code': 'authorization_code',
  'authorization_code_with_pkce': 'authorization_code_pkce',
  'implicit': 'implicit',
  'password_credentials': 'password',
  'client_credentials': 'client_credentials',
};
const _pmKeyRename = {
  'accessTokenUrl': 'tokenUrl',
  'grant_type': 'grantType',
  'redirect_uri': 'redirectUri',
  'client_authentication': 'clientAuth',
  'addTokenTo': 'addTo',
  'headerPrefix': 'headerPrefix',
  'isSecretBase64Encoded': 'secretBase64',
  'queryParamKey': 'queryParam',
};

AuthConfig _pmAuth(dynamic a, {String def = 'inherit'}) {
  if (a is! Map) return AuthConfig(type: def);
  final pmType = a['type']?.toString() ?? 'noauth';
  final type = _pmAuthToOurs[pmType] ?? pmType;
  final p = <String, String>{};
  final fields = a[pmType];
  if (fields is List) {
    for (final f in fields) {
      if (f is Map) {
        final k = f['key'].toString();
        p[_pmKeyRename[k] ?? k] = f['value'] is String ? f['value'] : (f['value'] == null ? '' : jsonEncode(f['value']));
      }
    }
  } else if (fields is Map) {
    fields.forEach((k, v) => p[_pmKeyRename[k] ?? k.toString()] = v?.toString() ?? '');
  }
  if (type == 'oauth2' && p['grantType'] != null) p['grantType'] = _pmGrant[p['grantType']] ?? p['grantType']!;
  if (type == 'oauth2' && p['addTo'] == 'queryParams') p['addTo'] = 'query';
  if (type == 'oauth2' && p['clientAuth'] == 'body') p['clientAuth'] = 'body';
  if (type == 'oauth1' && p['addParamsToHeader'] == 'false') p['addTo'] = 'query';
  if (type == 'jwt' && p['addTokenTo'] == 'queryParam') p['addTo'] = 'query';
  if (!authTypes.containsKey(type)) return AuthConfig(type: 'none');
  return AuthConfig(type: type, p: p);
}

List<KV> _pmKv(dynamic l) => l is List
    ? l.whereType<Map>().map((e) => KV(
          key: e['key']?.toString() ?? '',
          value: e['value']?.toString() ?? (e['src'] is List ? (e['src'] as List).join(';') : e['src']?.toString() ?? ''),
          description: _desc(e['description']),
          enabled: e['disabled'] != true,
          type: e['type'] == 'file' ? 'file' : (e['type'] == 'secret' ? 'secret' : 'text'),
        )).toList()
    : [];

Folder importPostmanCollection(Map<String, dynamic> j) {
  final info = j['info'] as Map? ?? {};
  final col = Folder(
    id: newId(),
    name: info['name']?.toString() ?? 'Imported Collection',
    description: _desc(info['description']),
    auth: _pmAuth(j['auth'], def: 'none'),
    variables: _pmKv(j['variable']),
    expanded: true,
  );
  col.children.addAll(_pmItems(j['item'] as List? ?? []));
  return col;
}

List<Node> _pmItems(List items) {
  final out = <Node>[];
  for (final it in items.whereType<Map>()) {
    if (it['item'] is List) {
      final f = Folder(id: newId(), name: it['name']?.toString() ?? 'Folder', description: _desc(it['description']), auth: _pmAuth(it['auth']));
      f.children.addAll(_pmItems(it['item'] as List));
      out.add(f);
    } else {
      out.add(_pmRequest(it));
    }
  }
  return out;
}

ApiRequest _pmRequest(Map it) {
  final req = it['request'];
  final r = ApiRequest(id: newId(), name: it['name']?.toString() ?? 'Request');
  if (req is String) {
    r.url = req;
    return r;
  }
  if (req is! Map) return r;
  r.method = req['method']?.toString().toUpperCase() ?? 'GET';
  r.description = _desc(req['description']);
  final url = req['url'];
  if (url is String) {
    r.url = url;
  } else if (url is Map) {
    r.url = url['raw']?.toString() ?? '';
    final q = _pmKv(url['query']);
    r.params = q;
  }
  if (r.params.isEmpty) r.params = _queryFromUrl(r.url);
  r.headers = _pmKv(req['header']);
  r.auth = _pmAuth(req['auth']);
  final body = req['body'];
  if (body is Map) {
    switch (body['mode']) {
      case 'raw':
        r.body.mode = 'raw';
        r.body.raw = body['raw']?.toString() ?? '';
        final lang = (body['options']?['raw']?['language'])?.toString();
        r.body.rawLang = lang ?? (r.body.raw.trimLeft().startsWith('<') ? 'xml' : r.body.raw.trimLeft().startsWith(RegExp(r'[{\[]')) ? 'json' : 'text');
        if (r.body.rawLang == 'xml' && r.body.raw.contains(':Envelope')) {
          r.type = RequestType.soap;
          final action = r.headers.where((h) => h.key.toLowerCase() == 'soapaction');
          if (action.isNotEmpty) r.opts['soapAction'] = action.first.value.replaceAll('"', '');
          r.opts['soapVersion'] = r.body.raw.contains('2003/05/soap-envelope') ? '1.2' : '1.1';
        }
      case 'urlencoded':
        r.body.mode = 'urlencoded';
        r.body.urlEncoded = _pmKv(body['urlencoded']);
      case 'formdata':
        r.body.mode = 'form-data';
        r.body.formData = _pmKv(body['formdata']);
      case 'file':
        r.body.mode = 'binary';
        r.body.binaryPath = body['file']?['src']?.toString() ?? '';
      case 'graphql':
        r.type = RequestType.graphql;
        r.body.mode = 'graphql';
        r.body.gqlQuery = body['graphql']?['query']?.toString() ?? '';
        r.body.gqlVariables = body['graphql']?['variables']?.toString() ?? '';
    }
  }
  return r;
}

List<KV> _queryFromUrl(String url) {
  final i = url.indexOf('?');
  if (i < 0) return [];
  return url.substring(i + 1).split('&').where((e) => e.isNotEmpty).map((p) {
    final j = p.indexOf('=');
    return j < 0 ? KV(key: p) : KV(key: p.substring(0, j), value: p.substring(j + 1));
  }).toList();
}

Environment importPostmanEnvironment(Map j) => Environment(
      id: newId(),
      name: j['name']?.toString() ?? 'Imported Environment',
      variables: (j['values'] as List? ?? [])
          .whereType<Map>()
          .map((v) => KV(key: v['key']?.toString() ?? '', value: v['value']?.toString() ?? '', enabled: v['enabled'] != false, type: v['type'] == 'secret' ? 'secret' : 'text'))
          .toList(),
    );

Map<String, dynamic> exportPostmanEnvironment(Environment e) => {
      'id': e.id,
      'name': e.name,
      'values': e.variables.map((v) => {'key': v.key, 'value': v.value, 'type': v.type == 'secret' ? 'secret' : 'default', 'enabled': v.enabled}).toList(),
      '_postman_variable_scope': 'environment',
    };

Map<String, dynamic>? _pmAuthOut(AuthConfig a) {
  if (a.type == 'inherit') return null;
  final t = _oursToPm[a.type] ?? a.type;
  final reverse = {for (final e in _pmKeyRename.entries) e.value: e.key};
  return {
    'type': t,
    if (t != 'noauth') t: a.p.entries.map((e) => {'key': reverse[e.key] ?? e.key, 'value': e.value, 'type': 'string'}).toList(),
  };
}

List<Map<String, dynamic>> _pmKvOut(List<KV> l) => l
    .map((e) => {
          'key': e.key,
          if (e.type == 'file') 'src': e.value else 'value': e.value,
          if (e.type == 'file') 'type': 'file' else 'type': 'text',
          if (!e.enabled) 'disabled': true,
          if (e.description.isNotEmpty) 'description': e.description,
        })
    .toList();

/// Exports a collection as Postman v2.1. Only HTTP-based request types are representable.
Map<String, dynamic> exportPostmanCollection(Folder c) {
  List<Map<String, dynamic>> items(List<Node> nodes) => [
        for (final n in nodes)
          if (n is Folder)
            {'name': n.name, 'description': n.description, 'item': items(n.children), if (_pmAuthOut(n.auth) != null) 'auth': _pmAuthOut(n.auth)}
          else if (n is ApiRequest && (n.type == RequestType.http || n.type == RequestType.graphql || n.type == RequestType.soap))
            {
              'name': n.name,
              'request': {
                'method': n.method,
                'header': _pmKvOut(n.headers),
                'url': {'raw': n.url},
                if (n.description.isNotEmpty) 'description': n.description,
                if (_pmAuthOut(n.auth) != null) 'auth': _pmAuthOut(n.auth),
                if (n.type == RequestType.graphql || n.body.mode == 'graphql')
                  'body': {'mode': 'graphql', 'graphql': {'query': n.body.gqlQuery, 'variables': n.body.gqlVariables}}
                else if (n.body.mode == 'raw')
                  'body': {'mode': 'raw', 'raw': n.body.raw, 'options': {'raw': {'language': n.body.rawLang}}}
                else if (n.body.mode == 'urlencoded')
                  'body': {'mode': 'urlencoded', 'urlencoded': _pmKvOut(n.body.urlEncoded)}
                else if (n.body.mode == 'form-data')
                  'body': {'mode': 'formdata', 'formdata': _pmKvOut(n.body.formData)}
                else if (n.body.mode == 'binary')
                  'body': {'mode': 'file', 'file': {'src': n.body.binaryPath}},
              },
            },
      ];
  return {
    'info': {
      '_postman_id': c.id,
      'name': c.name,
      'description': c.description,
      'schema': 'https://schema.getpostman.com/json/collection/v2.1.0/collection.json',
    },
    'item': items(c.children),
    if (_pmAuthOut(c.auth) != null) 'auth': _pmAuthOut(c.auth),
    'variable': c.variables.map((v) => {'key': v.key, 'value': v.value}).toList(),
  };
}

// ---------------------------------------------------------------------------- cURL

List<String> shellSplit(String s) {
  final out = <String>[];
  final cur = StringBuffer();
  var inToken = false;
  String? quote;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (quote != null) {
      if (c == quote) {
        quote = null;
      } else if (c == '\\' && quote == '"' && i + 1 < s.length && '"\\\$`'.contains(s[i + 1])) {
        cur.write(s[++i]);
      } else {
        cur.write(c);
      }
    } else if (c == "'" || c == '"') {
      quote = c;
      inToken = true;
    } else if (c == '\$' && i + 1 < s.length && s[i + 1] == "'") {
      quote = "'";
      inToken = true;
      i++;
    } else if (c == '\\' && i + 1 < s.length) {
      final n = s[i + 1];
      i++;
      if (n == '\n' || n == '\r') continue;
      cur.write(n);
      inToken = true;
    } else if (c == '^' && i + 1 < s.length && (s[i + 1] == '\n' || s[i + 1] == '\r')) {
      i++; // Windows cmd line continuation
    } else if (c.trim().isEmpty) {
      if (inToken) {
        out.add(cur.toString());
        cur.clear();
        inToken = false;
      }
    } else {
      cur.write(c);
      inToken = true;
    }
  }
  if (inToken) out.add(cur.toString());
  return out;
}

ApiRequest parseCurl(String cmd) {
  final t = shellSplit(cmd);
  if (t.isEmpty || t.first != 'curl') throw const FormatException('Not a cURL command');
  final r = ApiRequest(id: newId(), name: 'Imported cURL');
  String? method;
  final data = <String>[];
  final form = <KV>[];
  var getMode = false;
  for (var i = 1; i < t.length; i++) {
    final a = t[i];
    String next() => i + 1 < t.length ? t[++i] : '';
    String? inlineVal(String flag) => a.startsWith('$flag=') ? a.substring(flag.length + 1) : null;
    if (a == '-X' || a == '--request') {
      method = next();
    } else if (a.startsWith('-X') && a.length > 2) {
      method = a.substring(2);
    } else if (a == '-H' || a == '--header') {
      final h = next();
      final c = h.indexOf(':');
      if (c > 0) r.headers.add(KV(key: h.substring(0, c).trim(), value: h.substring(c + 1).trim()));
    } else if (['-d', '--data', '--data-raw', '--data-binary', '--data-ascii', '--data-urlencode', '--json'].contains(a) ||
        ['--data', '--data-raw', '--data-binary', '--data-ascii', '--data-urlencode', '--json'].any((f) => inlineVal(f) != null)) {
      final v = a.contains('=') && a.startsWith('--') && !['--data', '--data-raw'].contains(a) ? a.substring(a.indexOf('=') + 1) : next();
      data.add(v);
      if (a == '--json') {
        r.headers.add(KV(key: 'Content-Type', value: 'application/json'));
        r.headers.add(KV(key: 'Accept', value: 'application/json'));
      }
    } else if (a == '-F' || a == '--form' || a == '--form-string') {
      final f = next();
      final e = f.indexOf('=');
      if (e > 0) {
        final v = f.substring(e + 1);
        final isFile = v.startsWith('@') && a != '--form-string';
        form.add(KV(key: f.substring(0, e), value: isFile ? v.substring(1).split(';').first : v, type: isFile ? 'file' : 'text'));
      }
    } else if (a == '-u' || a == '--user') {
      final u = next();
      final c = u.indexOf(':');
      r.auth = AuthConfig(type: 'basic', p: {'username': c < 0 ? u : u.substring(0, c), 'password': c < 0 ? '' : u.substring(c + 1)});
    } else if (a == '-A' || a == '--user-agent') {
      r.headers.add(KV(key: 'User-Agent', value: next()));
    } else if (a == '-b' || a == '--cookie') {
      r.headers.add(KV(key: 'Cookie', value: next()));
    } else if (a == '-e' || a == '--referer') {
      r.headers.add(KV(key: 'Referer', value: next()));
    } else if (a == '--url') {
      r.url = next();
    } else if (a == '-k' || a == '--insecure') {
      r.opts['verifySsl'] = 'false';
    } else if (a == '-L' || a == '--location') {
      r.opts['followRedirects'] = 'true';
    } else if (a == '-G' || a == '--get') {
      getMode = true;
    } else if (a == '-I' || a == '--head') {
      method = 'HEAD';
    } else if (a == '--oauth2-bearer') {
      r.auth = AuthConfig(type: 'bearer', p: {'token': next()});
    } else if (['-o', '--output', '-m', '--max-time', '--connect-timeout', '-w', '--write-out', '--retry', '-x', '--proxy', '--cacert', '--cert', '--key', '-E'].contains(a)) {
      final v = next();
      if (a == '-m' || a == '--max-time') r.opts['timeoutMs'] = ((double.tryParse(v) ?? 0) * 1000).round().toString();
    } else if (!a.startsWith('-') && r.url.isEmpty) {
      r.url = a;
    }
  }
  if (getMode && data.isNotEmpty) {
    r.url += (r.url.contains('?') ? '&' : '?') + data.join('&');
    data.clear();
  }
  if (form.isNotEmpty) {
    r.body.mode = 'form-data';
    r.body.formData = form;
  } else if (data.isNotEmpty) {
    final body = data.join('&');
    final ct = r.headers.where((h) => h.key.toLowerCase() == 'content-type').map((h) => h.value.toLowerCase()).firstOrNull ?? '';
    final looksJson = body.trimLeft().startsWith('{') || body.trimLeft().startsWith('[');
    if (ct.contains('x-www-form-urlencoded') || (ct.isEmpty && !looksJson && body.contains('=') && !body.contains('\n'))) {
      r.body.mode = 'urlencoded';
      r.body.urlEncoded = body.split('&').where((e) => e.isNotEmpty).map((p) {
        final e = p.indexOf('=');
        String dec(String s) {
          try {
            return Uri.decodeQueryComponent(s);
          } catch (_) {
            return s;
          }
        }

        return e < 0 ? KV(key: dec(p)) : KV(key: dec(p.substring(0, e)), value: dec(p.substring(e + 1)));
      }).toList();
      r.headers.removeWhere((h) => h.key.toLowerCase() == 'content-type');
    } else {
      r.body.mode = 'raw';
      r.body.raw = body;
      r.body.rawLang = ct.contains('json') || looksJson ? 'json' : ct.contains('xml') ? 'xml' : ct.contains('html') ? 'html' : 'text';
    }
  }
  r.method = (method ?? (data.isNotEmpty || form.isNotEmpty ? 'POST' : 'GET')).toUpperCase();
  r.params = _queryFromUrl(r.url);
  final u = Uri.tryParse(r.url);
  if (u != null && u.host.isNotEmpty) r.name = '${r.method} ${u.host}${u.path}';
  return r;
}
