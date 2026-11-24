import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import '../core/graphql_schema.dart';
import '../core/grpc/grpc_engine.dart';
import '../core/grpc/proto_schema.dart';
import '../core/http_engine.dart';
import '../core/sessions.dart';
import '../core/variables.dart';
import '../core/wsdl.dart';
import '../models/models.dart';

/// One open editor tab. Holds a draft copy of a request plus its runtime state.
class RequestTab extends ChangeNotifier {
  final String id = newId();
  ApiRequest draft;

  /// Id of the saved request in the tree, or null for an unsaved request.
  String? sourceId;
  bool dirty = false;

  ResponseData? response;
  bool sending = false;
  HttpEngine? httpEngine;

  final List<LogMessage> logs = [];
  StreamSession? session;

  // gRPC
  ProtoRegistry? registry;
  String? registryError;
  GrpcEngine? grpcEngine;
  bool grpcStreamOpen = false;

  GqlSchema? gqlSchema;
  List<SoapOperation> soapOps = [];
  List<String> kafkaTopics = [];

  RequestTab(this.draft, {this.sourceId});

  void addLog(LogMessage m) {
    logs.add(m);
    if (logs.length > 5000) logs.removeRange(0, logs.length - 5000);
    notifyListeners();
  }

  void touch() => notifyListeners();

  Future<void> disposeRuntime() async {
    httpEngine?.cancel();
    await session?.close();
    await grpcEngine?.close();
  }
}

class ConsoleEntry {
  final DateTime time = DateTime.now();
  final String method;
  final String url;
  final int? status;
  final int timeMs;
  final String? error;
  final List<MapEntry<String, String>> requestHeaders;
  final String requestBody;
  final List<MapEntry<String, String>> responseHeaders;
  final String responseBody;
  ConsoleEntry(this.method, this.url, this.status, this.timeMs, this.error, this.requestHeaders, this.requestBody,
      this.responseHeaders, this.responseBody);
}

class AppState extends ChangeNotifier {
  AppSettings settings = AppSettings();
  List<Folder> collections = [];
  List<Environment> environments = [];
  String? activeEnvId;
  List<KV> globals = [];
  List<HistoryEntry> history = [];
  CookieJar cookieJar = CookieJar();
  final List<ConsoleEntry> console = [];

  final List<RequestTab> tabs = [];
  int activeTab = -1;

  /// Sidebar section: collections | environments | history
  String sidebarSection = 'collections';
  String? selectedNodeId;

  Directory? _dir;
  Timer? _saveTimer;
  bool loaded = false;

  RequestTab? get currentTab => activeTab >= 0 && activeTab < tabs.length ? tabs[activeTab] : null;
  Environment? get activeEnv => environments.where((e) => e.id == activeEnvId).firstOrNull;

  // ------------------------------------------------------------------ persistence
  Future<void> load({Directory? dir}) async {
    _dir = dir ?? Directory('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}courier');
    await _dir!.create(recursive: true);
    final ws = _file('workspace.json');
    if (await ws.exists()) {
      try {
        final j = jsonDecode(await ws.readAsString()) as Map<String, dynamic>;
        collections = (j['collections'] as List? ?? []).map((e) => Folder.fromJson(Map<String, dynamic>.from(e as Map))).toList();
        environments = (j['environments'] as List? ?? []).map((e) => Environment.fromJson(e as Map)).toList();
        activeEnvId = j['activeEnvId'] as String?;
        globals = KV.listFrom(j['globals']);
        cookieJar = CookieJar((j['cookies'] as List? ?? []).map((e) => StoredCookie.fromJson(e as Map)).toList());
      } catch (e) {
        await ws.copy('${ws.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}');
      }
    } else {
      _seed();
    }
    final st = _file('settings.json');
    if (await st.exists()) {
      try {
        settings = AppSettings.fromJson(jsonDecode(await st.readAsString()) as Map);
      } catch (_) {}
    }
    final hist = _file('history.json');
    if (await hist.exists()) {
      try {
        history = (jsonDecode(await hist.readAsString()) as List).map((e) => HistoryEntry.fromJson(e as Map)).toList();
      } catch (_) {}
    }
    final open = _file('tabs.json');
    if (await open.exists()) {
      try {
        final j = jsonDecode(await open.readAsString()) as Map;
        for (final t in (j['tabs'] as List? ?? [])) {
          final tab = RequestTab(ApiRequest.fromJson(Map<String, dynamic>.from(t['draft'] as Map)), sourceId: t['sourceId'] as String?)
            ..dirty = t['dirty'] == true;
          if (tab.sourceId != null && findNode(tab.sourceId!) == null) tab.sourceId = null;
          tabs.add(tab);
        }
        activeTab = (j['active'] as int? ?? 0).clamp(-1, tabs.length - 1);
      } catch (_) {}
    }
    if (tabs.isEmpty) newTab(RequestType.http);
    loaded = true;
    notifyListeners();
  }

