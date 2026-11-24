import 'dart:convert';

import 'package:uuid/uuid.dart';

const _uuid = Uuid();
String newId() => _uuid.v4();

/// The protocol a request speaks.
enum RequestType {
  http('HTTP', 'HTTP'),
  graphql('GraphQL', 'GQL'),
  grpc('gRPC', 'gRPC'),
  websocket('WebSocket', 'WS'),
  socketio('Socket.IO', 'SIO'),
  mqtt('MQTT', 'MQTT'),
  sse('Server-Sent Events', 'SSE'),
  soap('SOAP', 'SOAP'),
  kafka('Kafka', 'KAFKA');

  const RequestType(this.label, this.badge);
  final String label;
  final String badge;

  static RequestType parse(String? s) =>
      RequestType.values.firstWhere((e) => e.name == s, orElse: () => RequestType.http);

  bool get isStreaming =>
      this == websocket || this == socketio || this == mqtt || this == sse || this == kafka;
}

const httpMethods = ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS', 'TRACE', 'CONNECT'];

/// A key/value row (params, headers, form fields, variables).
class KV {
  String key;
  String value;
  String description;
  bool enabled;

  /// 'text' | 'file' (form-data) | 'secret' (variables)
  String type;

  KV({this.key = '', this.value = '', this.description = '', this.enabled = true, this.type = 'text'});

  KV copy() => KV(key: key, value: value, description: description, enabled: enabled, type: type);

  Map<String, dynamic> toJson() => {
        'key': key,
        'value': value,
        if (description.isNotEmpty) 'description': description,
        'enabled': enabled,
        if (type != 'text') 'type': type,
      };

  factory KV.fromJson(Map<String, dynamic> j) => KV(
        key: j['key']?.toString() ?? '',
        value: j['value']?.toString() ?? '',
        description: j['description']?.toString() ?? '',
        enabled: j['enabled'] != false,
        type: j['type']?.toString() ?? 'text',
      );

  static List<KV> listFrom(dynamic l) =>
      l is List ? l.whereType<Map>().map((e) => KV.fromJson(Map<String, dynamic>.from(e))).toList() : <KV>[];
}

/// Authentication configuration. `type` selects the scheme, `p` holds its fields.
class AuthConfig {
  String type;
  Map<String, String> p;

  AuthConfig({this.type = 'inherit', Map<String, String>? p}) : p = p ?? {};

  String get(String k, [String def = '']) => p[k] ?? def;
  void set(String k, String v) => p[k] = v;

  AuthConfig copy() => AuthConfig(type: type, p: Map.of(p));
  Map<String, dynamic> toJson() => {'type': type, 'p': p};
  factory AuthConfig.fromJson(dynamic j, {String def = 'inherit'}) {
    if (j is! Map) return AuthConfig(type: def);
    return AuthConfig(
      type: j['type']?.toString() ?? def,
      p: (j['p'] as Map?)?.map((k, v) => MapEntry(k.toString(), v?.toString() ?? '')) ?? {},
    );
  }
}

const authTypes = <String, String>{
  'inherit': 'Inherit auth from parent',
  'none': 'No Auth',
  'apikey': 'API Key',
  'bearer': 'Bearer Token',
  'basic': 'Basic Auth',
  'digest': 'Digest Auth',
  'oauth1': 'OAuth 1.0',
  'oauth2': 'OAuth 2.0',
  'hawk': 'Hawk Authentication',
  'awsv4': 'AWS Signature',
  'ntlm': 'NTLM Authentication',
  'akamai': 'Akamai EdgeGrid',
  'jwt': 'JWT Bearer',
};

class BodyConfig {
  /// none | form-data | urlencoded | raw | binary | graphql
  String mode;

  /// text | json | xml | html | javascript
  String rawLang;
  String raw;
  List<KV> formData;
  List<KV> urlEncoded;
  String binaryPath;
  String gqlQuery;
  String gqlVariables;

  BodyConfig({
    this.mode = 'none',
    this.rawLang = 'json',
    this.raw = '',
    List<KV>? formData,
    List<KV>? urlEncoded,
    this.binaryPath = '',
    this.gqlQuery = '',
    this.gqlVariables = '',
  })  : formData = formData ?? [],
        urlEncoded = urlEncoded ?? [];

  Map<String, dynamic> toJson() => {
        'mode': mode,
        'rawLang': rawLang,
        'raw': raw,
        'formData': formData.map((e) => e.toJson()).toList(),
        'urlEncoded': urlEncoded.map((e) => e.toJson()).toList(),
        'binaryPath': binaryPath,
        'gqlQuery': gqlQuery,
        'gqlVariables': gqlVariables,
      };

