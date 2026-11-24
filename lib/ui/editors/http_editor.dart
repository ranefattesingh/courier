import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/graphql_schema.dart';
import '../../core/http_engine.dart';
import '../../core/wsdl.dart';
import '../../models/models.dart';
import '../../state/executor.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/message_log.dart';
import '../widgets/response_view.dart';
import 'actions.dart';
import 'shared.dart';

/// Editor for HTTP, GraphQL and SOAP requests.
class HttpEditor extends StatelessWidget {
  final EditorCtx ctx;
  const HttpEditor(this.ctx, {super.key});

  @override
  Widget build(BuildContext context) {
    final r = ctx.r;
    final tab = ctx.tab;
    final subscription = r.type == RequestType.graphql && isGraphQLSubscription(r);
    final active = isActive(tab);
    final labels = <String>[];
    final builders = <Widget Function()>[];
    void add(String l, Widget Function() b) {
      labels.add(l);
      builders.add(b);
    }

    if (r.type == RequestType.graphql) {
      add('Query', () => _GraphQLBody(ctx));
    } else if (r.type == RequestType.soap) {
      add('Envelope', () => _SoapBody(ctx));
    }
    final paramCount = r.params.where((p) => p.enabled && p.key.isNotEmpty).length;
    add('Params${paramCount > 0 ? ' ($paramCount)' : ''}', () => paramsTab(ctx));
    add('Authorization', () => authTab(ctx));
    final hc = r.headers.where((h) => h.enabled && h.key.isNotEmpty).length;
    add('Headers${hc > 0 ? ' ($hc)' : ''}', () => headersTab(ctx));
    if (r.type == RequestType.http) add('Body', () => _BodyTab(ctx));
    add('Tests${r.tests.isNotEmpty || r.extracts.isNotEmpty ? ' (${r.tests.length + r.extracts.length})' : ''}', () => TestsTab(ctx));
    add('Settings', () => SettingsTab(ctx));
    add('Docs', () => descriptionTab(ctx));

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      RequestTitleBar(ctx),
      UrlBar(
        ctx,
        showMethod: r.type != RequestType.soap || true,
        hint: r.type == RequestType.graphql ? 'Enter GraphQL endpoint (http(s):// or ws(s):// for subscriptions)' : 'Enter URL or paste cURL',
        buttonLabel: subscription ? 'Subscribe' : 'Send',
        activeLabel: subscription ? 'Unsubscribe' : 'Cancel',
        active: active,
        onPrimary: () => runPrimaryAction(ctx.state, tab),
      ),
      Expanded(
        child: requestResponseSplit(
          ctx,
          request: SimpleTabs(key: ValueKey('reqtabs${tab.id}${r.type}'), labels: labels, builders: builders),
          response: subscription
              ? MessageLog(messages: tab.logs, onClear: () => {tab.logs.clear(), tab.touch()}, emptyText: 'Subscribe to receive events')
              : ResponseView(response: tab.response, loading: tab.sending, onCancel: () => tab.httpEngine?.cancel()),
        ),
      ),
    ]);
  }
}

// ---------------------------------------------------------------------------- Body

class _BodyTab extends StatefulWidget {
  final EditorCtx ctx;
  const _BodyTab(this.ctx);

  @override
  State<_BodyTab> createState() => _BodyTabState();
}

