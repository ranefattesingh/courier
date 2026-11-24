import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../models/models.dart';
import 'auth.dart';
import 'variables.dart';

const userAgent = 'CourierRuntime/1.0';

/// Returns a copy of [r] with every {{variable}} substituted.
ApiRequest resolveRequest(ApiRequest r, VariableScope s, AuthConfig effectiveAuth) {
  final c = r.clone();
  String f(String v) => s.resolve(v);
  List<KV> kv(List<KV> l) => l
      .map((e) => KV(key: f(e.key), value: e.type == 'file' ? e.value : f(e.value), enabled: e.enabled, type: e.type))
      .toList();
  c.url = f(c.url).trim();
  c.params = kv(c.params);
  c.headers = kv(c.headers);
  c.body.raw = f(c.body.raw);
  c.body.formData = kv(c.body.formData);
  c.body.urlEncoded = kv(c.body.urlEncoded);
  c.body.binaryPath = f(c.body.binaryPath);
  c.body.gqlQuery = f(c.body.gqlQuery);
  c.body.gqlVariables = f(c.body.gqlVariables);
  c.message = f(c.message);
  c.opts = c.opts.map((k, v) => MapEntry(k, f(v)));
  c.subscriptions = kv(c.subscriptions);
  c.auth = AuthConfig(type: effectiveAuth.type, p: effectiveAuth.p.map((k, v) => MapEntry(k, f(v))));
  return c;
}

Uri parseUrl(String raw, {String defaultScheme = 'http'}) {
  var url = raw.trim();
  if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(url)) url = '$defaultScheme://$url';
  try {
    return Uri.parse(url);
  } catch (_) {
    return Uri.parse(Uri.encodeFull(url));
  }
}

const _mimeByExt = {
  'json': 'application/json',
  'xml': 'application/xml',
  'txt': 'text/plain',
  'csv': 'text/csv',
  'html': 'text/html',
  'htm': 'text/html',
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'gif': 'image/gif',
  'svg': 'image/svg+xml',
  'webp': 'image/webp',
  'pdf': 'application/pdf',
  'zip': 'application/zip',
  'gz': 'application/gzip',
  'js': 'application/javascript',
  'mp4': 'video/mp4',
  'mp3': 'audio/mpeg',
  'wav': 'audio/wav',
  'proto': 'text/plain',
  'yaml': 'application/yaml',
  'yml': 'application/yaml',
};

String mimeForPath(String path) => _mimeByExt[path.split('.').last.toLowerCase()] ?? 'application/octet-stream';

const rawContentTypes = {
  'json': 'application/json',
  'xml': 'application/xml',
  'html': 'text/html',
  'javascript': 'application/javascript',
  'text': 'text/plain',
};

