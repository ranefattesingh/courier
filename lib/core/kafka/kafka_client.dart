import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// A minimal, dependency-free Kafka client speaking the binary protocol directly.
/// Supports: Metadata, Produce (RecordBatch v2), ListOffsets, Fetch,
/// SASL PLAIN / SCRAM-SHA-256 / SCRAM-SHA-512, TLS.

class KafkaConfig {
  final List<(String, int)> bootstrap;

  /// PLAINTEXT | SSL | SASL_PLAINTEXT | SASL_SSL
  final String security;

  /// PLAIN | SCRAM-SHA-256 | SCRAM-SHA-512
  final String saslMechanism;
  final String username;
  final String password;
  final bool verifySsl;
  final String clientId;

  KafkaConfig({
    required this.bootstrap,
    this.security = 'PLAINTEXT',
    this.saslMechanism = 'PLAIN',
    this.username = '',
    this.password = '',
    this.verifySsl = true,
    this.clientId = 'courier',
  });

  static List<(String, int)> parseServers(String s) => s
      .split(RegExp(r'[,\s]+'))
      .where((e) => e.trim().isNotEmpty)
      .map((e) {
        var v = e.trim().replaceFirst(RegExp(r'^\w+://'), '');
        final i = v.lastIndexOf(':');
        return i > 0 ? (v.substring(0, i), int.tryParse(v.substring(i + 1)) ?? 9092) : (v, 9092);
      })
      .toList();
}

class KafkaException implements Exception {
  final String message;
  final int code;
  KafkaException(this.message, [this.code = -1]);
  @override
  String toString() => code >= 0 ? 'Kafka error $code (${kafkaErrorName(code)}): $message' : 'Kafka: $message';
}

String kafkaErrorName(int c) => const {
      1: 'OFFSET_OUT_OF_RANGE',
      2: 'CORRUPT_MESSAGE',
      3: 'UNKNOWN_TOPIC_OR_PARTITION',
      5: 'LEADER_NOT_AVAILABLE',
      6: 'NOT_LEADER_OR_FOLLOWER',
      7: 'REQUEST_TIMED_OUT',
      10: 'MESSAGE_TOO_LARGE',
      17: 'INVALID_TOPIC_EXCEPTION',
      19: 'NOT_ENOUGH_REPLICAS',
      29: 'TOPIC_AUTHORIZATION_FAILED',
      33: 'UNSUPPORTED_SASL_MECHANISM',
      34: 'ILLEGAL_SASL_STATE',
      35: 'UNSUPPORTED_VERSION',
      36: 'TOPIC_ALREADY_EXISTS',
      58: 'SASL_AUTHENTICATION_FAILED',
      87: 'INVALID_RECORD',
    }[c] ??
    'ERROR';

// ------------------------------------------------------------------ encoding helpers

class _W {
  final BytesBuilder b = BytesBuilder();
  void i8(int v) => b.addByte(v & 0xff);
  void i16(int v) => b.add((ByteData(2)..setInt16(0, v)).buffer.asUint8List());
  void i32(int v) => b.add((ByteData(4)..setInt32(0, v)).buffer.asUint8List());
  void u32(int v) => b.add((ByteData(4)..setUint32(0, v)).buffer.asUint8List());
  void i64(int v) => b.add((ByteData(8)..setInt64(0, v)).buffer.asUint8List());
  void str(String? s) {
    if (s == null) {
      i16(-1);
      return;
    }
    final e = utf8.encode(s);
    i16(e.length);
    b.add(e);
  }

  void bytes(List<int>? d) {
    if (d == null) {
      i32(-1);
      return;
    }
    i32(d.length);
    b.add(d);
  }

  void array<T>(List<T>? items, void Function(T) each) {
    if (items == null) {
      i32(-1);
      return;
    }
    i32(items.length);
    items.forEach(each);
  }

  void varint(int v) => uvarint((v << 1) ^ (v >> 63));
  void uvarint(int v) {
    while (true) {
      if (v >= 0 && v < 0x80) {
        b.addByte(v);
        return;
      }
      b.addByte((v & 0x7f) | 0x80);
      v = v >>> 7;
    }
  }

  void vbytes(List<int>? d) {
    if (d == null) {
      varint(-1);
      return;
    }
    varint(d.length);
    b.add(d);
  }

  Uint8List done() => b.toBytes();
}

