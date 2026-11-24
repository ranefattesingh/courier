import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import 'dialogs/dialogs.dart';
import 'dialogs/runner.dart';
import 'theme.dart';
import 'widgets/common.dart';
import 'widgets/motion.dart';

class Sidebar extends StatelessWidget {
  const Sidebar({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final cs = Theme.of(context).colorScheme;
    Widget railItem(String id, IconData icon, String label) {
      final sel = state.sidebarSection == id;
      return InkWell(
        onTap: () {
          state.sidebarSection = id;
          state.changed(save: false);
        },
        child: Container(
          width: 72,
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: sel ? cs.surfaceContainerHigh : null,
            border: Border(left: BorderSide(color: sel ? cs.primary : Colors.transparent, width: 2)),
          ),
          child: Column(children: [
            Icon(icon, size: 20, color: sel ? cs.onSurface : cs.onSurfaceVariant),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(fontSize: 10.5, color: sel ? cs.onSurface : cs.onSurfaceVariant)),
          ]),
        ),
      );
    }

    return Material(
      color: cs.surfaceContainerLow,
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          decoration: BoxDecoration(border: Border(right: BorderSide(color: cs.outlineVariant))),
          child: Column(children: [
            railItem('collections', Icons.inventory_2_outlined, 'Collections'),
            railItem('environments', Icons.layers_outlined, 'Environments'),
            railItem('history', Icons.history, 'History'),
          ]),
        ),
        Expanded(
          child: FadeIn(
            key: ValueKey('section-${state.sidebarSection}'),
            child: switch (state.sidebarSection) {
              'environments' => const _EnvironmentsPanel(),
              'history' => const _HistoryPanel(),
              _ => const _CollectionsPanel(),
            },
          ),
        ),
      ]),
    );
  }
}

// ============================================================================ Collections

class _CollectionsPanel extends StatefulWidget {
  const _CollectionsPanel();

  @override
  State<_CollectionsPanel> createState() => _CollectionsPanelState();
}

class _CollectionsPanelState extends State<_CollectionsPanel> {
  String _filter = '';

  bool _matches(Node n) {
    if (_filter.isEmpty) return true;
    final f = _filter.toLowerCase();
    if (n.name.toLowerCase().contains(f)) return true;
    if (n is ApiRequest) return n.url.toLowerCase().contains(f);
    if (n is Folder) return n.children.any(_matches);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final cs = Theme.of(context).colorScheme;
    final filtering = _filter.isNotEmpty;
    // Each folder's children live in an ExpandSection so opening/closing animates smoothly.
    Widget? node(Node n, int depth) {
      if (!_matches(n)) return null;
      final row = _TreeRow(key: ValueKey('row-${n.id}'), node: n, depth: depth, filtering: filtering);
      if (n is! Folder) return row;
      return Column(key: ValueKey('node-${n.id}'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        row,
        ExpandSection(
          expanded: n.expanded || filtering,
          builder: () => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [for (final c in n.children) ?node(c, depth + 1)],
          ),
        ),
      ]);
    }

    final rows = [for (final c in state.collections) ?node(c, 0)];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 4, 4),
        child: Row(children: [
          IconButton(
            tooltip: 'New collection',
            iconSize: 18,
            icon: const Icon(Icons.add),
            onPressed: () async {
              final n = await promptText(context, 'New collection', hint: 'e.g. Payments Service', okLabel: 'Create');
              if (n != null) state.addCollection(n);
            },
          ),
          Expanded(
            child: TextField(
              style: const TextStyle(fontSize: 12.5),
              decoration: const InputDecoration(hintText: 'Search collections', prefixIcon: Icon(Icons.search, size: 16), prefixIconConstraints: BoxConstraints(minWidth: 30)),
              onChanged: (v) => setState(() => _filter = v),
            ),
          ),
          IconButton(tooltip: 'Import', iconSize: 18, icon: const Icon(Icons.file_download_outlined), onPressed: () => showImportDialog(context, state)),
          IconButton(tooltip: 'Export', iconSize: 18, icon: const Icon(Icons.file_upload_outlined), onPressed: () => showExportDialog(context, state)),
        ]),
      ),
      Expanded(
        child: state.collections.isEmpty
            ? EmptyHint(
                Icons.inventory_2_outlined,
                'Create a collection for your project or microservice to group requests into folders',
                action: FilledButton(
                  onPressed: () async {
                    final n = await promptText(context, 'New collection', okLabel: 'Create');
                    if (n != null) state.addCollection(n);
                  },
                  child: const Text('Create Collection'),
                ),
              )
            : DragTarget<String>(
                onWillAcceptWithDetails: (_) => false,
                builder: (_, __, ___) => ListView(padding: const EdgeInsets.only(bottom: 30), children: rows),
              ),
      ),
      Divider(color: cs.outlineVariant),
    ]);
  }
}

