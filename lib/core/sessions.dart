import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:socket_io_client/socket_io_client.dart' as sio;
import 'package:typed_data/typed_data.dart' as typed;

import '../models/models.dart';
import 'auth.dart';
import 'http_engine.dart';
import 'kafka/kafka_client.dart';

typedef LogFn = void Function(LogMessage m);

/// Base class for long-lived protocol connections shown as a message log.
abstract class StreamSession {
  final LogFn log;
  final void Function() changed;
  bool connected = false;
  bool busy = false;
  StreamSession(this.log, this.changed);

  void info(String s) => log(LogMessage(MsgDir.info, s));
  void error(Object e) => log(LogMessage(MsgDir.error, e.toString()));
  void setConnected(bool v) {
    connected = v;
    busy = false;
    changed();
  }

  Future<void> close();
}

String prettyIfJson(String s) {
  final t = s.trimLeft();
  if (t.startsWith('{') || t.startsWith('[')) {
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(s));
    } catch (_) {}
  }
  return s;
}

String bytesToDisplay(List<int>? b) {
  if (b == null) return 'null';
  try {
    return utf8.decode(b);
  } catch (_) {
    return 'base64:${base64.encode(b)}';
  }
}

// ============================================================================ WebSocket

class WebSocketSession extends StreamSession {
  WebSocket? _ws;
  WebSocketSession(super.log, super.changed);

  Future<void> connect(String url, Map<String, String> headers, List<String> protocols, AppSettings s, bool verifySsl) async {
    busy = true;
    changed();
    try {
      var u = url.trim();
      if (u.startsWith('http://')) u = 'ws://${u.substring(7)}';
      if (u.startsWith('https://')) u = 'wss://${u.substring(8)}';
      if (!u.contains('://')) u = 'ws://$u';
      final client = createHttpClient(s, verifySsl: verifySsl, connectTimeout: const Duration(seconds: 15));
      _ws = await WebSocket.connect(u, headers: headers, protocols: protocols.isEmpty ? null : protocols, customClient: client);
      _ws!.pingInterval = const Duration(seconds: 25);
      info('Connected to $u${_ws!.protocol != null ? ' (protocol: ${_ws!.protocol})' : ''}');
      setConnected(true);
      _ws!.listen(
        (data) => log(LogMessage(MsgDir.received, data is String ? data : 'binary(${(data as List<int>).length} bytes): ${base64.encode(data)}')),
        onError: (e) => error(e),
        onDone: () {
          info('Disconnected${_ws?.closeCode != null ? ' (code ${_ws!.closeCode}${(_ws!.closeReason ?? '').isNotEmpty ? ': ${_ws!.closeReason}' : ''})' : ''}');
          setConnected(false);
        },
      );
    } catch (e) {
      error('Connection failed: $e');
      setConnected(false);
    }
  }

  void send(String text, {bool binary = false}) {
    if (_ws == null || !connected) return;
    if (binary) {
      _ws!.add(base64.decode(text.trim()));
    } else {
      _ws!.add(text);
    }
    log(LogMessage(MsgDir.sent, text));
  }

  @override
  Future<void> close() async {
    await _ws?.close(WebSocketStatus.normalClosure, 'Closed by client');
    _ws = null;
    if (connected) setConnected(false);
  }
}

// ============================================================================ GraphQL subscriptions

class GraphQLWsSession extends StreamSession {
  WebSocket? _ws;
  GraphQLWsSession(super.log, super.changed);

  /// protocol: graphql-transport-ws (modern) | graphql-ws (legacy subscriptions-transport-ws)
  Future<void> subscribe(String url, Map<String, String> headers, String query, dynamic variables, String protocol,
      AppSettings s, bool verifySsl) async {
    busy = true;
    changed();
    final modern = protocol != 'graphql-ws';
    try {
      final client = createHttpClient(s, verifySsl: verifySsl, connectTimeout: const Duration(seconds: 15));
      _ws = await WebSocket.connect(url, headers: headers, protocols: [protocol], customClient: client);
      info('Connected to $url using $protocol');
      setConnected(true);
      _ws!.add(jsonEncode({'type': 'connection_init', 'payload': headers}));
      _ws!.listen((data) {
        final msg = data is String ? data : utf8.decode(data as List<int>);
        Map<String, dynamic> m;
        try {
          m = jsonDecode(msg) as Map<String, dynamic>;
        } catch (_) {
          log(LogMessage(MsgDir.received, msg));
          return;
        }
        switch (m['type']) {
          case 'connection_ack':
            info('Connection acknowledged; subscribing');
            _ws!.add(jsonEncode({
              'id': '1',
              'type': modern ? 'subscribe' : 'start',
              'payload': {'query': query, 'variables': variables},
            }));
            log(LogMessage(MsgDir.sent, prettyIfJson(jsonEncode({'query': query, 'variables': variables}))));
          case 'next':
          case 'data':
            log(LogMessage(MsgDir.received, prettyIfJson(jsonEncode(m['payload'])), label: 'next'));
          case 'error':
            log(LogMessage(MsgDir.error, prettyIfJson(jsonEncode(m['payload']))));
          case 'complete':
            info('Subscription completed by server');
          case 'ping':
            _ws!.add(jsonEncode({'type': 'pong'}));
          case 'ka':
          case 'pong':
            break;
          default:
            log(LogMessage(MsgDir.received, prettyIfJson(msg)));
        }
      }, onError: (e) => error(e), onDone: () {
        info('Disconnected');
        setConnected(false);
      });
    } catch (e) {
      error('Connection failed: $e');
      setConnected(false);
    }
  }