/// Builds the wire request (url, headers, body) for HTTP, GraphQL and SOAP requests.
/// [r] must already be variable-resolved.
Future<PreparedRequest> buildHttpRequest(ApiRequest r, AppSettings settings) async {
  final uri = parseUrl(r.url);
  final p = PreparedRequest(method: r.method.toUpperCase(), uri: uri);
  for (final h in r.headers) {
    if (h.enabled && h.key.trim().isNotEmpty) p.headers.add(MapEntry(h.key.trim(), h.value));
  }
  void defaultCt(String ct) {
    if (p.header('content-type') == null) p.headers.add(MapEntry('Content-Type', ct));
  }

  if (r.type == RequestType.graphql || r.body.mode == 'graphql') {
    dynamic vars = {};
    final vs = r.body.gqlVariables.trim();
    if (vs.isNotEmpty) {
      try {
        vars = jsonDecode(vs);
      } catch (e) {
        throw FormatException('GraphQL variables are not valid JSON: $e');
      }
    }
    final op = r.opt('gqlOperation');
    p.body = utf8.encode(jsonEncode({'query': r.body.gqlQuery, 'variables': vars, if (op.isNotEmpty) 'operationName': op}));
    defaultCt('application/json');
  } else if (r.type == RequestType.soap) {
    var envelope = r.body.raw;
    final wsse = r.opt('wsseType', 'none');
    if (wsse != 'none') envelope = injectWsSecurity(envelope, r.opt('wsseUser'), r.opt('wssePass'), digest: wsse == 'digest');
    p.body = utf8.encode(envelope);
    final action = r.opt('soapAction');
    if (r.opt('soapVersion', '1.1') == '1.2') {
      defaultCt('application/soap+xml; charset=utf-8${action.isNotEmpty ? '; action="$action"' : ''}');
    } else {
      defaultCt('text/xml; charset=utf-8');
      if (p.header('soapaction') == null) p.headers.add(MapEntry('SOAPAction', '"$action"'));
    }
  } else {
    switch (r.body.mode) {
      case 'raw':
        p.body = utf8.encode(r.body.raw);
        defaultCt(rawContentTypes[r.body.rawLang] ?? 'text/plain');
      case 'urlencoded':
        p.body = utf8.encode(r.body.urlEncoded
            .where((e) => e.enabled && e.key.isNotEmpty)
            .map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
            .join('&'));
        defaultCt('application/x-www-form-urlencoded');
      case 'form-data':
        final boundary = '--------------------------${List.generate(24, (_) => Random().nextInt(10)).join()}';
        final b = BytesBuilder();
        for (final f in r.body.formData.where((e) => e.enabled && e.key.isNotEmpty)) {
          b.add(utf8.encode('--$boundary\r\n'));
          if (f.type == 'file') {
            for (final path in f.value.split(';').where((e) => e.trim().isNotEmpty)) {
              final file = File(path.trim());
              if (!await file.exists()) throw FileSystemException('Form file not found', path);
              final name = file.uri.pathSegments.last;
              b.add(utf8.encode('Content-Disposition: form-data; name="${f.key}"; filename="$name"\r\n'
                  'Content-Type: ${mimeForPath(name)}\r\n\r\n'));
              b.add(await file.readAsBytes());
              b.add(utf8.encode('\r\n'));
            }
          } else {
            b.add(utf8.encode('Content-Disposition: form-data; name="${f.key}"\r\n\r\n${f.value}\r\n'));
          }
        }
        b.add(utf8.encode('--$boundary--\r\n'));
        p.body = b.toBytes();
        p.headers.removeWhere((h) => h.key.toLowerCase() == 'content-type');
        p.headers.add(MapEntry('Content-Type', 'multipart/form-data; boundary=$boundary'));
      case 'binary':
        if (r.body.binaryPath.isNotEmpty) {
          final file = File(r.body.binaryPath);
          if (!await file.exists()) throw FileSystemException('Binary body file not found', r.body.binaryPath);
          p.body = await file.readAsBytes();
          defaultCt(mimeForPath(r.body.binaryPath));
        }
      default:
        break;
    }
  }
  if (p.header('user-agent') == null) p.headers.add(const MapEntry('User-Agent', userAgent));
  if (p.header('accept') == null) p.headers.add(const MapEntry('Accept', '*/*'));
  if (settings.sendNoCacheHeader && p.header('cache-control') == null) {
    p.headers.add(const MapEntry('Cache-Control', 'no-cache'));
  }
  return p;
}

/// Adds a WS-Security UsernameToken header to a SOAP envelope.
String injectWsSecurity(String envelope, String user, String pass, {required bool digest}) {
  final created = DateTime.now().toUtc().toIso8601String();
  final nonceBytes = List.generate(16, (_) => Random.secure().nextInt(256));
  final nonce = base64.encode(nonceBytes);
  final pw = digest ? base64.encode(sha1.convert([...nonceBytes, ...utf8.encode(created), ...utf8.encode(pass)]).bytes) : pass;
  final type = digest ? 'PasswordDigest' : 'PasswordText';
  const wsse = 'http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd';
  const wsu = 'http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd';
  final sec = '<wsse:Security xmlns:wsse="$wsse" xmlns:wsu="$wsu"><wsse:UsernameToken>'
      '<wsse:Username>$user</wsse:Username>'
      '<wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#$type">$pw</wsse:Password>'
      '<wsse:Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">$nonce</wsse:Nonce>'
      '<wsu:Created>$created</wsu:Created></wsse:UsernameToken></wsse:Security>';
  final envMatch = RegExp(r'<(\w+):Envelope').firstMatch(envelope);
  final prefix = envMatch?.group(1) ?? 'soap';
  final headerOpen = RegExp('<$prefix:Header\\s*/>|<$prefix:Header(\\s[^>]*)?>');
  final hm = headerOpen.firstMatch(envelope);
  if (hm != null) {
    if (hm.group(0)!.endsWith('/>')) {
      return envelope.replaceRange(hm.start, hm.end, '<$prefix:Header>$sec</$prefix:Header>');
    }
    return envelope.replaceRange(hm.end, hm.end, sec);
  }
  final bm = RegExp('<$prefix:Body').firstMatch(envelope);
  if (bm == null) return envelope;
  return envelope.replaceRange(bm.start, bm.start, '<$prefix:Header>$sec</$prefix:Header>\n  ');
}

// ---------------------------------------------------------------------------- Cookies

class CookieJar {
  final List<StoredCookie> cookies;
  CookieJar([List<StoredCookie>? c]) : cookies = c ?? [];

  static bool domainMatches(String host, String domain) {
    final d = domain.startsWith('.') ? domain.substring(1) : domain;
    return host == d || host.endsWith('.$d');
  }

