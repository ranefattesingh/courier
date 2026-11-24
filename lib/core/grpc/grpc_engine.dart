import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:grpc/grpc.dart';

import 'proto_parser.dart';
import 'proto_schema.dart';
import 'wire_codec.dart';

const _descriptorProto = '''
syntax = "proto2";
package google.protobuf;
message FileDescriptorProto {
  optional string name = 1; optional string package = 2; repeated string dependency = 3;
  repeated DescriptorProto message_type = 4; repeated EnumDescriptorProto enum_type = 5;
  repeated ServiceDescriptorProto service = 6; optional string syntax = 12;
}
message DescriptorProto {
  optional string name = 1; repeated FieldDescriptorProto field = 2; repeated DescriptorProto nested_type = 3;
  repeated EnumDescriptorProto enum_type = 4; optional MessageOptions options = 7;
  repeated OneofDescriptorProto oneof_decl = 8;
}
message MessageOptions { optional bool map_entry = 7; }
message FieldOptions { optional bool packed = 2; }
message FieldDescriptorProto {
  optional string name = 1; optional int32 number = 3; optional int32 label = 4; optional int32 type = 5;
  optional string type_name = 6; optional FieldOptions options = 8; optional int32 oneof_index = 9;
  optional string json_name = 10; optional bool proto3_optional = 17;
}
message OneofDescriptorProto { optional string name = 1; }
message EnumDescriptorProto { optional string name = 1; repeated EnumValueDescriptorProto value = 2; }
message EnumValueDescriptorProto { optional string name = 1; optional int32 number = 2; }
message ServiceDescriptorProto { optional string name = 1; repeated MethodDescriptorProto method = 2; }
message MethodDescriptorProto {
  optional string name = 1; optional string input_type = 2; optional string output_type = 3;
  optional bool client_streaming = 5; optional bool server_streaming = 6;
}
''';

const _reflectionProto = '''
syntax = "proto3";
package reflection;
message ServerReflectionRequest {
  string host = 1;
  oneof message_request { string file_by_filename = 3; string file_containing_symbol = 4; string list_services = 7; }
}
message ServerReflectionResponse {
  string valid_host = 1;
  ServerReflectionRequest original_request = 2;
  oneof message_response {
    FileDescriptorResponse file_descriptor_response = 4;
    ListServiceResponse list_services_response = 6;
    ErrorResponse error_response = 7;
  }
}
message FileDescriptorResponse { repeated bytes file_descriptor_proto = 1; }
message ListServiceResponse { repeated ServiceResponse service = 1; }
message ServiceResponse { string name = 1; }
message ErrorResponse { int32 error_code = 1; string error_message = 2; }
''';

final ProtoRegistry _metaRegistry =
    ProtoParser.parseAll({'descriptor.proto': _descriptorProto, 'reflection.proto': _reflectionProto}, includeWellKnown: false);
final WireCodec _metaCodec = WireCodec(_metaRegistry, emitDefaults: false);

const _typeNames = {
  1: 'double', 2: 'float', 3: 'int64', 4: 'uint64', 5: 'int32', 6: 'fixed64', 7: 'fixed32', 8: 'bool', //
  9: 'string', 10: 'group', 11: 'message', 12: 'bytes', 13: 'uint32', 14: 'enum', 15: 'sfixed32',
  16: 'sfixed64', 17: 'sint32', 18: 'sint64',
};

