import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:highlight/highlight.dart' show highlight, Node;
import 'package:highlight/languages/all.dart' show allLanguages;
import 'package:xml/xml.dart';

import '../../core/variables.dart';
import '../../models/models.dart' hide Node;
import '../theme.dart';

bool _languagesRegistered = false;
void _ensureLanguages() {
  if (_languagesRegistered) return;
  allLanguages.forEach(highlight.registerLanguage);
  _languagesRegistered = true;
}

// ============================================================================ text controllers

/// Highlights {{variables}}: green when defined, red when not.
class VarHighlightController extends TextEditingController {
  VariableScope Function()? scope;
  VarHighlightController({super.text, this.scope});

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final s = scope;
    if (s == null || !text.contains('{{')) return TextSpan(style: style, text: text);
    final sc = s();
    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in varPattern.allMatches(text)) {
      if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start)));
      final defined = sc.isDefined(m.group(1)!.trim());
      spans.add(TextSpan(
        text: m.group(0),
        style: TextStyle(
          color: defined ? const Color(0xFF4CC38A) : const Color(0xFFEF6F61),
          backgroundColor: (defined ? const Color(0xFF4CC38A) : const Color(0xFFEF6F61)).withValues(alpha: 0.12),
        ),
      ));
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return TextSpan(style: style, children: spans);
  }
}

Map<String, TextStyle> codeTheme(bool dark) => dark
    ? const {
        'keyword': TextStyle(color: Color(0xFFC586C0)),
        'built_in': TextStyle(color: Color(0xFF4EC9B0)),
        'type': TextStyle(color: Color(0xFF4EC9B0)),
        'literal': TextStyle(color: Color(0xFF569CD6)),
        'number': TextStyle(color: Color(0xFFB5CEA8)),
        'string': TextStyle(color: Color(0xFFCE9178)),
        'attr': TextStyle(color: Color(0xFF9CDCFE)),
        'attribute': TextStyle(color: Color(0xFF9CDCFE)),
        'name': TextStyle(color: Color(0xFF569CD6)),
        'tag': TextStyle(color: Color(0xFF808080)),
        'comment': TextStyle(color: Color(0xFF6A9955), fontStyle: FontStyle.italic),
        'meta': TextStyle(color: Color(0xFF808080)),
        'variable': TextStyle(color: Color(0xFF9CDCFE)),
        'title': TextStyle(color: Color(0xFFDCDCAA)),
        'params': TextStyle(color: Color(0xFF9CDCFE)),
        'symbol': TextStyle(color: Color(0xFFB5CEA8)),
      }
    : const {
        'keyword': TextStyle(color: Color(0xFFAF00DB)),
        'built_in': TextStyle(color: Color(0xFF267F99)),
        'type': TextStyle(color: Color(0xFF267F99)),
        'literal': TextStyle(color: Color(0xFF0000FF)),
        'number': TextStyle(color: Color(0xFF098658)),
        'string': TextStyle(color: Color(0xFFA31515)),
        'attr': TextStyle(color: Color(0xFF0451A5)),
        'attribute': TextStyle(color: Color(0xFFE50000)),
        'name': TextStyle(color: Color(0xFF800000)),
        'tag': TextStyle(color: Color(0xFF800000)),
        'comment': TextStyle(color: Color(0xFF008000), fontStyle: FontStyle.italic),
        'meta': TextStyle(color: Color(0xFF808080)),
        'variable': TextStyle(color: Color(0xFF001080)),
        'title': TextStyle(color: Color(0xFF795E26)),
        'params': TextStyle(color: Color(0xFF001080)),
        'symbol': TextStyle(color: Color(0xFF098658)),
      };

/// Syntax-highlighting controller backed by the `highlight` package.
class CodeController extends TextEditingController {
  String language;
  VariableScope Function()? scope;
  CodeController({super.text, this.language = 'json', this.scope});

