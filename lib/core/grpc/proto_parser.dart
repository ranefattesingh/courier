import 'proto_schema.dart';

/// Parser for .proto source files (proto2 / proto3 / editions syntax subset needed
/// for invoking services: messages, enums, oneofs, maps, nested types, services).
class ProtoParser {
  final String source;
  final String fileName;
  late final List<_Tok> _t;
  int _i = 0;
  String _package = '';
  String _syntax = 'proto2';

  /// Type references to be resolved after all files are parsed.
  final List<(ProtoField, String scope)> _unresolved = [];
  final List<(ProtoMethod, String scope, bool isInput, String raw)> _unresolvedMethods = [];
  final ProtoRegistry registry = ProtoRegistry();
  final List<String> imports = [];

  ProtoParser(this.source, {this.fileName = 'input.proto'}) {
    _t = _tokenize(source);
  }

  /// Parses several files and resolves cross-file type references.
  static ProtoRegistry parseAll(Map<String, String> files, {bool includeWellKnown = true}) {
    final parsers = <ProtoParser>[];
    final all = <String, String>{if (includeWellKnown) ...wellKnownProtos, ...files};
    for (final e in all.entries) {
      final p = ProtoParser(e.value, fileName: e.key);
      p._parseFile();
      parsers.add(p);
    }
    final reg = ProtoRegistry();
    for (final p in parsers) {
      reg.merge(p.registry);
    }
    for (final p in parsers) {
      p._resolve(reg);
    }
    return reg;
  }

  // ------------------------------------------------------------------ tokenizer
  static List<_Tok> _tokenize(String s) {
    final out = <_Tok>[];
    var i = 0;
    var line = 1;
    while (i < s.length) {
      final c = s[i];
      if (c == '\n') {
        line++;
        i++;
      } else if (c.trim().isEmpty) {
        i++;
      } else if (s.startsWith('//', i)) {
        while (i < s.length && s[i] != '\n') {
          i++;
        }
      } else if (s.startsWith('/*', i)) {
        final end = s.indexOf('*/', i + 2);
        final stop = end < 0 ? s.length : end + 2;
        line += '\n'.allMatches(s.substring(i, stop)).length;
        i = stop;
      } else if (c == '"' || c == "'") {
        final sb = StringBuffer();
        i++;
        while (i < s.length && s[i] != c) {
          if (s[i] == '\\' && i + 1 < s.length) {
            sb.write(s[i + 1]);
            i += 2;
          } else {
            sb.write(s[i++]);
          }
        }
        i++;
        out.add(_Tok(sb.toString(), line, isString: true));
      } else if (RegExp(r'[A-Za-z0-9_.\-+]').hasMatch(c)) {
        final start = i;
        while (i < s.length && RegExp(r'[A-Za-z0-9_.\-+]').hasMatch(s[i])) {
          i++;
        }
        out.add(_Tok(s.substring(start, i), line));
      } else {
        out.add(_Tok(c, line));
        i++;
      }
    }
    return out;
  }

  bool get _eof => _i >= _t.length;
  String get _peek => _eof ? '' : _t[_i].v;
  String _next() {
    if (_eof) throw FormatException('$fileName: unexpected end of file');
    return _t[_i++].v;
  }

  void _expect(String v) {
    final line = _eof ? -1 : _t[_i].line;
    final got = _next();
    if (got != v) throw FormatException('$fileName:$line: expected "$v" but found "$got"');
  }

  bool _accept(String v) {
    if (_peek == v) {
      _i++;
      return true;
    }
    return false;
  }

  void _skipStatement() {
    var depth = 0;
    while (!_eof) {
      final v = _next();
      if (v == '{') depth++;
      if (v == '}') {
        depth--;
        if (depth <= 0) return;
      }
      if (v == ';' && depth == 0) return;
    }
  }

  void _skipBlock() {
    _expect('{');
    var depth = 1;
    while (!_eof && depth > 0) {
      final v = _next();
      if (v == '{') depth++;
      if (v == '}') depth--;
    }
  }

  /// Skips `[ ... ]` field options, returning `packed` if present.
  bool? _fieldOptions() {
    bool? packed;
    if (!_accept('[')) return null;
    var depth = 1;
    String? prev;
    while (!_eof && depth > 0) {
      final v = _next();
      if (v == '[') depth++;
      if (v == ']') depth--;
      if (prev == '=' && _t[_i - 3].v == 'packed') packed = v == 'true';
      prev = v;
    }
    return packed;
  }

