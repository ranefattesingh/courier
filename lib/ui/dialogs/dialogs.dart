import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../../core/codegen.dart';
import '../../core/importers.dart';
import '../../models/models.dart';
import '../../state/app_state.dart';
import '../../state/executor.dart';
import '../theme.dart';
import '../widgets/auth_editor.dart';
import '../widgets/common.dart';

Future<T?> _bigDialog<T>(BuildContext context, {required String title, required Widget child, double width = 900, double height = 640, List<Widget> actions = const []}) {
  return showDialog<T>(
    context: context,
    builder: (ctx) => Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(
        width: width,
        height: height,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 8, 8),
            child: Row(children: [
              Expanded(child: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
              ...actions,
              IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => Navigator.pop(ctx)),
            ]),
          ),
          const Divider(),
          Expanded(child: child),
        ]),
      ),
    ),
  );
}

// ============================================================================ Save

/// Saves a tab; asks for a location if the request is not yet in a collection.
Future<void> saveTabInteractive(BuildContext context, AppState state, RequestTab tab) async {
  if (state.saveTab(tab)) {
    toast(context, 'Saved "${tab.draft.name}"');
    return;
  }
  await showDialog(context: context, builder: (_) => _SaveDialog(state: state, tab: tab));
}

class _SaveDialog extends StatefulWidget {
  final AppState state;
  final RequestTab tab;
  const _SaveDialog({required this.state, required this.tab});

  @override
  State<_SaveDialog> createState() => _SaveDialogState();
}

