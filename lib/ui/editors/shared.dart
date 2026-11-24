import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/tests.dart';
import '../../core/variables.dart';
import '../../models/models.dart';
import '../../state/app_state.dart';
import '../dialogs/dialogs.dart';
import '../theme.dart';
import '../widgets/auth_editor.dart';
import '../widgets/common.dart';
import 'actions.dart';

/// Request/response split direction chosen in settings: stacked (vertical) or side by side.
Axis paneAxis(AppState s) => s.settings.responsePane == 'right' ? Axis.horizontal : Axis.vertical;

/// Request/response split that follows the user's layout preference.
Widget requestResponseSplit(EditorCtx ctx, {required Widget request, required Widget response, double initial = 0.5}) {
  final axis = paneAxis(ctx.state);
  return SplitView(key: ValueKey('split-$axis'), axis: axis, initial: initial, min: 0.2, first: request, second: response);
}

/// Convenience bundle passed to all editors.
class EditorCtx {
  final AppState state;
  final RequestTab tab;
  EditorCtx(this.state, this.tab);
  ApiRequest get r => tab.draft;
  void changed() {
    state.markDirty(tab);
    tab.touch();
  }

  VariableScope scope() => state.scopeFor(tab.sourceId);
}

// ---------------------------------------------------------------------------- URL <-> params

List<KV> parseQueryParams(String url) {
  final q = url.indexOf('?');
  if (q < 0) return [];
  var query = url.substring(q + 1);
  final h = query.indexOf('#');
  if (h >= 0) query = query.substring(0, h);
  if (query.isEmpty) return [];
  return query.split('&').map((p) {
    final i = p.indexOf('=');
    return i < 0 ? KV(key: p) : KV(key: p.substring(0, i), value: p.substring(i + 1));
  }).toList();
}

void syncParamsFromUrl(ApiRequest r) {
  final parsed = parseQueryParams(r.url);
  final disabled = r.params.where((p) => !p.enabled).toList();
  for (var i = 0; i < parsed.length; i++) {
    final old = r.params.where((p) => p.enabled).elementAtOrNull(i);
    if (old != null) parsed[i].description = old.description;
  }
  r.params = [...parsed, ...disabled];
}

void syncUrlFromParams(ApiRequest r) {
  final base = r.url.contains('?') ? r.url.substring(0, r.url.indexOf('?')) : r.url;
  final enabled = r.params.where((p) => p.enabled && (p.key.isNotEmpty || p.value.isNotEmpty));
  final q = enabled.map((p) => p.value.isEmpty && !p.key.contains('=') ? p.key : '${p.key}=${p.value}').join('&');
  r.url = q.isEmpty ? base : '$base?$q';
}

// ---------------------------------------------------------------------------- header bar

class RequestTitleBar extends StatelessWidget {
  final EditorCtx ctx;
  final List<Widget> actions;
  const RequestTitleBar(this.ctx, {super.key, this.actions = const []});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final path = ctx.tab.sourceId == null ? null : ctx.state.pathTo(ctx.tab.sourceId!);
    final crumbs = path == null ? <String>[] : path.take(path.length - 1).map((n) => n.name).toList();
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 10, 4),
      child: Row(children: [
        Icon(typeIcon(ctx.r.type), size: 16, color: typeColor(ctx.r.type)),
        const SizedBox(width: 8),
        if (crumbs.isNotEmpty)
          Flexible(
            child: Text('${crumbs.join(' / ')} / ', overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
          ),
        Flexible(
          flex: 2,
          child: InkWell(
            onTap: () async {
              final n = await promptText(context, 'Rename request', initial: ctx.r.name);
              if (n == null) return;
              ctx.r.name = n;
              if (ctx.tab.sourceId != null) {
                ctx.state.renameNode(ctx.tab.sourceId!, n);
              } else {
                ctx.changed();
              }
            },
            child: Text(ctx.r.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          ),
        ),
        const Spacer(),
        ...actions,
        if (ctx.r.type == RequestType.http || ctx.r.type == RequestType.graphql || ctx.r.type == RequestType.soap)
          TextButton.icon(
            onPressed: () => showCodegenDialog(context, ctx.state, ctx.tab),
            icon: const Icon(Icons.code, size: 16),
            label: const Text('Code'),
          ),
        const SizedBox(width: 4),
        OutlinedButton.icon(
          onPressed: () => saveTabInteractive(context, ctx.state, ctx.tab),
          icon: Icon(Icons.save_outlined, size: 16, color: ctx.tab.dirty ? cs.primary : null),
          label: Text(ctx.tab.dirty ? 'Save' : 'Saved'),
        ),
      ]),
    );
  }
}