class _BodyTabState extends State<_BodyTab> {
  @override
  Widget build(BuildContext context) {
    final ctx = widget.ctx;
    final b = ctx.r.body;
    final cs = Theme.of(context).colorScheme;
    const modes = {'none': 'none', 'form-data': 'form-data', 'urlencoded': 'x-www-form-urlencoded', 'raw': 'raw', 'binary': 'binary', 'graphql': 'GraphQL'};
    void set(void Function() f) {
      setState(f);
      ctx.changed();
    }

    Widget content;
    switch (b.mode) {
      case 'form-data':
        content = SingleChildScrollView(child: KvTable(rows: b.formData, allowFiles: true, scope: ctx.scope, onChanged: ctx.changed));
      case 'urlencoded':
        content = SingleChildScrollView(child: KvTable(rows: b.urlEncoded, scope: ctx.scope, onChanged: ctx.changed));
      case 'raw':
        content = CodeEditor(
          value: b.raw,
          language: b.rawLang,
          scope: ctx.scope,
          fontSize: ctx.state.settings.editorFontSize,
          onChanged: (v) {
            b.raw = v;
            ctx.changed();
          },
        );
      case 'binary':
        content = Align(
          alignment: Alignment.topLeft,
          child: Row(children: [
            OutlinedButton.icon(
              onPressed: () async {
                final f = await openFile();
                if (f != null) set(() => b.binaryPath = f.path);
              },
              icon: const Icon(Icons.attach_file, size: 16),
              label: const Text('Select File'),
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(b.binaryPath.isEmpty ? 'No file selected' : b.binaryPath, overflow: TextOverflow.ellipsis)),
            if (b.binaryPath.isNotEmpty) IconButton(icon: const Icon(Icons.close, size: 16), onPressed: () => set(() => b.binaryPath = '')),
          ]),
        );
      case 'graphql':
        content = Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            flex: 3,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('QUERY', style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
              const SizedBox(height: 4),
              Expanded(child: CodeEditor(value: b.gqlQuery, language: 'graphql', onChanged: (v) => {b.gqlQuery = v, ctx.changed()})),
            ]),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 2,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('GRAPHQL VARIABLES', style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
              const SizedBox(height: 4),
              Expanded(child: CodeEditor(value: b.gqlVariables, language: 'json', scope: ctx.scope, onChanged: (v) => {b.gqlVariables = v, ctx.changed()})),
            ]),
          ),
        ]);
      default:
        content = Center(child: Text('This request does not have a body', style: TextStyle(color: cs.onSurfaceVariant)));
    }
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 4, children: [
          for (final m in modes.entries)
            InkWell(
              onTap: () => set(() => b.mode = m.key),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Radio<String>(
                  value: m.key,
                  groupValue: b.mode,
                  visualDensity: VisualDensity.compact,
                  onChanged: (v) => set(() => b.mode = v!),
                ),
                Text(m.value, style: const TextStyle(fontSize: 13)),
                const SizedBox(width: 6),
              ]),
            ),
          if (b.mode == 'raw') ...[
            const SizedBox(width: 6),
            CompactDropdown<String>(
              value: b.rawLang,
              items: const {'text': 'Text', 'javascript': 'JavaScript', 'json': 'JSON', 'html': 'HTML', 'xml': 'XML'},
              onChanged: (v) => set(() => b.rawLang = v),
            ),
            TextButton(onPressed: () => set(() => b.raw = beautify(b.raw, b.rawLang)), child: const Text('Beautify')),
          ],
        ]),
        const SizedBox(height: 8),
        Expanded(child: content),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------- GraphQL

class _GraphQLBody extends StatefulWidget {
  final EditorCtx ctx;
  const _GraphQLBody(this.ctx);

  @override
  State<_GraphQLBody> createState() => _GraphQLBodyState();
}

class _GraphQLBodyState extends State<_GraphQLBody> {
  bool _loading = false;
  String? _error;
  String _filter = '';
  String? _type;