class _R {
  final Uint8List buf;
  final ByteData bd;
  int pos;
  _R(this.buf) : pos = 0, bd = ByteData.sublistView(buf);
  int i8() => bd.getInt8(pos++);
  int i16() {
    final v = bd.getInt16(pos);
    pos += 2;
    return v;
  }

  int i32() {
    final v = bd.getInt32(pos);
    pos += 4;
    return v;
  }

  int u32() {
    final v = bd.getUint32(pos);
    pos += 4;
    return v;
  }

  int i64() {
    final v = bd.getInt64(pos);
    pos += 8;
    return v;
  }

  String? str() {
    final n = i16();
    if (n < 0) return null;
    final s = utf8.decode(buf.sublist(pos, pos + n), allowMalformed: true);
    pos += n;
    return s;
  }

  Uint8List? bytes() {
    final n = i32();
    if (n < 0) return null;
    final s = Uint8List.sublistView(buf, pos, pos + n);
    pos += n;
    return s;
  }

  List<T> array<T>(T Function() each) {
    final n = i32();
    if (n < 0) return [];
    return List.generate(n, (_) => each());
  }

  int uvarint() {
    var result = 0, shift = 0;
    while (true) {
      final b = buf[pos++];
      result |= (b & 0x7f) << shift;
      if (b & 0x80 == 0) return result;
      shift += 7;
    }
  }

  int varint() {
    final n = uvarint();
    return (n >>> 1) ^ -(n & 1);
  }

  Uint8List? vbytes() {
    final n = varint();
    if (n < 0) return null;
    final s = Uint8List.sublistView(buf, pos, pos + n);
    pos += n;
    return s;
  }

  bool get atEnd => pos >= buf.length;
}

// ------------------------------------------------------------------ CRC32C

final List<int> _crcTable = () {
  final t = List<int>.filled(256, 0);
  for (var i = 0; i < 256; i++) {
    var c = i;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0x82F63B78 ^ (c >>> 1) : c >>> 1;
    }
    t[i] = c;
  }
  return t;
}();

