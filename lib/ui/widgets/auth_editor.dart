import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/auth.dart';
import '../../core/http_engine.dart';
import '../../core/oauth2.dart';
import '../../core/variables.dart';
import '../../models/models.dart';
import '../../state/app_state.dart';
import 'common.dart';

class AuthEditor extends StatefulWidget {
  final AuthConfig auth;
  final VoidCallback onChanged;
  final bool allowInherit;

  /// Name of the folder/collection auth is inherited from (when type == inherit).
  final String inheritedFrom;
  final VariableScope Function()? scope;

  /// Restrict to schemes that make sense for the protocol (null = all).
  final Set<String>? only;

  const AuthEditor({
    super.key,
    required this.auth,
    required this.onChanged,
    this.allowInherit = true,
    this.inheritedFrom = '',
    this.scope,
    this.only,
  });

  @override
  State<AuthEditor> createState() => _AuthEditorState();
}

class _AuthEditorState extends State<AuthEditor> {
  bool _fetching = false;
  String _status = '';

  AuthConfig get a => widget.auth;

  void _set(String k, String v) {
    a.set(k, v);
    widget.onChanged();
  }

  Widget _text(String label, String key, {String hint = '', bool secret = false, bool multiline = false, String? help, String def = ''}) =>
      FieldRow(
        label,
        SyncedTextField(
          key: ValueKey('${a.type}.$key'),
          value: a.get(key, def),
          hint: hint,
          obscure: secret,
          multiline: multiline,
          scope: widget.scope,
          onChanged: (v) => _set(key, v),
        ),
        help: help,
      );

  Widget _select(String label, String key, Map<String, String> options, {String? help}) => FieldRow(
        label,
        Align(
          alignment: Alignment.centerLeft,
          child: CompactDropdown<String>(
            width: 320,
            value: a.get(key, options.keys.first),
            items: options,
            onChanged: (v) => setState(() => _set(key, v)),
          ),
        ),
        help: help,
      );

