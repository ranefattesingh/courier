import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/importers.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import 'dialogs/dialogs.dart';
import 'dialogs/runner.dart';
import 'editors/actions.dart';
import 'editors/request_editor.dart';
import 'sidebar.dart';
import 'theme.dart';
import 'widgets/common.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  double _sidebarWidth = 330;
  bool _sidebarVisible = true;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  /// App-wide shortcuts. Handled globally so they keep working regardless of which
  /// widget has focus (and after dialogs close); ignored while a dialog is open.
  bool _onKey(KeyEvent e) {
    if (e is! KeyDownEvent || !mounted) return false;
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    final kb = HardwareKeyboard.instance;
    final state = context.read<AppState>();
    final mod = Platform.isMacOS ? kb.isMetaPressed : kb.isControlPressed;
    final k = e.logicalKey;
    if (kb.isControlPressed && k == LogicalKeyboardKey.tab) {
      if (state.tabs.isNotEmpty) state.selectTab((state.activeTab + (kb.isShiftPressed ? state.tabs.length - 1 : 1)) % state.tabs.length);
      return true;
    }
    if (!mod) return false;
    final t = state.currentTab;
    if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) {
      if (t != null) runPrimaryAction(state, t);
    } else if (k == LogicalKeyboardKey.keyS) {
      if (t != null) saveTabInteractive(context, state, t);
    } else if (k == LogicalKeyboardKey.keyT) {
      state.newTab(RequestType.http);
    } else if (k == LogicalKeyboardKey.keyW) {
      if (t != null) _closeTab(context, state, t);
    } else if (k == LogicalKeyboardKey.keyO) {
      showImportDialog(context, state);
    } else {
      return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final cs = Theme.of(context).colorScheme;
    return SizedBox.expand(
      child: SizedBox.expand(
        child: Focus(
          autofocus: true,
          child: Scaffold(
            body: Column(children: [
              _TopBar(onToggleSidebar: () => setState(() => _sidebarVisible = !_sidebarVisible)),
              Divider(color: cs.outlineVariant),
              Expanded(
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  if (_sidebarVisible) ...[
                    SizedBox(width: _sidebarWidth, child: const Sidebar()),
                    MouseRegion(
                      cursor: SystemMouseCursors.resizeColumn,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onPanUpdate: (d) => setState(() => _sidebarWidth = (_sidebarWidth + d.delta.dx).clamp(220, 600)),
                        child: Container(width: 5, alignment: Alignment.center, child: Container(width: 1, color: cs.outlineVariant)),
                      ),
                    ),
                  ],
                  Expanded(child: _EditorArea(onClose: (t) => _closeTab(context, state, t))),
                ]),
              ),
              _StatusBar(),
            ]),
          ),
        ),
      ),
    );
  }

  Future<void> _closeTab(BuildContext context, AppState state, RequestTab t) async {
    if (t.dirty) {
      final r = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Unsaved changes', style: TextStyle(fontSize: 16)),
          content: Text('Do you want to save changes to "${t.draft.name}" before closing?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, 'cancel'), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(ctx, 'discard'), child: const Text("Don't save")),
            FilledButton(onPressed: () => Navigator.pop(ctx, 'save'), child: const Text('Save')),
          ],
        ),
      );
      if (r == null || r == 'cancel') return;
      if (r == 'save') {
        if (!context.mounted) return;
        await saveTabInteractive(context, state, t);
        if (t.dirty) return;
      }
    }
    await state.closeTab(t);
  }
}