int crc32c(List<int> data) {
  var c = 0xFFFFFFFF;
  for (final b in data) {
    c = _crcTable[(c ^ b) & 0xff] ^ (c >>> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// Kafka's murmur2 (used by the default partitioner for keyed records).
int murmur2(List<int> data) {
  const m = 0x5bd1e995;
  const r = 24;
  final length = data.length;
  var h = (0x9747b28c ^ length) & 0xFFFFFFFF;
  int mul(int a, int b) => ((a & 0xFFFF) * b + ((((a >>> 16) * b) & 0xFFFF) << 16)) & 0xFFFFFFFF;
  final len4 = length ~/ 4;
  for (var i = 0; i < len4; i++) {
    final i4 = i * 4;
    var k = (data[i4] & 0xff) | ((data[i4 + 1] & 0xff) << 8) | ((data[i4 + 2] & 0xff) << 16) | ((data[i4 + 3] & 0xff) << 24);
    k = mul(k, m);
    k ^= k >>> r;
    k = mul(k, m);
    h = mul(h, m);
    h ^= k;
  }
  final rem = length % 4;
  final base = length & ~3;
  if (rem == 3) h ^= (data[base + 2] & 0xff) << 16;
  if (rem >= 2) h ^= (data[base + 1] & 0xff) << 8;
  if (rem >= 1) {
    h ^= data[base] & 0xff;
    h = mul(h, m);
  }
  h ^= h >>> 13;
  h = mul(h, m);
  h ^= h >>> 15;
  return h & 0xFFFFFFFF;
}

// ------------------------------------------------------------------ connection

class _Conn {
  final Socket socket;
  final String clientId;
  int _corr = 0;
  final _pending = <int, Completer<_R>>{};
  final _buf = BytesBuilder();
  bool closed = false;

  _Conn(this.socket, this.clientId) {
    socket.listen(_onData, onError: (e) => _failAll(e), onDone: () => _failAll(KafkaException('Connection closed by broker')));
  }

  static Future<_Conn> open(String host, int port, KafkaConfig cfg) async {
    final tls = cfg.security == 'SSL' || cfg.security == 'SASL_SSL';
    final Socket s = tls
        ? await SecureSocket.connect(host, port,
            timeout: const Duration(seconds: 10), onBadCertificate: cfg.verifySsl ? null : (_) => true)
        : await Socket.connect(host, port, timeout: const Duration(seconds: 10));
    s.setOption(SocketOption.tcpNoDelay, true);
    final c = _Conn(s, cfg.clientId);
    if (cfg.security.startsWith('SASL')) await c._sasl(cfg);
    return c;
  }

  void _failAll(Object e) {
    closed = true;
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(e);
    }
    _pending.clear();
  }

  void _onData(Uint8List d) {
    _buf.add(d);
    while (true) {
      final all = _buf.toBytes();
      if (all.length < 4) return;
      final len = ByteData.sublistView(all).getInt32(0);
      if (all.length < 4 + len) return;
      final frame = Uint8List.sublistView(all, 4, 4 + len);
      _buf.clear();
      if (all.length > 4 + len) _buf.add(Uint8List.sublistView(all, 4 + len));
      final r = _R(Uint8List.fromList(frame));
      final corr = r.i32();
      _pending.remove(corr)?.complete(r);
    }
  }

  Future<_R> request(int apiKey, int version, void Function(_W) body, {bool expectResponse = true}) {
    if (closed) throw KafkaException('Connection is closed');
    final corr = ++_corr;
    final w = _W()
      ..i16(apiKey)
      ..i16(version)
      ..i32(corr)
      ..str(clientId);
    body(w);
    final payload = w.done();
    final frame = _W()
      ..i32(payload.length)
      ..b.add(payload);
    final c = Completer<_R>();
    if (expectResponse) _pending[corr] = c;
    socket.add(frame.done());
    if (!expectResponse) c.complete(_R(Uint8List(0)));
    return c.future.timeout(const Duration(seconds: 40), onTimeout: () {
      _pending.remove(corr);
      throw KafkaException('Request timed out (api $apiKey)');
    });
  }

  Future<void> _sasl(KafkaConfig cfg) async {
    final mech = cfg.saslMechanism;
    final hs = await request(17, 1, (w) => w.str(mech));
    final err = hs.i16();
    final mechs = hs.array(() => hs.str() ?? '');
    if (err != 0) throw KafkaException('SASL mechanism $mech not enabled; broker supports ${mechs.join(', ')}', err);
    Future<Uint8List> auth(List<int> data) async {
      final r = await request(36, 0, (w) => w.bytes(data));
      final e = r.i16();
      final msg = r.str();
      final bytes = r.bytes() ?? Uint8List(0);
      if (e != 0) throw KafkaException('SASL authentication failed: ${msg ?? ''}', e);
      return bytes;
    }

    if (mech == 'PLAIN') {
      await auth(utf8.encode('\u0000${cfg.username}\u0000${cfg.password}'));
      return;
    }
    // SCRAM (RFC 5802)
    final hash = mech.endsWith('512') ? sha512 : sha256;
    final nonce = base64.encode(List.generate(24, (_) => Random.secure().nextInt(256)));
    final user = cfg.username.replaceAll('=', '=3D').replaceAll(',', '=2C');
    final clientFirstBare = 'n=$user,r=$nonce';
    final serverFirst = utf8.decode(await auth(utf8.encode('n,,$clientFirstBare')));
    final attrs = {for (final p in serverFirst.split(',')) p.substring(0, 1): p.substring(2)};
    final sNonce = attrs['r']!, salt = base64.decode(attrs['s']!), iter = int.parse(attrs['i']!);
    if (!sNonce.startsWith(nonce)) throw KafkaException('SCRAM server nonce mismatch');
    final salted = _pbkdf2(hash, utf8.encode(cfg.password), salt, iter);
    final clientKey = Hmac(hash, salted).convert(utf8.encode('Client Key')).bytes;
    final storedKey = hash.convert(clientKey).bytes;
    final clientFinalNoProof = 'c=biws,r=$sNonce';
    final authMsg = '$clientFirstBare,$serverFirst,$clientFinalNoProof';
    final sig = Hmac(hash, storedKey).convert(utf8.encode(authMsg)).bytes;
    final proof = List.generate(clientKey.length, (i) => clientKey[i] ^ sig[i]);
    final serverFinal = utf8.decode(await auth(utf8.encode('$clientFinalNoProof,p=${base64.encode(proof)}')));
    if (serverFinal.startsWith('e=')) throw KafkaException('SCRAM: ${serverFinal.substring(2)}');
  }

  static List<int> _pbkdf2(Hash h, List<int> pass, List<int> salt, int iterations) {
    final mac = Hmac(h, pass);
    var u = mac.convert([...salt, 0, 0, 0, 1]).bytes;
    final out = List<int>.of(u);
    for (var i = 1; i < iterations; i++) {
      u = mac.convert(u).bytes;
      for (var j = 0; j < out.length; j++) {
        out[j] ^= u[j];
      }
    }
    return out;
  }

  Future<void> close() async {
    closed = true;
    await socket.close();
    socket.destroy();
  }
}

// ------------------------------------------------------------------ public API

class KafkaPartitionInfo {
  final int id;
  final int leader;
  final int error;
  KafkaPartitionInfo(this.id, this.leader, this.error);
}

class KafkaTopicInfo {
  final String name;
  final int error;
  final bool internal;
  final List<KafkaPartitionInfo> partitions;
  KafkaTopicInfo(this.name, this.error, this.internal, this.partitions);
}

class KafkaMetadata {
  final Map<int, (String, int)> brokers;
  final Map<String, KafkaTopicInfo> topics;
  KafkaMetadata(this.brokers, this.topics);
}

class KafkaRecord {
  final String topic;
  final int partition;
  final int offset;
  final DateTime timestamp;
  final Uint8List? key;
  final Uint8List? value;
  final List<MapEntry<String, Uint8List?>> headers;
  KafkaRecord(this.topic, this.partition, this.offset, this.timestamp, this.key, this.value, this.headers);
}

class ProduceResult {
  final int partition;
  final int offset;
  ProduceResult(this.partition, this.offset);
}

class KafkaClient {
  final KafkaConfig cfg;
  final Map<int, _Conn> _brokerConns = {};
  _Conn? _boot;
  KafkaMetadata? _meta;
  int _rr = 0;

  KafkaClient(this.cfg);

  Future<_Conn> _bootstrap() async {
    if (_boot != null && !_boot!.closed) return _boot!;
    Object? last;
    for (final (h, p) in cfg.bootstrap) {
      try {
        return _boot = await _Conn.open(h, p, cfg);
      } catch (e) {
        last = e;
      }
    }
    throw KafkaException('Unable to connect to any bootstrap server: $last');
  }

  Future<KafkaMetadata> metadata({List<String>? topics}) async {
    final c = await _bootstrap();
    final r = await c.request(3, 1, (w) => w.array<String>(topics, w.str));
    final brokers = <int, (String, int)>{};
    for (final _ in Iterable.generate(r.i32())) {
      final id = r.i32();
      final host = r.str()!;
      final port = r.i32();
      r.str(); // rack
      brokers[id] = (host, port);
    }
    r.i32(); // controller id
    final ts = <String, KafkaTopicInfo>{};
    for (final _ in Iterable.generate(r.i32())) {
      final err = r.i16();
      final name = r.str()!;
      final internal = r.i8() != 0;
      final parts = <KafkaPartitionInfo>[];
      for (final _ in Iterable.generate(r.i32())) {
        final perr = r.i16();
        final pid = r.i32();
        final leader = r.i32();
        r.array(r.i32);
        r.array(r.i32);
        parts.add(KafkaPartitionInfo(pid, leader, perr));
      }
      parts.sort((a, b) => a.id.compareTo(b.id));
      ts[name] = KafkaTopicInfo(name, err, internal, parts);
    }
    return _meta = KafkaMetadata(brokers, ts);
  }

  Future<_Conn> _leaderConn(int brokerId) async {
    final existing = _brokerConns[brokerId];
    if (existing != null && !existing.closed) return existing;
    final b = _meta!.brokers[brokerId];
    if (b == null) throw KafkaException('Unknown broker $brokerId');
    try {
      return _brokerConns[brokerId] = await _Conn.open(b.$1, b.$2, cfg);
    } on SocketException catch (e) {
      throw KafkaException('Cannot reach broker $brokerId at ${b.$1}:${b.$2} (advertised listener): ${e.message}');
    }
  }

  Future<KafkaTopicInfo> _topic(String topic) async {
    var md = await metadata(topics: [topic]);
    var t = md.topics[topic];
    // Auto-created topics may report LEADER_NOT_AVAILABLE briefly.
    for (var i = 0; i < 10 && t != null && (t.error == 5 || t.partitions.any((p) => p.leader < 0)); i++) {
      await Future.delayed(const Duration(milliseconds: 300));
      md = await metadata(topics: [topic]);
      t = md.topics[topic];
    }
    if (t == null) throw KafkaException('Topic $topic not found');
    if (t.error != 0) throw KafkaException('Topic $topic', t.error);
    if (t.partitions.isEmpty) throw KafkaException('Topic $topic has no partitions');
    return t;
  }

  static Uint8List encodeBatch(List<(List<int>?, List<int>?, List<MapEntry<String, List<int>?>>)> records, {int? timestamp}) {
    final now = timestamp ?? DateTime.now().millisecondsSinceEpoch;
    final recs = _W();
    for (var i = 0; i < records.length; i++) {
      final (k, v, hs) = records[i];
      final rec = _W()
        ..i8(0)
        ..varint(0) // timestamp delta
        ..varint(i) // offset delta
        ..vbytes(k)
        ..vbytes(v)
        ..varint(hs.length);
      for (final h in hs) {
        rec.vbytes(utf8.encode(h.key));
        rec.vbytes(h.value);
      }
      final rb = rec.done();
      recs.varint(rb.length);
      recs.b.add(rb);
    }
    final afterCrc = _W()
      ..i16(0) // attributes
      ..i32(records.length - 1)
      ..i64(now)
      ..i64(now)
      ..i64(-1) // producer id
      ..i16(-1) // producer epoch
      ..i32(-1) // base sequence
      ..i32(records.length)
      ..b.add(recs.done());
    final tail = afterCrc.done();
    final mid = _W()
      ..i32(-1) // partition leader epoch
      ..i8(2) // magic
      ..u32(crc32c(tail))
      ..b.add(tail);
    final midBytes = mid.done();
    final batch = _W()
      ..i64(0)
      ..i32(midBytes.length)
      ..b.add(midBytes);
    return batch.done();
  }

  Future<ProduceResult> produce(
    String topic, {
    List<int>? key,
    List<int>? value,
    List<MapEntry<String, List<int>?>> headers = const [],
    int partition = -1,
    int acks = -1,
  }) async {
    final t = await _topic(topic);
    var pid = partition;
    if (pid < 0) {
      pid = key != null && key.isNotEmpty
          ? (murmur2(key) & 0x7fffffff) % t.partitions.length
          : (_rr++) % t.partitions.length;
    }
    final p = t.partitions.firstWhere((e) => e.id == pid, orElse: () => throw KafkaException('Partition $pid does not exist'));
    final conn = await _leaderConn(p.leader);
    final batch = encodeBatch([(key, value, headers)]);
    final r = await conn.request(0, 3, (w) {
      w.str(null);
      w.i16(acks);
      w.i32(30000);
      w.i32(1);
      w.str(topic);
      w.i32(1);
      w.i32(pid);
      w.bytes(batch);
    }, expectResponse: acks != 0);
    if (acks == 0) return ProduceResult(pid, -1);
    r.i32(); // topics
    r.str();
    r.i32(); // partitions
    final rp = r.i32();
    final err = r.i16();
    final offset = r.i64();
    if (err != 0) throw KafkaException('Produce to $topic[$rp] failed', err);
    return ProduceResult(rp, offset);
  }

  /// timestamp: -2 earliest, -1 latest
  Future<int> listOffset(String topic, int partition, int leader, int timestamp) async {
    final conn = await _leaderConn(leader);
    final r = await conn.request(2, 1, (w) {
      w.i32(-1);
      w.i32(1);
      w.str(topic);
      w.i32(1);
      w.i32(partition);
      w.i64(timestamp);
    });
    r.i32();
    r.str();
    r.i32();
    r.i32();
    final err = r.i16();
    r.i64();
    final off = r.i64();
    if (err != 0) throw KafkaException('ListOffsets $topic[$partition]', err);
    return off;
  }

  /// Streams records from [topic]. [from]: 'earliest' | 'latest' | offset number.
  Stream<KafkaRecord> consume(String topic, {String from = 'latest', int? partitionFilter, required bool Function() active}) async* {
    final t = await _topic(topic);
    final parts = t.partitions.where((p) => partitionFilter == null || partitionFilter < 0 || p.id == partitionFilter).toList();
    final offsets = <int, int>{};
    for (final p in parts) {
      final explicit = int.tryParse(from);
      offsets[p.id] = explicit ?? await listOffset(topic, p.id, p.leader, from == 'earliest' ? -2 : -1);
    }
    final byLeader = <int, List<KafkaPartitionInfo>>{};
    for (final p in parts) {
      (byLeader[p.leader] ??= []).add(p);
    }
    while (active()) {
      var got = false;
      for (final entry in byLeader.entries) {
        if (!active()) return;
        final conn = await _leaderConn(entry.key);
        final r = await conn.request(1, 4, (w) {
          w.i32(-1);
          w.i32(500); // max wait
          w.i32(1);
          w.i32(4 * 1024 * 1024);
          w.i8(0);
          w.i32(1);
          w.str(topic);
          w.i32(entry.value.length);
          for (final p in entry.value) {
            w.i32(p.id);
            w.i64(offsets[p.id]!);
            w.i32(1024 * 1024);
          }
        });
        r.i32(); // throttle
        final nTopics = r.i32();
        for (var ti = 0; ti < nTopics; ti++) {
          final tname = r.str()!;
          final nParts = r.i32();
          for (var pi = 0; pi < nParts; pi++) {
            final pid = r.i32();
            final err = r.i16();
            r.i64(); // high watermark
            r.i64(); // last stable
            final nAborted = r.i32();
            for (var a = 0; a < (nAborted < 0 ? 0 : nAborted); a++) {
              r.i64();
              r.i64();
            }
            final records = r.bytes();
            if (err == 1) {
              offsets[pid] = await listOffset(topic, pid, entry.key, -2);
              continue;
            }
            if (err != 0) throw KafkaException('Fetch $tname[$pid]', err);
            if (records == null || records.isEmpty) continue;
            for (final rec in decodeBatches(tname, pid, records)) {
              if (rec.offset < offsets[pid]!) continue;
              offsets[pid] = rec.offset + 1;
              got = true;
              yield rec;
            }
          }
        }
      }
      if (!got) await Future.delayed(const Duration(milliseconds: 200));
    }
  }

  static List<KafkaRecord> decodeBatches(String topic, int partition, Uint8List data) {
    final out = <KafkaRecord>[];
    final r = _R(data);
    while (r.pos + 17 <= data.length) {
      final baseOffset = r.i64();
      final batchLen = r.i32();
      final end = r.pos + batchLen;
      if (end > data.length) break; // partial batch at end of fetch
      r.i32(); // leader epoch
      final magic = r.i8();
      if (magic != 2) {
        r.pos = end;
        continue;
      }
      r.u32(); // crc
      final attrs = r.i16();
      r.i32(); // last offset delta
      final firstTs = r.i64();
      r.i64();
      r.i64();
      r.i16();
      r.i32();
      final count = r.i32();
      var body = Uint8List.sublistView(data, r.pos, end);
      final codec = attrs & 7;
      if (codec == 1) {
        body = Uint8List.fromList(gzip.decode(body));
      } else if (codec != 0) {
        out.add(KafkaRecord(topic, partition, baseOffset, DateTime.now(), null,
            utf8.encode('[batch of $count records compressed with ${const {2: 'snappy', 3: 'lz4', 4: 'zstd'}[codec]} — decompression not supported]'), []));
        r.pos = end;
        continue;
      }
      final isControl = attrs & 0x20 != 0;
      final rr = _R(body);
      for (var i = 0; i < count && !rr.atEnd; i++) {
        final len = rr.varint();
        final recEnd = rr.pos + len;
        rr.i8();
        final tsDelta = rr.varint();
        final offDelta = rr.varint();
        final key = rr.vbytes();
        final value = rr.vbytes();
        final nh = rr.varint();
        final hs = <MapEntry<String, Uint8List?>>[];
        for (var h = 0; h < nh; h++) {
          final hk = utf8.decode(rr.vbytes() ?? Uint8List(0));
          hs.add(MapEntry(hk, rr.vbytes()));
        }
        rr.pos = recEnd;
        if (!isControl) {
          out.add(KafkaRecord(topic, partition, baseOffset + offDelta,
              DateTime.fromMillisecondsSinceEpoch(firstTs + tsDelta), key, value, hs));
        }
      }
      r.pos = end;
    }
    return out;
  }

  Future<void> close() async {
    await _boot?.close();
    for (final c in _brokerConns.values) {
      await c.close();
    }
    _brokerConns.clear();
    _boot = null;
  }
}