class _SaveDialogState extends State<_SaveDialog> {
  late final _name = TextEditingController(text: widget.tab.draft.name.replaceFirst(RegExp(r'^Untitled '), ''));
  String? _target;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final rows = <Widget>[];
    void walk(Folder f, int depth) {
      rows.add(InkWell(
        onTap: () => setState(() => _target = f.id),
        child: Container(
          color: _target == f.id ? cs.primary.withValues(alpha: 0.15) : null,
          padding: EdgeInsets.fromLTRB(10 + depth * 18.0, 7, 10, 7),
          child: Row(children: [
            Icon(depth == 0 ? Icons.inventory_2_outlined : Icons.folder_outlined, size: 16, color: cs.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(child: Text(f.name, style: const TextStyle(fontSize: 13))),
          ]),
        ),
      ));
      for (final c in f.children.whereType<Folder>()) {
        walk(c, depth + 1);
      }
    }

    for (final c in widget.state.collections) {
      walk(c, 0);
    }
    return AlertDialog(
      title: const Text('Save request', style: TextStyle(fontSize: 16)),
      content: SizedBox(
        width: 460,
        height: 420,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Request name'), autofocus: true),
          const SizedBox(height: 14),
          Row(children: [
            Text('Save to', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            const Spacer(),
            TextButton.icon(
              onPressed: () async {
                final n = await promptText(context, 'New collection', hint: 'Collection name', okLabel: 'Create');
                if (n != null) setState(() => _target = widget.state.addCollection(n).id);
              },
              icon: const Icon(Icons.add, size: 15),
              label: const Text('New collection'),
            ),
            TextButton.icon(
              onPressed: _target == null
                  ? null
                  : () async {
                      final n = await promptText(context, 'New folder', hint: 'Folder name', okLabel: 'Create');
                      final parent = widget.state.findNode(_target!);
                      if (n != null && parent is Folder) setState(() => _target = widget.state.addFolder(parent, n).id);
                    },
              icon: const Icon(Icons.create_new_folder_outlined, size: 15),
              label: const Text('New folder'),
            ),
          ]),
          const SizedBox(height: 4),
          Expanded(
            child: Container(
              decoration: BoxDecoration(border: Border.all(color: cs.outlineVariant)),
              child: rows.isEmpty ? const EmptyHint(Icons.inventory_2_outlined, 'Create a collection first') : ListView(children: rows),
            ),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _target == null || _name.text.trim().isEmpty
              ? null
              : () {
                  widget.state.saveTabAs(widget.tab, widget.state.findNode(_target!) as Folder, _name.text.trim());
                  Navigator.pop(context);
                },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

// ============================================================================ Code generation

Future<void> showCodegenDialog(BuildContext context, AppState state, RequestTab tab) async {
  final ex = Executor(state);
  String lang = 'curl';
  String code = '';
  String gen() => code;

  try {
    final p = await ex.prepare(tab.draft, tab.sourceId);
    final resolved = ex.resolve(tab.draft, tab.sourceId);
    code = generateCode(lang, p, resolved);
    if (!context.mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        return AlertDialog(
          title: Row(children: [
            const Text('Code snippet', style: TextStyle(fontSize: 16)),
            const SizedBox(width: 16),
            CompactDropdown<String>(
              value: lang,
              items: codegenLanguages,
              onChanged: (v) => set(() {
                lang = v;
                code = generateCode(lang, p, resolved);
              }),
            ),
            const Spacer(),
            IconButton(
              tooltip: 'Copy',
              icon: const Icon(Icons.copy, size: 18),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: gen()));
                toast(ctx, 'Copied');
              },
            ),
          ]),
          content: SizedBox(
            width: 760,
            height: 480,
            child: CodeEditor(
              key: ValueKey(lang),
              value: code,
              readOnly: true,
              language: const {'curl': 'bash', 'http': 'http', 'python': 'python', 'fetch': 'javascript', 'axios': 'javascript', 'go': 'go', 'csharp': 'cs', 'java': 'java', 'powershell': 'powershell'}[lang]!,
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
        );
      }),
    );
  } catch (e) {
    if (context.mounted) toast(context, 'Cannot generate code: $e', error: true);
  }
}

// ============================================================================ Import / Export

Future<void> showImportDialog(BuildContext context, AppState state) async {
  final c = TextEditingController();
  String? error;
  await showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) {
        void doImport(String text) {
          try {
            final res = importAny(text);
            if (res.isEmpty) throw const FormatException('Nothing to import');
            state.collections.addAll(res.collections);
            state.environments.addAll(res.environments);
            for (final r in res.requests) {
              state.newTab(r.type, from: r);
            }
            state.changed();
            Navigator.pop(ctx);
            toast(context,
                'Imported ${[if (res.collections.isNotEmpty) '${res.collections.length} collection(s)', if (res.environments.isNotEmpty) '${res.environments.length} environment(s)', if (res.requests.isNotEmpty) '${res.requests.length} request(s)'].join(', ')}');
          } catch (e) {
            set(() => error = e is FormatException ? e.message : e.toString());
          }
        }

        return AlertDialog(
          title: const Text('Import', style: TextStyle(fontSize: 16)),
          content: SizedBox(
            width: 640,
            height: 420,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Supported: ${supportedImportFormats.join(' · ')}', style: const TextStyle(fontSize: 12)),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () async {
                  final files = await openFiles(acceptedTypeGroups: const [XTypeGroup(label: 'JSON / YAML / text', extensions: ['json', 'yaml', 'yml', 'txt', 'sh', 'curl'])]);
                  for (final f in files) {
                    doImport(await f.readAsString());
                    if (error != null) break;
                  }
                },
                icon: const Icon(Icons.upload_file, size: 16),
                label: const Text('Upload files'),
              ),
              const SizedBox(height: 10),
              const Text('…or paste raw text', style: TextStyle(fontSize: 12)),
              const SizedBox(height: 6),
              Expanded(
                child: TextField(
                  controller: c,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  style: mono(ctx, size: 12),
                  decoration: const InputDecoration(hintText: "curl -X GET 'https://api.example.com'\n\nor paste a Postman / Insomnia / Courier export (JSON or YAML)"),
                ),
              ),
              if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: TextStyle(color: Theme.of(ctx).colorScheme.error, fontSize: 12))),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(onPressed: () => doImport(c.text), child: const Text('Import')),
          ],
        );
      },
    ),
  );
}

