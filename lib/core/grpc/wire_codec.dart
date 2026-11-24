import 'dart:convert';
import 'dart:typed_data';

import 'proto_schema.dart';

/// Dynamic protobuf binary codec driven by a [ProtoRegistry].
class WireCodec {
  final ProtoRegistry reg;

  /// Emit proto3 default values for absent scalar fields when decoding.
  final bool emitDefaults;
  WireCodec(this.reg, {this.emitDefaults = true});

  // ======================================================================== encode
  Uint8List encode(String typeName, dynamic json) {
    final w = _Writer();
    _encodeMessage(w, typeName, json);
    return w.toBytes();
  }

  void _encodeMessage(_Writer w, String typeName, dynamic json) {
    json = _wktToPlain(typeName, json);
    if (json == null) return;
    if (json is! Map) throw FormatException('Expected a JSON object for message $typeName, got ${json.runtimeType}');
    final m = reg.message(typeName);
    for (final entry in json.entries) {
      final key = entry.key.toString();
      if (key == '@type') continue;
      final f = m.byJsonKey(key);
      if (f == null) throw FormatException('Message $typeName has no field "$key"');
      final v = entry.value;
      if (v == null) continue;
      final entryMsg = f.type == 'message' ? reg.messages[f.typeName] : null;
      if (entryMsg != null && entryMsg.isMapEntry) {
        if (v is! Map) throw FormatException('Field "$key" is a map; expected a JSON object');
        for (final me in v.entries) {
          final sub = _Writer();
          _encodeField(sub, entryMsg.fields[0], _mapKey(entryMsg.fields[0], me.key.toString()));
          _encodeField(sub, entryMsg.fields[1], me.value);
          w.tag(f.number, 2);
          w.bytes(sub.toBytes());
        }
        continue;
      }
      if (f.repeated) {
        if (v is! List) throw FormatException('Field "$key" is repeated; expected a JSON array');
        if (f.isPackable && f.packedOption != false && m.syntax != 'proto2' || f.packedOption == true) {
          final sub = _Writer();
          for (final item in v) {
            _writeScalar(sub, f, item);
          }
          w.tag(f.number, 2);
          w.bytes(sub.toBytes());
        } else {
          for (final item in v) {
            _encodeField(w, f, item);
          }
        }
      } else {
        _encodeField(w, f, v);
      }
    }
  }

  dynamic _mapKey(ProtoField f, String k) {
    if (f.type == 'bool') return k == 'true';
    if (f.type == 'string') return k;
    return int.parse(k);
  }

  void _encodeField(_Writer w, ProtoField f, dynamic v) {
    switch (f.type) {
      case 'message':
        final sub = _Writer();
        _encodeMessage(sub, f.typeName, v);
        w.tag(f.number, 2);
        w.bytes(sub.toBytes());
      case 'group':
        w.tag(f.number, 3);
        _encodeMessage(w, f.typeName, v);
        w.tag(f.number, 4);
      case 'string':
        w.tag(f.number, 2);
        w.bytes(utf8.encode(v is String ? v : jsonEncode(v)));
      case 'bytes':
        w.tag(f.number, 2);
        w.bytes(v is List ? v.cast<int>() : _b64(v.toString()));
      default:
        w.tag(f.number, _wireType(f.type));
        _writeScalar(w, f, v);
    }
  }

  static List<int> _b64(String s) {
    var t = s.replaceAll('-', '+').replaceAll('_', '/').replaceAll(RegExp(r'\s'), '');
    while (t.length % 4 != 0) {
      t += '=';
    }
    return base64.decode(t);
  }

  static int _wireType(String t) {
    switch (t) {
      case 'fixed64':
      case 'sfixed64':
      case 'double':
        return 1;
      case 'fixed32':
      case 'sfixed32':
      case 'float':
        return 5;
      case 'string':
      case 'bytes':
      case 'message':
        return 2;
      default:
        return 0;
    }
  }