class _TopBar extends StatelessWidget {
  final VoidCallback onToggleSidebar;
  const _TopBar({required this.onToggleSidebar});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: 46,
      color: cs.surfaceContainerLowest,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(children: [
        IconButton(tooltip: 'Toggle sidebar', iconSize: 18, icon: const Icon(Icons.view_sidebar_outlined), onPressed: onToggleSidebar),
        const SizedBox(width: 4),
        Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(6)),
          child: const Icon(Icons.send_rounded, size: 14, color: Colors.white),
        ),
        const SizedBox(width: 8),
        const Text('Courier', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
        const SizedBox(width: 18),
        PopupMenuButton<String>(
          tooltip: 'Create new',
          offset: const Offset(0, 40),
          itemBuilder: (_) => [
            for (final t in RequestType.values)
              PopupMenuItem(
                value: 'req:${t.name}',
                height: 34,
                child: Row(children: [Icon(typeIcon(t), size: 16, color: typeColor(t)), const SizedBox(width: 10), Flexible(child: Text(t.label, overflow: TextOverflow.ellipsis))]),
              ),
            const PopupMenuDivider(),
            const PopupMenuItem(value: 'collection', height: 34, child: Row(children: [Icon(Icons.inventory_2_outlined, size: 16), SizedBox(width: 10), Text('Collection')])),
            const PopupMenuItem(value: 'environment', height: 34, child: Row(children: [Icon(Icons.layers_outlined, size: 16), SizedBox(width: 10), Text('Environment')])),
          ],
          onSelected: (v) async {
            if (v.startsWith('req:')) {
              state.newTab(RequestType.parse(v.substring(4)));
            } else if (v == 'collection') {
              final n = await promptText(context, 'New collection', okLabel: 'Create');
              if (n != null) state.addCollection(n);
            } else {
              final n = await promptText(context, 'New environment', okLabel: 'Create');
              if (n != null && context.mounted) showEnvironmentEditor(context, state, env: state.addEnvironment(n));
            }
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(color: cs.primary, borderRadius: BorderRadius.circular(4)),
            child: const Row(children: [Icon(Icons.add, size: 16, color: Colors.white), SizedBox(width: 4), Text('New', style: TextStyle(color: Colors.white, fontSize: 13))]),
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton(onPressed: () => showImportDialog(context, state), child: const Text('Import')),
        const SizedBox(width: 8),
        OutlinedButton.icon(onPressed: () => showRunner(context, state), icon: const Icon(Icons.play_arrow, size: 16), label: const Text('Runner')),
        const Spacer(),
        CompactDropdown<String>(
          width: 220,
          value: state.activeEnvId ?? '',
          items: {'': 'No Environment', for (final e in state.environments) e.id: e.name},
          onChanged: (v) => state.setActiveEnv(v.isEmpty ? null : v),
        ),
        IconButton(tooltip: 'Environment quick look', iconSize: 18, icon: const Icon(Icons.remove_red_eye_outlined), onPressed: () => showVariablesQuickLook(context, state)),
        const SizedBox(width: 6),
        IconButton(tooltip: 'Cookies', iconSize: 18, icon: const Icon(Icons.cookie_outlined), onPressed: () => showCookiesDialog(context, state)),
        IconButton(tooltip: 'Console', iconSize: 18, icon: const Icon(Icons.terminal), onPressed: () => showConsoleDialog(context, state)),
        PopupMenuButton<String>(
          tooltip: 'Workspace',
          icon: const Icon(Icons.more_vert, size: 18),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'export', height: 32, child: Text('Export workspace (all collections & environments)')),
            PopupMenuItem(value: 'paste', height: 32, child: Text('Import cURL from clipboard')),
            PopupMenuItem(value: 'shortcuts', height: 32, child: Text('Keyboard shortcuts')),
          ],
          onSelected: (v) async {
            switch (v) {
              case 'export':
                await exportWorkspace(context, state);
              case 'paste':
                final d = await Clipboard.getData('text/plain');
                try {
                  final r = parseCurl(d?.text ?? '');
                  state.newTab(r.type, from: r);
                } catch (e) {
                  if (context.mounted) toast(context, 'Clipboard does not contain a cURL command', error: true);
                }
              case 'shortcuts':
                if (!context.mounted) return;
                final m = Platform.isMacOS ? '⌘' : 'Ctrl';
                await showDialog(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Keyboard shortcuts', style: TextStyle(fontSize: 16)),
                    content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      for (final (k, d) in [
                        ('$m + Enter', 'Send / Connect / Invoke'),
                        ('$m + S', 'Save request'),
                        ('$m + T', 'New tab'),
                        ('$m + W', 'Close tab'),
                        ('$m + O', 'Import'),
                        ('Ctrl + Tab', 'Next tab'),
                      ])
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(children: [SizedBox(width: 130, child: Text(k, style: const TextStyle(fontWeight: FontWeight.w600))), Text(d)]),
                        ),
                    ]),
                  ),
                );
            }
          },
        ),
        IconButton(tooltip: 'Settings', iconSize: 18, icon: const Icon(Icons.settings_outlined), onPressed: () => showSettingsDialog(context, state)),
      ]),
    );
  }
}

