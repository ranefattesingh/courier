import 'dart:convert';

import '../models/models.dart';
import 'importers.dart';

/// Imports Insomnia exports:
///  * v4 JSON (`{"_type": "export", "__export_format": 4, "resources": [...]}`)
///  * v5 YAML / JSON (`type: collection.insomnia.rest/5.0`, `environment.insomnia.rest/5.0`)

bool isInsomniaV4(Map j) => j['_type'] == 'export' && j['resources'] is List;
bool isInsomniaV5(Map j) => (j['type']?.toString() ?? '').contains('insomnia.rest/');

/// Converts Insomnia's Nunjucks templating to Courier variables.
String convertInsomniaTemplate(String s) {
  if (!s.contains('{{') && !s.contains('{%')) return s;
  var out = s.replaceAllMapped(RegExp(r"\{\{\s*_\.([\w.\-]+)\s*\}\}"), (m) => '{{${m[1]}}}');
  out = out.replaceAllMapped(RegExp(r"""\{\{\s*_\[\s*['"]([^'"]+)['"]\s*\]\s*\}\}"""), (m) => '{{${m[1]}}}');
  out = out.replaceAllMapped(RegExp(r"\{%\s*uuid\s*(?:'v\d'|" r'"v\d")?\s*%\}'), (_) => r'{{$guid}}');
  out = out.replaceAllMapped(RegExp(r"""\{%\s*now\s*['"]?([\w-]*)['"]?[^%]*%\}"""), (m) {
    switch (m[1]) {
      case 'millis':
        return r'{{$timestampMs}}';
      case 'unix':
        return r'{{$timestamp}}';
      default:
        return r'{{$isoTimestamp}}';
    }
  });
  // Plain {{ var }} with spaces → {{var}}
  out = out.replaceAllMapped(RegExp(r'\{\{\s+([\w.\-$]+)\s+\}\}'), (m) => '{{${m[1]}}}');
  return out;
}

String _t(dynamic v) => v == null ? '' : convertInsomniaTemplate(v is String ? v : v.toString());

/// Flattens nested environment data: {"a": {"b": 1}} → a.b = 1
List<KV> _envVars(dynamic data) {
  final out = <KV>[];
  void walk(String prefix, dynamic v) {
    if (v is Map) {
      v.forEach((k, x) => walk(prefix.isEmpty ? '$k' : '$prefix.$k', x));
    } else {
      out.add(KV(key: prefix, value: v is String ? _t(v) : jsonEncode(v)));
    }
  }

  if (data is Map) walk('', data);
  return out;
}

List<KV> _pairs(dynamic l) => l is List
    ? l.whereType<Map>().where((e) => (e['name'] ?? '').toString().isNotEmpty || (e['value'] ?? '').toString().isNotEmpty).map((e) => KV(
          key: _t(e['name']),
          value: e['type'] == 'file' ? (e['fileName']?.toString() ?? '') : _t(e['value']),
          description: e['description']?.toString() ?? '',
          enabled: e['disabled'] != true,
          type: e['type'] == 'file' ? 'file' : 'text',
        )).toList()
    : [];