  int _int(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is bool) return v ? 1 : 0;
    final s = v.toString().trim();
    final i = int.tryParse(s);
    if (i != null) return i;
    final b = BigInt.tryParse(s);
    if (b != null) return b.toSigned(64).toInt();
    throw FormatException('Expected an integer, got "$v"');
  }

  double _double(dynamic v) {
    if (v is num) return v.toDouble();
    final s = v.toString();
    if (s == 'NaN') return double.nan;
    if (s == 'Infinity') return double.infinity;
    if (s == '-Infinity') return double.negativeInfinity;
    return double.parse(s);
  }

  void _writeScalar(_Writer w, ProtoField f, dynamic v) {
    switch (f.type) {
      case 'int32':
      case 'int64':
      case 'uint32':
      case 'uint64':
        w.varint(_int(v));
      case 'bool':
        w.varint(v == true || v == 'true' || v == 1 ? 1 : 0);
      case 'enum':
        if (v is String && int.tryParse(v) == null) {
          final e = reg.enums[f.typeName];
          final n = e?.values[v];
          if (n == null) throw FormatException('Unknown enum value "$v" for ${f.typeName}');
          w.varint(n);
        } else {
          w.varint(_int(v));
        }
      case 'sint32':
      case 'sint64':
        final n = _int(v);
        w.varint((n << 1) ^ (n >> 63));
      case 'fixed32':
      case 'sfixed32':
        w.fixed32(_int(v));
      case 'float':
        w.float32(_double(v));
      case 'fixed64':
      case 'sfixed64':
        w.fixed64(_int(v));
      case 'double':
        w.float64(_double(v));
      default:
        throw FormatException('Cannot pack type ${f.type}');
    }
  }

  /// Converts canonical JSON forms of well-known types into their plain message form.
  dynamic _wktToPlain(String t, dynamic v) {
    switch (t) {
      case 'google.protobuf.Timestamp':
        if (v is String) {
          final d = DateTime.parse(v).toUtc();
          final us = d.microsecondsSinceEpoch;
          return {'seconds': us ~/ 1000000, 'nanos': (us % 1000000) * 1000};
        }
      case 'google.protobuf.Duration':
        if (v is String) {
          final s = double.parse(v.replaceAll('s', ''));
          final secs = s.truncate();
          return {'seconds': secs, 'nanos': ((s - secs) * 1e9).round()};
        }
      case 'google.protobuf.FieldMask':
        if (v is String) return {'paths': v.isEmpty ? [] : v.split(',')};
      case 'google.protobuf.Struct':
        if (v is Map && !(v.length == 1 && v['fields'] is Map && v['fields'].values.every((x) => x is Map))) {
          return {'fields': v.map((k, x) => MapEntry(k, x))};
        }
      case 'google.protobuf.ListValue':
        if (v is List) return {'values': v};
      case 'google.protobuf.Value':
        if (v == null) return {'null_value': 0};
        if (v is num) return {'number_value': v};
        if (v is String) return {'string_value': v};
        if (v is bool) return {'bool_value': v};
        if (v is List) return {'list_value': v};
        if (v is Map) {
          const keys = {'null_value', 'number_value', 'string_value', 'bool_value', 'struct_value', 'list_value'};
          if (v.length == 1 && keys.contains(v.keys.first)) return v;
          return {'struct_value': v};
        }
      case 'google.protobuf.Any':
        if (v is Map && v['@type'] is String) {
          final url = v['@type'] as String;
          final inner = url.substring(url.lastIndexOf('/') + 1);
          if (reg.messages.containsKey(inner)) {
            final body = Map<String, dynamic>.from(v)..remove('@type');
            final payload = body.length == 1 && body.containsKey('value') && _isWkt(inner) ? body['value'] : body;
            return {'type_url': url, 'value': base64.encode(encode(inner, payload))};
          }
        }
      default:
        if (t.startsWith('google.protobuf.') && t.endsWith('Value') && v is! Map) return {'value': v};
    }
    return v;
  }

  static bool _isWkt(String t) => t.startsWith('google.protobuf.');

  // ======================================================================== decode
  dynamic decode(String typeName, List<int> bytes) {
    final r = _Reader(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
    return _decodeMessage(r, typeName, r.length);
  }

  dynamic _decodeMessage(_Reader r, String typeName, int end, {int? groupNumber}) {
    final m = reg.message(typeName);
    final out = <String, dynamic>{};
    while (r.pos < end) {
      final tag = r.varint();
      final num = tag >>> 3;
      final wt = tag & 7;
      if (wt == 4) {
        if (num == groupNumber) break;
        throw const FormatException('Unexpected end-group tag');
      }
      final f = m.byNumber(num);
      if (f == null) {
        r.skip(wt, num);
        continue;
      }
      final entryMsg = f.type == 'message' ? reg.messages[f.typeName] : null;
      if (entryMsg != null && entryMsg.isMapEntry) {
        final len = r.varint();
        final e = _decodeMessage(r, f.typeName, r.pos + len) as Map<String, dynamic>;
        final map = (out[f.name] ??= <String, dynamic>{}) as Map<String, dynamic>;
        map[e['key'].toString()] = e['value'];
        continue;
      }
      if (f.repeated) {
        final list = (out[f.name] ??= <dynamic>[]) as List;
        if (wt == 2 && f.isPackable) {
          final len = r.varint();
          final stop = r.pos + len;
          while (r.pos < stop) {
            list.add(_readScalar(r, f));
          }
        } else {
          list.add(_readValue(r, f, wt));
        }
      } else {
        out[f.name] = _readValue(r, f, wt);
      }
    }
    if (emitDefaults) {
      for (final f in m.fields) {
        if (out.containsKey(f.name)) continue;
        final entryMsg = f.type == 'message' ? reg.messages[f.typeName] : null;
        if (entryMsg != null && entryMsg.isMapEntry) {
          out[f.name] = <String, dynamic>{};
        } else if (f.repeated) {
          out[f.name] = [];
        } else if (f.oneof == null && f.type != 'message' && f.type != 'group' && m.syntax != 'proto2') {
          out[f.name] = _default(f);
        }
      }
    }
    return _plainToWkt(typeName, out);
  }

  dynamic _default(ProtoField f) {
    switch (f.type) {
      case 'string':
      case 'bytes':
        return '';
      case 'bool':
        return false;
      case 'double':
      case 'float':
        return 0.0;
      case 'enum':
        return reg.enums[f.typeName]?.nameOf(0) ?? 0;
      default:
        return 0;
    }
  }

  dynamic _readValue(_Reader r, ProtoField f, int wt) {
    switch (f.type) {
      case 'message':
        final len = r.varint();
        return _decodeMessage(r, f.typeName, r.pos + len);
      case 'group':
        return _decodeMessage(r, f.typeName, r.length, groupNumber: f.number);
      case 'string':
        return utf8.decode(r.lenBytes(), allowMalformed: true);
      case 'bytes':
        return base64.encode(r.lenBytes());
      default:
        return _readScalar(r, f);
    }
  }

  dynamic _readScalar(_Reader r, ProtoField f) {
    switch (f.type) {
      case 'int32':
        return r.varint().toSigned(32);
      case 'int64':
        return r.varint();
      case 'uint32':
        return r.varint() & 0xFFFFFFFF;
      case 'uint64':
        final v = r.varint();
        return v < 0 ? BigInt.from(v).toUnsigned(64).toString() : v;
      case 'bool':
        return r.varint() != 0;
      case 'enum':
        final v = r.varint().toSigned(32);
        return reg.enums[f.typeName]?.nameOf(v) ?? v;
      case 'sint32':
      case 'sint64':
        final n = r.varint();
        return (n >>> 1) ^ -(n & 1);
      case 'fixed32':
        return r.fixed32().getUint32(0, Endian.little);
      case 'sfixed32':
        return r.fixed32().getInt32(0, Endian.little);
      case 'float':
        return r.fixed32().getFloat32(0, Endian.little);
      case 'fixed64':
        final v = r.fixed64().getInt64(0, Endian.little);
        return v < 0 ? BigInt.from(v).toUnsigned(64).toString() : v;
      case 'sfixed64':
        return r.fixed64().getInt64(0, Endian.little);
      case 'double':
        return r.fixed64().getFloat64(0, Endian.little);
    }
    throw FormatException('Unsupported scalar ${f.type}');
  }

  dynamic _plainToWkt(String t, Map<String, dynamic> m) {
    switch (t) {
      case 'google.protobuf.Timestamp':
        final s = (m['seconds'] as num?)?.toInt() ?? 0;
        final n = (m['nanos'] as num?)?.toInt() ?? 0;
        return DateTime.fromMicrosecondsSinceEpoch(s * 1000000 + n ~/ 1000, isUtc: true).toIso8601String();
      case 'google.protobuf.Duration':
        final s = (m['seconds'] as num?)?.toInt() ?? 0;
        final n = (m['nanos'] as num?)?.toInt() ?? 0;
        if (n == 0) return '${s}s';
        return '${(s + n / 1e9).toString()}s';
      case 'google.protobuf.FieldMask':
        return (m['paths'] as List? ?? []).join(',');
      case 'google.protobuf.Struct':
        return m['fields'] ?? {};
      case 'google.protobuf.ListValue':
        return m['values'] ?? [];
      case 'google.protobuf.Value':
        if (m.containsKey('null_value')) return null;
        for (final k in ['number_value', 'string_value', 'bool_value', 'struct_value', 'list_value']) {
          if (m.containsKey(k)) return m[k];
        }
        return null;
      case 'google.protobuf.Empty':
        return <String, dynamic>{};
      case 'google.protobuf.Any':
        final url = m['type_url']?.toString() ?? '';
        final inner = url.substring(url.lastIndexOf('/') + 1);
        if (reg.messages.containsKey(inner)) {
          try {
            final decoded = decode(inner, base64.decode(m['value']?.toString() ?? ''));
            if (decoded is Map) return {'@type': url, ...decoded};
            return {'@type': url, 'value': decoded};
          } catch (_) {}
        }
        return m;
      default:
        if (t.startsWith('google.protobuf.') && t.endsWith('Value') && m.containsKey('value')) return m['value'];
    }
    return m;
  }
}