  List<StoredCookie> matching(Uri uri) {
    cookies.removeWhere((c) => c.expired);
    return cookies
        .where((c) =>
            domainMatches(uri.host, c.domain) &&
            (uri.path.isEmpty ? '/' : uri.path).startsWith(c.path) &&
            (!c.secure || uri.scheme == 'https' || uri.scheme == 'wss'))
        .toList();
  }

  List<StoredCookie> store(Uri uri, List<Cookie> received) {
    final out = <StoredCookie>[];
    for (final c in received) {
      DateTime? exp = c.expires;
      if (c.maxAge != null) exp = DateTime.now().add(Duration(seconds: c.maxAge!));
      final sc = StoredCookie(
        name: c.name,
        value: c.value,
        domain: (c.domain ?? uri.host).toLowerCase(),
        path: c.path ?? '/',
        expires: exp,
        secure: c.secure,
        httpOnly: c.httpOnly,
      );
      cookies.removeWhere((e) => e.name == sc.name && e.domain == sc.domain && e.path == sc.path);
      if (!sc.expired) cookies.add(sc);
      out.add(sc);
    }
    return out;
  }
}

// ---------------------------------------------------------------------------- Client

HttpClient createHttpClient(AppSettings s, {required bool verifySsl, Duration? connectTimeout}) {
  final ctx = SecurityContext(withTrustedRoots: true);
  if (s.caCertPath.isNotEmpty) ctx.setTrustedCertificates(s.caCertPath);
  if (s.clientCertPath.isNotEmpty) {
    ctx.useCertificateChain(s.clientCertPath);
    ctx.usePrivateKey(s.clientKeyPath.isNotEmpty ? s.clientKeyPath : s.clientCertPath,
        password: s.clientKeyPassphrase.isEmpty ? null : s.clientKeyPassphrase);
  }
  final c = HttpClient(context: ctx)
    ..autoUncompress = true
    ..userAgent = null
    ..maxConnectionsPerHost = 1
    ..idleTimeout = const Duration(seconds: 15)
    ..badCertificateCallback = (cert, host, port) => !verifySsl;
  if (connectTimeout != null) c.connectionTimeout = connectTimeout;
  switch (s.proxyMode) {
    case 'system':
      c.findProxy = HttpClient.findProxyFromEnvironment;
    case 'custom':
      if (s.proxyHost.isNotEmpty) {
        c.findProxy = (_) => 'PROXY ${s.proxyHost}:${s.proxyPort}';
        if (s.proxyUser.isNotEmpty) {
          c.addProxyCredentials(s.proxyHost, s.proxyPort, '', HttpClientBasicCredentials(s.proxyUser, s.proxyPass));
        }
      }
    default:
      c.findProxy = (_) => 'DIRECT';
  }
  return c;
}

class HttpEngine {
  HttpClient? _client;
  bool _cancelled = false;

  void cancel() {
    _cancelled = true;
    _client?.close(force: true);
  }

  Future<ResponseData> send(
    PreparedRequest p, {
    required AuthConfig auth,
    required AppSettings settings,
    required bool verifySsl,
    required bool followRedirects,
    required int timeoutMs,
    CookieJar? jar,
  }) async {
    final sw = Stopwatch()..start();
    final client = _client = createHttpClient(settings,
        verifySsl: verifySsl, connectTimeout: timeoutMs > 0 ? Duration(milliseconds: timeoutMs) : null);
    final result = ResponseData(method: p.method);
    try {
      final fut = _exchange(client, p, auth, settings, followRedirects, jar, result);
      if (timeoutMs > 0) {
        await fut.timeout(Duration(milliseconds: timeoutMs),
            onTimeout: () => throw TimeoutException('Request timed out after $timeoutMs ms'));
      } else {
        await fut;
      }
    } catch (e) {
      result.error = _cancelled ? 'Request cancelled' : _describeError(e);
    } finally {
      sw.stop();
      result.timeMs = sw.elapsedMilliseconds;
      client.close(force: true);
      _client = null;
    }
    return result;
  }

  static String _describeError(Object e) {
    if (e is SocketException) {
      return 'Could not connect: ${e.message}${e.osError != null ? ' (${e.osError!.message})' : ''}'
          '${e.address != null ? ' — ${e.address!.host}:${e.port ?? ''}' : ''}';
    }
    if (e is HandshakeException) return 'SSL handshake failed: ${e.message} ${e.osError?.message ?? ''}'.trim();
    if (e is TlsException) return 'TLS error: ${e.message} ${e.osError?.message ?? ''}'.trim();
    if (e is TimeoutException) return e.message ?? 'Request timed out';
    if (e is FileSystemException) return '${e.message}: ${e.path}';
    if (e is FormatException) return e.message;
    return e.toString();
  }