AuthConfig _auth(dynamic a, {String def = 'inherit'}) {
  if (a is! Map || a.isEmpty) return AuthConfig(type: def);
  if (a['disabled'] == true) return AuthConfig(type: 'none');
  final type = a['type']?.toString() ?? '';
  String g(String k) => _t(a[k]);
  switch (type) {
    case 'none':
      return AuthConfig(type: 'none');
    case 'inherit':
      return AuthConfig(type: 'inherit');
    case 'basic':
      return AuthConfig(type: 'basic', p: {'username': g('username'), 'password': g('password')});
    case 'digest':
      return AuthConfig(type: 'digest', p: {'username': g('username'), 'password': g('password')});
    case 'ntlm':
      return AuthConfig(type: 'ntlm', p: {'username': g('username'), 'password': g('password')});
    case 'bearer':
      return AuthConfig(type: 'bearer', p: {'token': g('token'), 'prefix': a['prefix'] == null || g('prefix').isEmpty ? 'Bearer' : g('prefix')});
    case 'apikey':
      return AuthConfig(type: 'apikey', p: {'key': g('key'), 'value': g('value'), 'in': a['addTo'] == 'queryParams' ? 'query' : 'header'});
    case 'oauth1':
      return AuthConfig(type: 'oauth1', p: {
        'consumerKey': g('consumerKey'),
        'consumerSecret': g('consumerSecret'),
        'token': g('tokenKey'),
        'tokenSecret': g('tokenSecret'),
        'signatureMethod': a['signatureMethod']?.toString() ?? 'HMAC-SHA1',
        'callback': g('callback'),
        'verifier': g('verifier'),
        'realm': g('realm'),
        'nonce': g('nonce'),
        'timestamp': g('timestamp'),
        'version': a['version']?.toString() ?? '1.0',
        'addTo': 'header',
      });
    case 'oauth2':
      final grant = a['grantType']?.toString() ?? 'authorization_code';
      return AuthConfig(type: 'oauth2', p: {
        'grantType': grant == 'authorization_code' && a['usePkce'] == true ? 'authorization_code_pkce' : grant,
        'authUrl': g('authorizationUrl'),
        'tokenUrl': g('accessTokenUrl'),
        'clientId': g('clientId'),
        'clientSecret': g('clientSecret'),
        'scope': g('scope'),
        'redirectUri': a['redirectUrl'] == null ? 'http://localhost:7777/callback' : g('redirectUrl'),
        'username': g('username'),
        'password': g('password'),
        'audience': g('audience'),
        'resource': g('resource'),
        'challengeMethod': a['pkceMethod']?.toString() ?? 'S256',
        'clientAuth': a['credentialsInBody'] == true ? 'body' : 'header',
        'headerPrefix': a['tokenPrefix'] == null || g('tokenPrefix').isEmpty ? 'Bearer' : g('tokenPrefix'),
        'accessToken': g('accessToken'),
      });
    case 'iam':
      return AuthConfig(type: 'awsv4', p: {
        'accessKey': g('accessKeyId'),
        'secretKey': g('secretAccessKey'),
        'sessionToken': g('sessionToken'),
        'region': a['region'] == null ? 'us-east-1' : g('region'),
        'service': a['service'] == null ? 'execute-api' : g('service'),
      });
    case 'hawk':
      return AuthConfig(type: 'hawk', p: {
        'authId': g('id'),
        'authKey': g('key'),
        'algorithm': a['algorithm']?.toString() ?? 'sha256',
        'ext': g('ext'),
        'includePayloadHash': '${a['validatePayload'] == true}',
      });
    case 'asap':
      return AuthConfig(type: 'jwt', p: {
        'algorithm': 'RS256',
        'privateKey': g('privateKey'),
        'payload': const JsonEncoder.withIndent('  ').convert({
          'iss': g('issuer'),
          if (g('subject').isNotEmpty) 'sub': g('subject'),
          'aud': g('audience'),
          ...?(() {
            try {
              final extra = g('additionalClaims');
              return extra.isEmpty ? null : Map<String, dynamic>.from(jsonDecode(extra) as Map);
            } catch (_) {
              return null;
            }
          })(),
        }),
        'header': jsonEncode({'kid': g('keyId')}),
        'addTo': 'header',
      });
    default:
      return AuthConfig(type: type.isEmpty ? def : 'none');
  }
}

void _applyBody(ApiRequest r, dynamic body) {
  if (body is! Map) return;
  final mime = (body['mimeType']?.toString() ?? '').toLowerCase();
  final text = _t(body['text']);
  if (mime.contains('graphql')) {
    r.type = RequestType.graphql;
    r.body.mode = 'graphql';
    try {
      final j = jsonDecode(body['text']?.toString() ?? '{}') as Map;
      r.body.gqlQuery = _t(j['query']);
      final vars = j['variables'];
      r.body.gqlVariables = vars == null ? '{}' : (vars is String ? _t(vars) : convertInsomniaTemplate(const JsonEncoder.withIndent('  ').convert(vars)));
      if (j['operationName'] != null) r.opts['gqlOperation'] = j['operationName'].toString();
    } catch (_) {
      r.body.gqlQuery = text;
    }
    return;
  }
  if (mime == 'multipart/form-data') {
    r.body.mode = 'form-data';
    r.body.formData = _pairs(body['params']);
    return;
  }
  if (mime == 'application/x-www-form-urlencoded') {
    r.body.mode = 'urlencoded';
    r.body.urlEncoded = _pairs(body['params']);
    return;
  }
  if (mime == 'application/octet-stream' || (body['fileName'] != null && text.isEmpty)) {
    r.body.mode = 'binary';
    r.body.binaryPath = body['fileName']?.toString() ?? '';
    return;
  }
  if (text.isEmpty && mime.isEmpty) return;
  r.body.mode = 'raw';
  r.body.raw = text;
  r.body.rawLang = mime.contains('json')
      ? 'json'
      : mime.contains('xml')
          ? 'xml'
          : mime.contains('html')
              ? 'html'
              : mime.contains('javascript')
                  ? 'javascript'
                  : 'text';
  if (r.body.rawLang == 'xml' && text.contains(':Envelope')) {
    r.type = RequestType.soap;
    final action = r.headers.where((h) => h.key.toLowerCase() == 'soapaction');
    if (action.isNotEmpty) r.opts['soapAction'] = action.first.value.replaceAll('"', '');
    r.opts['soapVersion'] = text.contains('2003/05/soap-envelope') ? '1.2' : '1.1';
  }
  // Insomnia stores the content type as mimeType; keep an explicit header only if the user had one.
}