  Future<void> _fetchSchema() async {
    final ctx = widget.ctx;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final probe = ctx.r.clone()
        ..type = RequestType.graphql
        ..method = 'POST'
        ..tests = []
        ..extracts = []
        ..body.gqlQuery = introspectionQuery
        ..body.gqlVariables = '{}'
        ..opts.remove('gqlOperation');
      if (probe.url.startsWith('ws')) probe.url = probe.url.replaceFirst('ws', 'http');
      final res = await Executor(ctx.state).sendHttp(probe, ctx.tab.sourceId, HttpEngine(), recordHistory: false);
      if (res.error != null) throw Exception(res.error);
      if (res.status >= 400) throw Exception('HTTP ${res.status}: ${res.bodyText}');
      ctx.tab.gqlSchema = GqlSchema.fromIntrospection(jsonDecode(res.bodyText) as Map<String, dynamic>);
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ctx = widget.ctx;
    final b = ctx.r.body;
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(
          flex: 5,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Text('QUERY', style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
              const Spacer(),
              SizedBox(
                width: 180,
                child: SyncedTextField(
                  value: ctx.r.opt('gqlOperation'),
                  hint: 'Operation name (optional)',
                  onChanged: (v) {
                    ctx.r.opts['gqlOperation'] = v;
                    ctx.changed();
                  },
                ),
              ),
              if (isGraphQLSubscription(ctx.r)) ...[
                const SizedBox(width: 6),
                CompactDropdown<String>(
                  value: ctx.r.opt('gqlWsProtocol', 'graphql-transport-ws'),
                  items: const {'graphql-transport-ws': 'graphql-transport-ws', 'graphql-ws': 'graphql-ws (legacy)'},
                  onChanged: (v) {
                    ctx.r.opts['gqlWsProtocol'] = v;
                    ctx.changed();
                  },
                ),
              ],
            ]),
            const SizedBox(height: 6),
            Expanded(
              flex: 3,
              child: CodeEditor(
                value: b.gqlQuery,
                language: 'graphql',
                fontSize: ctx.state.settings.editorFontSize,
                onChanged: (v) {
                  b.gqlQuery = v;
                  ctx.changed();
                },
              ),
            ),
            const SizedBox(height: 8),
            Text('VARIABLES', style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
            const SizedBox(height: 4),
            Expanded(
              flex: 1,
              child: CodeEditor(value: b.gqlVariables, language: 'json', scope: ctx.scope, onChanged: (v) => {b.gqlVariables = v, ctx.changed()}),
            ),
          ]),
        ),
        const SizedBox(width: 10),
        SizedBox(width: 290, child: _schemaPanel(cs)),
      ]),
    );
  }

  Widget _schemaPanel(ColorScheme cs) {
    final schema = widget.ctx.tab.gqlSchema;
    return Container(
      decoration: BoxDecoration(border: Border.all(color: cs.outlineVariant), borderRadius: BorderRadius.circular(4)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
          child: Row(children: [
            const Text('Schema', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const Spacer(),
            if (_type != null) IconButton(iconSize: 16, tooltip: 'Back', icon: const Icon(Icons.arrow_back), onPressed: () => setState(() => _type = null)),
            TextButton.icon(
              onPressed: _loading ? null : _fetchSchema,
              icon: _loading ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.refresh, size: 15),
              label: Text(schema == null ? 'Fetch' : 'Refresh', style: const TextStyle(fontSize: 12)),
            ),
          ]),
        ),
        Divider(color: cs.outlineVariant),
        if (_error != null) Padding(padding: const EdgeInsets.all(8), child: SelectableText(_error!, style: TextStyle(color: cs.error, fontSize: 12))),
        if (schema == null && _error == null)
          const Expanded(child: EmptyHint(Icons.schema_outlined, 'Fetch the schema via introspection to browse types and generate queries'))
        else if (schema != null) ...[
          Padding(
            padding: const EdgeInsets.all(6),
            child: TextField(
              style: const TextStyle(fontSize: 12),
              decoration: const InputDecoration(hintText: 'Filter', prefixIcon: Icon(Icons.search, size: 15), prefixIconConstraints: BoxConstraints(minWidth: 26)),
              onChanged: (v) => setState(() => _filter = v.toLowerCase()),
            ),
          ),
          Expanded(child: _type == null ? _roots(schema, cs) : _typeView(schema, _type!, cs)),
        ],
      ]),
    );
  }

  Widget _roots(GqlSchema s, ColorScheme cs) {
    final roots = [('query', s.query), ('mutation', s.mutation), ('subscription', s.subscription)].where((e) => e.$2 != null);
    return ListView(children: [
      for (final (kind, name) in roots) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 2),
          child: Text(kind.toUpperCase(), style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant, fontWeight: FontWeight.w600)),
        ),
        for (final f in s.types[name]?.fields.where((f) => f.name.toLowerCase().contains(_filter)) ?? <GqlField>[])
          _fieldTile(f, cs, onInsert: () {
            widget.ctx.r.body.gqlQuery = s.operationFor(kind, f);
            widget.ctx.r.body.gqlVariables = const JsonEncoder.withIndent('  ').convert({for (final a in f.args) a.$1: null});
            widget.ctx.changed();
          }),
      ],
      Padding(
        padding: const EdgeInsets.fromLTRB(10, 12, 10, 2),
        child: Text('TYPES', style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant, fontWeight: FontWeight.w600)),
      ),
      for (final t in s.types.values.where((t) => t.name.toLowerCase().contains(_filter)))
        ListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          title: Text(t.name, style: const TextStyle(fontSize: 12.5)),
          trailing: Text(t.kind.toLowerCase(), style: TextStyle(fontSize: 10.5, color: cs.onSurfaceVariant)),
          onTap: () => setState(() => _type = t.name),
        ),
    ]);
  }

  Widget _fieldTile(GqlField f, ColorScheme cs, {VoidCallback? onInsert}) => ListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        title: Text.rich(TextSpan(children: [
          TextSpan(text: f.name, style: const TextStyle(fontSize: 12.5)),
          if (f.args.isNotEmpty) TextSpan(text: '(${f.args.map((a) => '${a.$1}: ${a.$2}').join(', ')})', style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
          TextSpan(text: ': ${f.type}', style: const TextStyle(fontSize: 12, color: Color(0xFFE6B44C))),
        ])),
        subtitle: f.description.isEmpty ? null : Text(f.description, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
        trailing: onInsert == null ? null : IconButton(iconSize: 15, tooltip: 'Generate operation', icon: const Icon(Icons.playlist_add), onPressed: onInsert),
        onTap: () => setState(() => _type = f.namedType),
      );

  Widget _typeView(GqlSchema s, String name, ColorScheme cs) {
    final t = s.types[name];
    if (t == null) return Center(child: Text('Scalar $name', style: TextStyle(color: cs.onSurfaceVariant)));
    return ListView(children: [
      Padding(
        padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.name, style: const TextStyle(fontWeight: FontWeight.w600)),
          Text(t.kind, style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
          if (t.description.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(t.description, style: const TextStyle(fontSize: 12))),
        ]),
      ),
      for (final f in t.fields.where((f) => f.name.toLowerCase().contains(_filter))) _fieldTile(f, cs),
      for (final e in t.enumValues) ListTile(dense: true, title: Text(e, style: const TextStyle(fontSize: 12.5))),
    ]);
  }
}