  File _file(String name) => File('${_dir!.path}${Platform.pathSeparator}$name');

  void _seed() {
    final demo = Folder(id: newId(), name: 'Sample API Collection', expanded: true, auth: AuthConfig(type: 'none'), variables: [
      KV(key: 'baseUrl', value: 'https://httpbin.org'),
    ]);
    final users = Folder(id: newId(), name: 'Users Service', expanded: true);
    users.children.addAll([
      ApiRequest(id: newId(), name: 'Get with query params', method: 'GET', url: '{{baseUrl}}/get?page=1&limit=10', params: [
        KV(key: 'page', value: '1'),
        KV(key: 'limit', value: '10'),
      ], tests: [
        TestRule(source: 'status', op: 'eq', expected: '200'),
        TestRule(source: 'jsonPath', property: r'$.args.page', op: 'eq', expected: '1'),
      ]),
      ApiRequest(
        id: newId(),
        name: 'Create user (JSON)',
        method: 'POST',
        url: '{{baseUrl}}/post',
        headers: [KV(key: 'X-Request-Id', value: '{{\$guid}}')],
        body: BodyConfig(mode: 'raw', rawLang: 'json', raw: '{\n  "name": "{{\$randomFullName}}",\n  "email": "{{\$randomEmail}}"\n}'),
        extracts: [VarExtract(source: 'jsonPath', path: r'$.json.email', variable: 'lastEmail', scope: 'environment')],
      ),
    ]);
    final auth = Folder(id: newId(), name: 'Auth Examples');
    auth.children.addAll([
      ApiRequest(id: newId(), name: 'Basic auth', url: '{{baseUrl}}/basic-auth/user/passwd',
          auth: AuthConfig(type: 'basic', p: {'username': 'user', 'password': 'passwd'})),
      ApiRequest(id: newId(), name: 'Digest auth', url: '{{baseUrl}}/digest-auth/auth/user/passwd',
          auth: AuthConfig(type: 'digest', p: {'username': 'user', 'password': 'passwd'})),
      ApiRequest(id: newId(), name: 'Bearer token', url: '{{baseUrl}}/bearer',
          auth: AuthConfig(type: 'bearer', p: {'token': '{{token}}'})),
    ]);
    final gql = ApiRequest.create(RequestType.graphql, name: 'Countries (GraphQL)')
      ..url = 'https://countries.trevorblades.com/graphql'
      ..body.gqlQuery = 'query Country(\$code: ID!) {\n  country(code: \$code) {\n    name\n    capital\n    currency\n  }\n}'
      ..body.gqlVariables = '{\n  "code": "IN"\n}';
    final ws = ApiRequest.create(RequestType.websocket, name: 'Echo WebSocket')
      ..url = 'wss://echo.websocket.org'
      ..message = '{"hello": "world"}';
    final sse = ApiRequest.create(RequestType.sse, name: 'SSE stream')..url = 'https://sse.dev/test';
    final soap = ApiRequest.create(RequestType.soap, name: 'Number to words (SOAP)')
      ..url = 'https://www.dataaccess.com/webservicesserver/NumberConversion.wso'
      ..opts['soapAction'] = ''
      ..body.raw = '<?xml version="1.0" encoding="utf-8"?>\n'
          '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">\n'
          '  <soap:Body>\n'
          '    <NumberToWords xmlns="http://www.dataaccess.com/webservicesserver/">\n'
          '      <ubiNum>500</ubiNum>\n'
          '    </NumberToWords>\n'
          '  </soap:Body>\n'
          '</soap:Envelope>';
    final grpc = ApiRequest.create(RequestType.grpc, name: 'gRPC call')
      ..url = 'grpcb.in:9000'
      ..opts['grpcReflection'] = 'true';
    final kafka = ApiRequest.create(RequestType.kafka, name: 'Kafka orders topic')
      ..opts['kafkaTopic'] = 'orders'
      ..opts['kafkaKey'] = 'order-{{\$randomInt}}'
      ..message = '{\n  "orderId": "{{\$guid}}",\n  "amount": {{\$randomPrice}}\n}';
    final mqtt = ApiRequest.create(RequestType.mqtt, name: 'MQTT public broker')
      ..url = 'mqtt://test.mosquitto.org:1883'
      ..opts['mqttTopic'] = 'courier/demo'
      ..subscriptions = [KV(key: 'courier/demo', value: '0')]
      ..message = 'hello from Courier';
    final protocols = Folder(id: newId(), name: 'Protocols');
    protocols.children.addAll([gql, ws, sse, soap, grpc, kafka, mqtt]);
    demo.children.addAll([users, auth, protocols]);
    collections = [demo];
    environments = [
      Environment(id: newId(), name: 'Development', variables: [
        KV(key: 'baseUrl', value: 'https://httpbin.org'),
        KV(key: 'token', value: 'dev-token-123', type: 'secret'),
      ]),
      Environment(id: newId(), name: 'Production', variables: [
        KV(key: 'baseUrl', value: 'https://httpbin.org'),
        KV(key: 'token', value: 'prod-token-456', type: 'secret'),
      ]),
    ];
    activeEnvId = environments.first.id;
  }

