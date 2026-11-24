import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../models/models.dart';
import 'http_engine.dart';

const oauth2Grants = {
  'authorization_code': 'Authorization Code',
  'authorization_code_pkce': 'Authorization Code (with PKCE)',
  'implicit': 'Implicit',
  'password': 'Password Credentials',
  'client_credentials': 'Client Credentials',
  'refresh_token': 'Refresh Token',
};

String _rand(int n) {
  final r = Random.secure();
  const c = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
  return List.generate(n, (_) => c[r.nextInt(c.length)]).join();
}

/// Obtains an OAuth 2.0 token. [a] must be variable-resolved.
/// Returns the token endpoint JSON (access_token, refresh_token, expires_in...).
Future<Map<String, dynamic>> fetchOAuth2Token(
  AuthConfig a,
  AppSettings settings, {
  required Future<void> Function(Uri) openBrowser,
  void Function(String)? status,
}) async {
  final grant = a.get('grantType', 'client_credentials');
  final redirect = a.get('redirectUri', 'http://localhost:7777/callback');
  final form = <String, String>{};
  String? verifier;

  if (grant == 'authorization_code' || grant == 'authorization_code_pkce' || grant == 'implicit') {
    final state = _rand(16);
    final params = <String, String>{
      'response_type': grant == 'implicit' ? 'token' : 'code',
      'client_id': a.get('clientId'),
      'redirect_uri': redirect,
      if (a.get('scope').isNotEmpty) 'scope': a.get('scope'),
      'state': state,
      if (a.get('audience').isNotEmpty) 'audience': a.get('audience'),
    };
    if (grant == 'authorization_code_pkce') {
      verifier = _rand(64);
      final method = a.get('challengeMethod', 'S256');
      params['code_challenge'] = method == 'plain'
          ? verifier
          : base64Url.encode(sha256.convert(ascii.encode(verifier)).bytes).replaceAll('=', '');
      params['code_challenge_method'] = method;
    }
    final authUri = Uri.parse(a.get('authUrl'));
    final full = authUri.replace(queryParameters: {...authUri.queryParameters, ...params});
    final result = await _awaitRedirect(Uri.parse(redirect), full, openBrowser, status, implicit: grant == 'implicit');
    if (result['error'] != null) throw Exception('Authorization failed: ${result['error']} ${result['error_description'] ?? ''}');
    if (result['state'] != null && result['state'] != state) throw Exception('OAuth state mismatch — possible CSRF');
    if (grant == 'implicit') return result;
    form['grant_type'] = 'authorization_code';
    form['code'] = result['code']?.toString() ?? '';
    form['redirect_uri'] = redirect;
    if (verifier != null) form['code_verifier'] = verifier;
  } else if (grant == 'password') {
    form['grant_type'] = 'password';
    form['username'] = a.get('username');
    form['password'] = a.get('password');
    if (a.get('scope').isNotEmpty) form['scope'] = a.get('scope');
  } else if (grant == 'refresh_token') {
    form['grant_type'] = 'refresh_token';
    form['refresh_token'] = a.get('refreshToken');
    if (a.get('scope').isNotEmpty) form['scope'] = a.get('scope');
  } else {
    form['grant_type'] = 'client_credentials';
    if (a.get('scope').isNotEmpty) form['scope'] = a.get('scope');
  }
  if (a.get('audience').isNotEmpty) form['audience'] = a.get('audience');
  if (a.get('resource').isNotEmpty) form['resource'] = a.get('resource');

  status?.call('Requesting token from ${a.get('tokenUrl')}…');
  final client = createHttpClient(settings, verifySsl: settings.verifySsl, connectTimeout: const Duration(seconds: 20));
  try {
    final req = await client.postUrl(Uri.parse(a.get('tokenUrl')));
    req.headers.set('Content-Type', 'application/x-www-form-urlencoded');
    req.headers.set('Accept', 'application/json');
    if (a.get('clientAuth', 'header') == 'header' && a.get('clientSecret').isNotEmpty) {
      req.headers.set('Authorization',
          'Basic ${base64.encode(utf8.encode('${Uri.encodeQueryComponent(a.get('clientId'))}:${Uri.encodeQueryComponent(a.get('clientSecret'))}'))}');
    } else {
      form['client_id'] = a.get('clientId');
      if (a.get('clientSecret').isNotEmpty) form['client_secret'] = a.get('clientSecret');
    }
    final body = utf8.encode(form.entries.map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join('&'));
    req.contentLength = body.length;
    req.add(body);
    final resp = await req.close();
    final text = await utf8.decodeStream(resp);
    Map<String, dynamic> json;
    try {
      json = Map<String, dynamic>.from(jsonDecode(text) as Map);
    } catch (_) {
      json = Map<String, dynamic>.from(Uri.splitQueryString(text));
    }
    if (resp.statusCode >= 400 || json['access_token'] == null) {
      throw Exception('Token request failed (HTTP ${resp.statusCode}): $text');
    }
    return json;
  } finally {
    client.close(force: true);
  }
}

Future<Map<String, String>> _awaitRedirect(Uri redirect, Uri authorizeUrl, Future<void> Function(Uri) openBrowser,
    void Function(String)? status,
    {required bool implicit}) async {
  final port = redirect.hasPort ? redirect.port : 80;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port, shared: true);
  final done = Completer<Map<String, String>>();
  const closePage = '<html><body style="font-family:sans-serif;padding:40px">'
      '<h2>Authorization complete</h2><p>You can close this window and return to Courier.</p></body></html>';
  server.listen((req) async {
    final path = req.uri.path;
    if (implicit && path == redirect.path && req.uri.queryParameters.isEmpty) {
      req.response.headers.contentType = ContentType.html;
      req.response.write('<html><body><script>'
          'location.replace("${redirect.path}_fragment?" + location.hash.substring(1));'
          '</script></body></html>');
      await req.response.close();
      return;
    }
    if (path == redirect.path || path == '${redirect.path}_fragment') {
      req.response.headers.contentType = ContentType.html;
      req.response.write(closePage);
      await req.response.close();
      if (!done.isCompleted) done.complete(req.uri.queryParameters);
    } else {
      req.response.statusCode = 404;
      await req.response.close();
    }
  });
  try {
    status?.call('Waiting for authorization in your browser…');
    await openBrowser(authorizeUrl);
    return await done.future.timeout(const Duration(minutes: 5),
        onTimeout: () => throw TimeoutException('Timed out waiting for the browser redirect'));
  } finally {
    await server.close(force: true);
  }
}
