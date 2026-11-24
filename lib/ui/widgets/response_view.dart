import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../../models/models.dart';
import '../theme.dart';
import 'common.dart';

/// Response pane for request/response protocols (HTTP, GraphQL, SOAP, gRPC unary).
class ResponseView extends StatefulWidget {
  final ResponseData? response;
  final bool loading;
  final VoidCallback? onCancel;
  final bool isGrpc;
  const ResponseView({super.key, this.response, this.loading = false, this.onCancel, this.isGrpc = false});

  @override
  State<ResponseView> createState() => _ResponseViewState();
}

class _ResponseViewState extends State<ResponseView> {
  String _mode = 'pretty';
  String _search = '';
  bool _wrap = true;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (widget.loading) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.5)),
          const SizedBox(height: 12),
          Text('Sending request…', style: TextStyle(color: cs.onSurfaceVariant)),
          const SizedBox(height: 8),
          if (widget.onCancel != null) OutlinedButton(onPressed: widget.onCancel, child: const Text('Cancel')),
        ]),
      );
    }
    final r = widget.response;
    if (r == null) {
      return const EmptyHint(Icons.send_outlined, 'Enter the URL and click Send to get a response');
    }
    if (r.error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.cloud_off, size: 42, color: cs.error.withValues(alpha: 0.7)),
            const SizedBox(height: 10),
            Text('Could not get response', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: cs.onSurface)),
            const SizedBox(height: 8),
            SelectableText(r.error!, textAlign: TextAlign.center, style: TextStyle(color: cs.onSurfaceVariant)),
            if (r.finalUrl.isNotEmpty) ...[
              const SizedBox(height: 6),
              SelectableText('${r.method} ${r.finalUrl}', style: mono(context, size: 12, color: cs.onSurfaceVariant)),
            ],
          ]),
        ),
      );
    }
    final passed = r.tests.where((t) => t.passed).length;
    final statusLabel = widget.isGrpc ? '${r.status} ${r.statusText}' : '${r.status} ${r.statusText}';
    final sColor = widget.isGrpc ? (r.status == 0 ? statusColor(200) : statusColor(500)) : statusColor(r.status);
    return SimpleTabs(
      labels: [
        'Body',
        'Cookies${r.cookies.isEmpty ? '' : ' (${r.cookies.length})'}',
        '${widget.isGrpc ? 'Metadata' : 'Headers'} (${r.headers.length})',
        if (widget.isGrpc) 'Trailers (${r.trailers.length})',
        'Test Results${r.tests.isEmpty ? '' : ' ($passed/${r.tests.length})'}',
        'Request',
      ],
      builders: [
        () => _body(r),
        () => _cookies(r),
        () => _headers(r.headers),
        if (widget.isGrpc) () => _headers(r.trailers),
        () => _tests(r),
        () => _request(r),
      ],
      trailing: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(children: [
          Text('Status: ', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          Text(statusLabel, style: TextStyle(fontSize: 12, color: sColor, fontWeight: FontWeight.w600)),
          const SizedBox(width: 14),
          Text('Time: ', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          Text('${r.timeMs} ms', style: TextStyle(fontSize: 12, color: statusColor(200), fontWeight: FontWeight.w600)),
          const SizedBox(width: 14),
          Text('Size: ', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          Text(formatBytes(r.size), style: TextStyle(fontSize: 12, color: statusColor(200), fontWeight: FontWeight.w600)),
          const SizedBox(width: 6),
          PopupMenuButton<String>(
            tooltip: 'More',
            icon: const Icon(Icons.more_horiz, size: 18),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'save', height: 32, child: Text('Save response to file')),
              PopupMenuItem(value: 'copy', height: 32, child: Text('Copy body')),
            ],
            onSelected: (v) async {
              if (v == 'copy') {
                await Clipboard.setData(ClipboardData(text: r.bodyText));
                if (mounted) toast(context, 'Response copied');
              } else {
                final ext = detectLanguage(r.contentType, r.bodyText);
                final loc = await getSaveLocation(suggestedName: 'response.${ext == 'text' ? 'txt' : ext}');
                if (loc != null) {
                  await XFile.fromData(Uint8List.fromList(r.body)).saveTo(loc.path);
                  if (mounted) toast(context, 'Saved to ${loc.path}');
                }
              }
            },
          ),
        ]),
      ),
    );
  }

  Widget _body(ResponseData r) {
    final cs = Theme.of(context).colorScheme;
    final ct = r.contentType.toLowerCase();
    final isImage = ct.startsWith('image/') && !ct.contains('svg');
    final lang = r.displayLanguage ?? detectLanguage(r.contentType, r.bodyText);
    var text = r.bodyText;
    if (_mode == 'pretty') text = beautify(text, lang);
    final lines = _search.isEmpty ? null : text.split('\n').where((l) => l.toLowerCase().contains(_search.toLowerCase())).length;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
        child: Row(children: [
          SegmentedButton<String>(
            style: const ButtonStyle(visualDensity: VisualDensity.compact, textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 12))),
            showSelectedIcon: false,
            segments: [
              const ButtonSegment(value: 'pretty', label: Text('Pretty')),
              const ButtonSegment(value: 'raw', label: Text('Raw')),
              if (isImage) const ButtonSegment(value: 'preview', label: Text('Preview')),
            ],
            selected: {_mode == 'preview' && !isImage ? 'pretty' : _mode},
            onSelectionChanged: (s) => setState(() => _mode = s.first),
          ),
          const SizedBox(width: 10),
          Text(lang.toUpperCase(), style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
          const Spacer(),
          SizedBox(
            width: 200,
            child: TextField(
              style: const TextStyle(fontSize: 12),
              decoration: InputDecoration(
                hintText: 'Find in response',
                prefixIcon: const Icon(Icons.search, size: 16),
                prefixIconConstraints: const BoxConstraints(minWidth: 28),
                suffixText: lines == null ? null : '$lines lines',
              ),
              onChanged: (v) => setState(() => _search = v),
            ),
          ),
          IconButton(
            tooltip: _wrap ? 'Disable wrapping' : 'Wrap lines',
            iconSize: 16,
            icon: Icon(_wrap ? Icons.wrap_text : Icons.notes),
            onPressed: () => setState(() => _wrap = !_wrap),
          ),
          IconButton(
            tooltip: 'Copy',
            iconSize: 16,
            icon: const Icon(Icons.copy),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (mounted) toast(context, 'Copied to clipboard');
            },
          ),
        ]),
      ),
      Expanded(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
          child: _mode == 'preview' && isImage
              ? Container(
                  color: cs.surfaceContainerLowest,
                  alignment: Alignment.center,
                  child: Image.memory(Uint8List.fromList(r.body), errorBuilder: (_, e, __) => Text('Cannot render image: $e')),
                )
              : _search.isNotEmpty
                  ? _searchView(text)
                  : _wrap
                      ? CodeEditor(key: ValueKey('resp${r.hashCode}$_mode'), value: text, language: _mode == 'raw' ? 'text' : lang, readOnly: true)
                      : Container(
                          decoration: BoxDecoration(color: cs.surfaceContainerLowest, border: Border.all(color: cs.outlineVariant)),
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.all(10),
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: SelectableText.rich(
                                CodeController(text: text, language: _mode == 'raw' ? 'text' : lang)
                                    .buildTextSpan(context: context, style: mono(context), withComposing: false),
                              ),
                            ),
                          ),
                        ),
        ),
      ),
    ]);
  }

  Widget _searchView(String text) {
    final cs = Theme.of(context).colorScheme;
    final q = _search.toLowerCase();
    final lines = text.split('\n');
    final hits = <int>[for (var i = 0; i < lines.length; i++) if (lines[i].toLowerCase().contains(q)) i];
    return Container(
      decoration: BoxDecoration(color: cs.surfaceContainerLowest, border: Border.all(color: cs.outlineVariant)),
      child: ListView.builder(
        itemCount: hits.length,
        itemBuilder: (_, i) {
          final line = lines[hits[i]];
          final spans = <TextSpan>[];
          var idx = 0;
          final lower = line.toLowerCase();
          while (true) {
            final f = lower.indexOf(q, idx);
            if (f < 0) {
              spans.add(TextSpan(text: line.substring(idx)));
              break;
            }
            spans.add(TextSpan(text: line.substring(idx, f)));
            spans.add(TextSpan(text: line.substring(f, f + q.length), style: TextStyle(backgroundColor: accent.withValues(alpha: 0.4))));
            idx = f + q.length;
          }
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 50, child: Text('${hits[i] + 1}', style: mono(context, size: 12, color: cs.onSurfaceVariant))),
              Expanded(child: SelectableText.rich(TextSpan(style: mono(context, size: 12), children: spans))),
            ]),
          );
        },
      ),
    );
  }

  Widget _headers(List<MapEntry<String, String>> h) {
    final cs = Theme.of(context).colorScheme;
    if (h.isEmpty) return const EmptyHint(Icons.list_alt, 'No headers');
    return ListView.separated(
      padding: const EdgeInsets.all(10),
      itemCount: h.length,
      separatorBuilder: (_, __) => Divider(color: cs.outlineVariant),
      itemBuilder: (_, i) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 260, child: SelectableText(h[i].key, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500))),
          Expanded(child: SelectableText(h[i].value, style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant))),
        ]),
      ),
    );
  }

  Widget _cookies(ResponseData r) {
    final cs = Theme.of(context).colorScheme;
    if (r.cookies.isEmpty) return const EmptyHint(Icons.cookie_outlined, 'No cookies received from the server');
    final hs = TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.onSurfaceVariant);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(10),
      child: Table(
        border: TableBorder.all(color: cs.outlineVariant),
        defaultColumnWidth: const IntrinsicColumnWidth(),
        children: [
          TableRow(children: [for (final h in ['Name', 'Value', 'Domain', 'Path', 'Expires', 'HttpOnly', 'Secure']) Padding(padding: const EdgeInsets.all(6), child: Text(h, style: hs))]),
          for (final c in r.cookies)
            TableRow(children: [
              for (final v in [c.name, c.value, c.domain, c.path, c.expires?.toIso8601String() ?? 'Session', '${c.httpOnly}', '${c.secure}'])
                Padding(padding: const EdgeInsets.all(6), child: SelectableText(v, style: const TextStyle(fontSize: 12))),
            ]),
        ],
      ),
    );
  }

  Widget _tests(ResponseData r) {
    final cs = Theme.of(context).colorScheme;
    if (r.tests.isEmpty) return const EmptyHint(Icons.fact_check_outlined, 'No tests for this request.\nAdd assertions in the Tests tab.');
    return ListView(
      padding: const EdgeInsets.all(10),
      children: [
        for (final t in r.tests)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: (t.passed ? statusColor(200) : statusColor(500)).withValues(alpha: 0.18), borderRadius: BorderRadius.circular(3)),
                child: Text(t.passed ? 'PASS' : 'FAIL', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: t.passed ? statusColor(200) : statusColor(500))),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(t.name, style: const TextStyle(fontSize: 13)),
                  if (t.message.isNotEmpty) Text(t.message, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                ]),
              ),
            ]),
          ),
      ],
    );
  }

  Widget _request(ResponseData r) {
    final cs = Theme.of(context).colorScheme;
    return ListView(padding: const EdgeInsets.all(10), children: [
      SelectableText('${r.method} ${r.finalUrl}', style: mono(context, size: 13)),
      const SizedBox(height: 10),
      Text('Request Headers', style: TextStyle(fontWeight: FontWeight.w600, color: cs.onSurfaceVariant, fontSize: 12)),
      const SizedBox(height: 4),
      for (final h in r.requestHeaders) SelectableText('${h.key}: ${h.value}', style: mono(context, size: 12)),
      if (r.requestBodyPreview.isNotEmpty) ...[
        const SizedBox(height: 10),
        Text('Request Body', style: TextStyle(fontWeight: FontWeight.w600, color: cs.onSurfaceVariant, fontSize: 12)),
        const SizedBox(height: 4),
        SelectableText(r.requestBodyPreview, style: mono(context, size: 12)),
      ],
    ]);
  }
}