  factory BodyConfig.fromJson(dynamic j) {
    if (j is! Map) return BodyConfig();
    return BodyConfig(
      mode: j['mode']?.toString() ?? 'none',
      rawLang: j['rawLang']?.toString() ?? 'json',
      raw: j['raw']?.toString() ?? '',
      formData: KV.listFrom(j['formData']),
      urlEncoded: KV.listFrom(j['urlEncoded']),
      binaryPath: j['binaryPath']?.toString() ?? '',
      gqlQuery: j['gqlQuery']?.toString() ?? '',
      gqlVariables: j['gqlVariables']?.toString() ?? '',
    );
  }
}

/// Declarative assertion evaluated against a response.
class TestRule {
  bool enabled;

  /// status | responseTime | header | body | jsonPath
  String source;
  String property;

  /// eq | neq | contains | notContains | exists | notExists | lt | gt | matches | isType
  String op;
  String expected;

  TestRule({this.enabled = true, this.source = 'status', this.property = '', this.op = 'eq', this.expected = '200'});

  Map<String, dynamic> toJson() =>
      {'enabled': enabled, 'source': source, 'property': property, 'op': op, 'expected': expected};
  factory TestRule.fromJson(Map j) => TestRule(
        enabled: j['enabled'] != false,
        source: j['source']?.toString() ?? 'status',
        property: j['property']?.toString() ?? '',
        op: j['op']?.toString() ?? 'eq',
        expected: j['expected']?.toString() ?? '',
      );
}

/// Pulls a value out of a response into a variable (request chaining).
class VarExtract {
  bool enabled;

  /// jsonPath | header | regex | status
  String source;
  String path;
  String variable;

  /// environment | global | collection
  String scope;

  VarExtract({this.enabled = true, this.source = 'jsonPath', this.path = '', this.variable = '', this.scope = 'environment'});

  Map<String, dynamic> toJson() =>
      {'enabled': enabled, 'source': source, 'path': path, 'variable': variable, 'scope': scope};
  factory VarExtract.fromJson(Map j) => VarExtract(
        enabled: j['enabled'] != false,
        source: j['source']?.toString() ?? 'jsonPath',
        path: j['path']?.toString() ?? '',
        variable: j['variable']?.toString() ?? '',
        scope: j['scope']?.toString() ?? 'environment',
      );
}

class ProtoFile {
  String name;
  String content;
  ProtoFile({required this.name, required this.content});
  Map<String, dynamic> toJson() => {'name': name, 'content': content};
  factory ProtoFile.fromJson(Map j) =>
      ProtoFile(name: j['name']?.toString() ?? 'file.proto', content: j['content']?.toString() ?? '');
}

abstract class Node {
  String id;
  String name;
  Node({required this.id, required this.name});
  Map<String, dynamic> toJson();

  static Node fromJson(Map<String, dynamic> j) =>
      j['kind'] == 'folder' ? Folder.fromJson(j) : ApiRequest.fromJson(j);
}

/// A collection (top level) or folder. Folders nest arbitrarily.
class Folder extends Node {
  List<Node> children;
  AuthConfig auth;
  List<KV> variables;
  String description;
  bool expanded;

  Folder({
    required super.id,
    required super.name,
    List<Node>? children,
    AuthConfig? auth,
    List<KV>? variables,
    this.description = '',
    this.expanded = false,
  })  : children = children ?? [],
        auth = auth ?? AuthConfig(),
        variables = variables ?? [];

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'folder',
        'id': id,
        'name': name,
        'description': description,
        'expanded': expanded,
        'auth': auth.toJson(),
        'variables': variables.map((e) => e.toJson()).toList(),
        'children': children.map((e) => e.toJson()).toList(),
      };

  factory Folder.fromJson(Map<String, dynamic> j) => Folder(
        id: j['id']?.toString() ?? newId(),
        name: j['name']?.toString() ?? 'Folder',
        description: j['description']?.toString() ?? '',
        expanded: j['expanded'] == true,
        auth: AuthConfig.fromJson(j['auth']),
        variables: KV.listFrom(j['variables']),
        children: (j['children'] as List? ?? [])
            .whereType<Map>()
            .map((e) => Node.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
      );

  /// Deep copy with fresh ids.
  Folder duplicate() {
    final f = Folder.fromJson(jsonDecode(jsonEncode(toJson())));
    void reid(Node n) {
      n.id = newId();
      if (n is Folder) n.children.forEach(reid);
    }

    reid(f);
    return f;
  }
}