  void scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), saveNow);
  }

  /// Overlapping saves (e.g. the debounce timer and the save on exit) each write their own
  /// temp file, and an older save never replaces a file a newer save has already written.
  int _saveSeq = 0;
  final Map<String, int> _writtenSeq = {};

  Future<void> saveNow() async {
    if (_dir == null) return;
    _saveTimer?.cancel();
    final seq = ++_saveSeq;
    final ws = {
      'version': 1,
      'collections': collections.map((c) => c.toJson()).toList(),
      'environments': environments.map((e) => e.toJson()).toList(),
      'activeEnvId': activeEnvId,
      'globals': globals.map((e) => e.toJson()).toList(),
      'cookies': cookieJar.cookies.map((c) => c.toJson()).toList(),
    };
    await _atomicWrite(seq, 'workspace.json', jsonEncode(ws));
    await _atomicWrite(seq, 'settings.json', jsonEncode(settings.toJson()));
    await _atomicWrite(seq, 'history.json', jsonEncode(history.map((h) => h.toJson()).toList()));
    await _atomicWrite(seq, 'tabs.json', jsonEncode({
      'active': activeTab,
      'tabs': tabs.map((t) => {'draft': t.draft.toJson(), 'sourceId': t.sourceId, 'dirty': t.dirty}).toList(),
    }));
  }

  Future<void> _atomicWrite(int seq, String name, String content) async {
    final f = _file(name);
    final tmp = File('${f.path}.$seq.tmp');
    await tmp.writeAsString(content, flush: true);
    if ((_writtenSeq[name] ?? 0) > seq) {
      await tmp.delete(); // a newer save already wrote this file
      return;
    }
    _writtenSeq[name] = seq;
    await tmp.rename(f.path);
  }

  void changed({bool save = true}) {
    if (save) scheduleSave();
    notifyListeners();
  }

  // ------------------------------------------------------------------ tree helpers
  /// Returns the chain [collection, ..., parentFolder, node] for [id].
  List<Node>? pathTo(String id) {
    List<Node>? walk(List<Node> nodes, List<Node> prefix) {
      for (final n in nodes) {
        if (n.id == id) return [...prefix, n];
        if (n is Folder) {
          final r = walk(n.children, [...prefix, n]);
          if (r != null) return r;
        }
      }
      return null;
    }

    return walk(collections, []);
  }

  Node? findNode(String id) => pathTo(id)?.last;
  Folder? parentOf(String id) {
    final p = pathTo(id);
    return p == null || p.length < 2 ? null : p[p.length - 2] as Folder;
  }

  Folder? collectionOf(String? id) {
    if (id == null) return null;
    final p = pathTo(id);
    return p == null || p.isEmpty ? null : p.first as Folder;
  }

  /// Resolves "inherit" by walking up the folder chain.
  AuthConfig effectiveAuth(ApiRequest r, String? sourceId) {
    if (r.auth.type != 'inherit') return r.auth;
    if (sourceId == null) return AuthConfig(type: 'none');
    final path = pathTo(sourceId);
    if (path == null) return AuthConfig(type: 'none');
    for (final n in path.reversed.skip(1)) {
      if (n is Folder && n.auth.type != 'inherit') return n.auth;
    }
    return AuthConfig(type: 'none');
  }

  String authSourceName(String? sourceId) {
    if (sourceId == null) return '';
    final path = pathTo(sourceId);
    if (path == null) return '';
    for (final n in path.reversed.skip(1)) {
      if (n is Folder && n.auth.type != 'inherit') return n.name;
    }
    return '';
  }

  Map<String, String> _kvMap(List<KV> l) => {for (final v in l.where((e) => e.enabled && e.key.isNotEmpty)) v.key: v.value};

  VariableScope scopeFor(String? sourceId, {Map<String, String>? local}) => VariableScope(
        globals: _kvMap(globals),
        collection: _kvMap(collectionOf(sourceId)?.variables ?? []),
        environment: _kvMap(activeEnv?.variables ?? []),
        local: local,
      );

  void setVariable(String scope, String name, String value, {String? sourceId}) {
    List<KV>? target;
    switch (scope) {
      case 'global':
        target = globals;
      case 'collection':
        target = collectionOf(sourceId)?.variables;
      default:
        target = activeEnv?.variables ?? globals;
    }
    if (target == null) return;
    final existing = target.where((e) => e.key == name).firstOrNull;
    if (existing != null) {
      existing.value = value;
      existing.enabled = true;
    } else {
      target.add(KV(key: name, value: value));
    }
    changed();
  }

  // ------------------------------------------------------------------ tree mutations
  Folder addCollection(String name) {
    final c = Folder(id: newId(), name: name, auth: AuthConfig(type: 'none'), expanded: true);
    collections.add(c);
    changed();
    return c;
  }

  Folder addFolder(Folder parent, String name) {
    final f = Folder(id: newId(), name: name, expanded: true);
    parent.children.add(f);
    parent.expanded = true;
    changed();
    return f;
  }

  ApiRequest addRequest(Folder parent, RequestType type, {String? name}) {
    final r = ApiRequest.create(type, name: name);
    parent.children.add(r);
    parent.expanded = true;
    changed();
    openRequest(r);
    return r;
  }

  void renameNode(String id, String name) {
    final n = findNode(id);
    if (n == null) return;
    n.name = name;
    for (final t in tabs.where((t) => t.sourceId == id)) {
      t.draft.name = name;
      t.touch();
    }
    changed();
  }

  void deleteNode(String id) {
    final path = pathTo(id);
    if (path == null) return;
    final ids = <String>{};
    void collect(Node n) {
      ids.add(n.id);
      if (n is Folder) n.children.forEach(collect);
    }

    collect(path.last);
    if (path.length == 1) {
      collections.removeWhere((c) => c.id == id);
    } else {
      (path[path.length - 2] as Folder).children.removeWhere((c) => c.id == id);
    }
    for (final t in tabs.where((t) => ids.contains(t.sourceId))) {
      t.sourceId = null;
      t.dirty = true;
    }
    changed();
  }

  Node duplicateNode(String id) {
    final path = pathTo(id)!;
    final n = path.last;
    final Node copy;
    if (n is Folder) {
      copy = n.duplicate()..name = '${n.name} Copy';
    } else {
      copy = (n as ApiRequest).clone(newIdentity: true)..name = '${n.name} Copy';
    }
    if (path.length == 1) {
      collections.insert(collections.indexOf(n as Folder) + 1, copy as Folder);
    } else {
      final parent = path[path.length - 2] as Folder;
      parent.children.insert(parent.children.indexOf(n) + 1, copy);
    }
    changed();
    return copy;
  }

  /// Moves [id] into [targetFolderId] (or before [beforeId] among its siblings).
  bool moveNode(String id, String targetFolderId, {int? index}) {
    if (id == targetFolderId) return false;
    final target = findNode(targetFolderId);
    if (target is! Folder) return false;
    final targetPath = pathTo(targetFolderId)!;
    if (targetPath.any((n) => n.id == id)) return false; // no moving into own subtree
    final path = pathTo(id);
    if (path == null || path.length == 1) return false;
    final node = path.last;
    (path[path.length - 2] as Folder).children.remove(node);
    final i = index == null ? target.children.length : index.clamp(0, target.children.length);
    target.children.insert(i, node);
    target.expanded = true;
    changed();
    return true;
  }

  void reorderCollection(String id, int newIndex) {
    final c = collections.firstWhere((e) => e.id == id);
    collections.remove(c);
    collections.insert(newIndex.clamp(0, collections.length), c);
    changed();
  }

  // ------------------------------------------------------------------ tabs
  void openRequest(ApiRequest saved) {
    final i = tabs.indexWhere((t) => t.sourceId == saved.id);
    if (i >= 0) {
      activeTab = i;
    } else {
      tabs.add(RequestTab(saved.clone(), sourceId: saved.id));
      activeTab = tabs.length - 1;
    }
    selectedNodeId = saved.id;
    changed();
  }

  RequestTab newTab(RequestType type, {ApiRequest? from}) {
    final t = RequestTab(from ?? ApiRequest.create(type, name: 'Untitled ${type.label} Request'));
    if (from != null) t.dirty = true;
    tabs.add(t);
    activeTab = tabs.length - 1;
    changed();
    return t;
  }

  void selectTab(int i) {
    activeTab = i;
    selectedNodeId = tabs[i].sourceId;
    changed();
  }

  Future<void> closeTab(RequestTab t) async {
    final i = tabs.indexOf(t);
    if (i < 0) return;
    await t.disposeRuntime();
    tabs.removeAt(i);
    if (activeTab >= tabs.length) activeTab = tabs.length - 1;
    if (activeTab > i) activeTab--;
    changed();
  }

  Future<void> closeOtherTabs(RequestTab keep) async {
    for (final t in List.of(tabs)) {
      if (t != keep) await t.disposeRuntime();
    }
    tabs.retainWhere((t) => t == keep);
    activeTab = tabs.isEmpty ? -1 : 0;
    changed();
  }

  void markDirty(RequestTab t) {
    if (!t.dirty) {
      t.dirty = true;
      notifyListeners();
    }
    scheduleSave();
  }

  /// Saves the tab back into the tree. Returns false if the request needs a location.
  bool saveTab(RequestTab t) {
    if (t.sourceId == null) return false;
    final path = pathTo(t.sourceId!);
    if (path == null) return false;
    final parent = path[path.length - 2] as Folder;
    final idx = parent.children.indexWhere((c) => c.id == t.sourceId);
    final copy = t.draft.clone()..id = t.sourceId!;
    parent.children[idx] = copy;
    t.dirty = false;
    t.touch();
    changed();
    return true;
  }

  void saveTabAs(RequestTab t, Folder parent, String name) {
    final copy = t.draft.clone(newIdentity: true)..name = name;
    parent.children.add(copy);
    parent.expanded = true;
    t.draft.name = name;
    t.draft.id = copy.id;
    t.sourceId = copy.id;
    t.dirty = false;
    t.touch();
    selectedNodeId = copy.id;
    changed();
  }

  void revertTab(RequestTab t) {
    if (t.sourceId == null) return;
    final n = findNode(t.sourceId!);
    if (n is ApiRequest) {
      t.draft = n.clone();
      t.dirty = false;
      t.touch();
      changed();
    }
  }

  // ------------------------------------------------------------------ environments
  Environment addEnvironment(String name) {
    final e = Environment(id: newId(), name: name);
    environments.add(e);
    changed();
    return e;
  }

  void setActiveEnv(String? id) {
    activeEnvId = id;
    changed();
  }

  void deleteEnvironment(String id) {
    environments.removeWhere((e) => e.id == id);
    if (activeEnvId == id) activeEnvId = null;
    changed();
  }

  // ------------------------------------------------------------------ history & console
  void addHistory(ApiRequest r, {int? status, int? timeMs}) {
    history.insert(0, HistoryEntry(time: DateTime.now(), request: r.clone(), status: status, timeMs: timeMs));
    if (history.length > settings.historyLimit) history.removeRange(settings.historyLimit, history.length);
    changed();
  }

  void clearHistory() {
    history.clear();
    changed();
  }

  void addConsole(ConsoleEntry e) {
    console.insert(0, e);
    if (console.length > 300) console.removeLast();
  }

  void updateSettings(void Function(AppSettings s) f) {
    f(settings);
    changed();
  }
}