  // ------------------------------------------------------------------ grammar
  void _parseFile() {
    while (!_eof) {
      final v = _next();
      switch (v) {
        case 'syntax':
        case 'edition':
          _expect('=');
          final s = _next();
          _syntax = v == 'edition' ? 'editions' : s;
          _expect(';');
        case 'package':
          _package = _next();
          _expect(';');
        case 'import':
          if (_peek == 'public' || _peek == 'weak') _next();
          imports.add(_next());
          _expect(';');
        case 'option':
          _skipStatement();
        case 'message':
          _message(_package);
        case 'enum':
          _enum(_package);
        case 'service':
          _service();
        case 'extend':
          _next();
          _skipBlock();
        case ';':
          break;
        default:
          throw FormatException('$fileName:${_t[_i - 1].line}: unexpected token "$v"');
      }
    }
  }

  String _join(String scope, String name) => scope.isEmpty ? name : '$scope.$name';

  void _message(String scope) {
    final name = _next();
    final full = _join(scope, name);
    final fields = <ProtoField>[];
    _expect('{');
    _messageBody(full, fields, null);
    registry.messages[full] = ProtoMessage(full, fields, syntax: _syntax);
  }

  void _messageBody(String full, List<ProtoField> fields, String? oneof) {
    while (!_accept('}')) {
      final v = _peek;
      switch (v) {
        case 'message':
          _next();
          _message(full);
        case 'enum':
          _next();
          _enum(full);
        case 'option':
        case 'reserved':
        case 'extensions':
          _skipStatement();
        case 'extend':
          _next();
          _next();
          _skipBlock();
        case 'oneof':
          _next();
          final oname = _next();
          _expect('{');
          _messageBody(full, fields, oname);
        case ';':
          _next();
        case 'map':
          _next();
          _expect('<');
          final k = _next();
          _expect(',');
          final val = _next();
          _expect('>');
          final fname = _next();
          _expect('=');
          final num = _parseInt(_next());
          _fieldOptions();
          _expect(';');
          final entryName = '${fname.split('_').map((p) => p.isEmpty ? '' : p[0].toUpperCase() + p.substring(1)).join()}Entry';
          final entryFull = '$full.$entryName';
          final kf = ProtoField(name: 'key', number: 1, type: k);
          final vf = ProtoField(
              name: 'value',
              number: 2,
              type: scalarTypes.contains(val) ? val : 'message',
              typeName: scalarTypes.contains(val) ? '' : val);
          if (!scalarTypes.contains(val)) _unresolved.add((vf, full));
          registry.messages[entryFull] = ProtoMessage(entryFull, [kf, vf], isMapEntry: true);
          fields.add(ProtoField(name: fname, number: num, type: 'message', typeName: entryFull, repeated: true));
        default:
          _field(full, fields, oneof);
      }
    }
  }

  int _parseInt(String s) {
    if (s.startsWith('0x') || s.startsWith('0X')) return int.parse(s.substring(2), radix: 16);
    return int.parse(s);
  }

  void _field(String scope, List<ProtoField> fields, String? oneof) {
    var label = '';
    if (_peek == 'repeated' || _peek == 'optional' || _peek == 'required') label = _next();
    final type = _next();
    if (type == 'group') {
      // proto2 groups: treat as nested message
      final gname = _next();
      _expect('=');
      final num = _parseInt(_next());
      _fieldOptions();
      final full = '$scope.$gname';
      final gfields = <ProtoField>[];
      _expect('{');
      _messageBody(full, gfields, null);
      registry.messages[full] = ProtoMessage(full, gfields, syntax: _syntax);
      fields.add(ProtoField(
          name: gname.toLowerCase(), number: num, type: 'group', typeName: full, repeated: label == 'repeated'));
      return;
    }
    final name = _next();
    _expect('=');
    final num = _parseInt(_next());
    final packed = _fieldOptions();
    _expect(';');
    final isScalar = scalarTypes.contains(type);
    final f = ProtoField(
      name: name,
      number: num,
      type: isScalar ? type : 'message',
      repeated: label == 'repeated',
      oneof: oneof ?? (label == 'optional' && _syntax == 'proto3' ? '_$name' : null),
      proto3Optional: label == 'optional' && _syntax == 'proto3',
      packedOption: packed,
    );
    if (!isScalar) {
      f.typeName = type;
      _unresolved.add((f, scope));
    }
    fields.add(f);
  }