class ApiRequest extends Node {
  RequestType type;
  String description;
  String method;
  String url;
  List<KV> params;
  List<KV> headers;
  AuthConfig auth;
  BodyConfig body;

  /// Compose buffer for streaming protocols / gRPC message JSON.
  String message;

  /// Protocol specific scalar options (see editors for keys).
  Map<String, String> opts;
  List<TestRule> tests;
  List<VarExtract> extracts;
  List<ProtoFile> protoFiles;

  /// MQTT subscriptions: key = topic filter, value = qos.
  List<KV> subscriptions;

  ApiRequest({
    required super.id,
    required super.name,
    this.type = RequestType.http,
    this.description = '',
    this.method = 'GET',
    this.url = '',
    List<KV>? params,
    List<KV>? headers,
    AuthConfig? auth,
    BodyConfig? body,
    this.message = '',
    Map<String, String>? opts,
    List<TestRule>? tests,
    List<VarExtract>? extracts,
    List<ProtoFile>? protoFiles,
    List<KV>? subscriptions,
  })  : params = params ?? [],
        headers = headers ?? [],
        auth = auth ?? AuthConfig(),
        body = body ?? BodyConfig(),
        opts = opts ?? {},
        tests = tests ?? [],
        extracts = extracts ?? [],
        protoFiles = protoFiles ?? [],
        subscriptions = subscriptions ?? [];

  String opt(String k, [String def = '']) => opts[k] ?? def;
  bool optBool(String k, [bool def = false]) => opts.containsKey(k) ? opts[k] == 'true' : def;
  int optInt(String k, [int def = 0]) => int.tryParse(opts[k] ?? '') ?? def;

  factory ApiRequest.create(RequestType type, {String? name}) {
    final r = ApiRequest(id: newId(), name: name ?? 'New ${type.label} Request', type: type);
    switch (type) {
      case RequestType.graphql:
        r.method = 'POST';
        r.body.mode = 'graphql';
        r.body.gqlQuery = 'query {\n  __typename\n}';
        r.body.gqlVariables = '{}';
      case RequestType.grpc:
        r.message = '{}';
        r.opts['grpcReflection'] = 'true';
      case RequestType.soap:
        r.method = 'POST';
        r.opts['soapVersion'] = '1.1';
        r.body.mode = 'raw';
        r.body.rawLang = 'xml';
        r.body.raw = '<?xml version="1.0" encoding="utf-8"?>\n'
            '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">\n'
            '  <soap:Body>\n  </soap:Body>\n</soap:Envelope>';
      case RequestType.kafka:
        r.url = 'localhost:9092';
        r.opts['kafkaAcks'] = '-1';
        r.opts['kafkaPartition'] = '-1';
        r.opts['kafkaSecurity'] = 'PLAINTEXT';
        r.opts['kafkaFrom'] = 'latest';
      case RequestType.mqtt:
        r.url = 'mqtt://localhost:1883';
        r.opts['mqttQos'] = '0';
      case RequestType.sse:
        r.headers.add(KV(key: 'Accept', value: 'text/event-stream'));
      default:
        break;
    }
    return r;
  }

  ApiRequest clone({bool newIdentity = false}) {
    final c = ApiRequest.fromJson(jsonDecode(jsonEncode(toJson())));
    if (newIdentity) c.id = newId();
    return c;
  }

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'request',
        'id': id,
        'name': name,
        'type': type.name,
        'description': description,
        'method': method,
        'url': url,
        'params': params.map((e) => e.toJson()).toList(),
        'headers': headers.map((e) => e.toJson()).toList(),
        'auth': auth.toJson(),
        'body': body.toJson(),
        'message': message,
        'opts': opts,
        'tests': tests.map((e) => e.toJson()).toList(),
        'extracts': extracts.map((e) => e.toJson()).toList(),
        'protoFiles': protoFiles.map((e) => e.toJson()).toList(),
        'subscriptions': subscriptions.map((e) => e.toJson()).toList(),
      };

  factory ApiRequest.fromJson(Map<String, dynamic> j) => ApiRequest(
        id: j['id']?.toString() ?? newId(),
        name: j['name']?.toString() ?? 'Request',
        type: RequestType.parse(j['type']?.toString()),
        description: j['description']?.toString() ?? '',
        method: j['method']?.toString() ?? 'GET',
        url: j['url']?.toString() ?? '',
        params: KV.listFrom(j['params']),
        headers: KV.listFrom(j['headers']),
        auth: AuthConfig.fromJson(j['auth']),
        body: BodyConfig.fromJson(j['body']),
        message: j['message']?.toString() ?? '',
        opts: (j['opts'] as Map?)?.map((k, v) => MapEntry(k.toString(), v?.toString() ?? '')) ?? {},
        tests: (j['tests'] as List? ?? []).whereType<Map>().map(TestRule.fromJson).toList(),
        extracts: (j['extracts'] as List? ?? []).whereType<Map>().map(VarExtract.fromJson).toList(),
        protoFiles: (j['protoFiles'] as List? ?? []).whereType<Map>().map(ProtoFile.fromJson).toList(),
        subscriptions: KV.listFrom(j['subscriptions']),
      );
}