  String? _cacheText;
  String? _cacheLang;
  bool? _cacheDark;
  List<InlineSpan>? _cacheSpans;

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    if (text.length > 150000 || language == 'text' || language.isEmpty) return TextSpan(style: style, text: text);
    if (_cacheText == text && _cacheLang == language && _cacheDark == dark && _cacheSpans != null) {
      return TextSpan(style: style, children: _cacheSpans);
    }
    _ensureLanguages();
    final theme = codeTheme(dark);
    List<InlineSpan> spans;
    try {
      final res = highlight.parse(text, language: _hlLang(language));
      spans = _convert(res.nodes ?? [], theme);
      if (scope != null && text.contains('{{')) spans = _overlayVars(spans);
    } catch (_) {
      spans = [TextSpan(text: text)];
    }
    _cacheText = text;
    _cacheLang = language;
    _cacheDark = dark;
    _cacheSpans = spans;
    return TextSpan(style: style, children: spans);
  }

  List<InlineSpan> _overlayVars(List<InlineSpan> spans) {
    final sc = scope!();
    final out = <InlineSpan>[];
    for (final s in spans) {
      if (s is! TextSpan || s.text == null || !s.text!.contains('{{')) {
        out.add(s);
        continue;
      }
      final t = s.text!;
      var last = 0;
      for (final m in varPattern.allMatches(t)) {
        if (m.start > last) out.add(TextSpan(text: t.substring(last, m.start), style: s.style));
        final ok = sc.isDefined(m.group(1)!.trim());
        out.add(TextSpan(text: m.group(0), style: (s.style ?? const TextStyle()).copyWith(color: ok ? const Color(0xFF4CC38A) : const Color(0xFFEF6F61))));
        last = m.end;
      }
      if (last < t.length) out.add(TextSpan(text: t.substring(last), style: s.style));
    }
    return out;
  }

  static String _hlLang(String l) {
    switch (l) {
      case 'html':
      case 'soap':
        return 'xml';
      case 'proto':
        return 'protobuf';
      default:
        return l;
    }
  }

  static List<InlineSpan> _convert(List<Node> nodes, Map<String, TextStyle> theme) {
    final spans = <InlineSpan>[];
    void walk(Node n, TextStyle? inherited) {
      final st = n.className != null ? (theme[n.className!] ?? inherited) : inherited;
      if (n.value != null) {
        spans.add(TextSpan(text: n.value, style: st));
      } else if (n.children != null) {
        for (final c in n.children!) {
          walk(c, st);
        }
      }
    }

    for (final n in nodes) {
      walk(n, null);
    }
    return spans;
  }
}

// ============================================================================ fields

/// A text field that keeps its own controller in sync with an externally owned value.
class SyncedTextField extends StatefulWidget {
  final String value;
  final ValueChanged<String> onChanged;
  final String? hint;
  final String? label;
  final bool multiline;
  final bool obscure;
  final TextStyle? style;
  final VariableScope Function()? scope;
  final ValueChanged<String>? onSubmitted;
  final bool dense;
  final bool borderless;
  final Widget? suffix;
  final FocusNode? focusNode;
  final bool readOnly;
  final int? minLines;

  const SyncedTextField({
    super.key,
    required this.value,
    required this.onChanged,
    this.hint,
    this.label,
    this.multiline = false,
    this.obscure = false,
    this.style,
    this.scope,
    this.onSubmitted,
    this.dense = true,
    this.borderless = false,
    this.suffix,
    this.focusNode,
    this.readOnly = false,
    this.minLines,
  });

  @override
  State<SyncedTextField> createState() => _SyncedTextFieldState();
}

class _SyncedTextFieldState extends State<SyncedTextField> {
  late final VarHighlightController _c = VarHighlightController(text: widget.value, scope: widget.scope);
  bool _hidden = true;