class _Writer {
  final BytesBuilder _b = BytesBuilder();
  void tag(int number, int wt) => varint((number << 3) | wt);
  void varint(int v) {
    while (true) {
      if (v >= 0 && v < 0x80) {
        _b.addByte(v);
        return;
      }
      _b.addByte((v & 0x7f) | 0x80);
      v = v >>> 7;
    }
  }

  void bytes(List<int> data) {
    varint(data.length);
    _b.add(data);
  }

  void fixed32(int v) => _b.add((ByteData(4)..setUint32(0, v & 0xFFFFFFFF, Endian.little)).buffer.asUint8List());
  void fixed64(int v) => _b.add((ByteData(8)..setInt64(0, v, Endian.little)).buffer.asUint8List());
  void float32(double v) => _b.add((ByteData(4)..setFloat32(0, v, Endian.little)).buffer.asUint8List());
  void float64(double v) => _b.add((ByteData(8)..setFloat64(0, v, Endian.little)).buffer.asUint8List());
  Uint8List toBytes() => _b.toBytes();
}

class _Reader {
  final Uint8List buf;
  int pos = 0;
  _Reader(this.buf);
  int get length => buf.length;

  int varint() {
    var result = 0;
    var shift = 0;
    while (true) {
      if (pos >= buf.length) throw const FormatException('Truncated varint');
      final b = buf[pos++];
      if (shift < 64) result |= (b & 0x7f) << shift;
      if (b & 0x80 == 0) return result;
      shift += 7;
    }
  }

  Uint8List lenBytes() {
    final len = varint();
    if (pos + len > buf.length) throw const FormatException('Truncated length-delimited field');
    final out = Uint8List.sublistView(buf, pos, pos + len);
    pos += len;
    return out;
  }

  ByteData fixed32() {
    final d = ByteData.sublistView(buf, pos, pos + 4);
    pos += 4;
    return d;
  }

  ByteData fixed64() {
    final d = ByteData.sublistView(buf, pos, pos + 8);
    pos += 8;
    return d;
  }

  void skip(int wt, int number) {
    switch (wt) {
      case 0:
        varint();
      case 1:
        pos += 8;
      case 2:
        pos += varint();
      case 5:
        pos += 4;
      case 3:
        while (true) {
          final tag = varint();
          if (tag & 7 == 4 && tag >>> 3 == number) return;
          skip(tag & 7, tag >>> 3);
        }
      default:
        throw FormatException('Unknown wire type $wt');
    }
  }
}