Future<void> exportCollection(BuildContext context, Folder c, {required bool postman}) async {
  final data = postman ? exportPostmanCollection(c) : exportCourier(collections: [c]);
  final name = '${c.name.replaceAll(RegExp(r'[^\w\- ]'), '_')}.${postman ? 'postman_collection' : 'courier'}.json';
  await _saveJson(context, name, data);
}

Future<void> exportEnvironment(BuildContext context, Environment e, {required bool postman}) async {
  final data = postman ? exportPostmanEnvironment(e) : exportCourier(environments: [e]);
  await _saveJson(context, '${e.name.replaceAll(RegExp(r'[^\w\- ]'), '_')}.${postman ? 'postman_environment' : 'courier'}.json', data);
}

Future<void> exportWorkspace(BuildContext context, AppState state) =>
    _saveJson(context, 'courier-workspace.json', exportCourier(collections: state.collections, environments: state.environments));

Future<void> _saveJson(BuildContext context, String name, Object data) async {
  final loc = await getSaveLocation(suggestedName: name, acceptedTypeGroups: const [XTypeGroup(label: 'JSON', extensions: ['json'])]);
  if (loc == null) return;
  await XFile.fromData(Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent('  ').convert(data))), mimeType: 'application/json').saveTo(loc.path);
  if (context.mounted) toast(context, 'Exported to ${loc.path}');
}

/// Courier export or Postman v2.1. Postman's format only represents HTTP-family requests.
Future<void> showExportDialog(BuildContext context, AppState state, {Folder? initial}) async {
  String scope = initial?.id ?? 'all';
  String format = 'courier';
  bool includeEnvs = true;
  int countUnsupported(Folder f) => f.children.fold(0, (n, c) {
        if (c is Folder) return n + countUnsupported(c);
        final r = c as ApiRequest;
        return n + (r.type == RequestType.http || r.type == RequestType.graphql || r.type == RequestType.soap ? 0 : 1);
      });
  await showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
      final cs = Theme.of(ctx).colorScheme;
      final selected = scope == 'all' ? state.collections : state.collections.where((c) => c.id == scope).toList();
      final unsupported = selected.fold<int>(0, (n, c) => n + countUnsupported(c));
      return AlertDialog(
        title: const Text('Export', style: TextStyle(fontSize: 16)),
        content: SizedBox(
          width: 520,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('What to export', style: TextStyle(fontSize: 12)),
            const SizedBox(height: 6),
            CompactDropdown<String>(
              width: 480,
              value: scope,
              items: {'all': 'All collections (${state.collections.length})', for (final c in state.collections) c.id: c.name},
              onChanged: (v) => set(() => scope = v),
            ),
            const SizedBox(height: 14),
            const Text('Format', style: TextStyle(fontSize: 12)),
            RadioListTile<String>(
              value: 'courier',
              groupValue: format,
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Courier JSON'),
              subtitle: const Text('Full fidelity: every protocol, auth, tests, variables and folders. Re-import into Courier.'),
              onChanged: (v) => set(() => format = v!),
            ),
            RadioListTile<String>(
              value: 'postman',
              groupValue: format,
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Postman Collection v2.1 JSON'),
              subtitle: const Text('Importable by Postman, Insomnia and most API tools. One file per collection.'),
              onChanged: (v) => set(() => format = v!),
            ),
            if (format == 'courier')
              CheckboxListTile(
                value: includeEnvs,
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text('Include environments (${state.environments.length}) and globals'),
                onChanged: (v) => set(() => includeEnvs = v ?? true),
              ),
            if (format == 'postman' && unsupported > 0)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('$unsupported request(s) use protocols Postman\'s collection format cannot hold (gRPC, WebSocket, Socket.IO, MQTT, SSE, Kafka) and will be left out. Use Courier JSON to keep them.',
                    style: TextStyle(fontSize: 12, color: cs.error)),
              ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: selected.isEmpty
                ? null
                : () async {
                    Navigator.pop(ctx);
                    if (format == 'postman') {
                      for (final c in selected) {
                        await exportCollection(context, c, postman: true);
                      }
                    } else if (scope == 'all') {
                      await _saveJson(context, 'courier-export.json', exportCourier(
                        collections: selected,
                        environments: includeEnvs ? [...state.environments, if (state.globals.isNotEmpty) Environment(id: newId(), name: 'Globals', variables: state.globals)] : [],
                      ));
                    } else {
                      final c = selected.single;
                      await _saveJson(context, '${c.name.replaceAll(RegExp(r'[^\w\- ]'), '_')}.courier.json',
                          exportCourier(collections: [c], environments: includeEnvs ? state.environments : []));
                    }
                  },
            child: const Text('Export'),
          ),
        ],
      );
    }),
  );
}