  @override
  void didUpdateWidget(covariant SyncedTextField old) {
    super.didUpdateWidget(old);
    _c.scope = widget.scope;
    if (widget.value != _c.text) {
      final sel = _c.selection;
      _c.text = widget.value;
      if (sel.isValid && sel.end <= widget.value.length) _c.selection = sel;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return TextField(
      controller: _c,
      focusNode: widget.focusNode,
      readOnly: widget.readOnly,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      obscureText: widget.obscure && _hidden,
      maxLines: widget.multiline ? null : 1,
      minLines: widget.multiline ? (widget.minLines ?? 3) : null,
      style: widget.style ?? TextStyle(fontSize: 13, color: cs.onSurface),
      decoration: InputDecoration(
        hintText: widget.hint,
        labelText: widget.label,
        border: widget.borderless ? InputBorder.none : null,
        enabledBorder: widget.borderless ? InputBorder.none : null,
        focusedBorder: widget.borderless ? InputBorder.none : null,
        contentPadding: widget.borderless ? const EdgeInsets.symmetric(horizontal: 8, vertical: 9) : null,
        suffixIcon: widget.obscure
            ? IconButton(
                icon: Icon(_hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 16),
                onPressed: () => setState(() => _hidden = !_hidden),
              )
            : widget.suffix,
        suffixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 28),
      ),
    );
  }
}

/// Multi-line code editor with syntax highlighting, tab support, and beautify.
class CodeEditor extends StatefulWidget {
  final String value;
  final ValueChanged<String>? onChanged;
  final String language;
  final bool readOnly;
  final VariableScope Function()? scope;
  final String? hint;
  final double? fontSize;

  const CodeEditor({
    super.key,
    required this.value,
    this.onChanged,
    this.language = 'json',
    this.readOnly = false,
    this.scope,
    this.hint,
    this.fontSize,
  });

  @override
  State<CodeEditor> createState() => _CodeEditorState();
}

class _CodeEditorState extends State<CodeEditor> {
  late final CodeController _c = CodeController(text: widget.value, language: widget.language, scope: widget.scope);
  final _focus = FocusNode();
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(covariant CodeEditor old) {
    super.didUpdateWidget(old);
    _c.language = widget.language;
    _c.scope = widget.scope;
    if (widget.value != _c.text) {
      final sel = _c.selection;
      _c.text = widget.value;
      if (sel.isValid && sel.end <= widget.value.length) _c.selection = sel;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode n, KeyEvent e) {
    if (widget.readOnly || e is! KeyDownEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.tab) {
      final sel = _c.selection;
      if (!sel.isValid) return KeyEventResult.handled;
      final t = _c.text.replaceRange(sel.start, sel.end, '  ');
      _c.value = TextEditingValue(text: t, selection: TextSelection.collapsed(offset: sel.start + 2));
      widget.onChanged?.call(t);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.enter && !HardwareKeyboard.instance.isControlPressed && !HardwareKeyboard.instance.isMetaPressed) {
      // auto-indent
      final sel = _c.selection;
      if (!sel.isValid) return KeyEventResult.ignored;
      final before = _c.text.substring(0, sel.start);
      final lineStart = before.lastIndexOf('\n') + 1;
      final indent = RegExp(r'^[ \t]*').firstMatch(before.substring(lineStart))!.group(0)!;
      final extra = before.trimRight().endsWith('{') || before.trimRight().endsWith('[') ? '  ' : '';
      final ins = '\n$indent$extra';
      final t = _c.text.replaceRange(sel.start, sel.end, ins);
      _c.value = TextEditingValue(text: t, selection: TextSelection.collapsed(offset: sel.start + ins.length));
      widget.onChanged?.call(t);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLowest,
        border: Border.all(color: cs.outlineVariant),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Focus(
        onKeyEvent: _onKey,
        child: TextField(
          controller: _c,
          focusNode: _focus,
          scrollController: _scroll,
          readOnly: widget.readOnly,
          onChanged: widget.onChanged,
          expands: true,
          maxLines: null,
          minLines: null,
          textAlignVertical: TextAlignVertical.top,
          style: mono(context, size: widget.fontSize),
          decoration: InputDecoration(
            hintText: widget.hint,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            contentPadding: const EdgeInsets.all(10),
          ),
        ),
      ),
    );
  }
}

String beautify(String text, String lang) {
  try {
    if (lang == 'json') return const JsonEncoder.withIndent('  ').convert(jsonDecode(text));
    if (lang == 'xml' || lang == 'html') return XmlDocument.parse(text).toXmlString(pretty: true, indent: '  ');
  } catch (_) {}
  return text;
}

String detectLanguage(String contentType, String body) {
  final ct = contentType.toLowerCase();
  if (ct.contains('json')) return 'json';
  if (ct.contains('html')) return 'html';
  if (ct.contains('xml')) return 'xml';
  if (ct.contains('javascript')) return 'javascript';
  if (ct.contains('css')) return 'css';
  final t = body.trimLeft();
  if (t.startsWith('{') || t.startsWith('[')) return 'json';
  if (t.startsWith('<')) return t.toLowerCase().startsWith('<!doctype html') || t.toLowerCase().startsWith('<html') ? 'html' : 'xml';
  return 'text';
}

// ============================================================================ key/value table

class KvTable extends StatefulWidget {
  final List<KV> rows;
  final VoidCallback onChanged;
  final bool showDescription;
  final bool allowFiles;
  final bool allowSecret;
  final String keyHint;
  final String valueHint;
  final VariableScope Function()? scope;
  final List<String> keySuggestions;

