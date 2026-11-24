const introspectionQuery = '''
query IntrospectionQuery {
  __schema {
    queryType { name }
    mutationType { name }
    subscriptionType { name }
    types {
      kind name description
      fields(includeDeprecated: true) {
        name description
        args { name description type { ...TypeRef } defaultValue }
        type { ...TypeRef }
        isDeprecated
      }
      inputFields { name description type { ...TypeRef } defaultValue }
      enumValues(includeDeprecated: true) { name description }
    }
  }
}
fragment TypeRef on __Type {
  kind name
  ofType { kind name ofType { kind name ofType { kind name ofType { kind name ofType { kind name } } } } }
}
''';

String typeRefToString(dynamic t) {
  if (t is! Map) return '?';
  switch (t['kind']) {
    case 'NON_NULL':
      return '${typeRefToString(t['ofType'])}!';
    case 'LIST':
      return '[${typeRefToString(t['ofType'])}]';
    default:
      return t['name']?.toString() ?? '?';
  }
}

String namedType(dynamic t) {
  while (t is Map && t['name'] == null) {
    t = t['ofType'];
  }
  return t is Map ? t['name']?.toString() ?? '' : '';
}

class GqlField {
  final String name;
  final String type;
  final String namedType;
  final String description;
  final List<(String, String)> args;
  GqlField(this.name, this.type, this.namedType, this.description, this.args);
}

class GqlType {
  final String name;
  final String kind;
  final String description;
  final List<GqlField> fields;
  final List<String> enumValues;
  GqlType(this.name, this.kind, this.description, this.fields, this.enumValues);
}

class GqlSchema {
  final Map<String, GqlType> types;
  final String? query, mutation, subscription;
  GqlSchema(this.types, this.query, this.mutation, this.subscription);

  factory GqlSchema.fromIntrospection(Map<String, dynamic> json) {
    final s = (json['data'] ?? json)['__schema'] as Map?;
    if (s == null) throw const FormatException('Response does not contain __schema (is introspection disabled?)');
    final types = <String, GqlType>{};
    for (final t in (s['types'] as List)) {
      final name = t['name'].toString();
      if (name.startsWith('__')) continue;
      final fields = [
        for (final f in (t['fields'] as List? ?? t['inputFields'] as List? ?? []))
          GqlField(
            f['name'].toString(),
            typeRefToString(f['type']),
            namedType(f['type']),
            f['description']?.toString() ?? '',
            [for (final a in (f['args'] as List? ?? [])) (a['name'].toString(), typeRefToString(a['type']))],
          ),
      ];
      types[name] = GqlType(name, t['kind'].toString(), t['description']?.toString() ?? '', fields,
          [for (final e in (t['enumValues'] as List? ?? [])) e['name'].toString()]);
    }
    return GqlSchema(types, s['queryType']?['name'], s['mutationType']?['name'], s['subscriptionType']?['name']);
  }

  /// Generates an operation selecting scalar leaves of [field] (2 levels deep).
  String operationFor(String rootKind, GqlField field) {
    final args = field.args;
    final varDefs = args.map((a) => '\$${a.$1}: ${a.$2}').join(', ');
    final callArgs = args.map((a) => '${a.$1}: \$${a.$1}').join(', ');
    final sel = _selection(field.namedType, 2, '    ');
    return '$rootKind ${_cap(field.name)}${varDefs.isEmpty ? '' : '($varDefs)'} {\n'
        '  ${field.name}${callArgs.isEmpty ? '' : '($callArgs)'}${sel.isEmpty ? '' : ' {\n$sel  }'}\n}';
  }

  String _selection(String typeName, int depth, String indent) {
    final t = types[typeName];
    if (t == null || t.fields.isEmpty || depth <= 0) return '';
    final sb = StringBuffer();
    for (final f in t.fields) {
      final ft = types[f.namedType];
      if (ft == null || ft.kind == 'SCALAR' || ft.kind == 'ENUM') {
        if (f.args.every((a) => !a.$2.endsWith('!'))) sb.writeln('$indent${f.name}');
      } else if (depth > 1 && f.args.every((a) => !a.$2.endsWith('!'))) {
        final inner = _selection(f.namedType, depth - 1, '$indent  ');
        if (inner.isNotEmpty) sb.write('$indent${f.name} {\n$inner$indent}\n');
      }
    }
    if (sb.isEmpty && t.kind != 'OBJECT') return '${indent}__typename\n';
    return sb.toString();
  }

  static String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}
