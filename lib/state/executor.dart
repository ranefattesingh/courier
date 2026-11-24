import 'dart:async';
import 'dart:convert';

import 'package:grpc/grpc.dart' show GrpcError;

import '../core/auth.dart';
import '../core/grpc/grpc_engine.dart';
import '../core/grpc/proto_parser.dart';
import '../core/grpc/proto_schema.dart';
import '../core/grpc/wire_codec.dart';
import '../core/http_engine.dart';
import '../core/tests.dart';
import '../core/variables.dart';
import '../models/models.dart';
import 'app_state.dart';

/// Runs requests with the full pipeline: variables → auth → send → tests → extracts → history.
class Executor {
  final AppState state;
  Executor(this.state);

  bool verifySsl(ApiRequest r) => r.optBool('verifySsl', state.settings.verifySsl);
  bool followRedirects(ApiRequest r) => r.optBool('followRedirects', state.settings.followRedirects);
  int timeoutMs(ApiRequest r) => r.optInt('timeoutMs', state.settings.timeoutMs);

  ApiRequest resolve(ApiRequest draft, String? sourceId, {Map<String, String>? local}) {
    final scope = state.scopeFor(sourceId, local: local);
    return resolveRequest(draft, scope, state.effectiveAuth(draft, sourceId));
  }

  /// Builds the request with auth applied — used by code generation and streaming protocols.
  Future<PreparedRequest> prepare(ApiRequest draft, String? sourceId) async {
    final r = resolve(draft, sourceId);
    final p = await buildHttpRequest(r, state.settings);
    await AuthApplier.apply(r.auth, p);
    return p;
  }

  /// Headers (incl. auth) for non-HTTP protocols that carry HTTP-style metadata.
  Future<Map<String, String>> headersFor(ApiRequest resolved, {bool includeDefaults = false}) async {
    final p = PreparedRequest(method: 'GET', uri: parseUrl(resolved.url.isEmpty ? 'localhost' : resolved.url));
    for (final h in resolved.headers.where((h) => h.enabled && h.key.isNotEmpty)) {
      p.headers.add(MapEntry(h.key, h.value));
    }
    if (resolved.auth.type != 'digest' && resolved.auth.type != 'ntlm') {
      await AuthApplier.apply(resolved.auth, p);
    }
    return p.headerMap();
  }

  Future<ResponseData> sendHttp(ApiRequest draft, String? sourceId, HttpEngine engine,
      {Map<String, String>? local, bool recordHistory = true}) async {
    final r = resolve(draft, sourceId, local: local);
    PreparedRequest p;
    try {
      if (r.url.isEmpty) throw const FormatException('Enter a request URL');
      p = await buildHttpRequest(r, state.settings);
      await AuthApplier.apply(r.auth, p);
    } catch (e) {
      return ResponseData(error: e is FormatException ? e.message : e.toString(), method: r.method, finalUrl: r.url);
    }
    final res = await engine.send(p,
        auth: r.auth,
        settings: state.settings,
        verifySsl: verifySsl(r),
        followRedirects: followRedirects(r),
        timeoutMs: timeoutMs(r),
        jar: state.cookieJar);
    _afterResponse(draft, r, sourceId, res, recordHistory: recordHistory);
    state.addConsole(ConsoleEntry(res.method, res.finalUrl.isEmpty ? p.uri.toString() : res.finalUrl, res.error == null ? res.status : null,
        res.timeMs, res.error, res.requestHeaders.isEmpty ? p.headers : res.requestHeaders, res.requestBodyPreview,
        res.headers, res.body.length > 50000 ? '${res.bodyText.substring(0, 50000)}…' : res.bodyText));
    return res;
  }