  const KvTable({
    super.key,
    required this.rows,
    required this.onChanged,
    this.showDescription = true,
    this.allowFiles = false,
    this.allowSecret = false,
    this.keyHint = 'Key',
    this.valueHint = 'Value',
    this.scope,
    this.keySuggestions = const [],
  });

  @override
  State<KvTable> createState() => _KvTableState();
}

class _KvTableState extends State<KvTable> {
  bool _bulk = false;
  int _gen = 0;

  String _toBulk() => widget.rows
      .where((r) => r.key.isNotEmpty || r.value.isNotEmpty)
      .map((r) => '${r.enabled ? '' : '//'}${r.key}:${r.value}')
      .join('\n');

  void _fromBulk(String s) {
    final rows = <KV>[];
    for (final line in s.split('\n')) {
      if (line.trim().isEmpty) continue;
      var l = line;
      var enabled = true;
      if (l.startsWith('//')) {
        enabled = false;
        l = l.substring(2);
      }
      final i = l.indexOf(':');
      rows.add(i < 0 ? KV(key: l.trim(), enabled: enabled) : KV(key: l.substring(0, i).trim(), value: l.substring(i + 1).trimLeft(), enabled: enabled));
    }
    widget.rows
      ..clear()
      ..addAll(rows);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final header = TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.onSurfaceVariant);
    final bulkToggle = TextButton(
      onPressed: () => setState(() {
        _bulk = !_bulk;
        _gen++;
      }),
      child: Text(_bulk ? 'Key-Value Edit' : 'Bulk Edit', style: const TextStyle(fontSize: 12)),
    );
    if (_bulk) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Align(alignment: Alignment.centerRight, child: bulkToggle),
        SizedBox(
          height: 220,
          child: CodeEditor(value: _toBulk(), language: 'text', onChanged: _fromBulk, hint: 'key:value, one per line. Prefix with // to disable.'),
        ),
      ]);
    }
    final all = [...widget.rows, null];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        decoration: BoxDecoration(border: Border.all(color: cs.outlineVariant)),
        child: Column(children: [
          Container(
            color: cs.surfaceContainerLow,
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(children: [
              const SizedBox(width: 36),
              Expanded(flex: 3, child: Padding(padding: const EdgeInsets.only(left: 8), child: Text(widget.keyHint, style: header))),
              Expanded(flex: 4, child: Padding(padding: const EdgeInsets.only(left: 8), child: Text(widget.valueHint, style: header))),
              if (widget.showDescription)
                Expanded(flex: 3, child: Padding(padding: const EdgeInsets.only(left: 8), child: Text('Description', style: header))),
              SizedBox(width: widget.allowSecret ? 72 : 40, child: Align(alignment: Alignment.centerRight, child: bulkToggle)),
              const SizedBox(width: 30),
            ]),
          ),
          for (final r in all) _row(r, cs),
        ]),
      ),
    ]);
  }

  Widget _cellBorder(Widget child, ColorScheme cs) =>
      Container(decoration: BoxDecoration(border: Border(left: BorderSide(color: cs.outlineVariant))), child: child);

  Widget _row(KV? r, ColorScheme cs) {
    final placeholder = r == null;
    void ensure(void Function(KV) f) {
      if (r == null) {
        final n = KV();
        f(n);
        widget.rows.add(n);
        setState(() {});
      } else {
        f(r);
      }
      widget.onChanged();
    }

    final kv = r ?? KV();
    final isFile = kv.type == 'file';
    Widget keyField = SyncedTextField(
      key: ValueKey('k$_gen${placeholder ? 'new${widget.rows.length}' : identityHashCode(r)}'),
      value: kv.key,
      hint: placeholder ? widget.keyHint : null,
      borderless: true,
      scope: widget.scope,
      onChanged: (v) => ensure((x) => x.key = v),
    );
    if (widget.keySuggestions.isNotEmpty) {
      keyField = Row(children: [
        Expanded(child: keyField),
        PopupMenuButton<String>(
          tooltip: 'Common headers',
          icon: const Icon(Icons.arrow_drop_down, size: 16),
          padding: EdgeInsets.zero,
          itemBuilder: (_) => widget.keySuggestions.map((s) => PopupMenuItem(value: s, height: 30, child: Text(s))).toList(),
          onSelected: (s) => ensure((x) => x.key = s),
        ),
      ]);
    }
    return Container(
      key: placeholder ? ValueKey('placeholder${widget.rows.length}') : ObjectKey(r),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: cs.outlineVariant))),
      child: Row(children: [
        SizedBox(
          width: 36,
          child: placeholder
              ? const SizedBox()
              : Checkbox(
                  value: kv.enabled,
                  visualDensity: VisualDensity.compact,
                  onChanged: (v) => ensure((x) => x.enabled = v ?? true),
                ),
        ),
        Expanded(flex: 3, child: _cellBorder(keyField, cs)),
        Expanded(
          flex: 4,
          child: _cellBorder(
            isFile
                ? Row(children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Text(kv.value.isEmpty ? 'No file selected' : kv.value.split(RegExp(r'[\\/]')).last,
                            overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: kv.value.isEmpty ? cs.onSurfaceVariant : cs.onSurface)),
                      ),
                    ),
                    TextButton(
                      onPressed: () async {
                        final f = await openFile();
                        if (f != null) ensure((x) => x.value = f.path);
                      },
                      child: const Text('Select file', style: TextStyle(fontSize: 12)),
                    ),
                  ])
                : SyncedTextField(
                    key: ValueKey('v$_gen${placeholder ? 'new${widget.rows.length}' : identityHashCode(r)}'),
                    value: kv.value,
                    hint: placeholder ? widget.valueHint : null,
                    borderless: true,
                    obscure: kv.type == 'secret',
                    scope: widget.scope,
                    onChanged: (v) => ensure((x) => x.value = v),
                  ),
            cs,
          ),
        ),
        if (widget.showDescription)
          Expanded(
            flex: 3,
            child: _cellBorder(
              SyncedTextField(
                key: ValueKey('d$_gen${placeholder ? 'new${widget.rows.length}' : identityHashCode(r)}'),
                value: kv.description,
                hint: placeholder ? 'Description' : null,
                borderless: true,
                onChanged: (v) => ensure((x) => x.description = v),
              ),
              cs,
            ),
          ),
        SizedBox(
          width: widget.allowSecret ? 72 : 40,
          child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            if (widget.allowFiles && !placeholder)
              PopupMenuButton<String>(
                tooltip: 'Field type',
                initialValue: kv.type,
                padding: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(isFile ? 'File' : 'Text', style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
                ),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'text', height: 30, child: Text('Text')),
                  PopupMenuItem(value: 'file', height: 30, child: Text('File')),
                ],
                onSelected: (t) => setState(() => ensure((x) {
                      x.type = t;
                      x.value = '';
                    })),
              ),
            if (widget.allowSecret && !placeholder)
              IconButton(
                tooltip: kv.type == 'secret' ? 'Secret (masked)' : 'Mark as secret',
                iconSize: 15,
                icon: Icon(kv.type == 'secret' ? Icons.lock : Icons.lock_open, color: cs.onSurfaceVariant),
                onPressed: () => setState(() => ensure((x) => x.type = x.type == 'secret' ? 'text' : 'secret')),
              ),
          ]),
        ),
        SizedBox(
          width: 30,
          child: placeholder
              ? null
              : IconButton(
                  iconSize: 15,
                  tooltip: 'Delete',
                  icon: Icon(Icons.close, color: cs.onSurfaceVariant),
                  onPressed: () {
                    widget.rows.remove(r);
                    setState(() {});
                    widget.onChanged();
                  },
                ),
        ),
      ]),
    );
  }
}