/// Adds enabled query params to the URL (Insomnia keeps them separate from the URL).
void _mergeParams(ApiRequest r) {
  final enabled = r.params.where((p) => p.enabled && p.key.isNotEmpty).toList();
  if (enabled.isEmpty) return;
  final q = enabled.map((p) => '${p.key}=${p.value}').join('&');
  r.url = r.url.contains('?') ? '${r.url}&$q' : '${r.url}?$q';
}

ApiRequest _httpRequest(Map m) {
  final r = ApiRequest(id: newId(), name: m['name']?.toString() ?? 'Request');
  r.method = (m['method']?.toString() ?? 'GET').toUpperCase();
  r.url = _t(m['url']);
  r.description = m['description']?.toString() ?? '';
  r.headers = _pairs(m['headers']);
  final existing = parseQueryParamsLoose(r.url);
  r.params = _pairs(m['parameters']);
  _mergeParams(r);
  r.params = [...existing, ...r.params];
  r.auth = _auth(m['authentication']);
  _applyBody(r, m['body']);
  final follow = m['settingFollowRedirects'] ?? (m['settings'] is Map ? m['settings']['followRedirects'] : null);
  if (follow == 'off' || follow == false) r.opts['followRedirects'] = 'false';
  if (follow == 'on' || follow == true) r.opts['followRedirects'] = 'true';
  if (r.url.startsWith('ws://') || r.url.startsWith('wss://')) r.type = RequestType.websocket;
  return r;
}

ApiRequest _grpcRequest(Map m, String? protoText, String? protoName) {
  final r = ApiRequest.create(RequestType.grpc, name: m['name']?.toString() ?? 'gRPC request');
  r.url = _t(m['url']);
  r.description = m['description']?.toString() ?? '';
  final method = (m['protoMethodName']?.toString() ?? '').replaceFirst(RegExp(r'^/'), '');
  if (method.isNotEmpty) r.opts['grpcMethod'] = method;
  final body = m['body'];
  r.message = body is Map ? _t(body['text']) : '{}';
  if (r.message.trim().isEmpty) r.message = '{}';
  r.headers = _pairs(m['metadata']);
  r.auth = _auth(m['authentication']);
  if (protoText != null && protoText.isNotEmpty) {
    r.protoFiles = [ProtoFile(name: protoName ?? 'service.proto', content: protoText)];
    r.opts['grpcReflection'] = 'false';
  } else {
    r.opts['grpcReflection'] = 'true';
  }
  if (r.url.startsWith('grpcs://')) r.opts['grpcTls'] = 'true';
  return r;
}

ApiRequest _wsRequest(Map m, String message) {
  final r = ApiRequest.create(RequestType.websocket, name: m['name']?.toString() ?? 'WebSocket');
  r.url = _t(m['url']);
  r.description = m['description']?.toString() ?? '';
  r.headers = _pairs(m['headers']);
  r.params = _pairs(m['parameters']);
  _mergeParams(r);
  r.auth = _auth(m['authentication']);
  r.message = message;
  return r;
}

/// Applies folder-level headers (an Insomnia feature) to every request below the folder.
void _inheritHeaders(Folder f, List<KV> inherited) {
  for (final c in f.children) {
    if (c is ApiRequest) {
      for (final h in inherited.reversed) {
        if (!c.headers.any((x) => x.key.toLowerCase() == h.key.toLowerCase())) c.headers.insert(0, h.copy());
      }
    }
  }
}

double _sortKey(Map m) {
  final v = m['metaSortKey'] ?? (m['meta'] is Map ? m['meta']['sortKey'] : null);
  return v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
}

// ============================================================================ v4