  void _enum(String scope) {
    final name = _next();
    final full = _join(scope, name);
    final values = <String, int>{};
    _expect('{');
    while (!_accept('}')) {
      if (_peek == 'option' || _peek == 'reserved') {
        _skipStatement();
        continue;
      }
      if (_accept(';')) continue;
      final vname = _next();
      _expect('=');
      var n = _next();
      if (n == '-') n = '-${_next()}';
      values[vname] = _parseInt(n);
      _fieldOptions();
      _expect(';');
    }
    registry.enums[full] = ProtoEnum(full, values);
  }

  void _service() {
    final name = _next();
    final full = _join(_package, name);
    final methods = <ProtoMethod>[];
    _expect('{');
    while (!_accept('}')) {
      final v = _next();
      if (v == 'option') {
        _skipStatement();
        continue;
      }
      if (v == ';') continue;
      if (v != 'rpc') throw FormatException('$fileName: unexpected "$v" in service $name');
      final mname = _next();
      _expect('(');
      final cs = _accept('stream');
      final input = _next();
      _expect(')');
      _expect('returns');
      _expect('(');
      final ss = _accept('stream');
      final output = _next();
      _expect(')');
      if (_peek == '{') {
        _skipBlock();
        _accept(';');
      } else {
        _expect(';');
      }
      final m = ProtoMethod(mname, input, output, clientStreaming: cs, serverStreaming: ss);
      methods.add(m);
      _unresolvedMethods.add((m, _package, true, input));
    }
    registry.services[full] = ProtoService(full, methods);
  }

  // ------------------------------------------------------------------ resolution
  static String? resolveName(ProtoRegistry reg, String name, String scope) {
    if (name.startsWith('.')) {
      final n = name.substring(1);
      return reg.messages.containsKey(n) || reg.enums.containsKey(n) ? n : null;
    }
    var s = scope;
    while (true) {
      final cand = s.isEmpty ? name : '$s.$name';
      if (reg.messages.containsKey(cand) || reg.enums.containsKey(cand)) return cand;
      if (s.isEmpty) break;
      final i = s.lastIndexOf('.');
      s = i < 0 ? '' : s.substring(0, i);
    }
    return null;
  }

  void _resolve(ProtoRegistry reg) {
    for (final (f, scope) in _unresolved) {
      final r = resolveName(reg, f.typeName, scope);
      if (r == null) throw FormatException('$fileName: unknown type "${f.typeName}" (field "${f.name}")');
      f.typeName = r;
      f.type = reg.enums.containsKey(r) ? 'enum' : 'message';
    }
    for (final svc in registry.services.values) {
      final resolved = <ProtoMethod>[];
      for (final m in svc.methods) {
        final i = resolveName(reg, m.inputType, _package);
        final o = resolveName(reg, m.outputType, _package);
        if (i == null) throw FormatException('$fileName: unknown input type "${m.inputType}" for ${m.name}');
        if (o == null) throw FormatException('$fileName: unknown output type "${m.outputType}" for ${m.name}');
        resolved.add(ProtoMethod(m.name, i, o, clientStreaming: m.clientStreaming, serverStreaming: m.serverStreaming));
      }
      svc.methods
        ..clear()
        ..addAll(resolved);
      reg.services[svc.fullName] = svc;
    }
  }
}

class _Tok {
  final String v;
  final int line;
  final bool isString;
  _Tok(this.v, this.line, {this.isString = false});
}

/// Well-known types, always available to user protos.
const wellKnownProtos = <String, String>{
  'google/protobuf/wkt.proto': '''
syntax = "proto3";
package google.protobuf;
message Timestamp { int64 seconds = 1; int32 nanos = 2; }
message Duration { int64 seconds = 1; int32 nanos = 2; }
message Empty {}
message Any { string type_url = 1; bytes value = 2; }
message FieldMask { repeated string paths = 1; }
message Struct { map<string, Value> fields = 1; }
message Value {
  oneof kind {
    NullValue null_value = 1;
    double number_value = 2;
    string string_value = 3;
    bool bool_value = 4;
    Struct struct_value = 5;
    ListValue list_value = 6;
  }
}
enum NullValue { NULL_VALUE = 0; }
message ListValue { repeated Value values = 1; }
message DoubleValue { double value = 1; }
message FloatValue { float value = 1; }
message Int64Value { int64 value = 1; }
message UInt64Value { uint64 value = 1; }
message Int32Value { int32 value = 1; }
message UInt32Value { uint32 value = 1; }
message BoolValue { bool value = 1; }
message StringValue { string value = 1; }
message BytesValue { bytes value = 1; }
''',
};