// ============================================================================ layout helpers

class SplitView extends StatefulWidget {
  final Widget first;
  final Widget second;
  final Axis axis;
  final double initial;
  final double min;
  const SplitView({super.key, required this.first, required this.second, this.axis = Axis.vertical, this.initial = 0.5, this.min = 0.15});

  @override
  State<SplitView> createState() => _SplitViewState();
}

class _SplitViewState extends State<SplitView> {
  late double _ratio = widget.initial;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, c) {
      final total = widget.axis == Axis.vertical ? c.maxHeight : c.maxWidth;
      final firstSize = (total - 6) * _ratio;
      final divider = MouseRegion(
        cursor: widget.axis == Axis.vertical ? SystemMouseCursors.resizeRow : SystemMouseCursors.resizeColumn,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanUpdate: (d) => setState(() {
            final delta = widget.axis == Axis.vertical ? d.delta.dy : d.delta.dx;
            _ratio = ((firstSize + delta) / (total - 6)).clamp(widget.min, 1 - widget.min);
          }),
          child: Container(
            width: widget.axis == Axis.vertical ? double.infinity : 6,
            height: widget.axis == Axis.vertical ? 6 : double.infinity,
            alignment: Alignment.center,
            child: Container(
              width: widget.axis == Axis.vertical ? double.infinity : 1,
              height: widget.axis == Axis.vertical ? 1 : double.infinity,
              color: cs.outlineVariant,
            ),
          ),
        ),
      );
      final children = [
        SizedBox(
          width: widget.axis == Axis.horizontal ? firstSize : null,
          height: widget.axis == Axis.vertical ? firstSize : null,
          child: widget.first,
        ),
        divider,
        Expanded(child: widget.second),
      ];
      return widget.axis == Axis.vertical ? Column(children: children) : Row(children: children);
    });
  }
}