/// URL row: [method] [url] [primary button]
class UrlBar extends StatelessWidget {
  final EditorCtx ctx;
  final bool showMethod;
  final String hint;
  final String buttonLabel;
  final String activeLabel;
  final bool active;
  final VoidCallback? onPrimary;
  final List<Widget> extra;
  final bool syncParams;
  final Widget? prefix;
  const UrlBar(
    this.ctx, {
    super.key,
    this.showMethod = false,
    this.hint = 'Enter URL or paste text',
    this.buttonLabel = 'Send',
    this.activeLabel = 'Cancel',
    this.active = false,
    this.onPrimary,
    this.extra = const [],
    this.syncParams = true,
    this.prefix,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
      child: Row(children: [
        Expanded(
          child: Container(
            decoration: BoxDecoration(border: Border.all(color: cs.outline), borderRadius: BorderRadius.circular(4), color: cs.surfaceContainerLow),
            child: Row(children: [
              if (prefix != null) prefix!,
              if (showMethod)
                PopupMenuButton<String>(
                  tooltip: 'Method',
                  initialValue: ctx.r.method,
                  onSelected: (m) {
                    ctx.r.method = m;
                    ctx.changed();
                  },
                  itemBuilder: (_) => [
                    for (final m in httpMethods)
                      PopupMenuItem(value: m, height: 32, child: Text(m, style: TextStyle(fontWeight: FontWeight.w700, color: methodColor(m), fontSize: 13))),
                  ],
                  child: Container(
                    width: 110,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(border: Border(right: BorderSide(color: cs.outline))),
                    child: Row(children: [
                      Expanded(child: Text(ctx.r.method, style: TextStyle(fontWeight: FontWeight.w700, color: methodColor(ctx.r.method), fontSize: 13))),
                      Icon(Icons.keyboard_arrow_down, size: 16, color: cs.onSurfaceVariant),
                    ]),
                  ),
                ),
              Expanded(
                child: SyncedTextField(
                  value: ctx.r.url,
                  hint: hint,
                  borderless: true,
                  scope: ctx.scope,
                  style: TextStyle(fontSize: 13.5, color: cs.onSurface),
                  onSubmitted: (_) => onPrimary?.call(),
                  onChanged: (v) {
                    ctx.r.url = v;
                    if (syncParams) syncParamsFromUrl(ctx.r);
                    ctx.changed();
                  },
                ),
              ),
            ]),
          ),
        ),
        const SizedBox(width: 8),
        ...extra,
        FilledButton(
          onPressed: onPrimary,
          style: active ? FilledButton.styleFrom(backgroundColor: cs.surfaceContainerHighest, foregroundColor: cs.onSurface) : null,
          child: Text(active ? activeLabel : buttonLabel),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------- common tabs

Widget paramsTab(EditorCtx ctx, {String title = 'Query Params'}) => SingleChildScrollView(
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
        const SizedBox(height: 8),
        KvTable(
          rows: ctx.r.params,
          scope: ctx.scope,
          onChanged: () {
            syncUrlFromParams(ctx.r);
            ctx.changed();
          },
        ),
      ]),
    );

Widget headersTab(EditorCtx ctx, {String title = 'Headers', String keyHint = 'Key', bool showAuto = true}) {
  return Builder(builder: (context) {
    final cs = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
        const SizedBox(height: 8),
        KvTable(rows: ctx.r.headers, scope: ctx.scope, keyHint: keyHint, keySuggestions: commonHeaders, onChanged: ctx.changed),
        if (showAuto) ...[
          const SizedBox(height: 14),
          Text('Auto-generated headers (added when not set above)', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          const SizedBox(height: 4),
          for (final h in autoHeaders(ctx.r))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(children: [
                SizedBox(width: 200, child: Text(h.key, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant))),
                Text(h.value, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              ]),
            ),
        ],
      ]),
    );
  });
}

Widget authTab(EditorCtx ctx, {Set<String>? only}) => AuthEditor(
      key: ValueKey('auth${ctx.tab.id}'),
      auth: ctx.r.auth,
      onChanged: ctx.changed,
      scope: ctx.scope,
      inheritedFrom: ctx.state.authSourceName(ctx.tab.sourceId),
      only: only,
    );

Widget descriptionTab(EditorCtx ctx) => Padding(
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('Documentation', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
        const SizedBox(height: 8),
        Expanded(
          child: CodeEditor(
            value: ctx.r.description,
            language: 'markdown',
            hint: 'Describe what this request does, expected inputs and outputs…',
            onChanged: (v) {
              ctx.r.description = v;
              ctx.changed();
            },
          ),
        ),
      ]),
    );