  @override
  Future<void> close() async {
    try {
      _ws?.add(jsonEncode({'id': '1', 'type': 'complete'}));
    } catch (_) {}
    await _ws?.close();
    _ws = null;
    if (connected) setConnected(false);
  }
}

// ============================================================================ SSE

class SseSession extends StreamSession {
  HttpClient? _client;
  StreamSubscription? _sub;
  SseSession(super.log, super.changed);

  Future<void> connect(PreparedRequest p, AppSettings s, bool verifySsl) async {
    busy = true;
    changed();
    final client = _client = createHttpClient(s, verifySsl: verifySsl, connectTimeout: const Duration(seconds: 15));
    client.idleTimeout = const Duration(days: 1);
    try {
      final req = await client.openUrl(p.method, p.uri);
      for (final h in p.headers) {
        req.headers.set(h.key, h.value, preserveHeaderCase: true);
      }
      if (p.header('accept') == null || p.header('accept') == '*/*') req.headers.set('Accept', 'text/event-stream');
      req.headers.set('Cache-Control', 'no-cache');
      req.contentLength = p.body.length;
      if (p.body.isNotEmpty) req.add(p.body);
      final resp = await req.close();
      final ct = resp.headers.contentType?.mimeType ?? '';
      if (resp.statusCode >= 300) {
        final body = await utf8.decodeStream(resp);
        error('HTTP ${resp.statusCode} ${resp.reasonPhrase}\n$body');
        setConnected(false);
        return;
      }
      info('Connected — HTTP ${resp.statusCode} ($ct)');
      setConnected(true);
      var event = '', id = '';
      final data = StringBuffer();
      var hasData = false;
      void dispatch() {
        if (hasData) {
          var text = data.toString();
          if (text.endsWith('\n')) text = text.substring(0, text.length - 1);
          log(LogMessage(MsgDir.received, prettyIfJson(text), label: [event.isEmpty ? 'message' : event, if (id.isNotEmpty) 'id: $id'].join(' · ')));
        }
        event = '';
        data.clear();
        hasData = false;
      }

      _sub = resp.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        if (line.isEmpty) {
          dispatch();
        } else if (line.startsWith(':')) {
          // comment / heartbeat
        } else {
          final i = line.indexOf(':');
          final field = i < 0 ? line : line.substring(0, i);
          var value = i < 0 ? '' : line.substring(i + 1);
          if (value.startsWith(' ')) value = value.substring(1);
          switch (field) {
            case 'event':
              event = value;
            case 'data':
              data.writeln(value);
              hasData = true;
            case 'id':
              id = value;
            case 'retry':
              info('Server requested retry interval $value ms');
          }
        }
      }, onError: (e) {
        error(e);
        setConnected(false);
      }, onDone: () {
        dispatch();
        info('Stream closed by server');
        setConnected(false);
      });
    } catch (e) {
      error('Connection failed: $e');
      setConnected(false);
    }
  }

  @override
  Future<void> close() async {
    await _sub?.cancel();
    _client?.close(force: true);
    _client = null;
    if (connected) {
      info('Disconnected');
      setConnected(false);
    }
  }
}

// ============================================================================ Socket.IO

class SocketIoSession extends StreamSession {
  sio.Socket? _socket;
  SocketIoSession(super.log, super.changed);

  void connect(String url, {required Map<String, String> headers, String path = '/socket.io', dynamic auth, String transport = 'websocket', Map<String, String> query = const {}}) {
    busy = true;
    changed();
    final builder = sio.OptionBuilder()
        .setTransports(transport == 'polling' ? ['polling'] : transport == 'both' ? ['polling', 'websocket'] : ['websocket'])
        .setExtraHeaders(headers)
        .setPath(path.isEmpty ? '/socket.io' : path)
        .disableAutoConnect()
        .enableForceNew()
        .disableReconnection();
    if (query.isNotEmpty) builder.setQuery(query);
    if (auth is Map && auth.isNotEmpty) builder.setAuth(auth);
    final s = _socket = sio.io(url, builder.build());
    s.onConnect((_) {
      info('Connected (id: ${s.id})');
      setConnected(true);
    });
    s.onConnectError((e) {
      error('Connect error: $e');
      setConnected(false);
    });
    s.onError((e) => error(e));
    s.onDisconnect((reason) {
      info('Disconnected: $reason');
      setConnected(false);
    });
    s.onAny((event, data) {
      log(LogMessage(MsgDir.received, _fmt(data), label: event));
    });
    s.connect();
  }