// ---------------------------------------------------------------------------- SOAP

class _SoapBody extends StatefulWidget {
  final EditorCtx ctx;
  const _SoapBody(this.ctx);

  @override
  State<_SoapBody> createState() => _SoapBodyState();
}

class _SoapBodyState extends State<_SoapBody> {
  bool _loading = false;
  String? _error;

  Future<void> _loadWsdl({String? fromFile}) async {
    final ctx = widget.ctx;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      String text;
      if (fromFile != null) {
        text = await XFile(fromFile).readAsString();
      } else {
        final probe = ctx.r.clone()
          ..type = RequestType.http
          ..method = 'GET'
          ..tests = []
          ..extracts = []
          ..body = BodyConfig();
        final wsdlUrl = ctx.r.opt('wsdlUrl');
        probe.url = wsdlUrl.isNotEmpty ? wsdlUrl : '${ctx.r.url.split('?').first}?wsdl';
        final res = await Executor(ctx.state).sendHttp(probe, ctx.tab.sourceId, HttpEngine(), recordHistory: false);
        if (res.error != null) throw Exception(res.error);
        if (res.status >= 400) throw Exception('HTTP ${res.status} fetching WSDL');
        text = res.bodyText;
      }
      final ops = parseWsdl(text);
      if (ops.isEmpty) throw Exception('No SOAP operations found in WSDL');
      ctx.tab.soapOps = ops;
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _applyOp(SoapOperation op) {
    final r = widget.ctx.r;
    r.opts['soapAction'] = op.soapAction;
    r.opts['soapVersion'] = op.version;
    r.opts['soapOperation'] = '${op.name}/${op.version}';
    r.body.raw = op.envelope;
    if (op.endpoint.isNotEmpty) r.url = op.endpoint;
    widget.ctx.changed();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final ctx = widget.ctx;
    final r = ctx.r;
    final cs = Theme.of(context).colorScheme;
    final ops = ctx.tab.soapOps;
    void set(String k, String v) {
      r.opts[k] = v;
      ctx.changed();
      setState(() {});
    }

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SizedBox(
            width: 300,
            child: SyncedTextField(value: r.opt('wsdlUrl'), hint: 'WSDL URL (default: <endpoint>?wsdl)', scope: ctx.scope, onChanged: (v) => r.opts['wsdlUrl'] = v),
          ),
          OutlinedButton(onPressed: _loading ? null : () => _loadWsdl(), child: Text(_loading ? 'Loading…' : 'Load WSDL')),
          OutlinedButton(
            onPressed: _loading
                ? null
                : () async {
                    final f = await openFile(acceptedTypeGroups: const [XTypeGroup(label: 'WSDL', extensions: ['wsdl', 'xml'])]);
                    if (f != null) _loadWsdl(fromFile: f.path);
                  },
            child: const Text('Import file'),
          ),
          if (ops.isNotEmpty)
            CompactDropdown<String>(
              width: 260,
              value: r.opt('soapOperation', '${ops.first.name}/${ops.first.version}'),
              items: {for (final o in ops) '${o.name}/${o.version}': '${o.name} (SOAP ${o.version})'},
              onChanged: (v) => _applyOp(ops.firstWhere((o) => '${o.name}/${o.version}' == v)),
            ),
        ]),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(_error!, style: TextStyle(color: cs.error, fontSize: 12))),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          CompactDropdown<String>(value: r.opt('soapVersion', '1.1'), items: const {'1.1': 'SOAP 1.1', '1.2': 'SOAP 1.2'}, onChanged: (v) => set('soapVersion', v)),
          SizedBox(
            width: 300,
            child: SyncedTextField(value: r.opt('soapAction'), hint: 'SOAPAction', scope: ctx.scope, onChanged: (v) => {r.opts['soapAction'] = v, ctx.changed()}),
          ),
          CompactDropdown<String>(
            value: r.opt('wsseType', 'none'),
            items: const {'none': 'No WS-Security', 'text': 'WSS UsernameToken (PasswordText)', 'digest': 'WSS UsernameToken (PasswordDigest)'},
            onChanged: (v) => set('wsseType', v),
          ),
          if (r.opt('wsseType', 'none') != 'none') ...[
            SizedBox(width: 130, child: SyncedTextField(value: r.opt('wsseUser'), hint: 'Username', scope: ctx.scope, onChanged: (v) => {r.opts['wsseUser'] = v, ctx.changed()})),
            SizedBox(width: 130, child: SyncedTextField(value: r.opt('wssePass'), hint: 'Password', obscure: true, scope: ctx.scope, onChanged: (v) => {r.opts['wssePass'] = v, ctx.changed()})),
          ],
          TextButton(onPressed: () => {r.body.raw = beautify(r.body.raw, 'xml'), ctx.changed(), setState(() {})}, child: const Text('Beautify')),
        ]),
        const SizedBox(height: 8),
        Expanded(
          child: CodeEditor(
            value: r.body.raw,
            language: 'xml',
            scope: ctx.scope,
            fontSize: ctx.state.settings.editorFontSize,
            onChanged: (v) {
              r.body.raw = v;
              ctx.changed();
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            r.opt('soapVersion', '1.1') == '1.2'
                ? 'Content-Type: application/soap+xml; action="…" is added automatically'
                : 'Content-Type: text/xml and SOAPAction header are added automatically',
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
        ),
      ]),
    );
  }
}

/// Small colored method label used in menus.
Widget methodText(String m) => Text(m, style: TextStyle(color: methodColor(m), fontWeight: FontWeight.w700, fontSize: 12));