class SettingsTab extends StatefulWidget {
  final EditorCtx ctx;
  final bool redirects;
  final bool timeout;
  const SettingsTab(this.ctx, {super.key, this.redirects = true, this.timeout = true});

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  @override
  Widget build(BuildContext context) {
    final ctx = widget.ctx;
    final cs = Theme.of(context).colorScheme;
    final s = ctx.state.settings;
    Widget toggle(String title, String sub, String key, bool global) {
      final has = ctx.r.opts.containsKey(key);
      return ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(title, style: const TextStyle(fontSize: 13)),
        subtitle: Text('$sub${has ? '' : ' (using app default)'}', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (has)
            TextButton(
              onPressed: () => setState(() {
                ctx.r.opts.remove(key);
                ctx.changed();
              }),
              child: const Text('Reset', style: TextStyle(fontSize: 12)),
            ),
          Switch(
            value: ctx.r.optBool(key, global),
            onChanged: (v) => setState(() {
              ctx.r.opts[key] = v.toString();
              ctx.changed();
            }),
          ),
        ]),
      );
    }

    return ListView(padding: const EdgeInsets.all(14), children: [
      toggle('Enable SSL certificate verification', 'Verify server certificates when sending requests.', 'verifySsl', s.verifySsl),
      if (widget.redirects) toggle('Automatically follow redirects', 'Follow HTTP 3xx responses as redirects.', 'followRedirects', s.followRedirects),
      if (widget.timeout)
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Request timeout (ms)', style: TextStyle(fontSize: 13)),
          subtitle: Text('0 = use app default (${s.timeoutMs == 0 ? 'no timeout' : '${s.timeoutMs} ms'})', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          trailing: SizedBox(
            width: 120,
            child: SyncedTextField(
              value: ctx.r.opt('timeoutMs', '0'),
              onChanged: (v) {
                ctx.r.opts['timeoutMs'] = int.tryParse(v)?.toString() ?? '0';
                ctx.changed();
              },
            ),
          ),
        ),
    ]);
  }
}

class TestsTab extends StatefulWidget {
  final EditorCtx ctx;
  const TestsTab(this.ctx, {super.key});

  @override
  State<TestsTab> createState() => _TestsTabState();
}

class _TestsTabState extends State<TestsTab> {
  int _gen = 0;