/// Converts decoded FileDescriptorProto maps into a registry.
ProtoRegistry registryFromDescriptors(Iterable<Map<String, dynamic>> files) {
  final reg = ProtoRegistry();
  for (final f in files) {
    final pkg = f['package']?.toString() ?? '';
    final syntax = (f['syntax']?.toString() ?? '').isEmpty ? 'proto2' : f['syntax'].toString();
    String join(String scope, String n) => scope.isEmpty ? n : '$scope.$n';
    void addEnum(Map e, String scope) {
      reg.enums[join(scope, e['name'])] = ProtoEnum(join(scope, e['name']), {
        for (final v in (e['value'] as List? ?? [])) v['name'].toString(): (v['number'] as num?)?.toInt() ?? 0,
      });
    }

    void addMsg(Map m, String scope) {
      final full = join(scope, m['name']);
      final oneofs = (m['oneof_decl'] as List? ?? []).map((o) => o['name'].toString()).toList();
      final fields = <ProtoField>[];
      for (final fd in (m['field'] as List? ?? [])) {
        final t = _typeNames[(fd['type'] as num?)?.toInt() ?? 9] ?? 'string';
        final oi = (fd['oneof_index'] as num?)?.toInt();
        fields.add(ProtoField(
          name: fd['name'].toString(),
          number: (fd['number'] as num).toInt(),
          type: t,
          typeName: (fd['type_name']?.toString() ?? '').replaceFirst(RegExp(r'^\.'), ''),
          repeated: (fd['label'] as num?)?.toInt() == 3,
          oneof: oi != null && oi < oneofs.length ? oneofs[oi] : null,
          jsonName: fd['json_name']?.toString(),
          packedOption: (fd['options'] as Map?)?['packed'] as bool?,
          proto3Optional: fd['proto3_optional'] == true,
        ));
      }
      reg.messages[full] =
          ProtoMessage(full, fields, isMapEntry: (m['options'] as Map?)?['map_entry'] == true, syntax: syntax);
      for (final n in (m['nested_type'] as List? ?? [])) {
        addMsg(n as Map, full);
      }
      for (final e in (m['enum_type'] as List? ?? [])) {
        addEnum(e as Map, full);
      }
    }

    for (final m in (f['message_type'] as List? ?? [])) {
      addMsg(m as Map, pkg);
    }
    for (final e in (f['enum_type'] as List? ?? [])) {
      addEnum(e as Map, pkg);
    }
    for (final s in (f['service'] as List? ?? [])) {
      final full = join(pkg, s['name']);
      reg.services[full] = ProtoService(full, [
        for (final m in (s['method'] as List? ?? []))
          ProtoMethod(
            m['name'].toString(),
            m['input_type'].toString().replaceFirst(RegExp(r'^\.'), ''),
            m['output_type'].toString().replaceFirst(RegExp(r'^\.'), ''),
            clientStreaming: m['client_streaming'] == true,
            serverStreaming: m['server_streaming'] == true,
          ),
      ]);
    }
  }
  // Make well-known types available even if the server did not send them.
  final wk = ProtoParser.parseAll({});
  for (final e in wk.messages.entries) {
    reg.messages.putIfAbsent(e.key, () => e.value);
  }
  for (final e in wk.enums.entries) {
    reg.enums.putIfAbsent(e.key, () => e.value);
  }
  return reg;
}

class _RawClient extends Client {
  _RawClient(super.channel);

  ResponseStream<List<int>> call(String path, Stream<List<int>> requests, CallOptions options) =>
      $createStreamingCall(ClientMethod<List<int>, List<int>>(path, (x) => x, (x) => x), requests, options: options);
}

class GrpcTarget {
  final String host;
  final int port;
  final bool tls;
  GrpcTarget(this.host, this.port, this.tls);

  static GrpcTarget parse(String url, {bool? tls}) {
    var u = url.trim();
    var secure = tls ?? false;
    final m = RegExp(r'^(grpcs?|https?)://').firstMatch(u);
    if (m != null) {
      if (tls == null) secure = m.group(1) == 'grpcs' || m.group(1) == 'https';
      u = u.substring(m.end);
    }
    u = u.split('/').first;
    final i = u.lastIndexOf(':');
    if (i > 0 && !u.endsWith(']')) {
      return GrpcTarget(u.substring(0, i), int.tryParse(u.substring(i + 1)) ?? (secure ? 443 : 80), secure);
    }
    return GrpcTarget(u, secure ? 443 : 80, secure);
  }
}

String describeGrpcError(Object e) {
  if (e is GrpcError) {
    return '${e.codeName} (${e.code})${e.message != null && e.message!.isNotEmpty ? ': ${e.message}' : ''}';
  }
  if (e is SocketException) return 'Could not connect: ${e.message} ${e.osError?.message ?? ''}'.trim();
  return e.toString();
}

/// Manages one channel and dynamic calls on it.
class GrpcEngine {
  ClientChannel? _channel;
  ResponseStream<List<int>>? _active;
  StreamController<List<int>>? _outgoing;

  ClientChannel _open(GrpcTarget t, {required bool verifySsl, Duration? connectTimeout}) {
    return _channel = ClientChannel(
      t.host,
      port: t.port,
      options: ChannelOptions(
        credentials: t.tls
            ? ChannelCredentials.secure(onBadCertificate: verifySsl ? null : (cert, host) => true)
            : const ChannelCredentials.insecure(),
        connectTimeout: connectTimeout,
        userAgent: 'courier-grpc/1.0',
      ),
    );
  }