// ============================================================================ Folder / Collection settings

Future<void> showFolderSettings(BuildContext context, AppState state, Folder f, {bool isCollection = false}) async {
  final draft = Folder.fromJson(jsonDecode(jsonEncode(f.toJson())) as Map<String, dynamic>);
  await _bigDialog(
    context,
    title: '${isCollection ? 'Collection' : 'Folder'} — ${f.name}',
    actions: [
      FilledButton(
        onPressed: () {
          f.name = draft.name;
          f.description = draft.description;
          f.auth = draft.auth;
          f.variables = draft.variables;
          state.changed();
          Navigator.pop(context);
        },
        child: const Text('Save'),
      ),
      const SizedBox(width: 6),
    ],
    child: StatefulBuilder(
      builder: (ctx, set) => SimpleTabs(
        labels: ['Overview', 'Authorization', if (isCollection) 'Variables'],
        builders: [
          () => Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  SyncedTextField(value: draft.name, label: 'Name', onChanged: (v) => draft.name = v),
                  const SizedBox(height: 12),
                  Expanded(child: CodeEditor(value: draft.description, language: 'markdown', hint: 'Description (markdown)', onChanged: (v) => draft.description = v)),
                ]),
              ),
          () => AuthEditor(
                auth: draft.auth,
                allowInherit: !isCollection,
                onChanged: () {},
                inheritedFrom: state.authSourceName(f.id),
                scope: () => state.scopeFor(f.id),
              ),
          if (isCollection)
            () => SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    const Text('Collection variables are available to every request in this collection. Environment variables override them.', style: TextStyle(fontSize: 12)),
                    const SizedBox(height: 10),
                    KvTable(rows: draft.variables, allowSecret: true, keyHint: 'Variable', valueHint: 'Value', onChanged: () {}),
                  ]),
                ),
        ],
      ),
    ),
  );
}

// ============================================================================ Environments

Future<void> showEnvironmentEditor(BuildContext context, AppState state, {Environment? env, bool globals = false}) async {
  final title = globals ? 'Globals' : env!.name;
  final rows = globals ? state.globals : env!.variables;
  await _bigDialog(
    context,
    title: title,
    width: 900,
    height: 600,
    actions: [
      if (!globals) ...[
        TextButton(
          onPressed: () async {
            final n = await promptText(context, 'Rename environment', initial: env!.name);
            if (n != null) {
              env.name = n;
              state.changed();
            }
          },
          child: const Text('Rename'),
        ),
        TextButton(onPressed: () => exportEnvironment(context, env!, postman: true), child: const Text('Export')),
        TextButton(
          onPressed: () {
            state.setActiveEnv(env!.id);
          },
          child: const Text('Set active'),
        ),
      ],
    ],
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(
          globals
              ? 'Global variables are available everywhere, with the lowest precedence.'
              : 'Use variables as {{name}} in URLs, headers, bodies and auth. Mark sensitive values as secret to mask them.',
          style: const TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 10),
        KvTable(rows: rows, allowSecret: true, keyHint: 'Variable', valueHint: 'Value', onChanged: state.changed),
      ]),
    ),
  );
}

// ============================================================================ Settings