  Widget _check(String label, String key, {String? help}) => FieldRow(
        label,
        Align(
          alignment: Alignment.centerLeft,
          child: Checkbox(value: a.get(key) == 'true', onChanged: (v) => setState(() => _set(key, (v ?? false).toString()))),
        ),
        help: help,
      );

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 4),
        child: Text(t, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );

  Future<void> _getToken() async {
    final appState = context.read<AppState>();
    setState(() {
      _fetching = true;
      _status = '';
    });
    try {
      final scope = widget.scope?.call() ?? VariableScope();
      final resolved = AuthConfig(type: 'oauth2', p: a.p.map((k, v) => MapEntry(k, scope.resolve(v))));
      final tok = await fetchOAuth2Token(resolved, appState.settings,
          openBrowser: (u) async {
            if (!await launchUrl(u, mode: LaunchMode.externalApplication)) throw Exception('Could not open browser for $u');
          },
          status: (s) => mounted ? setState(() => _status = s) : null);
      a.set('accessToken', tok['access_token']?.toString() ?? '');
      if (tok['refresh_token'] != null) a.set('refreshToken', tok['refresh_token'].toString());
      if (tok['id_token'] != null) a.set('idToken', tok['id_token'].toString());
      if (tok['token_type'] != null) a.set('tokenType', tok['token_type'].toString());
      final exp = int.tryParse(tok['expires_in']?.toString() ?? '');
      a.set('expiresAt', exp == null ? '' : DateTime.now().add(Duration(seconds: exp)).toIso8601String());
      widget.onChanged();
      setState(() => _status = 'Token received${exp != null ? ' (expires in ${exp}s)' : ''}');
    } catch (e) {
      setState(() => _status = 'Error: $e');
    } finally {
      if (mounted) setState(() => _fetching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final types = Map.of(authTypes)..removeWhere((k, _) => (!widget.allowInherit && k == 'inherit') || (widget.only != null && !widget.only!.contains(k) && k != 'inherit' && k != 'none'));
    final type = types.containsKey(a.type) ? a.type : types.keys.first;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(14),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 260,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Auth Type', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            const SizedBox(height: 6),
            CompactDropdown<String>(
              width: 240,
              value: type,
              items: types,
              onChanged: (v) => setState(() {
                a.type = v;
                widget.onChanged();
              }),
            ),
            const SizedBox(height: 12),
            Text(_describe(type), style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant, height: 1.4)),
          ]),
        ),
        const SizedBox(width: 24),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: _fields(type, cs))),
      ]),
    );
  }

  String _describe(String t) {
    switch (t) {
      case 'inherit':
        return widget.inheritedFrom.isEmpty
            ? 'This request uses the authorization of its parent folder or collection. Save it to a collection to inherit.'
            : 'This request is using authorization from "${widget.inheritedFrom}".';
      case 'none':
        return 'This request does not use any authorization.';
      case 'digest':
        return 'Courier performs the challenge round-trip automatically: it sends the request, reads the WWW-Authenticate challenge and retries with the computed digest.';
      case 'ntlm':
        return 'NTLMv2 handshake (negotiate → challenge → authenticate) over a single kept-alive connection.';
      case 'oauth2':
        return 'Use an existing access token or obtain a new one using any OAuth 2.0 grant type.';
      default:
        return 'The authorization header will be automatically generated when you send the request.';
    }
  }

  List<Widget> _fields(String type, ColorScheme cs) {
    switch (type) {
      case 'apikey':
        return [
          _text('Key', 'key', hint: 'X-API-Key'),
          _text('Value', 'value', secret: true),
          _select('Add to', 'in', {'header': 'Header', 'query': 'Query Params'}),
        ];
      case 'bearer':
        return [_text('Token', 'token', secret: true), _text('Prefix', 'prefix', def: 'Bearer', hint: 'Bearer')];
      case 'basic':
        return [_text('Username', 'username'), _text('Password', 'password', secret: true)];
      case 'digest':
        return [
          _text('Username', 'username'),
          _text('Password', 'password', secret: true),
          _section('Advanced (optional; auto-filled from challenge)'),
          _text('Realm', 'realm'),
          _text('Nonce', 'nonce'),
          _select('Algorithm', 'algorithm', {'': 'From server', 'MD5': 'MD5', 'MD5-sess': 'MD5-sess', 'SHA-256': 'SHA-256', 'SHA-256-sess': 'SHA-256-sess', 'SHA-512-256': 'SHA-512-256'}),
          _text('qop', 'qop', hint: 'auth'),
          _text('Client Nonce', 'clientNonce'),
          _text('Opaque', 'opaque'),
        ];
      case 'oauth1':
        return [
          _select('Signature Method', 'signatureMethod', {'HMAC-SHA1': 'HMAC-SHA1', 'HMAC-SHA256': 'HMAC-SHA256', 'HMAC-SHA512': 'HMAC-SHA512', 'PLAINTEXT': 'PLAINTEXT'}),
          _text('Consumer Key', 'consumerKey'),
          _text('Consumer Secret', 'consumerSecret', secret: true),
          _text('Access Token', 'token'),
          _text('Token Secret', 'tokenSecret', secret: true),
          _select('Add auth data to', 'addTo', {'header': 'Request Headers', 'query': 'Request URL / Query', 'body': 'Request Body (urlencoded)'}),
          _section('Advanced'),
          _text('Callback URL', 'callback'),
          _text('Verifier', 'verifier'),
          _text('Timestamp', 'timestamp', hint: 'auto'),
          _text('Nonce', 'nonce', hint: 'auto'),
          _text('Version', 'version', def: '1.0'),
          _text('Realm', 'realm'),
        ];
      case 'oauth2':
        final grant = a.get('grantType', 'authorization_code');
        final needsBrowser = grant.startsWith('authorization_code') || grant == 'implicit';
        final exp = DateTime.tryParse(a.get('expiresAt'));
        return [
          _section('Current Token'),
          _text('Access Token', 'accessToken', secret: true),
          if (exp != null)
            Padding(
              padding: const EdgeInsets.only(left: 170, bottom: 6),
              child: Text(exp.isBefore(DateTime.now()) ? 'Token expired at $exp' : 'Expires at ${exp.toLocal()}',
                  style: TextStyle(fontSize: 12, color: exp.isBefore(DateTime.now()) ? cs.error : cs.onSurfaceVariant)),
            ),
          _text('Header Prefix', 'headerPrefix', def: 'Bearer'),
          _select('Add token to', 'addTo', {'header': 'Request Headers', 'query': 'Request URL'}),
          _section('Configure New Token'),
          _select('Grant Type', 'grantType', oauth2Grants),
          if (needsBrowser) _text('Callback URL', 'redirectUri', def: 'http://localhost:7777/callback', help: 'Courier listens here'),
          if (needsBrowser) _text('Auth URL', 'authUrl', hint: 'https://provider.com/oauth/authorize'),
          if (grant != 'implicit') _text('Access Token URL', 'tokenUrl', hint: 'https://provider.com/oauth/token'),
          _text('Client ID', 'clientId'),
          if (grant != 'implicit') _text('Client Secret', 'clientSecret', secret: true),
          if (grant == 'authorization_code_pkce') _select('Code Challenge Method', 'challengeMethod', {'S256': 'SHA-256', 'plain': 'Plain'}),
          if (grant == 'password') _text('Username', 'username'),
          if (grant == 'password') _text('Password', 'password', secret: true),
          if (grant == 'refresh_token') _text('Refresh Token', 'refreshToken', secret: true),
          _text('Scope', 'scope', hint: 'e.g. read:org'),
          _text('Audience', 'audience'),
          _text('Resource', 'resource'),
          if (grant != 'implicit') _select('Client Authentication', 'clientAuth', {'header': 'Send as Basic Auth header', 'body': 'Send client credentials in body'}),
          const SizedBox(height: 10),
          Row(children: [
            const SizedBox(width: 170),
            FilledButton.icon(
              onPressed: _fetching ? null : _getToken,
              icon: _fetching ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.key, size: 16),
              label: const Text('Get New Access Token'),
            ),
            if (a.get('refreshToken').isNotEmpty && grant != 'refresh_token') ...[
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _fetching
                    ? null
                    : () async {
                        final g = a.get('grantType');
                        a.set('grantType', 'refresh_token');
                        await _getToken();
                        a.set('grantType', g);
                        widget.onChanged();
                      },
                child: const Text('Refresh'),
              ),
            ],
          ]),
          if (_status.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 170, top: 8),
              child: SelectableText(_status, style: TextStyle(fontSize: 12, color: _status.startsWith('Error') ? cs.error : cs.onSurfaceVariant)),
            ),
        ];
      case 'hawk':
        return [
          _text('Hawk Auth ID', 'authId'),
          _text('Hawk Auth Key', 'authKey', secret: true),
          _select('Algorithm', 'algorithm', {'sha256': 'SHA256', 'sha1': 'SHA1'}),
          _section('Advanced'),
          _text('User', 'user'),
          _text('Nonce', 'nonce', hint: 'auto'),
          _text('ext', 'ext'),
          _text('app', 'app'),
          _text('dlg', 'dlg'),
          _text('Timestamp', 'timestamp', hint: 'auto'),
          _check('Include payload hash', 'includePayloadHash'),
        ];
      case 'awsv4':
        return [
          _text('AccessKey', 'accessKey'),
          _text('SecretKey', 'secretKey', secret: true),
          _select('Add auth data to', 'addTo', {'header': 'Request Headers', 'query': 'Request URL (presigned)'}),
          _section('Advanced'),
          _text('AWS Region', 'region', def: 'us-east-1'),
          _text('Service Name', 'service', def: 'execute-api', hint: 'e.g. s3, execute-api, es'),
          _text('Session Token', 'sessionToken', secret: true),
        ];
      case 'ntlm':
        return [
          _text('Username', 'username'),
          _text('Password', 'password', secret: true),
          _section('Advanced'),
          _text('Domain', 'domain'),
          _text('Workstation', 'workstation'),
        ];
      case 'akamai':
        return [
          _text('Access Token', 'accessToken'),
          _text('Client Token', 'clientToken'),
          _text('Client Secret', 'clientSecret', secret: true),
          _section('Advanced'),
          _text('Nonce', 'nonce', hint: 'auto'),
          _text('Timestamp', 'timestamp', hint: 'auto'),
          _text('Headers to Sign', 'headersToSign', hint: 'comma separated'),
          _text('Max Body Size', 'maxBody', def: '131072'),
        ];
      case 'jwt':
        final alg = a.get('algorithm', 'HS256');
        return [
          _select('Add JWT token to', 'addTo', {'header': 'Request Header', 'query': 'Query Param'}),
          _select('Algorithm', 'algorithm', {
            for (final x in ['HS256', 'HS384', 'HS512', 'RS256', 'RS384', 'RS512', 'PS256', 'PS384', 'PS512', 'ES256', 'ES384', 'ES512']) x: x,
          }),
          if (alg.startsWith('HS')) _text('Secret', 'secret', secret: true),
          if (alg.startsWith('HS')) _check('Secret Base64 encoded', 'secretBase64'),
          if (!alg.startsWith('HS')) _text('Private Key (PEM)', 'privateKey', multiline: true, hint: '-----BEGIN PRIVATE KEY-----'),
          _text('Payload', 'payload', multiline: true, def: '{\n  "sub": "1234567890",\n  "name": "John Doe"\n}'),
          _section('Advanced'),
          _text('Request header prefix', 'prefix', def: 'Bearer'),
          _text('Query param name', 'queryParam', def: 'token'),
          _text('JWT headers', 'header', multiline: true, hint: '{"kid": "key-1"}'),
          Row(children: [
            const SizedBox(width: 170),
            TextButton(
              onPressed: () {
                try {
                  final scope = widget.scope?.call() ?? VariableScope();
                  final tok = AuthApplier.generateJwt(AuthConfig(type: 'jwt', p: a.p.map((k, v) => MapEntry(k, scope.resolve(v)))));
                  setState(() => _status = tok);
                } catch (e) {
                  setState(() => _status = 'Error: $e');
                }
              },
              child: const Text('Preview token'),
            ),
          ]),
          if (_status.isNotEmpty) Padding(padding: const EdgeInsets.only(left: 170), child: SelectableText(_status, style: const TextStyle(fontSize: 12))),
        ];
      case 'inherit':
        return const [];
      default:
        return const [];
    }
  }
}

/// Used to show "hidden" headers that will be generated (Postman-style).
List<MapEntry<String, String>> autoHeaders(ApiRequest r) => [
      const MapEntry('User-Agent', userAgent),
      const MapEntry('Accept', '*/*'),
      const MapEntry('Accept-Encoding', 'gzip, deflate'),
      const MapEntry('Connection', 'keep-alive'),
    ];