class Environment {
  String id;
  String name;
  List<KV> variables;
  Environment({required this.id, required this.name, List<KV>? variables}) : variables = variables ?? [];

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'variables': variables.map((e) => e.toJson()).toList()};
  factory Environment.fromJson(Map j) => Environment(
        id: j['id']?.toString() ?? newId(),
        name: j['name']?.toString() ?? 'Environment',
        variables: KV.listFrom(j['variables']),
      );
}

class HistoryEntry {
  final DateTime time;
  final ApiRequest request;
  final int? status;
  final int? timeMs;
  HistoryEntry({required this.time, required this.request, this.status, this.timeMs});

  Map<String, dynamic> toJson() =>
      {'time': time.toIso8601String(), 'request': request.toJson(), 'status': status, 'timeMs': timeMs};
  factory HistoryEntry.fromJson(Map j) => HistoryEntry(
        time: DateTime.tryParse(j['time']?.toString() ?? '') ?? DateTime.now(),
        request: ApiRequest.fromJson(Map<String, dynamic>.from(j['request'] as Map)),
        status: j['status'] as int?,
        timeMs: j['timeMs'] as int?,
      );
}

class AppSettings {
  bool darkMode;
  int timeoutMs;
  bool verifySsl;
  bool followRedirects;
  int maxRedirects;

  /// none | system | custom
  String proxyMode;
  String proxyHost;
  int proxyPort;
  String proxyUser;
  String proxyPass;
  String caCertPath;
  String clientCertPath;
  String clientKeyPath;
  String clientKeyPassphrase;
  int historyLimit;
  bool sendNoCacheHeader;
  bool autoSaveCookies;
  double editorFontSize;

  /// Where the response pane sits: 'bottom' (stacked) or 'right' (side by side).
  String responsePane;

  /// Subtle UI animations (expand/collapse, fades). Also off when the OS requests reduced motion.
  bool animations;

  AppSettings({
    this.darkMode = true,
    this.timeoutMs = 0,
    this.verifySsl = true,
    this.followRedirects = true,
    this.maxRedirects = 10,
    this.proxyMode = 'none',
    this.proxyHost = '',
    this.proxyPort = 8080,
    this.proxyUser = '',
    this.proxyPass = '',
    this.caCertPath = '',
    this.clientCertPath = '',
    this.clientKeyPath = '',
    this.clientKeyPassphrase = '',
    this.historyLimit = 300,
    this.sendNoCacheHeader = true,
    this.autoSaveCookies = true,
    this.editorFontSize = 13,
    this.responsePane = 'bottom',
    this.animations = true,
  });

  Map<String, dynamic> toJson() => {
        'darkMode': darkMode,
        'timeoutMs': timeoutMs,
        'verifySsl': verifySsl,
        'followRedirects': followRedirects,
        'maxRedirects': maxRedirects,
        'proxyMode': proxyMode,
        'proxyHost': proxyHost,
        'proxyPort': proxyPort,
        'proxyUser': proxyUser,
        'proxyPass': proxyPass,
        'caCertPath': caCertPath,
        'clientCertPath': clientCertPath,
        'clientKeyPath': clientKeyPath,
        'clientKeyPassphrase': clientKeyPassphrase,
        'historyLimit': historyLimit,
        'sendNoCacheHeader': sendNoCacheHeader,
        'autoSaveCookies': autoSaveCookies,
        'editorFontSize': editorFontSize,
        'responsePane': responsePane,
        'animations': animations,
      };