  Future<void> _exchange(HttpClient client, PreparedRequest p, AuthConfig auth, AppSettings settings,
      bool followRedirects, CookieJar? jar, ResponseData out) async {
    var method = p.method;
    var uri = p.uri;
    var headers = List<MapEntry<String, String>>.of(p.headers);
    var body = p.body;
    var redirects = 0;
    var digestTried = false;
    var ntlmStage = 0;
    if (auth.type == 'ntlm') {
      headers.removeWhere((h) => h.key.toLowerCase() == 'authorization');
      headers.add(MapEntry('Authorization', Ntlm.type1()));
      ntlmStage = 1;
    }

    while (true) {
      final req = await client.openUrl(method, uri);
      req.followRedirects = false;
      req.persistentConnection = true;
      req.headers.removeAll(HttpHeaders.acceptEncodingHeader);
      req.headers.set(HttpHeaders.acceptEncodingHeader, 'gzip, deflate');
      final sentHeaders = <MapEntry<String, String>>[];
      final setNames = <String>{};
      for (final h in headers) {
        final lower = h.key.toLowerCase();
        if (lower == 'content-length' || lower == 'host') continue;
        if (setNames.contains(lower)) {
          req.headers.add(h.key, h.value, preserveHeaderCase: true);
        } else {
          req.headers.set(h.key, h.value, preserveHeaderCase: true);
          setNames.add(lower);
        }
        sentHeaders.add(h);
      }
      if (jar != null && !setNames.contains('cookie')) {
        final cs = jar.matching(uri);
        if (cs.isNotEmpty) {
          final v = cs.map((c) => '${c.name}=${c.value}').join('; ');
          req.headers.set('Cookie', v, preserveHeaderCase: true);
          sentHeaders.add(MapEntry('Cookie', v));
        }
      }
      req.contentLength = body.length;
      if (body.isNotEmpty) req.add(body);
      final resp = await req.close();
      final bytes = await resp.fold<BytesBuilder>(BytesBuilder(copy: false), (b, d) => b..add(d)).then((b) => b.takeBytes());

      final respHeaders = <MapEntry<String, String>>[];
      resp.headers.forEach((name, values) {
        for (final v in values) {
          respHeaders.add(MapEntry(name, v));
        }
      });
      List<StoredCookie> cookies = [];
      try {
        if (jar != null && settings.autoSaveCookies) {
          cookies = jar.store(uri, resp.cookies);
        } else {
          cookies = CookieJar().store(uri, resp.cookies);
        }
      } catch (_) {}
      out.cookies.addAll(cookies);

      final wwwAuth = resp.headers[HttpHeaders.wwwAuthenticateHeader] ?? const <String>[];
      if (resp.statusCode == 401 && auth.type == 'digest' && !digestTried) {
        final ch = wwwAuth.firstWhere((v) => v.toLowerCase().startsWith('digest'), orElse: () => '');
        if (ch.isNotEmpty || auth.get('nonce').isNotEmpty) {
          digestTried = true;
          headers.removeWhere((h) => h.key.toLowerCase() == 'authorization');
          headers.add(MapEntry('Authorization', buildDigestHeader(auth, method, uri, ch, body)));
          continue;
        }
      }
      if (resp.statusCode == 401 && ntlmStage == 1) {
        final ch = wwwAuth.firstWhere((v) => v.toLowerCase().startsWith('ntlm '), orElse: () => '');
        if (ch.isNotEmpty) {
          ntlmStage = 2;
          headers.removeWhere((h) => h.key.toLowerCase() == 'authorization');
          headers.add(MapEntry('Authorization',
              Ntlm.type3(ch, auth.get('username'), auth.get('password'), auth.get('domain'), auth.get('workstation'))));
          continue;
        }
      }

      final loc = resp.headers.value(HttpHeaders.locationHeader);
      if (followRedirects && resp.isRedirect && loc != null && redirects < settings.maxRedirects) {
        redirects++;
        final next = uri.resolve(loc);
        if (resp.statusCode == 303 || ((resp.statusCode == 301 || resp.statusCode == 302) && method == 'POST')) {
          method = 'GET';
          body = [];
          headers.removeWhere((h) => h.key.toLowerCase() == 'content-type');
        }
        if (next.host != uri.host) headers.removeWhere((h) => h.key.toLowerCase() == 'authorization');
        uri = next;
        continue;
      }

      out
        ..status = resp.statusCode
        ..statusText = resp.reasonPhrase
        ..headers = respHeaders
        ..body = bytes
        ..finalUrl = uri.toString()
        ..method = method
        ..requestHeaders = sentHeaders
        ..requestBodyPreview = body.length > 20000
            ? '${utf8.decode(body.sublist(0, 20000), allowMalformed: true)}…'
            : utf8.decode(body, allowMalformed: true)
        ..size = bytes.length + respHeaders.fold<int>(0, (a, h) => a + h.key.length + h.value.length + 4);
      return;
    }
  }
}