class _TreeRow extends StatefulWidget {
  final Node node;
  final int depth;
  final bool filtering;
  const _TreeRow({super.key, required this.node, required this.depth, required this.filtering});

  @override
  State<_TreeRow> createState() => _TreeRowState();
}

class _TreeRowState extends State<_TreeRow> {
  bool _hover = false;

  /// Opens the row's action menu at [pos] (global coordinates). Actions always run with the
  /// row's own context: the ⋯ button that may have opened the menu only exists while the row
  /// is hovered, and the menu covering the row ends the hover, so its context is gone by the
  /// time an item is picked.
  Future<void> _menu(Offset pos) async {
    final state = context.read<AppState>();
    final n = widget.node;
    final isFolder = n is Folder;
    final isCollection = widget.depth == 0;
    final items = <PopupMenuEntry<String>>[
      if (isFolder) ...[
        for (final t in RequestType.values)
          PopupMenuItem(
            value: 'add:${t.name}',
            height: 30,
            child: Row(children: [Icon(typeIcon(t), size: 15, color: typeColor(t)), const SizedBox(width: 10), Flexible(child: Text('Add ${t.label} request', overflow: TextOverflow.ellipsis))]),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'folder', height: 30, child: Text('Add folder')),
        const PopupMenuItem(value: 'run', height: 30, child: Text('Run')),
        PopupMenuItem(value: 'edit', height: 30, child: Text(isCollection ? 'Edit collection (auth, variables)' : 'Edit folder (auth)')),
      ] else
        const PopupMenuItem(value: 'open', height: 30, child: Text('Open')),
      const PopupMenuItem(value: 'rename', height: 30, child: Text('Rename')),
      const PopupMenuItem(value: 'duplicate', height: 30, child: Text('Duplicate')),
      if (isFolder) ...[
        if (isCollection) const PopupMenuItem(value: 'exportdlg', height: 30, child: Text('Export…')),
        if (!isCollection) const PopupMenuItem(value: 'export', height: 30, child: Text('Export folder (Courier JSON)')),
        if (!isCollection) const PopupMenuItem(value: 'exportpm', height: 30, child: Text('Export folder (Postman v2.1)')),
      ],
      const PopupMenuDivider(),
      PopupMenuItem(value: 'delete', height: 30, child: Text('Delete', style: TextStyle(color: Theme.of(context).colorScheme.error))),
    ];
    final v = await showMenu<String>(context: context, position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx + 1, pos.dy + 1), items: items);
    if (v == null || !context.mounted) return;
    if (v.startsWith('add:')) {
      state.addRequest(n as Folder, RequestType.parse(v.substring(4)));
      return;
    }
    switch (v) {
      case 'folder':
        final name = await promptText(context, 'New folder', hint: 'Folder name', okLabel: 'Create');
        if (name != null) state.addFolder(n as Folder, name);
      case 'run':
        await showRunner(context, state, initial: n as Folder);
      case 'edit':
        await showFolderSettings(context, state, n as Folder, isCollection: isCollection);
      case 'open':
        state.openRequest(n as ApiRequest);
      case 'rename':
        final name = await promptText(context, 'Rename', initial: n.name);
        if (name != null) state.renameNode(n.id, name);
      case 'duplicate':
        state.duplicateNode(n.id);
      case 'exportdlg':
        await showExportDialog(context, state, initial: n as Folder);
      case 'export':
        await exportCollection(context, n as Folder, postman: false);
      case 'exportpm':
        await exportCollection(context, n as Folder, postman: true);
      case 'delete':
        if (await confirm(context, 'Delete "${n.name}"?', isFolder ? 'This deletes the folder and everything inside it.' : 'This request will be deleted permanently.')) {
          state.deleteNode(n.id);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final cs = Theme.of(context).colorScheme;
    final n = widget.node;
    final selected = state.selectedNodeId == n.id;
    final indent = 8.0 + widget.depth * 14;

    final content = AnimatedContainer(
      duration: Motion.of(context, Motion.fast),
      curve: Curves.easeOut,
      height: 30,
      padding: EdgeInsets.only(left: indent, right: 2),
      color: selected ? cs.primary.withValues(alpha: 0.12) : (_hover ? cs.surfaceContainerHigh : cs.surfaceContainerHigh.withValues(alpha: 0)),
      child: Row(children: [
        if (n is Folder)
          AnimatedRotation(
            turns: n.expanded || widget.filtering ? 0.25 : 0,
            duration: Motion.of(context),
            curve: Motion.curve,
            child: Icon(Icons.keyboard_arrow_right, size: 16, color: cs.onSurfaceVariant),
          )
        else
          const SizedBox(width: 2),
        if (n is Folder) ...[
          Icon(widget.depth == 0 ? Icons.inventory_2_outlined : (n.expanded ? Icons.folder_open_outlined : Icons.folder_outlined), size: 15, color: cs.onSurfaceVariant),
          const SizedBox(width: 6),
        ] else ...[
          MethodBadge(n as ApiRequest, size: 9.5),
          const SizedBox(width: 6),
        ],
        Expanded(
          child: Text(n.name,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, fontWeight: widget.depth == 0 ? FontWeight.w500 : FontWeight.normal, color: cs.onSurface)),
        ),
        if (_hover)
          Builder(
            builder: (bctx) => InkWell(
              onTap: () {
                // Open the menu just below the ⋯ button.
                final box = bctx.findRenderObject()! as RenderBox;
                _menu(box.localToGlobal(Offset(0, box.size.height)));
              },
              child: Padding(padding: const EdgeInsets.all(4), child: Icon(Icons.more_horiz, size: 16, color: cs.onSurfaceVariant)),
            ),
          ),
      ]),
    );

    final interactive = MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (n is Folder) {
            n.expanded = !n.expanded;
            state.selectedNodeId = n.id;
            state.changed();
          } else {
            state.openRequest(n as ApiRequest);
          }
        },
        // No double-tap handler here: it would delay every single click by ~300 ms while
        // Flutter waits to rule out a double click. Rename is in the context menu.
        onSecondaryTapDown: (d) => _menu(d.globalPosition),
        child: content,
      ),
    );

    final draggable = Draggable<String>(
      data: n.id,
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(4)),
          child: Text(n.name, style: TextStyle(fontSize: 13, color: cs.onSurface)),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: content),
      child: interactive,
    );

    return DragTarget<String>(
      onWillAcceptWithDetails: (d) => d.data != n.id,
      onAcceptWithDetails: (d) {
        if (n is Folder) {
          if (widget.depth == 0 && state.findNode(d.data) is Folder && state.collections.any((c) => c.id == d.data)) {
            state.reorderCollection(d.data, state.collections.indexOf(n));
          } else {
            state.moveNode(d.data, n.id);
          }
        } else {
          final parent = state.parentOf(n.id);
          if (parent != null) {
            final dragged = state.findNode(d.data);
            final oldParent = state.parentOf(d.data);
            var idx = parent.children.indexOf(n);
            if (oldParent == parent && dragged != null && parent.children.indexOf(dragged) < idx) idx--;
            state.moveNode(d.data, parent.id, index: idx);
          }
        }
      },
      builder: (context, candidates, _) => Container(
        decoration: candidates.isNotEmpty
            ? BoxDecoration(border: n is Folder ? Border.all(color: cs.primary) : Border(top: BorderSide(color: cs.primary, width: 2)))
            : null,
        child: widget.depth == 0 ? interactive : draggable,
      ),
    );
  }
}