  static String _fmt(dynamic d) {
    if (d is String) return d;
    try {
      return const JsonEncoder.withIndent('  ').convert(d);
    } catch (_) {
      return d.toString();
    }
  }

  /// [args] is a JSON array of arguments (or a single JSON value / raw string).
  void emit(String event, String args, {bool ack = false}) {
    if (_socket == null || !connected) return;
    dynamic parsed;
    try {
      parsed = args.trim().isEmpty ? null : jsonDecode(args);
    } catch (_) {
      parsed = args;
    }
    log(LogMessage(MsgDir.sent, args, label: event));
    if (ack) {
      _socket!.emitWithAck(event, parsed, ack: (resp) => log(LogMessage(MsgDir.received, _fmt(resp), label: '$event (ack)')));
    } else {
      _socket!.emit(event, parsed);
    }
  }

  @override
  Future<void> close() async {
    _socket?.dispose();
    _socket = null;
    if (connected) {
      info('Disconnected');
      setConnected(false);
    }
  }
}

// ============================================================================ MQTT

class MqttSession extends StreamSession {
  MqttServerClient? _client;
  StreamSubscription? _sub;
  MqttSession(super.log, super.changed);

  Future<void> connect(ApiRequest r, bool verifySsl) async {
    busy = true;
    changed();
    try {
      final raw = r.url.trim().isEmpty ? 'mqtt://localhost:1883' : r.url.trim();
      final uri = Uri.parse(raw.contains('://') ? raw : 'mqtt://$raw');
      final scheme = uri.scheme.toLowerCase();
      final ws = scheme == 'ws' || scheme == 'wss';
      final secure = scheme == 'mqtts' || scheme == 'ssl' || scheme == 'wss';
      final port = uri.hasPort ? uri.port : (ws ? (secure ? 443 : 80) : (secure ? 8883 : 1883));
      final clientId = r.opt('mqttClientId').isNotEmpty ? r.opt('mqttClientId') : 'courier-${DateTime.now().millisecondsSinceEpoch}';
      final server = ws ? '$scheme://${uri.host}${uri.path.isEmpty ? '/mqtt' : uri.path}' : uri.host;
      final c = _client = MqttServerClient.withPort(server, clientId, port);
      c.logging(on: false);
      c.keepAlivePeriod = r.optInt('mqttKeepAlive', 60);
      c.setProtocolV311();
      c.autoReconnect = false;
      if (ws) {
        c.useWebSocket = true;
        c.websocketProtocols = MqttClientConstants.protocolsSingleDefault;
      }
      if (secure) {
        c.secure = !ws;
        if (!verifySsl) c.onBadCertificate = (_) => true;
      }
      final conn = MqttConnectMessage().withClientIdentifier(clientId);
      if (r.optBool('mqttClean', true)) conn.startClean();
      final will = r.opt('mqttWillTopic');
      if (will.isNotEmpty) {
        conn.withWillTopic(will).withWillMessage(r.opt('mqttWillMessage')).withWillQos(MqttQos.values[r.optInt('mqttQos').clamp(0, 2)]);
      }
      c.connectionMessage = conn;
      c.onDisconnected = () {
        info('Disconnected');
        setConnected(false);
      };
      c.onSubscribed = (t) => info('Subscribed to "$t"');
      c.onUnsubscribed = (t) => info('Unsubscribed from "$t"');
      final user = r.opt('mqttUser');
      final status = await c.connect(user.isEmpty ? null : user, r.opt('mqttPass').isEmpty ? null : r.opt('mqttPass'));
      if (status?.state != MqttConnectionState.connected) {
        error('Connection refused: ${status?.returnCode}');
        c.disconnect();
        setConnected(false);
        return;
      }
      info('Connected to $raw as $clientId');
      setConnected(true);
      _sub = c.updates?.listen((msgs) {
        for (final m in msgs) {
          final p = m.payload as MqttPublishMessage;
          final bytes = Uint8List.fromList(p.payload.message);
          log(LogMessage(MsgDir.received, prettyIfJson(bytesToDisplay(bytes)),
              label: '${m.topic} · QoS ${p.header?.qos.index ?? 0}${p.header?.retain == true ? ' · retained' : ''}'));
        }
      });
      for (final s in r.subscriptions.where((e) => e.enabled && e.key.isNotEmpty)) {
        subscribe(s.key, int.tryParse(s.value) ?? 0);
      }
    } catch (e) {
      error('Connection failed: $e');
      try {
        _client?.disconnect();
      } catch (_) {}
      setConnected(false);
    }
  }