Future<void> showSettingsDialog(BuildContext context, AppState state) async {
  final s = state.settings;
  await _bigDialog(
    context,
    title: 'Settings',
    width: 760,
    height: 620,
    child: StatefulBuilder(builder: (ctx, set) {
      void upd(void Function() f) {
        state.updateSettings((_) => f());
        set(() {});
      }

      Future<void> pick(void Function(String) apply) async {
        final f = await openFile();
        if (f != null) upd(() => apply(f.path));
      }

      Widget fileField(String label, String value, void Function(String) apply) => FieldRow(
            label,
            Row(children: [
              Expanded(child: SyncedTextField(value: value, hint: 'Path to file', onChanged: (v) => upd(() => apply(v)))),
              const SizedBox(width: 6),
              OutlinedButton(onPressed: () => pick(apply), child: const Text('Browse')),
            ]),
          );

      return SimpleTabs(labels: const [
        'General',
        'Proxy',
        'Certificates',
      ], builders: [
        () => ListView(padding: const EdgeInsets.all(16), children: [
              SwitchListTile(title: const Text('Dark theme'), value: s.darkMode, onChanged: (v) => upd(() => s.darkMode = v)),
              FieldRow(
                'Request / response layout',
                Align(
                  alignment: Alignment.centerLeft,
                  child: SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 'bottom', icon: Icon(Icons.view_agenda_outlined, size: 16), label: Text('Stacked (response below)')),
                      ButtonSegment(value: 'right', icon: Icon(Icons.view_column_outlined, size: 16), label: Text('Side by side (response right)')),
                    ],
                    selected: {s.responsePane},
                    onSelectionChanged: (v) => upd(() => s.responsePane = v.first),
                  ),
                ),
              ),
              SwitchListTile(title: const Text('SSL certificate verification'), value: s.verifySsl, onChanged: (v) => upd(() => s.verifySsl = v)),
              SwitchListTile(title: const Text('Automatically follow redirects'), value: s.followRedirects, onChanged: (v) => upd(() => s.followRedirects = v)),
              SwitchListTile(title: const Text('Send no-cache header'), value: s.sendNoCacheHeader, onChanged: (v) => upd(() => s.sendNoCacheHeader = v)),
              SwitchListTile(title: const Text('Automatically persist cookies'), value: s.autoSaveCookies, onChanged: (v) => upd(() => s.autoSaveCookies = v)),
              FieldRow('Request timeout (ms)', SyncedTextField(value: '${s.timeoutMs}', hint: '0 = never', onChanged: (v) => upd(() => s.timeoutMs = int.tryParse(v) ?? 0))),
              FieldRow('Max redirects', SyncedTextField(value: '${s.maxRedirects}', onChanged: (v) => upd(() => s.maxRedirects = int.tryParse(v) ?? 10))),
              FieldRow('History limit', SyncedTextField(value: '${s.historyLimit}', onChanged: (v) => upd(() => s.historyLimit = int.tryParse(v) ?? 300))),
              FieldRow(
                'Editor font size',
                Slider(min: 10, max: 20, divisions: 10, value: s.editorFontSize, label: '${s.editorFontSize.round()}', onChanged: (v) => upd(() => s.editorFontSize = v)),
              ),
            ]),
        () => ListView(padding: const EdgeInsets.all(16), children: [
              RadioListTile<String>(value: 'none', groupValue: s.proxyMode, title: const Text('No proxy'), onChanged: (v) => upd(() => s.proxyMode = v!)),
              RadioListTile<String>(
                value: 'system',
                groupValue: s.proxyMode,
                title: const Text('Use system proxy'),
                subtitle: const Text('Reads http_proxy / https_proxy / no_proxy environment variables'),
                onChanged: (v) => upd(() => s.proxyMode = v!),
              ),
              RadioListTile<String>(value: 'custom', groupValue: s.proxyMode, title: const Text('Custom proxy'), onChanged: (v) => upd(() => s.proxyMode = v!)),
              if (s.proxyMode == 'custom') ...[
                FieldRow('Proxy host', SyncedTextField(value: s.proxyHost, hint: '127.0.0.1', onChanged: (v) => upd(() => s.proxyHost = v))),
                FieldRow('Proxy port', SyncedTextField(value: '${s.proxyPort}', onChanged: (v) => upd(() => s.proxyPort = int.tryParse(v) ?? 8080))),
                FieldRow('Username', SyncedTextField(value: s.proxyUser, onChanged: (v) => upd(() => s.proxyUser = v))),
                FieldRow('Password', SyncedTextField(value: s.proxyPass, obscure: true, onChanged: (v) => upd(() => s.proxyPass = v))),
              ],
            ]),
        () => ListView(padding: const EdgeInsets.all(16), children: [
              const Text('CA certificate', style: TextStyle(fontWeight: FontWeight.w600)),
              const Text('Trust an extra CA (PEM) for self-signed / corporate certificates.', style: TextStyle(fontSize: 12)),
              fileField('CA certificate file', s.caCertPath, (v) => s.caCertPath = v),
              const SizedBox(height: 16),
              const Text('Client certificate (mutual TLS)', style: TextStyle(fontWeight: FontWeight.w600)),
              const Text('Sent to servers that request a client certificate. PEM or PKCS#12.', style: TextStyle(fontSize: 12)),
              fileField('Certificate (CRT/PEM/PFX)', s.clientCertPath, (v) => s.clientCertPath = v),
              fileField('Private key (KEY)', s.clientKeyPath, (v) => s.clientKeyPath = v),
              FieldRow('Passphrase', SyncedTextField(value: s.clientKeyPassphrase, obscure: true, onChanged: (v) => upd(() => s.clientKeyPassphrase = v))),
            ]),
      ]);
    }),
  );
}