class MethodBadge extends StatelessWidget {
  final ApiRequest r;
  final double size;
  const MethodBadge(this.r, {super.key, this.size = 10.5});

  @override
  Widget build(BuildContext context) {
    final isHttp = r.type == RequestType.http;
    final label = isHttp ? (r.method == 'DELETE' ? 'DEL' : r.method == 'OPTIONS' ? 'OPT' : r.method) : r.type.badge;
    final color = isHttp ? methodColor(r.method) : typeColor(r.type);
    return SizedBox(
      width: 40,
      child: Text(label, style: TextStyle(fontSize: size, fontWeight: FontWeight.w700, color: color), textAlign: TextAlign.right),
    );
  }
}

class FieldRow extends StatelessWidget {
  final String label;
  final Widget child;
  final String? help;
  final double labelWidth;
  const FieldRow(this.label, this.child, {super.key, this.help, this.labelWidth = 170});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: labelWidth,
          child: Padding(
            padding: const EdgeInsets.only(top: 9, right: 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: TextStyle(fontSize: 13, color: cs.onSurface)),
              if (help != null) Text(help!, style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
            ]),
          ),
        ),
        Expanded(child: child),
      ]),
    );
  }
}

class CompactDropdown<T> extends StatelessWidget {
  final T value;
  final Map<T, String> items;
  final ValueChanged<T> onChanged;
  final double? width;
  final TextStyle? style;
  const CompactDropdown({super.key, required this.value, required this.items, required this.onChanged, this.width, this.style});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final v = items.containsKey(value) ? value : items.keys.first;
    final dd = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(border: Border.all(color: cs.outline), borderRadius: BorderRadius.circular(4)),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: v,
          isDense: true,
          isExpanded: width != null,
          focusColor: Colors.transparent,
          style: style ?? TextStyle(fontSize: 13, color: cs.onSurface),
          dropdownColor: cs.surfaceContainerHigh,
          padding: const EdgeInsets.symmetric(vertical: 8),
          items: items.entries.map((e) => DropdownMenuItem<T>(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis))).toList(),
          onChanged: (x) {
            if (x != null) onChanged(x);
          },
        ),
      ),
    );
    return width == null ? dd : SizedBox(width: width, child: dd);
  }
}

