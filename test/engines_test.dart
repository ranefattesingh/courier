import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:courier/core/auth.dart';
import 'package:courier/core/codegen.dart';
import 'package:courier/core/grpc/grpc_engine.dart';
import 'package:courier/core/grpc/proto_parser.dart';
import 'package:courier/core/grpc/wire_codec.dart';
import 'package:courier/core/http_engine.dart';
import 'package:courier/core/importers.dart';
import 'package:courier/core/kafka/kafka_client.dart';
import 'package:courier/core/sessions.dart';
import 'package:courier/core/tests.dart';
import 'package:courier/core/variables.dart';
import 'package:courier/core/wsdl.dart';
import 'package:courier/models/models.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart' as g;

const demoProto = '''
syntax = "proto3";
package demo;
import "google/protobuf/timestamp.proto";
enum Mood { MOOD_UNKNOWN = 0; HAPPY = 1; SAD = 2; }
message HelloRequest {
  string name = 1;
  repeated int32 nums = 2;
  map<string, int64> scores = 3;
  Mood mood = 4;
  Inner inner = 5;
  google.protobuf.Timestamp at = 6;
  sint64 delta = 7;
  oneof choice { string a = 8; int32 b = 9; }
  double ratio = 10;
  bytes blob = 11;
  message Inner { bool flag = 1; }
}
message HelloReply { string message = 1; int32 count = 2; }
service Greeter {
  rpc SayHello (HelloRequest) returns (HelloReply);
  rpc Countdown (HelloRequest) returns (stream HelloReply);
  rpc Chat (stream HelloRequest) returns (stream HelloReply);
}
''';