  @override
  Widget build(BuildContext context) {
    final ctx = widget.ctx;
    final cs = Theme.of(context).colorScheme;
    void changed() {
      ctx.changed();
      setState(() {});
    }

    return ListView(padding: const EdgeInsets.all(14), children: [
      Row(children: [
        const Text('Assertions', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(width: 8),
        Text('Evaluated after every response. {{variables}} are allowed in values.', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
        const Spacer(),
        TextButton.icon(
          onPressed: () {
            ctx.r.tests.add(TestRule());
            changed();
          },
          icon: const Icon(Icons.add, size: 16),
          label: const Text('Add assertion'),
        ),
      ]),
      const SizedBox(height: 6),
      if (ctx.r.tests.isEmpty) Text('No assertions yet.', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
      for (final t in ctx.r.tests)
        Padding(
          key: ObjectKey(t),
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            Checkbox(value: t.enabled, onChanged: (v) => {t.enabled = v ?? true, changed()}),
            CompactDropdown<String>(width: 170, value: t.source, items: testSources, onChanged: (v) => {t.source = v, changed()}),
            const SizedBox(width: 6),
            if (t.source == 'header' || t.source == 'jsonPath')
              Expanded(
                flex: 3,
                child: SyncedTextField(
                  key: ValueKey('p$_gen${identityHashCode(t)}'),
                  value: t.property,
                  hint: t.source == 'header' ? 'Header name' : r'$.data.items[0].id',
                  onChanged: (v) {
                    t.property = v;
                    ctx.changed();
                  },
                ),
              ),
            if (t.source == 'header' || t.source == 'jsonPath') const SizedBox(width: 6),
            CompactDropdown<String>(width: 160, value: t.op, items: testOps, onChanged: (v) => {t.op = v, changed()}),
            const SizedBox(width: 6),
            Expanded(
              flex: 3,
              child: t.op == 'exists' || t.op == 'notExists'
                  ? const SizedBox()
                  : SyncedTextField(
                      key: ValueKey('e$_gen${identityHashCode(t)}'),
                      value: t.expected,
                      hint: t.op == 'isType' ? 'string | number | boolean | array | object | null' : 'Expected value',
                      scope: ctx.scope,
                      onChanged: (v) {
                        t.expected = v;
                        ctx.changed();
                      },
                    ),
            ),
            IconButton(
              iconSize: 16,
              icon: const Icon(Icons.close),
              onPressed: () {
                ctx.r.tests.remove(t);
                _gen++;
                changed();
              },
            ),
          ]),
        ),
      const SizedBox(height: 22),
      Row(children: [
        const Text('Set variables from response', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(width: 8),
        Text('Chain requests by capturing values into variables.', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
        const Spacer(),
        TextButton.icon(
          onPressed: () {
            ctx.r.extracts.add(VarExtract());
            changed();
          },
          icon: const Icon(Icons.add, size: 16),
          label: const Text('Add variable'),
        ),
      ]),
      const SizedBox(height: 6),
      if (ctx.r.extracts.isEmpty) Text('No variable captures yet.', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
      for (final x in ctx.r.extracts)
        Padding(
          key: ObjectKey(x),
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            Checkbox(value: x.enabled, onChanged: (v) => {x.enabled = v ?? true, changed()}),
            CompactDropdown<String>(
              width: 150,
              value: x.source,
              items: const {'jsonPath': 'JSON path', 'header': 'Header', 'regex': 'Body regex', 'status': 'Status code'},
              onChanged: (v) => {x.source = v, changed()},
            ),
            const SizedBox(width: 6),
            Expanded(
              flex: 3,
              child: x.source == 'status'
                  ? const SizedBox()
                  : SyncedTextField(
                      key: ValueKey('xp$_gen${identityHashCode(x)}'),
                      value: x.path,
                      hint: x.source == 'header' ? 'Header name' : x.source == 'regex' ? r'token":"([^"]+)' : r'$.access_token',
                      onChanged: (v) {
                        x.path = v;
                        ctx.changed();
                      },
                    ),
            ),
            const SizedBox(width: 6),
            const Text('→', style: TextStyle(fontSize: 14)),
            const SizedBox(width: 6),
            Expanded(
              flex: 2,
              child: SyncedTextField(
                key: ValueKey('xv$_gen${identityHashCode(x)}'),
                value: x.variable,
                hint: 'variable name',
                onChanged: (v) {
                  x.variable = v;
                  ctx.changed();
                },
              ),
            ),
            const SizedBox(width: 6),
            CompactDropdown<String>(
              width: 130,
              value: x.scope,
              items: const {'environment': 'Environment', 'collection': 'Collection', 'global': 'Global'},
              onChanged: (v) => {x.scope = v, changed()},
            ),
            IconButton(
              iconSize: 16,
              icon: const Icon(Icons.close),
              onPressed: () {
                ctx.r.extracts.remove(x);
                _gen++;
                changed();
              },
            ),
          ]),
        ),
    ]);
  }
}

/// Listens to the tab and rebuilds the editor body on runtime changes.
class TabListener extends StatelessWidget {
  final RequestTab tab;
  final Widget Function(BuildContext) builder;
  const TabListener({super.key, required this.tab, required this.builder});

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: tab, builder: (c, _) => builder(c));
}

EditorCtx editorCtx(BuildContext context, RequestTab tab) => EditorCtx(context.read<AppState>(), tab);

String primaryLabel(RequestTab t) => isActive(t) ? 'Cancel' : 'Send';