ImportResult importInsomniaV4(Map j) {
  final resources = (j['resources'] as List).whereType<Map>().toList();
  final byParent = <String, List<Map>>{};
  for (final r in resources) {
    (byParent[r['parentId']?.toString() ?? ''] ??= []).add(r);
  }
  for (final l in byParent.values) {
    l.sort((a, b) => _sortKey(a).compareTo(_sortKey(b)));
  }
  final protoFiles = {for (final r in resources.where((r) => r['_type'] == 'proto_file')) r['_id'].toString(): r};
  final wsPayloads = {for (final r in resources.where((r) => r['_type'] == 'websocket_payload')) r['parentId'].toString(): _t(r['value'])};

  final workspaces = resources.where((r) => r['_type'] == 'workspace').toList();
  // Exports of a single folder/request may have no workspace resource.
  if (workspaces.isEmpty) {
    final ids = resources.map((r) => r['_id']).toSet();
    final roots = byParent.keys.where((p) => !ids.contains(p)).toList();
    for (final root in roots) {
      workspaces.add({'_id': root, 'name': 'Insomnia Import', '_type': 'workspace'});
    }
  }

  final collections = <Folder>[];
  final environments = <Environment>[];
  for (final ws in workspaces) {
    final col = Folder(id: newId(), name: ws['name']?.toString() ?? 'Insomnia Collection', description: ws['description']?.toString() ?? '', auth: AuthConfig(type: 'none'), expanded: true);

    void build(String parentId, Folder into) {
      for (final r in byParent[parentId] ?? const <Map>[]) {
        switch (r['_type']) {
          case 'request_group':
            final f = Folder(id: newId(), name: r['name']?.toString() ?? 'Folder', description: r['description']?.toString() ?? '', auth: _auth(r['authentication']));
            col.variables.addAll(_envVars(r['environment']).where((v) => !col.variables.any((x) => x.key == v.key)));
            build(r['_id'].toString(), f);
            _inheritHeaders(f, _pairs(r['headers']));
            into.children.add(f);
          case 'request':
            into.children.add(_httpRequest(r));
          case 'grpc_request':
            final pf = protoFiles[r['protoFileId']?.toString()];
            into.children.add(_grpcRequest(r, pf?['protoText']?.toString(), pf?['name']?.toString()));
          case 'websocket_request':
            into.children.add(_wsRequest(r, wsPayloads[r['_id'].toString()] ?? ''));
        }
      }
    }

    build(ws['_id'].toString(), col);

    for (final base in (byParent[ws['_id'].toString()] ?? const <Map>[]).where((r) => r['_type'] == 'environment')) {
      col.variables.insertAll(0, _envVars(base['data']).where((v) => !col.variables.any((x) => x.key == v.key)));
      for (final sub in (byParent[base['_id'].toString()] ?? const <Map>[]).where((r) => r['_type'] == 'environment')) {
        environments.add(Environment(id: newId(), name: sub['name']?.toString() ?? 'Environment', variables: _envVars(sub['data'])));
      }
    }
    if (col.children.isNotEmpty || col.variables.isNotEmpty) collections.add(col);
  }
  return ImportResult(collections: collections, environments: environments);
}

// ============================================================================ v5

ImportResult importInsomniaV5(Map j) {
  final type = j['type']?.toString() ?? '';
  final environments = <Environment>[];
  final collectionVars = <KV>[];
  final envs = j['environments'];
  if (envs is Map) {
    collectionVars.addAll(_envVars(envs['data']));
    for (final sub in (envs['subEnvironments'] as List? ?? []).whereType<Map>()) {
      environments.add(Environment(id: newId(), name: sub['name']?.toString() ?? 'Environment', variables: _envVars(sub['data'])));
    }
  }
  if (type.startsWith('environment.')) {
    final name = j['name']?.toString() ?? 'Insomnia Environment';
    if (collectionVars.isNotEmpty) environments.insert(0, Environment(id: newId(), name: name, variables: collectionVars));
    return ImportResult(environments: environments);
  }
  final col = Folder(id: newId(), name: j['name']?.toString() ?? 'Insomnia Collection', auth: AuthConfig(type: 'none'), expanded: true, variables: collectionVars);

  void build(List items, Folder into) {
    final sorted = items.whereType<Map>().toList()..sort((a, b) => _sortKey(a).compareTo(_sortKey(b)));
    for (final m in sorted) {
      if (m['children'] is List) {
        final f = Folder(id: newId(), name: m['name']?.toString() ?? 'Folder', description: m['description']?.toString() ?? '', auth: _auth(m['authentication']));
        col.variables.addAll(_envVars(m['environment']).where((v) => !col.variables.any((x) => x.key == v.key)));
        build(m['children'] as List, f);
        _inheritHeaders(f, _pairs(m['headers']));
        into.children.add(f);
      } else if (m['protoMethodName'] != null || (m['url']?.toString() ?? '').startsWith('grpc')) {
        into.children.add(_grpcRequest(m, m['protoFile'] is Map ? m['protoFile']['protoText']?.toString() : null, null));
      } else if ((m['url']?.toString() ?? '').startsWith('ws') && m['method'] == null) {
        into.children.add(_wsRequest(m, ''));
      } else {
        into.children.add(_httpRequest(m));
      }
    }
  }

  build(j['collection'] as List? ?? [], col);
  return ImportResult(collections: [col], environments: environments);
}