  Future<void> close() async {
    await _outgoing?.close();
    await _active?.cancel();
    await _channel?.shutdown();
    _channel = null;
  }

  Future<void> cancel() async {
    await _active?.cancel();
    await close();
  }

  /// Uses server reflection (v1 then v1alpha) to download all service definitions.
  Future<ProtoRegistry> reflect(GrpcTarget t, {required bool verifySsl, Map<String, String> metadata = const {}}) async {
    final ch = _open(t, verifySsl: verifySsl, connectTimeout: const Duration(seconds: 10));
    try {
      try {
        return await _reflectWith(ch, 'grpc.reflection.v1.ServerReflection', metadata);
      } on GrpcError catch (e) {
        if (e.code != StatusCode.unimplemented) rethrow;
        return await _reflectWith(ch, 'grpc.reflection.v1alpha.ServerReflection', metadata);
      }
    } finally {
      await ch.shutdown();
      _channel = null;
    }
  }

  Future<ProtoRegistry> _reflectWith(ClientChannel ch, String svc, Map<String, String> md) async {
    final out = StreamController<List<int>>();
    final client = _RawClient(ch);
    final resp = client.call('/$svc/ServerReflectionInfo', out.stream,
        CallOptions(metadata: md, timeout: const Duration(seconds: 30)));
    final it = StreamIterator(resp);
    Future<Map<String, dynamic>> ask(Map<String, dynamic> req) async {
      out.add(_metaCodec.encode('reflection.ServerReflectionRequest', req));
      if (!await it.moveNext()) throw StateError('Reflection stream ended unexpectedly');
      final r = _metaCodec.decode('reflection.ServerReflectionResponse', it.current) as Map<String, dynamic>;
      final err = r['error_response'];
      if (err is Map) throw GrpcError.custom(err['error_code'] ?? 2, 'Reflection: ${err['error_message']}');
      return r;
    }

    try {
      final list = await ask({'list_services': '*'});
      final services = ((list['list_services_response'] as Map?)?['service'] as List? ?? [])
          .map((s) => s['name'].toString())
          .where((n) => !n.startsWith('grpc.reflection.'))
          .toList();
      final files = <String, Map<String, dynamic>>{};
      Future<void> absorb(Map<String, dynamic> r) async {
        final fdr = r['file_descriptor_response'] as Map?;
        for (final b64 in (fdr?['file_descriptor_proto'] as List? ?? [])) {
          final fd = _metaCodec.decode('google.protobuf.FileDescriptorProto', base64.decode(b64.toString()))
              as Map<String, dynamic>;
          files[fd['name']?.toString() ?? '${files.length}'] = fd;
        }
      }

      for (final s in services) {
        await absorb(await ask({'file_containing_symbol': s}));
      }
      // Fetch any missing dependencies.
      for (var round = 0; round < 10; round++) {
        final missing = <String>{
          for (final f in files.values)
            for (final d in (f['dependency'] as List? ?? [])) d.toString(),
        }.where((d) => !files.containsKey(d) && !d.startsWith('google/protobuf/')).toList();
        if (missing.isEmpty) break;
        for (final d in missing) {
          try {
            await absorb(await ask({'file_by_filename': d}));
          } catch (_) {
            files[d] = {'name': d};
          }
        }
      }
      return registryFromDescriptors(files.values);
    } finally {
      await out.close();
      await it.cancel();
    }
  }

  /// Starts a call. For client/bidi streaming, use [sendMessage] and [halfClose].
  /// Returns the response stream of raw message bytes.
  ResponseStream<List<int>> start(
    GrpcTarget t,
    String methodPath, {
    required bool verifySsl,
    required Map<String, String> metadata,
    Duration? timeout,
    List<int>? firstMessage,
    bool keepOpen = false,
  }) {
    final ch = _open(t, verifySsl: verifySsl, connectTimeout: const Duration(seconds: 15));
    final out = _outgoing = StreamController<List<int>>();
    if (firstMessage != null) out.add(firstMessage);
    if (!keepOpen) out.close();
    final client = _RawClient(ch);
    return _active = client.call('/$methodPath', out.stream, CallOptions(metadata: metadata, timeout: timeout));
  }

  bool get canSend => _outgoing != null && !_outgoing!.isClosed;

  void sendMessage(List<int> bytes) => _outgoing?.add(bytes);

  Future<void> halfClose() async => _outgoing?.close();
}

/// Registry containing descriptor.proto and reflection.proto messages (used by tests and tooling).
ProtoRegistry get grpcMetaRegistry => _metaRegistry;