// ============================================================================ Environments

class _EnvironmentsPanel extends StatelessWidget {
  const _EnvironmentsPanel();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final cs = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 6),
        child: Row(children: [
          const Text('Environments', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          const Spacer(),
          IconButton(
            tooltip: 'New environment',
            iconSize: 18,
            icon: const Icon(Icons.add),
            onPressed: () async {
              final n = await promptText(context, 'New environment', hint: 'e.g. Staging', okLabel: 'Create');
              if (n != null && context.mounted) showEnvironmentEditor(context, state, env: state.addEnvironment(n));
            },
          ),
        ]),
      ),
      ListTile(
        dense: true,
        leading: const Icon(Icons.public, size: 18),
        title: const Text('Globals'),
        subtitle: Text('${state.globals.where((v) => v.key.isNotEmpty).length} variables', style: const TextStyle(fontSize: 11)),
        onTap: () => showEnvironmentEditor(context, state, globals: true),
      ),
      Divider(color: cs.outlineVariant),
      Expanded(
        child: state.environments.isEmpty
            ? const EmptyHint(Icons.layers_outlined, 'Create environments (Dev, Staging, Prod…) to switch variable sets quickly')
            : ListView(children: [
                for (final e in state.environments)
                  ListTile(
                    dense: true,
                    selected: e.id == state.activeEnvId,
                    leading: IconButton(
                      tooltip: e.id == state.activeEnvId ? 'Active environment' : 'Set active',
                      iconSize: 18,
                      icon: Icon(e.id == state.activeEnvId ? Icons.check_circle : Icons.radio_button_unchecked,
                          color: e.id == state.activeEnvId ? const Color(0xFF4CC38A) : cs.onSurfaceVariant),
                      onPressed: () => state.setActiveEnv(e.id == state.activeEnvId ? null : e.id),
                    ),
                    title: Text(e.name),
                    subtitle: Text('${e.variables.where((v) => v.key.isNotEmpty).length} variables', style: const TextStyle(fontSize: 11)),
                    onTap: () => showEnvironmentEditor(context, state, env: e),
                    trailing: PopupMenuButton<String>(
                      icon: const Icon(Icons.more_horiz, size: 16),
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'edit', height: 30, child: Text('Edit')),
                        PopupMenuItem(value: 'rename', height: 30, child: Text('Rename')),
                        PopupMenuItem(value: 'dup', height: 30, child: Text('Duplicate')),
                        PopupMenuItem(value: 'export', height: 30, child: Text('Export (Postman)')),
                        PopupMenuItem(value: 'delete', height: 30, child: Text('Delete')),
                      ],
                      onSelected: (v) async {
                        switch (v) {
                          case 'edit':
                            showEnvironmentEditor(context, state, env: e);
                          case 'rename':
                            final n = await promptText(context, 'Rename environment', initial: e.name);
                            if (n != null) {
                              e.name = n;
                              state.changed();
                            }
                          case 'dup':
                            state.environments.add(Environment(id: newId(), name: '${e.name} Copy', variables: e.variables.map((v) => v.copy()).toList()));
                            state.changed();
                          case 'export':
                            if (context.mounted) await exportEnvironment(context, e, postman: true);
                          case 'delete':
                            if (context.mounted && await confirm(context, 'Delete "${e.name}"?', 'All variables in this environment will be lost.')) {
                              state.deleteEnvironment(e.id);
                            }
                        }
                      },
                    ),
                  ),
              ]),
      ),
    ]);
  }
}

