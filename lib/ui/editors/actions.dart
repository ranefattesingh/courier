import 'dart:convert';

import 'package:grpc/grpc.dart' show GrpcError;

import '../../core/grpc/grpc_engine.dart';
import '../../core/grpc/wire_codec.dart';
import '../../core/http_engine.dart';
import '../../core/sessions.dart';
import '../../models/models.dart';
import '../../state/app_state.dart';
import '../../state/executor.dart';

bool isGraphQLSubscription(ApiRequest r) {
  final u = r.url.trim().toLowerCase();
  if (u.startsWith('ws://') || u.startsWith('wss://')) return true;
  final q = r.body.gqlQuery.replaceAll(RegExp(r'#.*'), '').trimLeft();
  return q.startsWith('subscription');
}

/// Whether the tab currently has a live connection / in-flight request.
bool isActive(RequestTab t) {
  if (t.sending) return true;
  if (t.session?.connected == true || t.session?.busy == true) return true;
  if (t.grpcStreamOpen) return true;
  return false;
}

Map<String, String> queryFromUrl(String url) {
  final u = Uri.tryParse(url);
  return u?.queryParameters ?? {};
}

/// The main action for a tab: Send / Connect / Invoke / Produce.
Future<void> runPrimaryAction(AppState state, RequestTab tab) async {
  final ex = Executor(state);
  final r = tab.draft;
  switch (r.type) {
    case RequestType.http:
    case RequestType.soap:
      await _sendHttp(state, tab);
    case RequestType.graphql:
      if (isGraphQLSubscription(r)) {
        await _toggleGqlSubscription(state, tab);
      } else {
        await _sendHttp(state, tab);
      }
    case RequestType.grpc:
      await invokeGrpc(state, tab);
    case RequestType.websocket:
      if (tab.session?.connected == true) {
        await tab.session!.close();
        return;
      }
      final res = ex.resolve(r, tab.sourceId);
      final s = WebSocketSession(tab.addLog, tab.touch);
      tab.session = s;
      final protos = res.opt('wsProtocols').split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      await s.connect(res.url, await ex.headersFor(res), protos, state.settings, ex.verifySsl(res));
      state.addHistory(r);
    case RequestType.socketio:
      if (tab.session?.connected == true || tab.session?.busy == true) {
        await tab.session!.close();
        return;
      }
      final res = ex.resolve(r, tab.sourceId);
      final s = SocketIoSession(tab.addLog, tab.touch);
      tab.session = s;
      dynamic auth;
      final authJson = res.opt('sioAuth').trim();
      if (authJson.isNotEmpty) {
        try {
          auth = jsonDecode(authJson);
        } catch (_) {
          tab.addLog(LogMessage(MsgDir.error, 'Handshake auth payload is not valid JSON'));
          return;
        }
      }
      var url = res.url.trim();
      if (!url.contains('://')) url = 'http://$url';
      final query = {for (final p in res.params.where((p) => p.enabled && p.key.isNotEmpty)) p.key: p.value};
      final base = url.split('?').first;
      s.connect(base,
          headers: await ex.headersFor(res),
          path: res.opt('sioPath', '/socket.io'),
          auth: auth,
          transport: res.opt('sioTransport', 'websocket'),
          query: {...queryFromUrl(url), ...query});
      state.addHistory(r);
    case RequestType.mqtt:
      if (tab.session?.connected == true) {
        await tab.session!.close();
        return;
      }
      final res = ex.resolve(r, tab.sourceId);
      final s = MqttSession(tab.addLog, tab.touch);
      tab.session = s;
      await s.connect(res, ex.verifySsl(res));
      state.addHistory(r);
    case RequestType.sse:
      if (tab.session?.connected == true || tab.session?.busy == true) {
        await tab.session!.close();
        return;
      }
      final s = SseSession(tab.addLog, tab.touch);
      tab.session = s;
      try {
        final p = await ex.prepare(r, tab.sourceId);
        await s.connect(p, state.settings, ex.verifySsl(r));
      } catch (e) {
        tab.addLog(LogMessage(MsgDir.error, e.toString()));
        s.setConnected(false);
      }
      state.addHistory(r);
    case RequestType.kafka:
      final s = (tab.session as KafkaSession?) ?? KafkaSession(tab.addLog, tab.touch);
      tab.session = s;
      await s.produce(ex.resolve(r, tab.sourceId), ex.verifySsl(r));
      state.addHistory(r);
  }
}

Future<void> _sendHttp(AppState state, RequestTab tab) async {
  if (tab.sending) {
    tab.httpEngine?.cancel();
    return;
  }
  tab.sending = true;
  tab.httpEngine = HttpEngine();
  tab.touch();
  try {
    tab.response = await Executor(state).sendHttp(tab.draft, tab.sourceId, tab.httpEngine!);
  } finally {
    tab.sending = false;
    tab.httpEngine = null;
    tab.touch();
  }
}

Future<void> _toggleGqlSubscription(AppState state, RequestTab tab) async {
  if (tab.session?.connected == true || tab.session?.busy == true) {
    await tab.session!.close();
    return;
  }
  final ex = Executor(state);
  final res = ex.resolve(tab.draft, tab.sourceId);
  dynamic vars = {};
  try {
    if (res.body.gqlVariables.trim().isNotEmpty) vars = jsonDecode(res.body.gqlVariables);
  } catch (e) {
    tab.addLog(LogMessage(MsgDir.error, 'Variables are not valid JSON: $e'));
    return;
  }
  var url = res.url.trim();
  if (url.startsWith('http://')) url = 'ws://${url.substring(7)}';
  if (url.startsWith('https://')) url = 'wss://${url.substring(8)}';
  final s = GraphQLWsSession(tab.addLog, tab.touch);
  tab.session = s;
  await s.subscribe(url, await ex.headersFor(res), res.body.gqlQuery, vars, res.opt('gqlWsProtocol', 'graphql-transport-ws'), state.settings,
      ex.verifySsl(res));
}