class EmptyHint extends StatelessWidget {
  final IconData icon;
  final String text;
  final Widget? action;
  const EmptyHint(this.icon, this.text, {super.key, this.action});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 42, color: cs.onSurfaceVariant.withValues(alpha: 0.5)),
          const SizedBox(height: 10),
          Text(text, textAlign: TextAlign.center, style: TextStyle(color: cs.onSurfaceVariant)),
          if (action != null) ...[const SizedBox(height: 12), action!],
        ]),
      ),
    );
  }
}

Future<String?> promptText(BuildContext context, String title, {String initial = '', String hint = '', String okLabel = 'Save'}) {
  final c = TextEditingController(text: initial)..selection = TextSelection(baseOffset: 0, extentOffset: initial.length);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title, style: const TextStyle(fontSize: 16)),
      content: SizedBox(
        width: 380,
        child: TextField(controller: c, autofocus: true, decoration: InputDecoration(hintText: hint), onSubmitted: (v) => Navigator.pop(ctx, v.trim())),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: Text(okLabel)),
      ],
    ),
  ).then((v) => v == null || v.isEmpty ? null : v);
}

Future<bool> confirm(BuildContext context, String title, String message, {String ok = 'Delete', bool danger = true}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title, style: const TextStyle(fontSize: 16)),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(
          style: danger ? FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error) : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(ok),
        ),
      ],
    ),
  );
  return r == true;
}

void toast(BuildContext context, String msg, {bool error = false}) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(msg),
    behavior: SnackBarBehavior.floating,
    width: 480,
    backgroundColor: error ? Theme.of(context).colorScheme.error : null,
    duration: Duration(seconds: error ? 5 : 2),
  ));
}

String formatBytes(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(2)} KB';
  return '${(b / 1024 / 1024).toStringAsFixed(2)} MB';
}

String formatTime(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}.${t.millisecond.toString().padLeft(3, '0')}';

const commonHeaders = [
  'Accept',
  'Accept-Encoding',
  'Accept-Language',
  'Authorization',
  'Cache-Control',
  'Connection',
  'Content-Type',
  'Cookie',
  'If-Match',
  'If-None-Match',
  'Origin',
  'Referer',
  'User-Agent',
  'X-API-Key',
  'X-Correlation-Id',
  'X-Forwarded-For',
  'X-Request-Id',
];

/// Tab bar + body that keeps the selected index in widget state.
class SimpleTabs extends StatefulWidget {
  final List<String> labels;
  final List<Widget Function()> builders;
  final Widget? trailing;
  final int initial;
  final ValueChanged<int>? onChanged;
  const SimpleTabs({super.key, required this.labels, required this.builders, this.trailing, this.initial = 0, this.onChanged});

  @override
  State<SimpleTabs> createState() => _SimpleTabsState();
}

class _SimpleTabsState extends State<SimpleTabs> {
  late int _i = widget.initial;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_i >= widget.labels.length) _i = 0;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: cs.outlineVariant))),
        child: Row(children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                for (var i = 0; i < widget.labels.length; i++)
                  InkWell(
                    onTap: () {
                      setState(() => _i = i);
                      widget.onChanged?.call(i);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                      decoration: BoxDecoration(
                        border: Border(bottom: BorderSide(color: i == _i ? cs.primary : Colors.transparent, width: 2)),
                      ),
                      child: Text(widget.labels[i],
                          style: TextStyle(fontSize: 13, color: i == _i ? cs.onSurface : cs.onSurfaceVariant, fontWeight: i == _i ? FontWeight.w500 : FontWeight.normal)),
                    ),
                  ),
              ]),
            ),
          ),
          if (widget.trailing != null) widget.trailing!,
        ]),
      ),
      Expanded(child: widget.builders[_i]()),
    ]);
  }
}