  void _afterResponse(ApiRequest draft, ApiRequest resolved, String? sourceId, ResponseData res, {bool recordHistory = true}) {
    if (res.error == null) {
      final scope = state.scopeFor(sourceId);
      final rules = resolved.tests
          .map((t) => TestRule(enabled: t.enabled, source: t.source, property: scope.resolve(t.property), op: t.op, expected: scope.resolve(t.expected)))
          .toList();
      res.tests = runTests(rules, res);
      final extracted = runExtracts(resolved.extracts, res);
      extracted.forEach((scopeName, vars) => vars.forEach((k, v) => state.setVariable(scopeName, k, v, sourceId: sourceId)));
    }
    if (recordHistory) state.addHistory(draft, status: res.error == null ? res.status : null, timeMs: res.timeMs);
  }

  // ------------------------------------------------------------------ gRPC

  /// Loads the schema either via reflection or from attached .proto files.
  Future<ProtoRegistry> loadGrpcSchema(ApiRequest draft, String? sourceId) async {
    final r = resolve(draft, sourceId);
    if (r.optBool('grpcReflection', true)) {
      final target = GrpcTarget.parse(r.url, tls: r.opts.containsKey('grpcTls') ? r.optBool('grpcTls') : null);
      return GrpcEngine().reflect(target, verifySsl: verifySsl(r), metadata: await headersFor(r));
    }
    if (r.protoFiles.isEmpty) throw const FormatException('Import a .proto file or enable server reflection');
    return ProtoParser.parseAll({for (final f in r.protoFiles) f.name: f.content});
  }

  /// Unary (or server-streaming collected) call used by the collection runner and the editor.
  Future<ResponseData> grpcUnary(ApiRequest draft, String? sourceId, ProtoRegistry reg, {GrpcEngine? engine}) async {
    final r = resolve(draft, sourceId);
    final sw = Stopwatch()..start();
    final res = ResponseData(method: 'gRPC', finalUrl: '${r.url}/${r.opt('grpcMethod')}', displayLanguage: 'json');
    final e = engine ?? GrpcEngine();
    try {
      final found = reg.findMethod(r.opt('grpcMethod'));
      if (found == null) throw const FormatException('Select a method');
      final m = found.$2;
      final codec = WireCodec(reg);
      final msg = r.message.trim().isEmpty ? <String, dynamic>{} : jsonDecode(r.message);
      final target = GrpcTarget.parse(r.url, tls: r.opts.containsKey('grpcTls') ? r.optBool('grpcTls') : null);
      final md = await headersFor(r);
      final deadline = timeoutMs(r);
      final stream = e.start(target, r.opt('grpcMethod'),
          verifySsl: verifySsl(r),
          metadata: md,
          timeout: deadline > 0 ? Duration(milliseconds: deadline) : null,
          firstMessage: codec.encode(m.inputType, msg));
      final replies = <dynamic>[];
      await for (final b in stream) {
        replies.add(codec.decode(m.outputType, b));
      }
      final headers = await stream.headers;
      final trailers = await stream.trailers;
      res.status = 0;
      res.statusText = 'OK';
      res.headers = headers.entries.toList();
      res.trailers = trailers.entries.toList();
      res.body = utf8.encode(const JsonEncoder.withIndent('  ').convert(m.serverStreaming ? replies : (replies.isEmpty ? {} : replies.first)));
      res.requestHeaders = md.entries.toList();
      res.requestBodyPreview = r.message;
    } on GrpcError catch (ge) {
      res.status = ge.code;
      res.statusText = ge.codeName;
      res.body = utf8.encode(const JsonEncoder.withIndent('  ').convert({
        'code': ge.code,
        'status': ge.codeName,
        'message': ge.message,
        if (ge.details != null && ge.details!.isNotEmpty) 'details': ge.details!.map((d) => d.toString()).toList(),
      }));
      res.trailers = (ge.trailers ?? {}).entries.toList();
    } catch (err) {
      res.error = err is FormatException ? 'Invalid input: ${err.message}' : describeGrpcError(err);
    } finally {
      sw.stop();
      res.timeMs = sw.elapsedMilliseconds;
      res.size = res.body.length;
      if (engine == null) await e.close();
    }
    _afterResponse(draft, r, sourceId, res);
    return res;
  }

  VariableScope scope(String? sourceId) => state.scopeFor(sourceId);
}
