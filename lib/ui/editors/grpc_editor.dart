import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';

import '../../models/models.dart';
import '../widgets/common.dart';
import '../widgets/message_log.dart';
import '../widgets/response_view.dart';
import 'actions.dart';
import 'shared.dart';

class GrpcEditor extends StatefulWidget {
  final EditorCtx ctx;
  const GrpcEditor(this.ctx, {super.key});

  @override
  State<GrpcEditor> createState() => _GrpcEditorState();
}

class _GrpcEditorState extends State<GrpcEditor> {
  EditorCtx get ctx => widget.ctx;

  Future<void> _importProto() async {
    final files = await openFiles(acceptedTypeGroups: const [XTypeGroup(label: 'Protocol Buffers', extensions: ['proto'])]);
    if (files.isEmpty) return;
    for (final f in files) {
      final content = await f.readAsString();
      ctx.r.protoFiles.removeWhere((p) => p.name == f.name);
      ctx.r.protoFiles.add(ProtoFile(name: f.name, content: content));
    }
    ctx.r.opts['grpcReflection'] = 'false';
    ctx.changed();
    await loadGrpcSchema(ctx.state, ctx.tab);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final r = ctx.r;
    final tab = ctx.tab;
    final reg = tab.registry;
    final methods = reg?.methodPaths ?? [];
    final found = reg?.findMethod(r.opt('grpcMethod'));
    final method = found?.$2;
    final streaming = method != null && (method.clientStreaming || method.serverStreaming);
    final canSend = method != null && method.clientStreaming && tab.grpcStreamOpen && (tab.grpcEngine?.canSend ?? false);
    final useReflection = r.optBool('grpcReflection', true);
    final tls = r.opts.containsKey('grpcTls') ? r.optBool('grpcTls') : (r.url.startsWith('grpcs://') || r.url.startsWith('https://'));

    final methodPicker = Container(
      width: 360,
      margin: const EdgeInsets.only(right: 8),
      child: methods.isEmpty
          ? OutlinedButton.icon(
              onPressed: tab.sending ? null : () => loadGrpcSchema(ctx.state, tab),
              icon: tab.sending
                  ? const SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh, size: 16),
              label: Text(useReflection ? 'Load methods via reflection' : 'Load methods from proto'),
            )
          : CompactDropdown<String>(
              width: 360,
              value: r.opt('grpcMethod', methods.first),
              items: {for (final m in methods) m: m},
              onChanged: (v) {
                r.opts['grpcMethod'] = v;
                ctx.changed();
              },
            ),
    );

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      RequestTitleBar(ctx),
      UrlBar(
        ctx,
        hint: 'Enter server URL, e.g. localhost:50051 or grpcs://api.example.com',
        syncParams: false,
        buttonLabel: streaming ? 'Invoke stream' : 'Invoke',
        activeLabel: 'Cancel',
        active: tab.sending || tab.grpcStreamOpen,
        onPrimary: () => invokeGrpc(ctx.state, tab),
        prefix: Tooltip(
          message: tls ? 'TLS enabled — click to use plaintext' : 'Plaintext — click to enable TLS',
          child: IconButton(
            icon: Icon(tls ? Icons.lock : Icons.lock_open, size: 16, color: tls ? const Color(0xFF4CC38A) : cs.onSurfaceVariant),
            onPressed: () {
              r.opts['grpcTls'] = (!tls).toString();
              tab.registry = null;
              ctx.changed();
            },
          ),
        ),
        extra: [methodPicker],
      ),
      if (tab.registryError != null)
        Padding(padding: const EdgeInsets.fromLTRB(14, 0, 14, 6), child: SelectableText(tab.registryError!, style: TextStyle(color: cs.error, fontSize: 12))),
      if (method != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
          child: Text('${method.kind}  ·  ${method.inputType} → ${method.outputType}', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
        ),
      Expanded(
        child: requestResponseSplit(
          ctx,
          initial: 0.52,
          request: SimpleTabs(
            key: ValueKey('grpc${tab.id}'),
            labels: ['Message', 'Metadata (${r.headers.where((h) => h.enabled && h.key.isNotEmpty).length})', 'Authorization', 'Service definition', 'Tests', 'Settings', 'Docs'],
            builders: [
              () => Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 4, runSpacing: 4, children: [
                        Text('Request message (JSON)', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                        const SizedBox(width: 12),
                        TextButton.icon(
                          onPressed: method == null
                              ? null
                              : () {
                                  r.message = const JsonEncoder.withIndent('  ').convert(reg!.example(method.inputType));
                                  ctx.changed();
                                },
                          icon: const Icon(Icons.auto_fix_high, size: 15),
                          label: const Text('Generate example'),
                        ),
                        TextButton(onPressed: () => {r.message = beautify(r.message, 'json'), ctx.changed()}, child: const Text('Beautify')),
                        if (method != null && method.clientStreaming) ...[
                          FilledButton.tonal(onPressed: canSend ? () => sendGrpcStreamMessage(ctx.state, tab) : null, child: const Text('Send message')),
                          OutlinedButton(onPressed: canSend ? () => endGrpcStream(tab) : null, child: const Text('End streaming')),
                        ],
                      ]),
                      const SizedBox(height: 6),
                      Expanded(
                        child: CodeEditor(
                          value: r.message,
                          language: 'json',
                          scope: ctx.scope,
                          fontSize: ctx.state.settings.editorFontSize,
                          onChanged: (v) {
                            r.message = v;
                            ctx.changed();
                          },
                        ),
                      ),
                    ]),
                  ),
              () => headersTab(ctx, title: 'Metadata', keyHint: 'Metadata key', showAuto: false),
              () => authTab(ctx, only: const {'apikey', 'bearer', 'basic', 'oauth2', 'jwt', 'awsv4', 'hawk', 'akamai', 'oauth1'}),
              () => _definition(cs),
              () => TestsTab(ctx),
              () => SettingsTab(ctx, redirects: false),
              () => descriptionTab(ctx),
            ],
          ),
          response: streaming || (tab.logs.isNotEmpty && tab.response == null)
              ? MessageLog(messages: tab.logs, onClear: () => {tab.logs.clear(), tab.touch()}, emptyText: 'Invoke the stream to see messages')
              : ResponseView(response: tab.response, loading: tab.sending, isGrpc: true, onCancel: () => invokeGrpc(ctx.state, tab)),
        ),
      ),
    ]);
  }

  Widget _definition(ColorScheme cs) {
    final r = ctx.r;
    final useReflection = r.optBool('grpcReflection', true);
    return ListView(padding: const EdgeInsets.all(14), children: [
      RadioListTile<bool>(
        value: true,
        groupValue: useReflection,
        dense: true,
        title: const Text('Use server reflection'),
        subtitle: const Text('Discover services from the server (grpc.reflection.v1 / v1alpha).'),
        onChanged: (_) {
          r.opts['grpcReflection'] = 'true';
          ctx.tab.registry = null;
          ctx.changed();
          setState(() {});
        },
      ),
      RadioListTile<bool>(
        value: false,
        groupValue: useReflection,
        dense: true,
        title: const Text('Use .proto files'),
        subtitle: const Text('Import one or more .proto files (imports between them are resolved).'),
        onChanged: (_) {
          r.opts['grpcReflection'] = 'false';
          ctx.tab.registry = null;
          ctx.changed();
          setState(() {});
        },
      ),
      const SizedBox(height: 8),
      Row(children: [
        OutlinedButton.icon(onPressed: _importProto, icon: const Icon(Icons.upload_file, size: 16), label: const Text('Import .proto files')),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          onPressed: () async {
            final name = await promptText(context, 'New proto file', initial: 'service.proto');
            if (name == null) return;
            r.protoFiles.add(ProtoFile(name: name, content: 'syntax = "proto3";\n\npackage example;\n\n'));
            r.opts['grpcReflection'] = 'false';
            ctx.changed();
            setState(() {});
          },
          icon: const Icon(Icons.add, size: 16),
          label: const Text('New proto'),
        ),
        const SizedBox(width: 8),
        FilledButton.tonal(onPressed: () => loadGrpcSchema(ctx.state, ctx.tab), child: const Text('Reload definitions')),
      ]),
      const SizedBox(height: 12),
      for (final f in r.protoFiles)
        Container(
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(border: Border.all(color: cs.outlineVariant), borderRadius: BorderRadius.circular(4)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
              child: Row(children: [
                const Icon(Icons.description_outlined, size: 15),
                const SizedBox(width: 6),
                Expanded(child: Text(f.name, style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13))),
                IconButton(
                  iconSize: 16,
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () {
                    r.protoFiles.remove(f);
                    ctx.tab.registry = null;
                    ctx.changed();
                    setState(() {});
                  },
                ),
              ]),
            ),
            SizedBox(
              height: 260,
              child: CodeEditor(
                value: f.content,
                language: 'protobuf',
                onChanged: (v) {
                  f.content = v;
                  ctx.changed();
                },
              ),
            ),
          ]),
        ),
      if (ctx.tab.registry != null) ...[
        const SizedBox(height: 6),
        Text('Loaded services', style: TextStyle(fontWeight: FontWeight.w600, color: cs.onSurfaceVariant, fontSize: 12)),
        for (final s in ctx.tab.registry!.services.values)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s.fullName, style: const TextStyle(fontWeight: FontWeight.w500)),
              for (final m in s.methods)
                Text('  ${m.name}(${m.clientStreaming ? 'stream ' : ''}${m.inputType}) → ${m.serverStreaming ? 'stream ' : ''}${m.outputType}',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            ]),
          ),
      ],
    ]);
  }
}