// ============================================================================ Cookies

Future<void> showCookiesDialog(BuildContext context, AppState state) async {
  await _bigDialog(
    context,
    title: 'Manage Cookies',
    width: 860,
    height: 560,
    child: StatefulBuilder(builder: (ctx, set) {
      final byDomain = <String, List<StoredCookie>>{};
      for (final c in state.cookieJar.cookies) {
        (byDomain[c.domain] ??= []).add(c);
      }
      final cs = Theme.of(ctx).colorScheme;
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(children: [
            Text('${state.cookieJar.cookies.length} cookies across ${byDomain.length} domains', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
            const Spacer(),
            OutlinedButton.icon(
              onPressed: () async {
                final domain = await promptText(ctx, 'Add cookie — domain', hint: 'example.com', okLabel: 'Next');
                if (domain == null || !ctx.mounted) return;
                final kv = await promptText(ctx, 'Cookie for $domain', hint: 'name=value', okLabel: 'Add');
                if (kv == null || !kv.contains('=')) return;
                state.cookieJar.cookies.add(StoredCookie(name: kv.substring(0, kv.indexOf('=')).trim(), value: kv.substring(kv.indexOf('=') + 1).trim(), domain: domain));
                state.changed();
                set(() {});
              },
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add cookie'),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () {
                state.cookieJar.cookies.clear();
                state.changed();
                set(() {});
              },
              child: const Text('Clear all'),
            ),
          ]),
        ),
        Expanded(
          child: byDomain.isEmpty
              ? const EmptyHint(Icons.cookie_outlined, 'No cookies stored. Cookies set by servers are saved here automatically.')
              : ListView(padding: const EdgeInsets.symmetric(horizontal: 16), children: [
                  for (final e in byDomain.entries) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 12, bottom: 4),
                      child: Row(children: [
                        Text(e.key, style: const TextStyle(fontWeight: FontWeight.w600)),
                        const Spacer(),
                        TextButton(
                          onPressed: () {
                            state.cookieJar.cookies.removeWhere((c) => c.domain == e.key);
                            state.changed();
                            set(() {});
                          },
                          child: const Text('Delete domain', style: TextStyle(fontSize: 12)),
                        ),
                      ]),
                    ),
                    for (final c in e.value)
                      Container(
                        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: cs.outlineVariant))),
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(children: [
                          SizedBox(width: 180, child: Text(c.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500))),
                          Expanded(child: SelectableText(c.value, style: mono(ctx, size: 12))),
                          SizedBox(width: 80, child: Text(c.path, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant))),
                          SizedBox(width: 170, child: Text(c.expires?.toLocal().toString().split('.').first ?? 'Session', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant))),
                          IconButton(
                            iconSize: 15,
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () {
                              state.cookieJar.cookies.remove(c);
                              state.changed();
                              set(() {});
                            },
                          ),
                        ]),
                      ),
                  ],
                ]),
        ),
      ]);
    }),
  );
}

