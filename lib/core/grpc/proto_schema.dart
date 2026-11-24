/// Runtime protobuf schema used for dynamic (code-gen free) encoding/decoding.
library;

const scalarTypes = {
  'double', 'float', 'int32', 'int64', 'uint32', 'uint64', 'sint32', 'sint64', //
  'fixed32', 'fixed64', 'sfixed32', 'sfixed64', 'bool', 'string', 'bytes',
};

class ProtoField {
  final String name;
  final int number;

  /// A scalar name, or 'message' / 'enum' / 'group'.
  String type;

  /// Fully qualified (no leading dot) message/enum name when type is message/enum.
  String typeName;
  final bool repeated;
  final String? oneof;
  final String jsonName;
  final bool? packedOption;
  final bool proto3Optional;

  ProtoField({
    required this.name,
    required this.number,
    required this.type,
    this.typeName = '',
    this.repeated = false,
    this.oneof,
    String? jsonName,
    this.packedOption,
    this.proto3Optional = false,
  }) : jsonName = jsonName ?? _camel(name);

  static String _camel(String s) {
    final parts = s.split('_');
    return parts.first + parts.skip(1).map((p) => p.isEmpty ? '' : p[0].toUpperCase() + p.substring(1)).join();
  }

  bool get isScalar => scalarTypes.contains(type);
  bool get isPackable => repeated && (isScalar && type != 'string' && type != 'bytes' || type == 'enum');
}

class ProtoMessage {
  final String fullName;
  final List<ProtoField> fields;
  final bool isMapEntry;
  final String syntax;
  ProtoMessage(this.fullName, this.fields, {this.isMapEntry = false, this.syntax = 'proto3'});

  ProtoField? byNumber(int n) {
    for (final f in fields) {
      if (f.number == n) return f;
    }
    return null;
  }

  ProtoField? byJsonKey(String k) {
    for (final f in fields) {
      if (f.name == k || f.jsonName == k) return f;
    }
    return null;
  }
}

class ProtoEnum {
  final String fullName;
  final Map<String, int> values;
  ProtoEnum(this.fullName, this.values);

  String? nameOf(int v) {
    for (final e in values.entries) {
      if (e.value == v) return e.key;
    }
    return null;
  }
}

class ProtoMethod {
  final String name;
  final String inputType;
  final String outputType;
  final bool clientStreaming;
  final bool serverStreaming;
  ProtoMethod(this.name, this.inputType, this.outputType, {this.clientStreaming = false, this.serverStreaming = false});

  String get kind => clientStreaming && serverStreaming
      ? 'Bidirectional streaming'
      : clientStreaming
          ? 'Client streaming'
          : serverStreaming
              ? 'Server streaming'
              : 'Unary';
}

class ProtoService {
  final String fullName;
  final List<ProtoMethod> methods;
  ProtoService(this.fullName, this.methods);
}

class ProtoRegistry {
  final Map<String, ProtoMessage> messages = {};
  final Map<String, ProtoEnum> enums = {};
  final Map<String, ProtoService> services = {};

  void merge(ProtoRegistry o) {
    messages.addAll(o.messages);
    enums.addAll(o.enums);
    services.addAll(o.services);
  }

  ProtoMessage message(String name) {
    final n = name.startsWith('.') ? name.substring(1) : name;
    final m = messages[n];
    if (m == null) throw StateError('Unknown message type "$n" (is the proto that defines it loaded?)');
    return m;
  }

  /// Methods as "package.Service/Method".
  List<String> get methodPaths => [
        for (final s in services.values)
          for (final m in s.methods) '${s.fullName}/${m.name}',
      ]..sort();

  (ProtoService, ProtoMethod)? findMethod(String path) {
    final i = path.lastIndexOf('/');
    if (i < 0) return null;
    final svc = services[path.substring(0, i)];
    if (svc == null) return null;
    for (final m in svc.methods) {
      if (m.name == path.substring(i + 1)) return (svc, m);
    }
    return null;
  }

  /// Builds an example JSON object for a message (used for "Generate example").
  dynamic example(String typeName, [int depth = 0]) {
    final m = messages[typeName];
    if (m == null || depth > 6) return {};
    final special = _wellKnownExample(typeName);
    if (special != null) return special;
    final out = <String, dynamic>{};
    final seenOneofs = <String>{};
    for (final f in m.fields) {
      if (f.oneof != null && !f.proto3Optional) {
        if (seenOneofs.contains(f.oneof)) continue;
        seenOneofs.add(f.oneof!);
      }
      dynamic v;
      final entry = f.type == 'message' ? messages[f.typeName] : null;
      if (entry != null && entry.isMapEntry) {
        final valField = entry.byNumber(2)!;
        out[f.name] = {'key': _scalarExample(valField, depth)};
        continue;
      }
      v = _scalarExample(f, depth);
      out[f.name] = f.repeated ? [v] : v;
    }
    return out;
  }

  dynamic _scalarExample(ProtoField f, int depth) {
    switch (f.type) {
      case 'string':
        return '';
      case 'bytes':
        return '';
      case 'bool':
        return false;
      case 'double':
      case 'float':
        return 0.0;
      case 'enum':
        final e = enums[f.typeName];
        return e == null || e.values.isEmpty ? 0 : e.values.keys.first;
      case 'message':
      case 'group':
        return example(f.typeName, depth + 1);
      default:
        return 0;
    }
  }

  static dynamic _wellKnownExample(String t) {
    switch (t) {
      case 'google.protobuf.Timestamp':
        return DateTime.now().toUtc().toIso8601String();
      case 'google.protobuf.Duration':
        return '1s';
      case 'google.protobuf.Empty':
        return <String, dynamic>{};
      case 'google.protobuf.Struct':
        return <String, dynamic>{};
      case 'google.protobuf.Value':
        return null;
      case 'google.protobuf.ListValue':
        return [];
      case 'google.protobuf.StringValue':
      case 'google.protobuf.BytesValue':
        return '';
      case 'google.protobuf.BoolValue':
        return false;
      case 'google.protobuf.DoubleValue':
      case 'google.protobuf.FloatValue':
      case 'google.protobuf.Int32Value':
      case 'google.protobuf.Int64Value':
      case 'google.protobuf.UInt32Value':
      case 'google.protobuf.UInt64Value':
        return 0;
      case 'google.protobuf.FieldMask':
        return '';
    }
    return null;
  }
}
