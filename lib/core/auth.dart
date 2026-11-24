import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:pointycastle/digests/md4.dart';

import '../models/models.dart';

final _rng = Random.secure();

/// Mutable request being prepared for the wire. Auth schemes modify it in place.
class PreparedRequest {
  String method;
  Uri uri;
  final List<MapEntry<String, String>> headers;
  List<int> body;

  PreparedRequest({required this.method, required this.uri, List<MapEntry<String, String>>? headers, List<int>? body})
      : headers = headers ?? [],
        body = body ?? [];

  String? header(String name) {
    final n = name.toLowerCase();
    for (final h in headers) {
      if (h.key.toLowerCase() == n) return h.value;
    }
    return null;
  }

  void setHeader(String name, String value) {
    headers.removeWhere((h) => h.key.toLowerCase() == name.toLowerCase());
    headers.add(MapEntry(name, value));
  }

  void addQuery(String key, String value) {
    final q = uri.query;
    final add = '${Uri.encodeQueryComponent(key)}=${Uri.encodeQueryComponent(value)}';
    uri = uri.replace(query: q.isEmpty ? add : '$q&$add');
  }

  Map<String, String> headerMap() => {for (final h in headers) h.key: h.value};
}

String rfc3986(String s) {
  final sb = StringBuffer();
  for (final b in utf8.encode(s)) {
    final c = String.fromCharCode(b);
    if (RegExp(r'[A-Za-z0-9\-._~]').hasMatch(c)) {
      sb.write(c);
    } else {
      sb.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
  }
  return sb.toString();
}

String randomHex(int bytes) => List.generate(bytes, (_) => _rng.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
String randomAlnum(int n) {
  const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  return List.generate(n, (_) => chars[_rng.nextInt(chars.length)]).join();
}

/// Applies stateless auth schemes. Digest and NTLM need a server challenge and
/// are completed by the HTTP engine via [buildDigestHeader] / [Ntlm].
class AuthApplier {
  static Future<void> apply(AuthConfig auth, PreparedRequest r) async {
    switch (auth.type) {
      case 'apikey':
        final key = auth.get('key');
        if (key.isEmpty) return;
        if (auth.get('in', 'header') == 'query') {
          r.addQuery(key, auth.get('value'));
        } else {
          r.setHeader(key, auth.get('value'));
        }
      case 'bearer':
        final t = auth.get('token');
        if (t.isNotEmpty) r.setHeader('Authorization', '${auth.get('prefix', 'Bearer')} $t'.trim());
      case 'basic':
        r.setHeader('Authorization', 'Basic ${base64.encode(utf8.encode('${auth.get('username')}:${auth.get('password')}'))}');
      case 'oauth1':
        _oauth1(auth, r);
      case 'oauth2':
        final t = auth.get('accessToken');
        if (t.isEmpty) return;
        if (auth.get('addTo', 'header') == 'query') {
          r.addQuery('access_token', t);
        } else {
          r.setHeader('Authorization', '${auth.get('headerPrefix', 'Bearer')} $t'.trim());
        }
      case 'hawk':
        _hawk(auth, r);
      case 'awsv4':
        _aws(auth, r);
      case 'akamai':
        _akamai(auth, r);
      case 'jwt':
        _jwt(auth, r);
      default:
        break;
    }
  }

  // ---------------------------------------------------------------- OAuth 1.0
  static void _oauth1(AuthConfig a, PreparedRequest r) {
    final method = a.get('signatureMethod', 'HMAC-SHA1');
    final oauth = <String, String>{
      'oauth_consumer_key': a.get('consumerKey'),
      'oauth_signature_method': method,
      'oauth_timestamp': a.get('timestamp').isNotEmpty
          ? a.get('timestamp')
          : (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString(),
      'oauth_nonce': a.get('nonce').isNotEmpty ? a.get('nonce') : randomAlnum(11),
      'oauth_version': a.get('version', '1.0'),
      if (a.get('token').isNotEmpty) 'oauth_token': a.get('token'),
      if (a.get('callback').isNotEmpty) 'oauth_callback': a.get('callback'),
      if (a.get('verifier').isNotEmpty) 'oauth_verifier': a.get('verifier'),
    };
    final params = <MapEntry<String, String>>[
      ...oauth.entries,
      for (final e in r.uri.queryParametersAll.entries)
        for (final v in e.value) MapEntry(e.key, v),
    ];
    final ct = r.header('content-type') ?? '';
    if (ct.contains('application/x-www-form-urlencoded') && r.body.isNotEmpty) {
      Uri.splitQueryString(utf8.decode(r.body, allowMalformed: true)).forEach((k, v) => params.add(MapEntry(k, v)));
    }
    final enc = params.map((e) => MapEntry(rfc3986(e.key), rfc3986(e.value))).toList()
      ..sort((x, y) => x.key == y.key ? x.value.compareTo(y.value) : x.key.compareTo(y.key));
    final paramStr = enc.map((e) => '${e.key}=${e.value}').join('&');
    final base = r.uri.replace(query: '', fragment: '').toString().replaceAll(RegExp(r'\?$'), '');
    final baseString = '${r.method.toUpperCase()}&${rfc3986(base)}&${rfc3986(paramStr)}';
    final key = '${rfc3986(a.get('consumerSecret'))}&${rfc3986(a.get('tokenSecret'))}';
    String sig;
    if (method == 'PLAINTEXT') {
      sig = key;
    } else {
      final h = method.endsWith('512') ? sha512 : method.endsWith('256') ? sha256 : sha1;
      sig = base64.encode(Hmac(h, utf8.encode(key)).convert(utf8.encode(baseString)).bytes);
    }
    oauth['oauth_signature'] = sig;
    if (a.get('addTo', 'header') == 'query') {
      oauth.forEach(r.addQuery);
    } else if (a.get('addTo') == 'body' && ct.contains('x-www-form-urlencoded')) {
      final extra = oauth.entries.map((e) => '${rfc3986(e.key)}=${rfc3986(e.value)}').join('&');
      r.body = utf8.encode(r.body.isEmpty ? extra : '${utf8.decode(r.body)}&$extra');
    } else {
      final realm = a.get('realm');
      final parts = [
        if (realm.isNotEmpty) 'realm="${rfc3986(realm)}"',
        ...oauth.entries.map((e) => '${e.key}="${rfc3986(e.value)}"'),
      ];
      r.setHeader('Authorization', 'OAuth ${parts.join(',')}');
    }
  }

  // ---------------------------------------------------------------- Hawk
  static void _hawk(AuthConfig a, PreparedRequest r) {
    final ts = a.get('timestamp').isNotEmpty ? a.get('timestamp') : (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
    final nonce = a.get('nonce').isNotEmpty ? a.get('nonce') : randomAlnum(6);
    final h = a.get('algorithm', 'sha256') == 'sha1' ? sha1 : sha256;
    final ext = a.get('ext');
    String hash = '';
    if (a.get('includePayloadHash') == 'true') {
      final ct = (r.header('content-type') ?? '').split(';').first.trim().toLowerCase();
      hash = base64.encode(h.convert(utf8.encode('hawk.1.payload\n$ct\n${utf8.decode(r.body, allowMalformed: true)}\n')).bytes);
    }
    final resource = r.uri.hasQuery ? '${r.uri.path.isEmpty ? '/' : r.uri.path}?${r.uri.query}' : (r.uri.path.isEmpty ? '/' : r.uri.path);
    final app = a.get('app'), dlg = a.get('dlg');
    var normalized = 'hawk.1.header\n$ts\n$nonce\n${r.method.toUpperCase()}\n$resource\n${r.uri.host.toLowerCase()}\n${r.uri.port}\n$hash\n$ext\n';
    if (app.isNotEmpty) normalized += '$app\n$dlg\n';
    final mac = base64.encode(Hmac(h, utf8.encode(a.get('authKey'))).convert(utf8.encode(normalized)).bytes);
    final parts = <String>[
      'id="${a.get('authId')}"',
      'ts="$ts"',
      'nonce="$nonce"',
      if (hash.isNotEmpty) 'hash="$hash"',
      if (ext.isNotEmpty) 'ext="$ext"',
      'mac="$mac"',
      if (app.isNotEmpty) 'app="$app"',
      if (dlg.isNotEmpty) 'dlg="$dlg"',
    ];
    r.setHeader('Authorization', 'Hawk ${parts.join(', ')}');
  }

  // ---------------------------------------------------------------- AWS SigV4
  static void _aws(AuthConfig a, PreparedRequest r) {
    final now = DateTime.now().toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    final dateStamp = '${now.year}${two(now.month)}${two(now.day)}';
    final amzDate = '${dateStamp}T${two(now.hour)}${two(now.minute)}${two(now.second)}Z';
    final region = a.get('region', 'us-east-1');
    final service = a.get('service', 'execute-api');
    final payloadHash = sha256.convert(r.body).toString();
    final session = a.get('sessionToken');

    r.setHeader('X-Amz-Date', amzDate);
    r.setHeader('X-Amz-Content-Sha256', payloadHash);
    if (session.isNotEmpty) r.setHeader('X-Amz-Security-Token', session);
    final host = r.uri.hasPort && !((r.uri.scheme == 'https' && r.uri.port == 443) || (r.uri.scheme == 'http' && r.uri.port == 80))
        ? '${r.uri.host}:${r.uri.port}'
        : r.uri.host;

    final signHeaders = <String, String>{'host': host};
    for (final h in r.headers) {
      final k = h.key.toLowerCase();
      if (k == 'content-type' || k.startsWith('x-amz-')) signHeaders[k] = h.value.trim().replaceAll(RegExp(r'\s+'), ' ');
    }
    final sortedKeys = signHeaders.keys.toList()..sort();
    final canonicalHeaders = sortedKeys.map((k) => '$k:${signHeaders[k]}\n').join();
    final signedHeaders = sortedKeys.join(';');

    final segs = r.uri.pathSegments.map((s) => service == 's3' ? rfc3986(s) : rfc3986(rfc3986(s))).join('/');
    final canonicalUri = '/$segs';
    final q = <MapEntry<String, String>>[
      for (final e in r.uri.queryParametersAll.entries)
        for (final v in e.value) MapEntry(rfc3986(e.key), rfc3986(v)),
    ]..sort((x, y) => x.key == y.key ? x.value.compareTo(y.value) : x.key.compareTo(y.key));
    final canonicalQuery = q.map((e) => '${e.key}=${e.value}').join('&');
    final canonicalRequest =
        '${r.method.toUpperCase()}\n$canonicalUri\n$canonicalQuery\n$canonicalHeaders\n$signedHeaders\n$payloadHash';
    final scope = '$dateStamp/$region/$service/aws4_request';
    final stringToSign = 'AWS4-HMAC-SHA256\n$amzDate\n$scope\n${sha256.convert(utf8.encode(canonicalRequest))}';
    List<int> hmac(List<int> k, String d) => Hmac(sha256, k).convert(utf8.encode(d)).bytes;
    var k = hmac(utf8.encode('AWS4${a.get('secretKey')}'), dateStamp);
    k = hmac(k, region);
    k = hmac(k, service);
    k = hmac(k, 'aws4_request');
    final signature = Hmac(sha256, k).convert(utf8.encode(stringToSign)).toString();
    final authValue =
        'AWS4-HMAC-SHA256 Credential=${a.get('accessKey')}/$scope, SignedHeaders=$signedHeaders, Signature=$signature';
    if (a.get('addTo', 'header') == 'query') {
      r.headers.removeWhere((h) => h.key.toLowerCase().startsWith('x-amz-'));
      r.addQuery('X-Amz-Algorithm', 'AWS4-HMAC-SHA256');
      r.addQuery('X-Amz-Credential', '${a.get('accessKey')}/$scope');
      r.addQuery('X-Amz-Date', amzDate);
      r.addQuery('X-Amz-SignedHeaders', signedHeaders);
      if (session.isNotEmpty) r.addQuery('X-Amz-Security-Token', session);
      r.addQuery('X-Amz-Signature', signature);
    } else {
      r.setHeader('Authorization', authValue);
    }
  }

  // ---------------------------------------------------------------- Akamai EdgeGrid
  static void _akamai(AuthConfig a, PreparedRequest r) {
    final now = DateTime.now().toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    final ts = a.get('timestamp').isNotEmpty
        ? a.get('timestamp')
        : '${now.year}${two(now.month)}${two(now.day)}T${two(now.hour)}:${two(now.minute)}:${two(now.second)}+0000';
    final nonce = a.get('nonce').isNotEmpty ? a.get('nonce') : '${randomHex(4)}-${randomHex(2)}-${randomHex(2)}-${randomHex(2)}-${randomHex(6)}';
    final authHeader =
        'EG1-HMAC-SHA256 client_token=${a.get('clientToken')};access_token=${a.get('accessToken')};timestamp=$ts;nonce=$nonce;';
    final signingKey = base64.encode(Hmac(sha256, utf8.encode(a.get('clientSecret'))).convert(utf8.encode(ts)).bytes);
    final headersToSign = a.get('headersToSign').split(',').map((e) => e.trim().toLowerCase()).where((e) => e.isNotEmpty);
    final canon = headersToSign
        .where((h) => r.header(h) != null)
        .map((h) => '$h:${r.header(h)!.trim().replaceAll(RegExp(r'\s+'), ' ')}')
        .join('\t');
    var contentHash = '';
    if (r.method.toUpperCase() == 'POST' && r.body.isNotEmpty) {
      final max = int.tryParse(a.get('maxBody', '131072')) ?? 131072;
      contentHash = base64.encode(sha256.convert(r.body.length > max ? r.body.sublist(0, max) : r.body).bytes);
    }
    final pathQuery = '${r.uri.path.isEmpty ? '/' : r.uri.path}${r.uri.hasQuery ? '?${r.uri.query}' : ''}';
    final data = [r.method.toUpperCase(), r.uri.scheme, r.uri.host, pathQuery, canon, contentHash, authHeader].join('\t');
    final sig = base64.encode(Hmac(sha256, utf8.encode(signingKey)).convert(utf8.encode(data)).bytes);
    r.setHeader('Authorization', '${authHeader}signature=$sig');
  }

  // ---------------------------------------------------------------- JWT Bearer
  static String generateJwt(AuthConfig a) {
    final algName = a.get('algorithm', 'HS256');
    Map<String, dynamic> payload;
    try {
      final p = a.get('payload', '{}').trim();
      payload = p.isEmpty ? {} : Map<String, dynamic>.from(jsonDecode(p) as Map);
    } catch (e) {
      throw FormatException('JWT payload is not valid JSON: $e');
    }
    Map<String, dynamic>? header;
    final hs = a.get('header').trim();
    if (hs.isNotEmpty) header = Map<String, dynamic>.from(jsonDecode(hs) as Map);
    final jwt = JWT(payload, header: header);
    final alg = <String, JWTAlgorithm>{
      'HS256': JWTAlgorithm.HS256,
      'HS384': JWTAlgorithm.HS384,
      'HS512': JWTAlgorithm.HS512,
      'RS256': JWTAlgorithm.RS256,
      'RS384': JWTAlgorithm.RS384,
      'RS512': JWTAlgorithm.RS512,
      'PS256': JWTAlgorithm.PS256,
      'PS384': JWTAlgorithm.PS384,
      'PS512': JWTAlgorithm.PS512,
      'ES256': JWTAlgorithm.ES256,
      'ES384': JWTAlgorithm.ES384,
      'ES512': JWTAlgorithm.ES512,
    }[algName]!;
    JWTKey key;
    if (algName.startsWith('HS')) {
      key = SecretKey(a.get('secret'), isBase64Encoded: a.get('secretBase64') == 'true');
    } else if (algName.startsWith('ES')) {
      key = ECPrivateKey(a.get('privateKey'));
    } else {
      key = RSAPrivateKey(a.get('privateKey'));
    }
    return jwt.sign(key, algorithm: alg, noIssueAt: payload.containsKey('iat'));
  }

  static void _jwt(AuthConfig a, PreparedRequest r) {
    final token = generateJwt(a);
    if (a.get('addTo', 'header') == 'query') {
      r.addQuery(a.get('queryParam', 'token'), token);
    } else {
      r.setHeader('Authorization', '${a.get('prefix', 'Bearer')} $token'.trim());
    }
  }
}

// ------------------------------------------------------------------ Digest

Map<String, String> parseAuthParams(String header) {
  final out = <String, String>{};
  final re = RegExp(r'(\w+)=(?:"((?:[^"\\]|\\.)*)"|([^\s,]+))');
  for (final m in re.allMatches(header)) {
    out[m.group(1)!.toLowerCase()] = m.group(2) ?? m.group(3) ?? '';
  }
  return out;
}

String buildDigestHeader(AuthConfig a, String method, Uri uri, String challenge, List<int> body, {int nc = 1}) {
  final c = parseAuthParams(challenge.replaceFirst(RegExp(r'^\s*Digest\s+', caseSensitive: false), ''));
  final realm = a.get('realm').isNotEmpty ? a.get('realm') : (c['realm'] ?? '');
  final nonce = a.get('nonce').isNotEmpty ? a.get('nonce') : (c['nonce'] ?? '');
  final algorithm = a.get('algorithm').isNotEmpty ? a.get('algorithm') : (c['algorithm'] ?? 'MD5');
  final qopOffered = (a.get('qop').isNotEmpty ? a.get('qop') : (c['qop'] ?? '')).split(',').map((e) => e.trim()).toList();
  final qop = qopOffered.contains('auth') ? 'auth' : (qopOffered.contains('auth-int') ? 'auth-int' : '');
  final opaque = a.get('opaque').isNotEmpty ? a.get('opaque') : (c['opaque'] ?? '');
  final cnonce = a.get('clientNonce').isNotEmpty ? a.get('clientNonce') : randomHex(8);
  final ncStr = nc.toRadixString(16).padLeft(8, '0');
  final hashAlg = algorithm.toUpperCase().startsWith('SHA-512') ? sha512 : algorithm.toUpperCase().startsWith('SHA-256') ? sha256 : md5;
  String h(String s) => hashAlg.convert(utf8.encode(s)).toString();
  final digestUri = '${uri.path.isEmpty ? '/' : uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';
  var ha1 = h('${a.get('username')}:$realm:${a.get('password')}');
  if (algorithm.toLowerCase().endsWith('-sess')) ha1 = h('$ha1:$nonce:$cnonce');
  final ha2 = qop == 'auth-int'
      ? h('${method.toUpperCase()}:$digestUri:${hashAlg.convert(body)}')
      : h('${method.toUpperCase()}:$digestUri');
  final response = qop.isEmpty ? h('$ha1:$nonce:$ha2') : h('$ha1:$nonce:$ncStr:$cnonce:$qop:$ha2');
  final parts = [
    'username="${a.get('username')}"',
    'realm="$realm"',
    'nonce="$nonce"',
    'uri="$digestUri"',
    'algorithm=$algorithm',
    if (qop.isNotEmpty) 'qop=$qop',
    if (qop.isNotEmpty) 'nc=$ncStr',
    if (qop.isNotEmpty) 'cnonce="$cnonce"',
    'response="$response"',
    if (opaque.isNotEmpty) 'opaque="$opaque"',
  ];
  return 'Digest ${parts.join(', ')}';
}

// ------------------------------------------------------------------ NTLM (v2)

class Ntlm {
  static const _flags = 0xA0088207;
  static final _sig = [0x4e, 0x54, 0x4c, 0x4d, 0x53, 0x53, 0x50, 0x00];

  static String type1() {
    final b = BytesBuilder();
    b.add(_sig);
    b.add(_u32(1));
    b.add(_u32(_flags));
    b.add(List.filled(16, 0)); // empty domain + workstation buffers
    return 'NTLM ${base64.encode(b.toBytes())}';
  }

  static List<int> _u32(int v) => [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff];
  static List<int> _u16(int v) => [v & 0xff, (v >> 8) & 0xff];
  static List<int> _utf16(String s) {
    final out = <int>[];
    for (final c in s.codeUnits) {
      out..add(c & 0xff)..add(c >> 8);
    }
    return out;
  }

  static List<int> _hmacMd5(List<int> key, List<int> data) => Hmac(md5, key).convert(data).bytes;

  static String type3(String challengeHeader, String user, String password, String domain, String workstation) {
    final token = challengeHeader.split(RegExp(r'\s+')).firstWhere((e) => e.length > 20, orElse: () => '');
    final t2 = base64.decode(token);
    final bd = ByteData.sublistView(Uint8List.fromList(t2));
    final serverChallenge = t2.sublist(24, 32);
    var targetInfo = <int>[];
    if (t2.length >= 48) {
      final len = bd.getUint16(40, Endian.little);
      final off = bd.getUint32(44, Endian.little);
      if (off + len <= t2.length) targetInfo = t2.sublist(off, off + len);
    }
    if (domain.isEmpty && user.contains('\\')) {
      final p = user.split('\\');
      domain = p[0];
      user = p[1];
    }
    final ntHash = MD4Digest().process(Uint8List.fromList(_utf16(password)));
    final v2Hash = _hmacMd5(ntHash, _utf16(user.toUpperCase() + domain));
    final clientChallenge = List.generate(8, (_) => _rng.nextInt(256));
    final ft = (DateTime.now().millisecondsSinceEpoch + 11644473600000) * 10000;
    final tsBytes = ByteData(8)..setUint64(0, ft, Endian.little);
    final blob = <int>[
      1, 1, 0, 0, 0, 0, 0, 0, //
      ...tsBytes.buffer.asUint8List(),
      ...clientChallenge,
      0, 0, 0, 0,
      ...targetInfo,
      0, 0, 0, 0,
    ];
    final ntProof = _hmacMd5(v2Hash, [...serverChallenge, ...blob]);
    final ntResp = [...ntProof, ...blob];
    final lmResp = [..._hmacMd5(v2Hash, [...serverChallenge, ...clientChallenge]), ...clientChallenge];

    final dom = _utf16(domain), usr = _utf16(user), ws = _utf16(workstation);
    var offset = 64;
    final payload = BytesBuilder();
    List<int> secBuf(List<int> data) {
      final r = [..._u16(data.length), ..._u16(data.length), ..._u32(offset)];
      offset += data.length;
      payload.add(data);
      return r;
    }

    final b = BytesBuilder();
    b.add(_sig);
    b.add(_u32(3));
    b.add(secBuf(lmResp));
    b.add(secBuf(ntResp));
    b.add(secBuf(dom));
    b.add(secBuf(usr));
    b.add(secBuf(ws));
    b.add(secBuf([]));
    b.add(_u32(_flags));
    b.add(payload.toBytes());
    return 'NTLM ${base64.encode(b.toBytes())}';
  }
}