void main() {
  late HttpServer http;
  late String base;

  setUpAll(() async {
    http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${http.port}';
    http.listen((req) async {
      final res = req.response;
      final body = await utf8.decodeStream(req);
      switch (req.uri.path) {
        case '/echo':
          res.headers.contentType = ContentType.json;
          res.cookies.add(Cookie('session', 'abc123')..path = '/');
          res.write(jsonEncode({
            'method': req.method,
            'query': req.uri.queryParameters,
            'headers': {for (final n in ['authorization', 'content-type', 'cookie', 'x-custom']) n: req.headers.value(n)},
            'body': body,
          }));
        case '/redirect':
          res.statusCode = 302;
          res.headers.set('Location', '/echo?from=redirect');
        case '/digest':
          final auth = req.headers.value('authorization') ?? '';
          if (!auth.startsWith('Digest ')) {
            res.statusCode = 401;
            res.headers.set('WWW-Authenticate', 'Digest realm="test", qop="auth", nonce="n0nce", opaque="op"');
          } else {
            final p = parseAuthParams(auth.substring(7));
            String h(String s) => md5.convert(utf8.encode(s)).toString();
            final ha1 = h('user:test:pass');
            final ha2 = h('${req.method}:${p['uri']}');
            final expect = h('$ha1:${p['nonce']}:${p['nc']}:${p['cnonce']}:${p['qop']}:$ha2');
            res.statusCode = expect == p['response'] ? 200 : 403;
            res.write(expect == p['response'] ? 'digest-ok' : 'bad');
          }
        case '/sse':
          res.headers.contentType = ContentType('text', 'event-stream');
          res.bufferOutput = false;
          for (var i = 1; i <= 3; i++) {
            res.write('event: tick\nid: $i\ndata: {"n": $i}\n\n');
            await res.flush();
          }
        case '/ws':
          final ws = await WebSocketTransformer.upgrade(req);
          ws.listen((m) => ws.add('echo:$m'));
          return;
        case '/gql':
          res.headers.contentType = ContentType.json;
          final j = jsonDecode(body);
          res.write(jsonEncode({'data': {'echo': j['variables']['v']}}));
      }
      await res.close();
    });
  });

  tearDownAll(() => http.close(force: true));

  final settings = AppSettings();

  Future<ResponseData> send(ApiRequest r, {CookieJar? jar}) async {
    final scope = VariableScope(environment: {'base': base, 'token': 'T0K'});
    final resolved = resolveRequest(r, scope, r.auth);
    final p = await buildHttpRequest(resolved, settings);
    await AuthApplier.apply(resolved.auth, p);
    return HttpEngine().send(p,
        auth: resolved.auth, settings: settings, verifySsl: true, followRedirects: true, timeoutMs: 5000, jar: jar);
  }

  test('HTTP raw JSON body, variables, bearer, cookies', () async {
    final r = ApiRequest.create(RequestType.http)
      ..method = 'POST'
      ..url = '{{base}}/echo?q={{\$randomInt}}'
      ..headers = [KV(key: 'X-Custom', value: 'yes')]
      ..auth = AuthConfig(type: 'bearer', p: {'token': '{{token}}'})
      ..body = BodyConfig(mode: 'raw', rawLang: 'json', raw: '{"a":1}');
    final jar = CookieJar();
    final res = await send(r, jar: jar);
    expect(res.error, isNull);
    expect(res.status, 200);
    final j = jsonDecode(res.bodyText);
    expect(j['headers']['authorization'], 'Bearer T0K');
    expect(j['headers']['content-type'], contains('application/json'));
    expect(j['headers']['x-custom'], 'yes');
    expect(j['body'], '{"a":1}');
    expect(int.tryParse(j['query']['q']), isNotNull);
    expect(jar.cookies.single.name, 'session');
    final res2 = await send(r, jar: jar);
    expect(jsonDecode(res2.bodyText)['headers']['cookie'], 'session=abc123');

    final tests = runTests([
      TestRule(source: 'status', op: 'eq', expected: '200'),
      TestRule(source: 'jsonPath', property: r'$.headers.x-custom', op: 'eq', expected: 'yes'),
      TestRule(source: 'jsonPath', property: 'body', op: 'contains', expected: '"a"'),
      TestRule(source: 'header', property: 'content-type', op: 'contains', expected: 'json'),
      TestRule(source: 'responseTime', op: 'lt', expected: '5000'),
    ], res);
    expect(tests.every((t) => t.passed), isTrue, reason: tests.map((t) => '${t.name}: ${t.message}').join('\n'));
    final ex = runExtracts([VarExtract(path: 'headers.authorization', variable: 'auth')], res);
    expect(ex['environment']!['auth'], 'Bearer T0K');
  });

  test('HTTP urlencoded, multipart, redirects, api key in query', () async {
    final r = ApiRequest.create(RequestType.http)
      ..method = 'POST'
      ..url = '{{base}}/echo'
      ..auth = AuthConfig(type: 'apikey', p: {'key': 'api_key', 'value': 'k1', 'in': 'query'})
      ..body = BodyConfig(mode: 'urlencoded', urlEncoded: [KV(key: 'a b', value: 'c&d')]);
    var res = await send(r);
    var j = jsonDecode(res.bodyText);
    expect(j['body'], 'a+b=c%26d');
    expect(j['query']['api_key'], 'k1');

    final tmp = File('${Directory.systemTemp.path}/courier_upload.txt')..writeAsStringSync('FILEDATA');
    r.body = BodyConfig(mode: 'form-data', formData: [KV(key: 'f', value: tmp.path, type: 'file'), KV(key: 'x', value: '1')]);
    res = await send(r);
    j = jsonDecode(res.bodyText);
    expect(j['headers']['content-type'], startsWith('multipart/form-data; boundary='));
    expect(j['body'], contains('FILEDATA'));
    expect(j['body'], contains('name="x"'));

    final red = ApiRequest.create(RequestType.http)..url = '{{base}}/redirect';
    res = await send(red);
    expect(res.status, 200);
    expect(jsonDecode(res.bodyText)['query']['from'], 'redirect');
  });

  test('Digest auth challenge/response', () async {
    final r = ApiRequest.create(RequestType.http)
      ..url = '{{base}}/digest'
      ..auth = AuthConfig(type: 'digest', p: {'username': 'user', 'password': 'pass'});
    final res = await send(r);
    expect(res.status, 200);
    expect(res.bodyText, 'digest-ok');
  });

  test('Signature auth schemes produce headers', () async {
    for (final a in [
      AuthConfig(type: 'oauth1', p: {'consumerKey': 'ck', 'consumerSecret': 'cs', 'signatureMethod': 'HMAC-SHA256'}),
      AuthConfig(type: 'hawk', p: {'authId': 'id', 'authKey': 'key', 'includePayloadHash': 'true'}),
      AuthConfig(type: 'awsv4', p: {'accessKey': 'AK', 'secretKey': 'SK', 'region': 'eu-west-1', 'service': 'execute-api'}),
      AuthConfig(type: 'akamai', p: {'accessToken': 'a', 'clientToken': 'c', 'clientSecret': 's'}),
      AuthConfig(type: 'jwt', p: {'algorithm': 'HS256', 'secret': 'secret', 'payload': '{"sub":"1"}'}),
      AuthConfig(type: 'basic', p: {'username': 'u', 'password': 'p'}),
    ]) {
      final p = PreparedRequest(method: 'POST', uri: Uri.parse('https://api.example.com/x?y=1'), body: utf8.encode('{}'))
        ..setHeader('Content-Type', 'application/json');
      await AuthApplier.apply(a, p);
      expect(p.header('authorization'), isNotNull, reason: a.type);
    }
    // NTLM messages build
    expect(Ntlm.type1(), startsWith('NTLM '));
    final fakeType2 = base64.encode([
      ...'NTLMSSP'.codeUnits, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x05, 0x82, 0x89, 0xa2, //
      1, 2, 3, 4, 5, 6, 7, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 48, 0, 0, 0,
    ]);
    expect(Ntlm.type3('NTLM $fakeType2', 'user', 'pass', 'DOM', 'WS'), startsWith('NTLM '));
  });

  test('GraphQL body', () async {
    final r = ApiRequest.create(RequestType.graphql)
      ..url = '{{base}}/gql'
      ..body.gqlQuery = 'query(\$v: String) { echo(v: \$v) }'
      ..body.gqlVariables = '{"v": "hi"}';
    final res = await send(r);
    expect(jsonDecode(res.bodyText)['data']['echo'], 'hi');
  });

  test('SOAP envelope with WS-Security', () async {
    final r = ApiRequest.create(RequestType.soap)
      ..url = '{{base}}/echo'
      ..opts['soapAction'] = 'urn:Do'
      ..opts['wsseType'] = 'digest'
      ..opts['wsseUser'] = 'bob'
      ..opts['wssePass'] = 'pw';
    final res = await send(r);
    final j = jsonDecode(res.bodyText);
    expect(j['headers']['content-type'], contains('text/xml'));
    expect(j['body'], contains('wsse:UsernameToken'));
    expect(j['body'], contains('<soap:Header>'));
  });

  test('SSE events', () async {
    final logs = <LogMessage>[];
    final s = SseSession(logs.add, () {});
    final p = PreparedRequest(method: 'GET', uri: Uri.parse('$base/sse'));
    await s.connect(p, settings, true);
    for (var i = 0; i < 50 && !logs.any((l) => l.text.contains('closed')); i++) {
      await Future.delayed(const Duration(milliseconds: 20));
    }
    final events = logs.where((l) => l.dir == MsgDir.received).toList();
    expect(events.length, 3);
    expect(events.first.label, 'tick · id: 1');
    expect(jsonDecode(events.last.text)['n'], 3);
  });

  test('WebSocket echo', () async {
    final logs = <LogMessage>[];
    final s = WebSocketSession(logs.add, () {});
    await s.connect('ws://127.0.0.1:${http.port}/ws', {}, [], settings, true);
    expect(s.connected, isTrue);
    s.send('hello');
    for (var i = 0; i < 50 && !logs.any((l) => l.dir == MsgDir.received); i++) {
      await Future.delayed(const Duration(milliseconds: 20));
    }
    expect(logs.firstWhere((l) => l.dir == MsgDir.received).text, 'echo:hello');
    await s.close();
  });

  test('proto parse + wire codec round trip', () {
    final reg = ProtoParser.parseAll({'demo.proto': demoProto});
    expect(reg.methodPaths, contains('demo.Greeter/SayHello'));
    final codec = WireCodec(reg);
    final input = {
      'name': 'Ann',
      'nums': [1, -2, 300],
      'scores': {'x': 5},
      'mood': 'HAPPY',
      'inner': {'flag': true},
      'at': '2024-01-02T03:04:05.000Z',
      'delta': -7,
      'b': 42,
      'ratio': 0.5,
      'blob': base64.encode([1, 2, 3]),
    };
    final bytes = codec.encode('demo.HelloRequest', input);
    final out = codec.decode('demo.HelloRequest', bytes) as Map;
    expect(out['name'], 'Ann');
    expect(out['nums'], [1, -2, 300]);
    expect(out['scores'], {'x': 5});
    expect(out['mood'], 'HAPPY');
    expect(out['inner'], {'flag': true});
    expect(out['at'], '2024-01-02T03:04:05.000Z');
    expect(out['delta'], -7);
    expect(out['b'], 42);
    expect(out.containsKey('a'), isFalse);
    expect(out['ratio'], 0.5);
    expect(out['blob'], base64.encode([1, 2, 3]));
    expect(reg.example('demo.HelloRequest'), isA<Map>());
  });

  test('gRPC unary, server streaming, bidi and reflection against a live server', () async {
    final reg = ProtoParser.parseAll({'demo.proto': demoProto});
    final codec = WireCodec(reg);
    final server = g.Server.create(services: [_DemoService(codec), _ReflectionService()]);
    await server.serve(address: InternetAddress.loopbackIPv4, port: 0);
    final target = GrpcTarget.parse('127.0.0.1:${server.port}');
    try {
      final e = GrpcEngine();
      final unary = e.start(target, 'demo.Greeter/SayHello',
          verifySsl: true, metadata: {'x-who': 'me'}, firstMessage: codec.encode('demo.HelloRequest', {'name': 'Bob'}));
      final reply = codec.decode('demo.HelloReply', await unary.single) as Map;
      expect(reply['message'], 'Hello Bob (me)');
      await e.close();

      final e2 = GrpcEngine();
      final stream = e2.start(target, 'demo.Greeter/Countdown',
          verifySsl: true, metadata: {}, firstMessage: codec.encode('demo.HelloRequest', {'name': 'x'}));
      final counts = await stream.map((b) => (codec.decode('demo.HelloReply', b) as Map)['count']).toList();
      expect(counts, [3, 2, 1]);
      await e2.close();

      final e3 = GrpcEngine();
      final chat = e3.start(target, 'demo.Greeter/Chat', verifySsl: true, metadata: {}, keepOpen: true);
      final got = <String>[];
      final done = chat.listen((b) => got.add((codec.decode('demo.HelloReply', b) as Map)['message'])).asFuture();
      e3.sendMessage(codec.encode('demo.HelloRequest', {'name': 'one'}));
      e3.sendMessage(codec.encode('demo.HelloRequest', {'name': 'two'}));
      await e3.halfClose();
      await done;
      expect(got, ['re:one', 're:two']);
      await e3.close();

      final reflected = await GrpcEngine().reflect(target, verifySsl: true);
      expect(reflected.methodPaths, contains('demo.Greeter/Countdown'));
      final m = reflected.findMethod('demo.Greeter/Countdown')!.$2;
      expect(m.serverStreaming, isTrue);
      final rc = WireCodec(reflected);
      expect((rc.decode('demo.HelloRequest', codec.encode('demo.HelloRequest', {'mood': 'SAD'})) as Map)['mood'], 'SAD');
    } finally {
      await server.shutdown();
    }
  });

  test('WSDL parsing', () {
    const wsdl = '''<?xml version="1.0"?>
<definitions xmlns="http://schemas.xmlsoap.org/wsdl/" xmlns:soap="http://schemas.xmlsoap.org/wsdl/soap/"
  xmlns:tns="http://example.com/calc" xmlns:xs="http://www.w3.org/2001/XMLSchema" targetNamespace="http://example.com/calc">
  <types><xs:schema targetNamespace="http://example.com/calc" elementFormDefault="qualified">
    <xs:element name="Add"><xs:complexType><xs:sequence>
      <xs:element name="a" type="xs:int"/><xs:element name="b" type="xs:int"/>
    </xs:sequence></xs:complexType></xs:element>
  </xs:schema></types>
  <message name="AddIn"><part name="parameters" element="tns:Add"/></message>
  <portType name="CalcPort"><operation name="Add"><input message="tns:AddIn"/></operation></portType>
  <binding name="CalcBinding" type="tns:CalcPort"><soap:binding transport="http://schemas.xmlsoap.org/soap/http"/>
    <operation name="Add"><soap:operation soapAction="http://example.com/calc/Add"/></operation></binding>
  <service name="Calc"><port name="CalcSoap" binding="tns:CalcBinding"><soap:address location="http://example.com/calc.asmx"/></port></service>
</definitions>''';
    final ops = parseWsdl(wsdl);
    expect(ops.single.name, 'Add');
    expect(ops.single.soapAction, 'http://example.com/calc/Add');
    expect(ops.single.endpoint, 'http://example.com/calc.asmx');
    expect(ops.single.envelope, contains('<tns:a>?</tns:a>'));
  });

  test('cURL import and code generation', () async {
    final r = parseCurl('''curl -X POST 'https://api.example.com/v1/items?x=1' \\
      -H 'Content-Type: application/json' -H "Authorization: Bearer abc" \\
      --data-raw '{"name":"it'"'"'s"}' -k''');
    expect(r.method, 'POST');
    expect(r.url, 'https://api.example.com/v1/items?x=1');
    expect(r.headers.length, 2);
    expect(r.body.mode, 'raw');
    expect(r.body.raw, '{"name":"it\'s"}');
    expect(r.params.single.key, 'x');
    expect(r.opts['verifySsl'], 'false');
    final p = await buildHttpRequest(r, AppSettings(sendNoCacheHeader: false));
    for (final lang in codegenLanguages.keys) {
      expect(generateCode(lang, p, r), isNotEmpty);
    }
    final form = parseCurl("curl https://x.test/u -F 'file=@/tmp/a.png' -F 'name=n' -u me:pw");
    expect(form.body.mode, 'form-data');
    expect(form.body.formData.first.type, 'file');
    expect(form.auth.type, 'basic');
  });

  test('Postman v2.1 import/export round trip', () {
    final pm = {
      'info': {'name': 'Shop', 'schema': 'https://schema.getpostman.com/json/collection/v2.1.0/collection.json'},
      'auth': {'type': 'bearer', 'bearer': [{'key': 'token', 'value': '{{tok}}'}]},
      'variable': [{'key': 'host', 'value': 'shop.test'}],
      'item': [
        {
          'name': 'Orders',
          'item': [
            {
              'name': 'Create order',
              'request': {
                'method': 'POST',
                'url': {'raw': 'https://{{host}}/orders?dry=1', 'query': [{'key': 'dry', 'value': '1'}]},
                'header': [{'key': 'X-A', 'value': '1', 'disabled': true}],
                'body': {'mode': 'raw', 'raw': '{"a":1}', 'options': {'raw': {'language': 'json'}}},
              },
            },
          ],
        },
      ],
    };
    final res = importAny(jsonEncode(pm));
    final col = res.collections.single;
    expect(col.name, 'Shop');
    expect(col.auth.type, 'bearer');
    expect(col.variables.single.key, 'host');
    final folder = col.children.single as Folder;
    final req = folder.children.single as ApiRequest;
    expect(req.method, 'POST');
    expect(req.headers.single.enabled, isFalse);
    expect(req.body.rawLang, 'json');
    final back = exportPostmanCollection(col);
    expect(importAny(jsonEncode(back)).collections.single.children.length, 1);

    final env = importAny(jsonEncode({'name': 'Dev', 'values': [{'key': 'a', 'value': 'b', 'enabled': true}]}));
    expect(env.environments.single.variables.single.value, 'b');
  });

  test('JSON path', () {
    final j = {
      'a': {'b': [{'c': 1}, {'c': 2}]},
      'x y': 3,
    };
    expect(jsonPathQuery(j, r'$.a.b[1].c'), 2);
    expect(jsonPathQuery(j, 'a.b[-1].c'), 2);
    expect(jsonPathQuery(j, r"$['x y']"), 3);
    expect(jsonPathQuery(j, r'$.a.b[*].c'), [1, 2]);
    expect(jsonPathQuery(j, r'$..c'), [1, 2]);
    expect(jsonPathQuery(j, 'a.b.length'), 2);
    expect(identical(jsonPathQuery(j, 'nope'), noValue), isTrue);
  });

  test('Kafka record batch encoding and CRC', () {
    expect(crc32c(utf8.encode('123456789')), 0xE3069283);
    expect(murmur2(utf8.encode('21')) & 0x7fffffff, isNonNegative);
    final batch = KafkaClient.encodeBatch([
      (utf8.encode('k'), utf8.encode('v'), [MapEntry('h', utf8.encode('1'))]),
    ]);
    final recs = KafkaClient.decodeBatches('t', 0, batch);
    expect(utf8.decode(recs.single.value!), 'v');
    expect(utf8.decode(recs.single.key!), 'k');
    expect(recs.single.headers.single.key, 'h');
  });

  final kafka = Platform.environment['KAFKA_BOOTSTRAP'];
  test('Kafka produce/consume against live broker', () async {
    final c = KafkaClient(KafkaConfig(bootstrap: KafkaConfig.parseServers(kafka!)));
    final topic = 'courier-test-${DateTime.now().millisecondsSinceEpoch}';
    // Metadata request with auto-create enabled brokers creates the topic.
    for (var i = 0; i < 3; i++) {
      try {
        await c.produce(topic, value: utf8.encode('warmup'));
        break;
      } catch (_) {
        await Future.delayed(const Duration(seconds: 1));
      }
    }
    final r1 = await c.produce(topic, key: utf8.encode('k1'), value: utf8.encode('{"n":1}'), headers: [MapEntry('src', utf8.encode('t'))]);
    expect(r1.offset, greaterThanOrEqualTo(0));
    var active = true;
    final got = <KafkaRecord>[];
    final sub = c.consume(topic, from: 'earliest', active: () => active).listen(got.add);
    for (var i = 0; i < 100 && got.length < 2; i++) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    active = false;
    await sub.cancel();
    expect(got.map((r) => utf8.decode(r.value!)), containsAll(['warmup', '{"n":1}']));
    final md = await c.metadata();
    expect(md.topics.containsKey(topic), isTrue);
    await c.close();
  }, skip: kafka == null ? 'Set KAFKA_BOOTSTRAP to run' : false);
}