  factory AppSettings.fromJson(Map j) => AppSettings(
        darkMode: j['darkMode'] != false,
        timeoutMs: (j['timeoutMs'] as num?)?.toInt() ?? 0,
        verifySsl: j['verifySsl'] != false,
        followRedirects: j['followRedirects'] != false,
        maxRedirects: (j['maxRedirects'] as num?)?.toInt() ?? 10,
        proxyMode: j['proxyMode']?.toString() ?? 'none',
        proxyHost: j['proxyHost']?.toString() ?? '',
        proxyPort: (j['proxyPort'] as num?)?.toInt() ?? 8080,
        proxyUser: j['proxyUser']?.toString() ?? '',
        proxyPass: j['proxyPass']?.toString() ?? '',
        caCertPath: j['caCertPath']?.toString() ?? '',
        clientCertPath: j['clientCertPath']?.toString() ?? '',
        clientKeyPath: j['clientKeyPath']?.toString() ?? '',
        clientKeyPassphrase: j['clientKeyPassphrase']?.toString() ?? '',
        historyLimit: (j['historyLimit'] as num?)?.toInt() ?? 300,
        sendNoCacheHeader: j['sendNoCacheHeader'] != false,
        autoSaveCookies: j['autoSaveCookies'] != false,
        editorFontSize: (j['editorFontSize'] as num?)?.toDouble() ?? 13,
        responsePane: j['responsePane'] == 'right' ? 'right' : 'bottom',
        animations: j['animations'] != false,
      );
}

/// Result of a single request/response exchange (HTTP, GraphQL, SOAP, gRPC unary).
class ResponseData {
  int status;
  String statusText;
  List<MapEntry<String, String>> headers;
  List<int> body;
  int timeMs;
  int size;
  List<StoredCookie> cookies;
  String? error;
  List<TestResult> tests;
  String finalUrl;
  String method;
  List<MapEntry<String, String>> requestHeaders;
  String requestBodyPreview;

  /// Overrides content-type detection (e.g. gRPC responses are JSON-rendered).
  String? displayLanguage;
  List<MapEntry<String, String>> trailers;

  ResponseData({
    this.status = 0,
    this.statusText = '',
    List<MapEntry<String, String>>? headers,
    List<int>? body,
    this.timeMs = 0,
    this.size = 0,
    List<StoredCookie>? cookies,
    this.error,
    List<TestResult>? tests,
    this.finalUrl = '',
    this.method = '',
    List<MapEntry<String, String>>? requestHeaders,
    this.requestBodyPreview = '',
    this.displayLanguage,
    List<MapEntry<String, String>>? trailers,
  })  : headers = headers ?? [],
        body = body ?? [],
        cookies = cookies ?? [],
        tests = tests ?? [],
        requestHeaders = requestHeaders ?? [],
        trailers = trailers ?? [];

  String header(String name) {
    final n = name.toLowerCase();
    for (final h in headers) {
      if (h.key.toLowerCase() == n) return h.value;
    }
    return '';
  }

  String get contentType => header('content-type');

  String get bodyText {
    try {
      return utf8.decode(body, allowMalformed: true);
    } catch (_) {
      return latin1.decode(body);
    }
  }
}

class TestResult {
  final String name;
  final bool passed;
  final String message;
  TestResult(this.name, this.passed, [this.message = '']);
}

class StoredCookie {
  String name;
  String value;
  String domain;
  String path;
  DateTime? expires;
  bool secure;
  bool httpOnly;
  StoredCookie({
    required this.name,
    required this.value,
    required this.domain,
    this.path = '/',
    this.expires,
    this.secure = false,
    this.httpOnly = false,
  });

  bool get expired => expires != null && expires!.isBefore(DateTime.now());

  Map<String, dynamic> toJson() => {
        'name': name,
        'value': value,
        'domain': domain,
        'path': path,
        'expires': expires?.toIso8601String(),
        'secure': secure,
        'httpOnly': httpOnly,
      };
  factory StoredCookie.fromJson(Map j) => StoredCookie(
        name: j['name']?.toString() ?? '',
        value: j['value']?.toString() ?? '',
        domain: j['domain']?.toString() ?? '',
        path: j['path']?.toString() ?? '/',
        expires: j['expires'] == null ? null : DateTime.tryParse(j['expires'].toString()),
        secure: j['secure'] == true,
        httpOnly: j['httpOnly'] == true,
      );
}

enum MsgDir { sent, received, info, error }

/// One entry in a streaming message log (WebSocket, MQTT, Kafka, SSE, gRPC streams...).
class LogMessage {
  final MsgDir dir;
  final DateTime time;
  final String text;

  /// Event name / topic / partition info.
  final String label;
  LogMessage(this.dir, this.text, {this.label = ''}) : time = DateTime.now();
}