// ============================================================================ History

class _HistoryPanel extends StatefulWidget {
  const _HistoryPanel();

  @override
  State<_HistoryPanel> createState() => _HistoryPanelState();
}

class _HistoryPanelState extends State<_HistoryPanel> {
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final cs = Theme.of(context).colorScheme;
    final items = state.history.where((h) => _filter.isEmpty || h.request.url.toLowerCase().contains(_filter) || h.request.name.toLowerCase().contains(_filter)).toList();
    String day(DateTime t) {
      final now = DateTime.now();
      final d = DateTime(t.year, t.month, t.day);
      final today = DateTime(now.year, now.month, now.day);
      if (d == today) return 'Today';
      if (d == today.subtract(const Duration(days: 1))) return 'Yesterday';
      return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
    }

    final children = <Widget>[];
    String? lastDay;
    for (final h in items) {
      final d = day(h.time);
      if (d != lastDay) {
        children.add(Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: Text(d, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: cs.onSurfaceVariant)),
        ));
        lastDay = d;
      }
      children.add(InkWell(
        onTap: () => state.newTab(h.request.type, from: h.request.clone(newIdentity: true)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(children: [
            MethodBadge(h.request, size: 9.5),
            const SizedBox(width: 8),
            Expanded(
              child: Text(h.request.url.isEmpty ? h.request.name : h.request.url, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5)),
            ),
            if (h.status != null) Text('${h.status}', style: TextStyle(fontSize: 11, color: statusColor(h.status!))),
          ]),
        ),
      ));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 4, 4),
        child: Row(children: [
          Expanded(
            child: TextField(
              style: const TextStyle(fontSize: 12.5),
              decoration: const InputDecoration(hintText: 'Search history', prefixIcon: Icon(Icons.search, size: 16), prefixIconConstraints: BoxConstraints(minWidth: 30)),
              onChanged: (v) => setState(() => _filter = v.toLowerCase()),
            ),
          ),
          IconButton(
            tooltip: 'Clear history',
            iconSize: 18,
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: state.history.isEmpty
                ? null
                : () async {
                    if (await confirm(context, 'Clear history?', 'All history entries will be removed.', ok: 'Clear')) state.clearHistory();
                  },
          ),
        ]),
      ),
      Expanded(child: items.isEmpty ? const EmptyHint(Icons.history, 'Requests you send will appear here') : ListView(children: children)),
    ]);
  }
}