Future<void> loadGrpcSchema(AppState state, RequestTab tab) async {
  tab.sending = true;
  tab.registryError = null;
  tab.touch();
  try {
    tab.registry = await Executor(state).loadGrpcSchema(tab.draft, tab.sourceId);
    final methods = tab.registry!.methodPaths;
    if (methods.isEmpty) {
      tab.registryError = 'No services found';
    } else if (!methods.contains(tab.draft.opt('grpcMethod'))) {
      tab.draft.opts['grpcMethod'] = methods.first;
    }
  } catch (e) {
    tab.registry = null;
    tab.registryError = e is GrpcError ? describeGrpcError(e) : e.toString();
  } finally {
    tab.sending = false;
    tab.touch();
  }
}

/// Invokes the selected gRPC method. Unary → response view; streaming → message log.
Future<void> invokeGrpc(AppState state, RequestTab tab) async {
  if (tab.grpcStreamOpen || tab.sending) {
    await tab.grpcEngine?.cancel();
    tab.grpcStreamOpen = false;
    tab.sending = false;
    tab.addLog(LogMessage(MsgDir.info, 'Call cancelled'));
    tab.touch();
    return;
  }
  if (tab.registry == null) {
    await loadGrpcSchema(state, tab);
    if (tab.registry == null) return;
  }
  final reg = tab.registry!;
  final found = reg.findMethod(tab.draft.opt('grpcMethod'));
  if (found == null) {
    tab.registryError = 'Select a method';
    tab.touch();
    return;
  }
  final m = found.$2;
  final ex = Executor(state);
  if (!m.clientStreaming && !m.serverStreaming) {
    tab.sending = true;
    tab.grpcEngine = GrpcEngine();
    tab.touch();
    try {
      tab.response = await ex.grpcUnary(tab.draft, tab.sourceId, reg, engine: tab.grpcEngine);
    } finally {
      await tab.grpcEngine?.close();
      tab.sending = false;
      tab.touch();
    }
    return;
  }
  // Streaming call
  final r = ex.resolve(tab.draft, tab.sourceId);
  final codec = WireCodec(reg);
  final e = tab.grpcEngine = GrpcEngine();
  try {
    final target = GrpcTarget.parse(r.url, tls: r.opts.containsKey('grpcTls') ? r.optBool('grpcTls') : null);
    final md = await ex.headersFor(r);
    List<int>? first;
    if (!m.clientStreaming) {
      first = codec.encode(m.inputType, r.message.trim().isEmpty ? {} : jsonDecode(r.message));
    }
    final deadline = ex.timeoutMs(r);
    final stream = e.start(target, r.opt('grpcMethod'),
        verifySsl: ex.verifySsl(r),
        metadata: md,
        timeout: deadline > 0 ? Duration(milliseconds: deadline) : null,
        firstMessage: first,
        keepOpen: m.clientStreaming);
    tab.grpcStreamOpen = true;
    tab.addLog(LogMessage(MsgDir.info, 'Started ${m.kind.toLowerCase()} call ${r.opt('grpcMethod')}'));
    if (first != null) tab.addLog(LogMessage(MsgDir.sent, r.message));
    state.addHistory(tab.draft);
    tab.touch();
    stream.headers.then((h) {
      if (h.isNotEmpty) tab.addLog(LogMessage(MsgDir.info, 'Response metadata: ${const JsonEncoder.withIndent('  ').convert(h)}'));
    }).catchError((_) {});
    stream.listen(
      (b) => tab.addLog(LogMessage(MsgDir.received, const JsonEncoder.withIndent('  ').convert(codec.decode(m.outputType, b)))),
      onError: (err) {
        tab.addLog(LogMessage(MsgDir.error, describeGrpcError(err)));
        tab.grpcStreamOpen = false;
        tab.touch();
      },
      onDone: () async {
        try {
          final tr = await stream.trailers;
          tab.addLog(LogMessage(MsgDir.info, 'Stream completed — status OK${tr.isEmpty ? '' : '\nTrailers: ${const JsonEncoder.withIndent('  ').convert(tr)}'}'));
        } catch (_) {
          tab.addLog(LogMessage(MsgDir.info, 'Stream completed'));
        }
        tab.grpcStreamOpen = false;
        await e.close();
        tab.touch();
      },
    );
  } catch (err) {
    tab.addLog(LogMessage(MsgDir.error, err is FormatException ? 'Invalid message: ${err.message}' : describeGrpcError(err)));
    tab.grpcStreamOpen = false;
    await e.close();
    tab.touch();
  }
}

/// Sends the compose buffer on an open client/bidi stream.
void sendGrpcStreamMessage(AppState state, RequestTab tab) {
  final reg = tab.registry;
  final e = tab.grpcEngine;
  if (reg == null || e == null || !e.canSend) return;
  final m = reg.findMethod(tab.draft.opt('grpcMethod'))!.$2;
  final text = Executor(state).scope(tab.sourceId).resolve(tab.draft.message);
  try {
    e.sendMessage(WireCodec(reg).encode(m.inputType, text.trim().isEmpty ? {} : jsonDecode(text)));
    tab.addLog(LogMessage(MsgDir.sent, text));
  } catch (err) {
    tab.addLog(LogMessage(MsgDir.error, 'Invalid message: $err'));
  }
}

Future<void> endGrpcStream(RequestTab tab) async {
  await tab.grpcEngine?.halfClose();
  tab.addLog(LogMessage(MsgDir.info, 'Client stream ended (half-close)'));
  tab.touch();
}