  void subscribe(String topic, int qos) {
    _client?.subscribe(topic, MqttQos.values[qos.clamp(0, 2)]);
  }

  void unsubscribe(String topic) => _client?.unsubscribe(topic);

  void publish(String topic, String payload, int qos, bool retain) {
    if (_client == null || !connected) return;
    final buf = typed.Uint8Buffer()..addAll(utf8.encode(payload));
    _client!.publishMessage(topic, MqttQos.values[qos.clamp(0, 2)], buf, retain: retain);
    log(LogMessage(MsgDir.sent, payload, label: '$topic · QoS $qos${retain ? ' · retain' : ''}'));
  }

  @override
  Future<void> close() async {
    await _sub?.cancel();
    try {
      _client?.disconnect();
    } catch (_) {}
    _client = null;
    if (connected) setConnected(false);
  }
}

// ============================================================================ Kafka

class KafkaSession extends StreamSession {
  KafkaClient? _producer;
  KafkaClient? _consumer;
  bool consuming = false;
  KafkaSession(super.log, super.changed);

  static KafkaConfig configFor(ApiRequest r, bool verifySsl) => KafkaConfig(
        bootstrap: KafkaConfig.parseServers(r.url),
        security: r.opt('kafkaSecurity', 'PLAINTEXT'),
        saslMechanism: r.opt('kafkaSaslMechanism', 'PLAIN'),
        username: r.opt('kafkaUser'),
        password: r.opt('kafkaPass'),
        verifySsl: verifySsl,
        clientId: r.opt('kafkaClientId', 'courier'),
      );

  Future<List<String>> listTopics(ApiRequest r, bool verifySsl) async {
    final c = KafkaClient(configFor(r, verifySsl));
    try {
      final md = await c.metadata();
      return md.topics.values.where((t) => !t.internal).map((t) => '${t.name}').toList()..sort();
    } finally {
      await c.close();
    }
  }

  Future<void> produce(ApiRequest r, bool verifySsl) async {
    busy = true;
    changed();
    try {
      _producer ??= KafkaClient(configFor(r, verifySsl));
      final topic = r.opt('kafkaTopic');
      if (topic.isEmpty) throw KafkaException('Topic is required');
      final key = r.opt('kafkaKey');
      final res = await _producer!.produce(
        topic,
        key: key.isEmpty ? null : utf8.encode(key),
        value: r.message.isEmpty && r.optBool('kafkaNullValue') ? null : utf8.encode(r.message),
        headers: r.headers.where((h) => h.enabled && h.key.isNotEmpty).map((h) => MapEntry(h.key, utf8.encode(h.value) as List<int>?)).toList(),
        partition: r.optInt('kafkaPartition', -1),
        acks: r.optInt('kafkaAcks', -1),
      );
      log(LogMessage(MsgDir.sent, prettyIfJson(r.message),
          label: '$topic · partition ${res.partition}${res.offset >= 0 ? ' · offset ${res.offset}' : ''}${key.isNotEmpty ? ' · key $key' : ''}'));
    } catch (e) {
      error(e);
      await _producer?.close();
      _producer = null;
    } finally {
      busy = false;
      changed();
    }
  }

  Future<void> startConsuming(ApiRequest r, bool verifySsl) async {
    if (consuming) return;
    consuming = true;
    connected = true;
    changed();
    final topic = r.opt('kafkaTopic');
    final c = _consumer = KafkaClient(configFor(r, verifySsl));
    final from = r.opt('kafkaFrom', 'latest');
    info('Consuming "$topic" from $from');
    try {
      await for (final rec in c.consume(topic, from: from, partitionFilter: r.optInt('kafkaConsumePartition', -1), active: () => consuming)) {
        final hs = rec.headers.map((h) => '${h.key}=${bytesToDisplay(h.value)}').join(', ');
        log(LogMessage(MsgDir.received, prettyIfJson(bytesToDisplay(rec.value)),
            label: 'partition ${rec.partition} · offset ${rec.offset}'
                '${rec.key != null ? ' · key ${bytesToDisplay(rec.key)}' : ''}'
                '${hs.isNotEmpty ? ' · headers {$hs}' : ''} · ${rec.timestamp.toIso8601String()}'));
      }
    } catch (e) {
      if (consuming) error(e);
    } finally {
      consuming = false;
      connected = false;
      await c.close();
      info('Consumer stopped');
      changed();
    }
  }

  Future<void> stopConsuming() async {
    consuming = false;
    await _consumer?.close();
    changed();
  }

  @override
  Future<void> close() async {
    await stopConsuming();
    await _producer?.close();
    _producer = null;
  }
}