class _EditorArea extends StatelessWidget {
  final void Function(RequestTab) onClose;
  const _EditorArea({required this.onClose});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final cs = Theme.of(context).colorScheme;
    final tab = state.currentTab;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        height: 38,
        color: cs.surfaceContainerLowest,
        child: Row(children: [
          Expanded(
            child: ReorderableListView.builder(
              scrollDirection: Axis.horizontal,
              buildDefaultDragHandles: false,
              itemCount: state.tabs.length,
              onReorder: (a, b) {
                if (b > a) b--;
                final current = state.currentTab;
                final t = state.tabs.removeAt(a);
                state.tabs.insert(b, t);
                state.activeTab = current == null ? -1 : state.tabs.indexOf(current);
                state.changed();
              },
              itemBuilder: (_, i) {
                final t = state.tabs[i];
                return ReorderableDragStartListener(
                  key: ObjectKey(t),
                  index: i,
                  child: _TabChip(tab: t, selected: i == state.activeTab, onTap: () => state.selectTab(i), onClose: () => onClose(t)),
                );
              },
            ),
          ),
          IconButton(tooltip: 'New tab', iconSize: 18, icon: const Icon(Icons.add), onPressed: () => state.newTab(RequestType.http)),
          PopupMenuButton<String>(
            tooltip: 'Tab actions',
            icon: const Icon(Icons.keyboard_arrow_down, size: 18),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'others', height: 32, child: Text('Close other tabs')),
              PopupMenuItem(value: 'all', height: 32, child: Text('Close all tabs')),
              PopupMenuItem(value: 'dup', height: 32, child: Text('Duplicate current tab')),
              PopupMenuItem(value: 'revert', height: 32, child: Text('Revert unsaved changes')),
            ],
            onSelected: (v) async {
              final t = state.currentTab;
              switch (v) {
                case 'others':
                  if (t != null) await state.closeOtherTabs(t);
                case 'all':
                  for (final x in List.of(state.tabs)) {
                    await state.closeTab(x);
                  }
                case 'dup':
                  if (t != null) state.newTab(t.draft.type, from: t.draft.clone(newIdentity: true)..name = '${t.draft.name} Copy');
                case 'revert':
                  if (t != null) state.revertTab(t);
              }
            },
          ),
        ]),
      ),
      Divider(color: cs.outlineVariant),
      Expanded(
        child: tab == null
            ? EmptyHint(
                Icons.send_outlined,
                'Open a request from the sidebar or create a new one',
                action: Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
                  for (final t in RequestType.values)
                    OutlinedButton.icon(
                      onPressed: () => state.newTab(t),
                      icon: Icon(typeIcon(t), size: 16, color: typeColor(t)),
                      label: Text(t.label),
                    ),
                ]),
              )
            : RequestEditor(key: ObjectKey(tab), tab: tab),
      ),
    ]);
  }
}

class _TabChip extends StatefulWidget {
  final RequestTab tab;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onClose;
  const _TabChip({required this.tab, required this.selected, required this.onTap, required this.onClose});

  @override
  State<_TabChip> createState() => _TabChipState();
}

class _TabChipState extends State<_TabChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: widget.tab,
      builder: (context, _) {
        final t = widget.tab;
        final live = isActive(t);
        return MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            onTap: widget.onTap,
            onTertiaryTapUp: (_) => widget.onClose(),
            child: Container(
              width: 200,
              padding: const EdgeInsets.only(left: 10, right: 4),
              decoration: BoxDecoration(
                color: widget.selected ? cs.surface : (_hover ? cs.surfaceContainer : null),
                border: Border(
                  top: BorderSide(color: widget.selected ? cs.primary : Colors.transparent, width: 2),
                  right: BorderSide(color: cs.outlineVariant),
                ),
              ),
              child: Row(children: [
                MethodBadge(t.draft, size: 9.5),
                const SizedBox(width: 6),
                if (live)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Container(width: 6, height: 6, decoration: const BoxDecoration(color: Color(0xFF4CC38A), shape: BoxShape.circle)),
                  ),
                Expanded(
                  child: Text(t.draft.name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, color: widget.selected ? cs.onSurface : cs.onSurfaceVariant, fontStyle: t.sourceId == null ? FontStyle.italic : null)),
                ),
                SizedBox(
                  width: 24,
                  child: t.dirty && !_hover
                      ? Center(child: Container(width: 7, height: 7, decoration: BoxDecoration(color: cs.primary, shape: BoxShape.circle)))
                      : (_hover || widget.selected)
                          ? InkWell(onTap: widget.onClose, child: Icon(Icons.close, size: 14, color: cs.onSurfaceVariant))
                          : null,
                ),
              ]),
            ),
          ),
        );
      },
    );
  }
}

class _StatusBar extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final cs = Theme.of(context).colorScheme;
    final live = state.tabs.where(isActive).length;
    return Container(
      height: 24,
      color: cs.surfaceContainerLowest,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(children: [
        Icon(Icons.circle, size: 8, color: live > 0 ? const Color(0xFF4CC38A) : cs.onSurfaceVariant),
        const SizedBox(width: 6),
        Text(live > 0 ? '$live active connection${live == 1 ? '' : 's'}' : 'Ready', style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
        const Spacer(),
        Text('${state.collections.length} collections · ${state.environments.length} environments · ${state.history.length} history',
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
        const SizedBox(width: 12),
        InkWell(
          onTap: () => state.updateSettings((s) => s.darkMode = !s.darkMode),
          child: Icon(state.settings.darkMode ? Icons.dark_mode_outlined : Icons.light_mode_outlined, size: 14, color: cs.onSurfaceVariant),
        ),
      ]),
    );
  }
}
