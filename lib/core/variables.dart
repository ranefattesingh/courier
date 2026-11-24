import 'dart:math';

import 'package:uuid/uuid.dart';

final _rand = Random();
const _uuid = Uuid();
final varPattern = RegExp(r'\{\{\s*([^{}]+?)\s*\}\}');

const _firstNames = ['Ava', 'Liam', 'Noah', 'Emma', 'Olivia', 'Mia', 'Lucas', 'Aria', 'Ethan', 'Zoe', 'Ravi', 'Kenji'];
const _lastNames = ['Smith', 'Garcia', 'Patel', 'Kim', 'Nguyen', 'Brown', 'Silva', 'Müller', 'Rossi', 'Tanaka'];
const _words = ['alpha', 'bravo', 'delta', 'orbit', 'quartz', 'nimbus', 'ember', 'pixel', 'lunar', 'cobalt'];
const _domains = ['example.com', 'example.org', 'test.dev', 'mail.test'];
const _colors = ['red', 'green', 'blue', 'teal', 'orange', 'purple', 'black', 'white'];
const _cities = ['Berlin', 'Tokyo', 'Austin', 'Lisbon', 'Pune', 'Toronto', 'Nairobi', 'Oslo'];

String _pick(List<String> l) => l[_rand.nextInt(l.length)];
String _hex(int n) => List.generate(n, (_) => _rand.nextInt(16).toRadixString(16)).join();

/// Dynamic variables, available everywhere as {{$name}}.
final Map<String, String Function()> dynamicVariables = {
  r'$guid': () => _uuid.v4(),
  r'$randomUUID': () => _uuid.v4(),
  r'$timestamp': () => (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString(),
  r'$timestampMs': () => DateTime.now().millisecondsSinceEpoch.toString(),
  r'$isoTimestamp': () => DateTime.now().toUtc().toIso8601String(),
  r'$randomInt': () => _rand.nextInt(1001).toString(),
  r'$randomBoolean': () => _rand.nextBool().toString(),
  r'$randomFirstName': () => _pick(_firstNames),
  r'$randomLastName': () => _pick(_lastNames),
  r'$randomFullName': () => '${_pick(_firstNames)} ${_pick(_lastNames)}',
  r'$randomUserName': () => '${_pick(_firstNames).toLowerCase()}${_rand.nextInt(999)}',
  r'$randomEmail': () => '${_pick(_firstNames).toLowerCase()}.${_pick(_lastNames).toLowerCase()}@${_pick(_domains)}',
  r'$randomWord': () => _pick(_words),
  r'$randomWords': () => List.generate(3, (_) => _pick(_words)).join(' '),
  r'$randomColor': () => _pick(_colors),
  r'$randomHexColor': () => '#${_hex(6)}',
  r'$randomCity': () => _pick(_cities),
  r'$randomIP': () => List.generate(4, (_) => _rand.nextInt(256)).join('.'),
  r'$randomPhoneNumber': () => '${200 + _rand.nextInt(799)}-${100 + _rand.nextInt(899)}-${1000 + _rand.nextInt(8999)}',
  r'$randomPrice': () => (_rand.nextInt(100000) / 100).toStringAsFixed(2),
  r'$randomAlphaNumeric': () => _hex(1),
  r'$randomHex': () => _hex(16),
  r'$randomPassword': () => List.generate(15, (_) => 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!@#'[_rand.nextInt(59)]).join(),
  r'$randomDateFuture': () => DateTime.now().add(Duration(days: 1 + _rand.nextInt(365))).toUtc().toIso8601String(),
  r'$randomDatePast': () => DateTime.now().subtract(Duration(days: 1 + _rand.nextInt(365))).toUtc().toIso8601String(),
};

/// Layered variable scope. Later layers override earlier ones:
/// globals < collection < environment < local (runtime).
class VariableScope {
  final Map<String, String> globals;
  final Map<String, String> collection;
  final Map<String, String> environment;
  final Map<String, String> local;

  VariableScope({
    Map<String, String>? globals,
    Map<String, String>? collection,
    Map<String, String>? environment,
    Map<String, String>? local,
  })  : globals = globals ?? {},
        collection = collection ?? {},
        environment = environment ?? {},
        local = local ?? {};

  String? lookup(String name) {
    if (name.startsWith(r'$')) {
      final f = dynamicVariables[name];
      if (f != null) return f();
    }
    return local[name] ?? environment[name] ?? collection[name] ?? globals[name];
  }

  bool isDefined(String name) =>
      dynamicVariables.containsKey(name) ||
      local.containsKey(name) ||
      environment.containsKey(name) ||
      collection.containsKey(name) ||
      globals.containsKey(name);

  /// Where a variable resolves from (for the UI).
  String? sourceOf(String name) {
    if (dynamicVariables.containsKey(name)) return 'Dynamic';
    if (local.containsKey(name)) return 'Local';
    if (environment.containsKey(name)) return 'Environment';
    if (collection.containsKey(name)) return 'Collection';
    if (globals.containsKey(name)) return 'Global';
    return null;
  }

  /// Replace every {{var}} in [input]; unresolved references are kept verbatim.
  String resolve(String input) {
    if (!input.contains('{{')) return input;
    var out = input;
    for (var depth = 0; depth < 8 && out.contains('{{'); depth++) {
      var changed = false;
      out = out.replaceAllMapped(varPattern, (m) {
        final v = lookup(m.group(1)!);
        if (v == null) return m.group(0)!;
        changed = true;
        return v;
      });
      if (!changed) break;
    }
    return out;
  }

  Map<String, String> get all => {...globals, ...collection, ...environment, ...local};
}