// ============================================================================ Console

Future<void> showConsoleDialog(BuildContext context, AppState state) async {
  await _bigDialog(
    context,
    title: 'Console',
    width: 1000,
    height: 640,
    child: StatefulBuilder(builder: (ctx, set) {
      final cs = Theme.of(ctx).colorScheme;
      if (state.console.isEmpty) return const EmptyHint(Icons.terminal, 'Requests you send will be logged here with full headers and bodies');
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(onPressed: () => set(() => state.console.clear()), child: const Text('Clear')),
        ),
        Expanded(
          child: ListView(children: [
            for (final e in state.console)
              ExpansionTile(
                dense: true,
                tilePadding: const EdgeInsets.symmetric(horizontal: 16),
                title: Row(children: [
                  SizedBox(width: 70, child: Text(e.method, style: TextStyle(color: methodColor(e.method), fontWeight: FontWeight.w700, fontSize: 12))),
                  Expanded(child: Text(e.url, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
                  if (e.error != null)
                    Text('Error', style: TextStyle(color: cs.error, fontSize: 12))
                  else
                    Text('${e.status}', style: TextStyle(color: statusColor(e.status ?? 0), fontWeight: FontWeight.w600, fontSize: 12)),
                  const SizedBox(width: 12),
                  SizedBox(width: 70, child: Text('${e.timeMs} ms', textAlign: TextAlign.right, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant))),
                  const SizedBox(width: 12),
                  Text(formatTime(e.time), style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
                ]),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (e.error != null) SelectableText(e.error!, style: TextStyle(color: cs.error)),
                  _consoleSection(ctx, 'Request Headers', e.requestHeaders.map((h) => '${h.key}: ${h.value}').join('\n')),
                  if (e.requestBody.isNotEmpty) _consoleSection(ctx, 'Request Body', e.requestBody),
                  if (e.responseHeaders.isNotEmpty) _consoleSection(ctx, 'Response Headers', e.responseHeaders.map((h) => '${h.key}: ${h.value}').join('\n')),
                  if (e.responseBody.isNotEmpty) _consoleSection(ctx, 'Response Body', e.responseBody),
                ],
              ),
          ]),
        ),
      ]);
    }),
  );
}

Widget _consoleSection(BuildContext ctx, String title, String body) => Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
        const SizedBox(height: 2),
        SelectableText(body, style: mono(ctx, size: 12)),
      ]),
    );

// ============================================================================ Variables quick look

Future<void> showVariablesQuickLook(BuildContext context, AppState state) async {
  final env = state.activeEnv;
  final cs = Theme.of(context).colorScheme;
  Widget section(String title, List<KV> vars, VoidCallback onEdit) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          const Spacer(),
          TextButton(onPressed: onEdit, child: const Text('Edit', style: TextStyle(fontSize: 12))),
        ]),
        if (vars.isEmpty) Text('No variables', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
        for (final v in vars.where((v) => v.key.isNotEmpty))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              SizedBox(width: 180, child: Text(v.key, style: TextStyle(fontSize: 12.5, color: v.enabled ? cs.onSurface : cs.onSurfaceVariant))),
              Expanded(child: Text(v.type == 'secret' ? '••••••••' : v.value, overflow: TextOverflow.ellipsis, style: mono(context, size: 12))),
            ]),
          ),
        const SizedBox(height: 12),
      ]);
  await showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            section(env == null ? 'No environment selected' : 'Environment: ${env.name}', env?.variables ?? [], () {
              Navigator.pop(ctx);
              if (env != null) showEnvironmentEditor(context, state, env: env);
            }),
            section('Globals', state.globals, () {
              Navigator.pop(ctx);
              showEnvironmentEditor(context, state, globals: true);
            }),
          ]),
        ),
      ),
    ),
  );
}
