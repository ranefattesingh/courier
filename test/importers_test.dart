import 'dart:convert';

import 'package:courier/core/import_insomnia.dart';
import 'package:courier/core/importers.dart';
import 'package:courier/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

List<ApiRequest> allRequests(Folder f) => [
      for (final c in f.children)
        if (c is Folder) ...allRequests(c) else c as ApiRequest,
    ];

void main() {
  test('Insomnia v4 export: folders, auth, bodies, envs, gRPC, WebSocket, templates', () {
    final export = {
      '_type': 'export',
      '__export_format': 4,
      'resources': [
        {'_id': 'wrk_1', '_type': 'workspace', 'parentId': null, 'name': 'Orders API'},
        {'_id': 'env_base', '_type': 'environment', 'parentId': 'wrk_1', 'name': 'Base Environment', 'data': {'host': 'api.test', 'nested': {'key': 'v'}}},
        {'_id': 'env_dev', '_type': 'environment', 'parentId': 'env_base', 'name': 'Dev', 'data': {'token': 'dev-123'}},
        {'_id': 'env_prod', '_type': 'environment', 'parentId': 'env_base', 'name': 'Prod', 'data': {'token': 'prod-456'}},
        {
          '_id': 'fld_1', '_type': 'request_group', 'parentId': 'wrk_1', 'name': 'Orders', 'metaSortKey': -10,
          'environment': {'orderPath': '/orders'},
          'headers': [{'name': 'X-Team', 'value': 'payments'}],
          'authentication': {'type': 'bearer', 'token': '{{ _.token }}'},
        },
        {'_id': 'fld_2', '_type': 'request_group', 'parentId': 'fld_1', 'name': 'Admin', 'metaSortKey': 5},
        {
          '_id': 'req_1', '_type': 'request', 'parentId': 'fld_1', 'name': 'Create order', 'metaSortKey': 2,
          'method': 'POST', 'url': 'https://{{ _.host }}{{ _.orderPath }}',
          'body': {'mimeType': 'application/json', 'text': '{"id": "{% uuid \'v4\' %}", "at": "{% now \'iso-8601\', \'\' %}"}'},
          'parameters': [{'name': 'dry', 'value': '1'}, {'name': 'off', 'value': 'x', 'disabled': true}],
          'headers': [{'name': 'Content-Type', 'value': 'application/json'}],
          'authentication': {},
        },
        {
          '_id': 'req_2', '_type': 'request', 'parentId': 'fld_1', 'name': 'Upload', 'metaSortKey': 1,
          'method': 'POST', 'url': 'https://{{ _.host }}/upload',
          'body': {'mimeType': 'multipart/form-data', 'params': [{'name': 'file', 'type': 'file', 'fileName': '/tmp/a.png'}, {'name': 'note', 'value': 'hi'}]},
          'authentication': {'type': 'basic', 'username': 'u', 'password': 'p'},
        },
        {
          '_id': 'req_3', '_type': 'request', 'parentId': 'fld_2', 'name': 'GraphQL', 'method': 'POST', 'url': 'https://{{ _.host }}/graphql',
          'body': {'mimeType': 'application/graphql', 'text': jsonEncode({'query': 'query { me { id } }', 'variables': {'a': 1}})},
          'authentication': {'type': 'oauth2', 'grantType': 'authorization_code', 'usePkce': true, 'authorizationUrl': 'https://auth/a', 'accessTokenUrl': 'https://auth/t', 'clientId': 'cid'},
        },
        {
          '_id': 'req_4', '_type': 'request', 'parentId': 'wrk_1', 'name': 'Form', 'method': 'POST', 'url': 'https://x.test/f',
          'body': {'mimeType': 'application/x-www-form-urlencoded', 'params': [{'name': 'a', 'value': '1'}]},
          'authentication': {'type': 'iam', 'accessKeyId': 'AK', 'secretAccessKey': 'SK', 'region': 'eu-west-1', 'service': 's3'},
        },
        {'_id': 'pf_1', '_type': 'proto_file', 'parentId': 'wrk_1', 'name': 'greeter.proto', 'protoText': 'syntax = "proto3";'},
        {
          '_id': 'greq_1', '_type': 'grpc_request', 'parentId': 'wrk_1', 'name': 'SayHello', 'url': 'grpcs://api.test:443',
          'protoFileId': 'pf_1', 'protoMethodName': '/helloworld.Greeter/SayHello', 'body': {'text': '{"name": "x"}'},
          'metadata': [{'name': 'x-md', 'value': '1'}],
        },
        {'_id': 'ws_1', '_type': 'websocket_request', 'parentId': 'wrk_1', 'name': 'Live', 'url': 'wss://api.test/ws', 'headers': [], 'authentication': {}},
        {'_id': 'wsp_1', '_type': 'websocket_payload', 'parentId': 'ws_1', 'value': '{"subscribe": "orders"}'},
        {'_id': 'jar_1', '_type': 'cookie_jar', 'parentId': 'wrk_1'},
      ],
    };
    final res = importAny(jsonEncode(export));
    final col = res.collections.single;
    expect(col.name, 'Orders API');
    expect(col.variables.map((v) => v.key), containsAll(['host', 'nested.key', 'orderPath']));
    expect(res.environments.map((e) => e.name), ['Dev', 'Prod']);
    expect(res.environments.first.variables.single.value, 'dev-123');

    final orders = col.children.first as Folder;
    expect(orders.name, 'Orders');
    expect(orders.auth.type, 'bearer');
    expect(orders.auth.get('token'), '{{token}}');
    // sorted by metaSortKey: Upload(1), Create order(2), Admin(5)
    expect(orders.children.map((n) => n.name).toList(), ['Upload', 'Create order', 'Admin']);

    final create = orders.children[1] as ApiRequest;
    expect(create.url, 'https://{{host}}{{orderPath}}?dry=1');
    expect(create.params.where((p) => p.enabled).single.key, 'dry');
    expect(create.params.where((p) => !p.enabled).single.key, 'off');
    expect(create.auth.type, 'inherit');
    expect(create.body.rawLang, 'json');
    expect(create.body.raw, contains(r'{{$guid}}'));
    expect(create.body.raw, contains(r'{{$isoTimestamp}}'));
    expect(create.headers.any((h) => h.key == 'X-Team'), isTrue, reason: 'folder headers are inherited');

    final upload = orders.children[0] as ApiRequest;
    expect(upload.body.mode, 'form-data');
    expect(upload.body.formData.first.type, 'file');
    expect(upload.body.formData.first.value, '/tmp/a.png');
    expect(upload.auth.type, 'basic');

    final gql = (orders.children[2] as Folder).children.single as ApiRequest;
    expect(gql.type, RequestType.graphql);
    expect(gql.body.gqlQuery, 'query { me { id } }');
    expect(jsonDecode(gql.body.gqlVariables), {'a': 1});
    expect(gql.auth.get('grantType'), 'authorization_code_pkce');
    expect(gql.auth.get('tokenUrl'), 'https://auth/t');

    final all = allRequests(col);
    final form = all.firstWhere((r) => r.name == 'Form');
    expect(form.body.mode, 'urlencoded');
    expect(form.auth.type, 'awsv4');
    expect(form.auth.get('service'), 's3');

    final grpc = all.firstWhere((r) => r.type == RequestType.grpc);
    expect(grpc.opt('grpcMethod'), 'helloworld.Greeter/SayHello');
    expect(grpc.protoFiles.single.name, 'greeter.proto');
    expect(grpc.opt('grpcReflection'), 'false');
    expect(grpc.opt('grpcTls'), 'true');
    expect(grpc.headers.single.key, 'x-md');

    final ws = all.firstWhere((r) => r.type == RequestType.websocket);
    expect(ws.message, '{"subscribe": "orders"}');
  });

  test('Insomnia v5 YAML collection', () {
    const yaml = '''
type: collection.insomnia.rest/5.0
name: Inventory
meta:
  id: wrk_abc
collection:
  - name: Items
    meta:
      id: fld_1
      sortKey: -1
    authentication:
      type: apikey
      key: X-API-Key
      value: "{{ _.apiKey }}"
      addTo: header
    children:
      - url: "{{ _.base }}/items"
        name: List items
        meta:
          id: req_1
          sortKey: 1
        method: GET
        parameters:
          - name: limit
            value: "10"
        headers:
          - name: Accept
            value: application/json
      - url: "{{ _.base }}/items"
        name: Add item
        meta:
          id: req_2
          sortKey: 2
        method: POST
        body:
          mimeType: application/xml
          text: <item><name>pen</name></item>
        authentication:
          type: digest
          username: u
          password: p
  - url: https://example.com/health
    name: Health
    method: HEAD
    meta:
      id: req_3
environments:
  name: Base Environment
  data:
    base: https://inv.test
    apiKey: k-1
  subEnvironments:
    - name: Staging
      data:
        base: https://staging.inv.test
''';
    final res = importAny(yaml);
    final col = res.collections.single;
    expect(col.name, 'Inventory');
    expect(col.variables.map((v) => v.key), containsAll(['base', 'apiKey']));
    expect(res.environments.single.name, 'Staging');
    final items = col.children.first as Folder;
    expect(items.auth.type, 'apikey');
    expect(items.auth.get('value'), '{{apiKey}}');
    final list = items.children.first as ApiRequest;
    expect(list.url, '{{base}}/items?limit=10');
    final add = items.children[1] as ApiRequest;
    expect(add.body.rawLang, 'xml');
    expect(add.auth.type, 'digest');
    expect((col.children[1] as ApiRequest).method, 'HEAD');
  });

  test('Insomnia v5 environment-only file', () {
    final res = importAny('type: environment.insomnia.rest/5.0\nname: Shared\nenvironments:\n  name: Base\n  data:\n    a: "1"\n');
    expect(res.collections, isEmpty);
    expect(res.environments.single.name, 'Shared');
    expect(res.environments.single.variables.single.key, 'a');
  });

  test('Insomnia template conversion', () {
    expect(convertInsomniaTemplate('{{ _.a.b }}/{{ _["x y"] }}/{{ plain }}'), '{{a.b}}/{{x y}}/{{plain}}');
    expect(convertInsomniaTemplate("{% now 'millis' %}"), r'{{$timestampMs}}');
    expect(convertInsomniaTemplate("{% now 'unix', '' %}"), r'{{$timestamp}}');
  });

  test('Postman v1 collection (classic Chrome app format)', () {
    final v1 = {
      'id': 'c1',
      'name': 'Legacy API',
      'order': ['r3'],
      'folders_order': ['f1'],
      'folders': [
        {'id': 'f1', 'name': 'Users', 'order': ['r1'], 'folders_order': ['f2']},
        {'id': 'f2', 'name': 'Admin', 'order': ['r2'], 'folders_order': []},
      ],
      'requests': [
        {
          'id': 'r1', 'name': 'Create user', 'method': 'POST', 'url': 'http://{{host}}/users?x=1',
          'headers': 'Content-Type: application/json\n//X-Off: 1\n', 'dataMode': 'raw', 'rawModeData': '{"a": 1}',
          'currentHelper': 'basicAuth', 'helperAttributes': {'username': 'u', 'password': 'p'},
        },
        {
          'id': 'r2', 'name': 'Upload avatar', 'method': 'PUT', 'url': 'http://{{host}}/avatar',
          'dataMode': 'params', 'data': [{'key': 'file', 'value': 'a.png', 'type': 'file', 'enabled': true}, {'key': 'n', 'value': '1', 'type': 'text', 'enabled': false}],
        },
        {'id': 'r3', 'name': 'Ping', 'method': 'GET', 'url': 'http://{{host}}/ping', 'headers': ''},
      ],
    };
    final col = importAny(jsonEncode(v1)).collections.single;
    expect(col.name, 'Legacy API');
    final users = col.children.first as Folder;
    expect(users.name, 'Users');
    final admin = users.children.firstWhere((n) => n is Folder) as Folder;
    expect(admin.name, 'Admin');
    final create = users.children.whereType<ApiRequest>().single;
    expect(create.body.rawLang, 'json');
    expect(create.headers.length, 2);
    expect(create.headers[1].enabled, isFalse);
    expect(create.auth.type, 'basic');
    expect(create.params.single.key, 'x');
    final upload = admin.children.single as ApiRequest;
    expect(upload.body.mode, 'form-data');
    expect(upload.body.formData[1].enabled, isFalse);
    expect((col.children.last as ApiRequest).name, 'Ping');
  });

  test('Postman data dump', () {
    final dump = {
      'version': 1,
      'collections': [
        {'info': {'name': 'V2'}, 'item': [{'name': 'a', 'request': {'method': 'GET', 'url': 'http://a'}}]},
        {'id': 'x', 'name': 'V1', 'order': ['r'], 'requests': [{'id': 'r', 'name': 'r', 'method': 'GET', 'url': 'http://r'}]},
      ],
      'environments': [{'name': 'Dev', 'values': [{'key': 'k', 'value': 'v', 'enabled': true}]}],
      'globals': [{'key': 'g', 'value': '1', 'enabled': true}],
    };
    final res = importAny(jsonEncode(dump));
    expect(res.collections.map((c) => c.name), ['V2', 'V1']);
    expect(res.environments.map((e) => e.name), ['Dev', 'Postman Globals']);
  });

  test('Courier export round trip keeps every protocol', () {
    final col = Folder(id: newId(), name: 'All', children: [
      for (final t in RequestType.values) ApiRequest.create(t),
      Folder(id: newId(), name: 'Sub', children: [Folder(id: newId(), name: 'SubSub', children: [ApiRequest.create(RequestType.kafka)])]),
    ]);
    final env = Environment(id: newId(), name: 'Dev', variables: [KV(key: 'a', value: 'b', type: 'secret')]);
    final res = importAny(jsonEncode(exportCourier(collections: [col], environments: [env])));
    final back = res.collections.single;
    expect(allRequests(back).map((r) => r.type).toSet(), RequestType.values.toSet());
    expect(((back.children.last as Folder).children.single as Folder).name, 'SubSub');
    expect(back.id, isNot(col.id), reason: 'imports get fresh ids');
    expect(res.environments.single.variables.single.type, 'secret');
  });

  test('unknown input is rejected with a helpful message', () {
    expect(() => importAny('hello world'), throwsA(isA<FormatException>()));
    expect(() => importAny('{"foo": 1}'), throwsA(isA<FormatException>()));
  });
}