class _DemoService extends g.Service {
  final WireCodec codec;
  _DemoService(this.codec) {
    $addMethod(g.ServiceMethod<List<int>, List<int>>('SayHello', (g.ServiceCall call, Future<List<int>> req) async {
      final m = codec.decode('demo.HelloRequest', await req) as Map;
      return codec.encode('demo.HelloReply', {'message': 'Hello ${m['name']} (${call.clientMetadata?['x-who']})'});
    }, false, false, (b) => b, (b) => b));
    $addMethod(g.ServiceMethod<List<int>, List<int>>('Countdown', (g.ServiceCall call, Future<List<int>> req) async* {
      await req;
      for (var i = 3; i > 0; i--) {
        yield codec.encode('demo.HelloReply', {'count': i});
      }
    }, false, true, (b) => b, (b) => b));
    $addMethod(g.ServiceMethod<List<int>, List<int>>('Chat', (g.ServiceCall call, Stream<List<int>> reqs) async* {
      await for (final r in reqs) {
        yield codec.encode('demo.HelloReply', {'message': 're:${(codec.decode('demo.HelloRequest', r) as Map)['name']}'});
      }
    }, true, true, (b) => b, (b) => b));
  }
  @override
  String get $name => 'demo.Greeter';
}

/// Minimal reflection server built with the same dynamic codec.
class _ReflectionService extends g.Service {
  _ReflectionService() {
    final meta = WireCodec(grpcMetaRegistry, emitDefaults: false);
    final fd = meta.encode('google.protobuf.FileDescriptorProto', {
      'name': 'demo.proto',
      'package': 'demo',
      'syntax': 'proto3',
      'enum_type': [
        {
          'name': 'Mood',
          'value': [
            {'name': 'MOOD_UNKNOWN', 'number': 0},
            {'name': 'HAPPY', 'number': 1},
            {'name': 'SAD', 'number': 2},
          ],
        },
      ],
      'message_type': [
        {
          'name': 'HelloRequest',
          'field': [
            {'name': 'name', 'number': 1, 'label': 1, 'type': 9},
            {'name': 'mood', 'number': 4, 'label': 1, 'type': 14, 'type_name': '.demo.Mood'},
          ],
        },
        {
          'name': 'HelloReply',
          'field': [
            {'name': 'message', 'number': 1, 'label': 1, 'type': 9},
            {'name': 'count', 'number': 2, 'label': 1, 'type': 5},
          ],
        },
      ],
      'service': [
        {
          'name': 'Greeter',
          'method': [
            {'name': 'SayHello', 'input_type': '.demo.HelloRequest', 'output_type': '.demo.HelloReply'},
            {'name': 'Countdown', 'input_type': '.demo.HelloRequest', 'output_type': '.demo.HelloReply', 'server_streaming': true},
          ],
        },
      ],
    });
    $addMethod(g.ServiceMethod<List<int>, List<int>>('ServerReflectionInfo', (g.ServiceCall call, Stream<List<int>> reqs) async* {
      await for (final r in reqs) {
        final q = meta.decode('reflection.ServerReflectionRequest', r) as Map;
        if (q.containsKey('list_services')) {
          yield meta.encode('reflection.ServerReflectionResponse', {
            'list_services_response': {
              'service': [
                {'name': 'demo.Greeter'},
                {'name': 'grpc.reflection.v1.ServerReflection'},
              ],
            },
          });
        } else {
          yield meta.encode('reflection.ServerReflectionResponse', {
            'file_descriptor_response': {'file_descriptor_proto': [base64.encode(fd)]},
          });
        }
      }
    }, true, true, (b) => b, (b) => b));
  }
  @override
  String get $name => 'grpc.reflection.v1.ServerReflection';
}
