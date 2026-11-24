import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../../models/models.dart';
import '../theme.dart';
import 'common.dart';

/// Scrollable log of streamed messages (WebSocket, MQTT, Kafka, SSE, gRPC streams…).
class MessageLog extends StatefulWidget {
  final List<LogMessage> messages;
  final VoidCallback onClear;
  final String emptyText;
  const MessageLog({super.key, required this.messages, required this.onClear, this.emptyText = 'No messages yet'});

  @override
  State<MessageLog> createState() => _MessageLogState();
}

class _MessageLogState extends State<MessageLog> {
  String _filter = '';
  String _dir = 'all';
  final _scroll = ScrollController();
  final Set<LogMessage> _expanded = {};
  bool _follow = true;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final items = widget.messages.where((m) {
      if (_dir == 'sent' && m.dir != MsgDir.sent) return false;
      if (_dir == 'received' && m.dir != MsgDir.received) return false;
      if (_filter.isNotEmpty && !m.text.toLowerCase().contains(_filter.toLowerCase()) && !m.label.toLowerCase().contains(_filter.toLowerCase())) {
        return false;
      }
      return true;
    }).toList();
    if (_follow) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
          child: Row(
            children: [
              Text(
                'Messages',
                style: TextStyle(fontWeight: FontWeight.w600, color: cs.onSurface),
              ),
              const SizedBox(width: 8),
              Text(
                '${widget.messages.where((m) => m.dir == MsgDir.sent || m.dir == MsgDir.received).length}',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
              const Spacer(),
              CompactDropdown<String>(
                value: _dir,
                items: const {'all': 'All messages', 'sent': 'Sent', 'received': 'Received'},
                onChanged: (v) => setState(() => _dir = v),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 200),
                  child: TextField(
                    style: const TextStyle(fontSize: 12),
                    decoration: const InputDecoration(
                      hintText: 'Search',
                      prefixIcon: Icon(Icons.search, size: 16),
                      prefixIconConstraints: BoxConstraints(minWidth: 28),
                    ),
                    onChanged: (v) => setState(() => _filter = v),
                  ),
                ),
              ),
              IconButton(
                tooltip: _follow ? 'Auto-scroll on' : 'Auto-scroll off',
                iconSize: 17,
                icon: Icon(_follow ? Icons.vertical_align_bottom : Icons.pause, color: _follow ? cs.primary : cs.onSurfaceVariant),
                onPressed: () => setState(() => _follow = !_follow),
              ),
              IconButton(tooltip: 'Clear messages', iconSize: 17, icon: const Icon(Icons.delete_sweep_outlined), onPressed: widget.onClear),
            ],
          ),
        ),
        Divider(color: cs.outlineVariant),
        Expanded(
          child: items.isEmpty
              ? EmptyHint(Icons.forum_outlined, widget.emptyText)
              : ListView.builder(controller: _scroll, itemCount: items.length, itemBuilder: (_, i) => _tile(items[i], cs)),
        ),
      ],
    );
  }

  Widget _tile(LogMessage m, ColorScheme cs) {
    final (icon, color) = switch (m.dir) {
      MsgDir.sent => (Icons.arrow_upward, const Color(0xFFE6B44C)),
      MsgDir.received => (Icons.arrow_downward, const Color(0xFF4CC38A)),
      MsgDir.info => (Icons.info_outline, cs.onSurfaceVariant),
      MsgDir.error => (Icons.error_outline, cs.error),
    };
    final expanded = _expanded.contains(m);
    final multi = m.text.contains('\n') || m.text.length > 160;
    final preview = multi && !expanded ? m.text.replaceAll(RegExp(r'\s+'), ' ') : m.text;
    return InkWell(
      onTap: multi ? () => setState(() => expanded ? _expanded.remove(m) : _expanded.add(m)) : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.6))),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(icon, size: 14, color: color),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (m.label.isNotEmpty)
                    Text(
                      m.label,
                      style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant, fontWeight: FontWeight.w500),
                    ),
                  expanded
                      ? SelectableText(
                          m.text,
                          style: mono(context, size: 12, color: m.dir == MsgDir.info ? cs.onSurfaceVariant : (m.dir == MsgDir.error ? cs.error : null)),
                        )
                      : Text(
                          preview,
                          maxLines: multi ? 2 : null,
                          overflow: multi ? TextOverflow.ellipsis : null,
                          style: mono(context, size: 12, color: m.dir == MsgDir.info ? cs.onSurfaceVariant : (m.dir == MsgDir.error ? cs.error : null)),
                        ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(formatTime(m.time), style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
            IconButton(
              visualDensity: VisualDensity.compact,
              iconSize: 14,
              tooltip: 'Copy',
              icon: Icon(Icons.copy, color: cs.onSurfaceVariant),
              onPressed: () => Clipboard.setData(ClipboardData(text: m.text)),
            ),
          ],
        ),
      ),
    );
  }
}
