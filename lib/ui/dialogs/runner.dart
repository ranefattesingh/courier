import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/http_engine.dart';
import '../../models/models.dart';
import '../../state/app_state.dart';
import '../../state/executor.dart';
import '../theme.dart';
import '../widgets/common.dart';

class _RunResult {
  final int iteration;
  final ApiRequest request;
  final String path;
  final ResponseData response;
  _RunResult(this.iteration, this.request, this.path, this.response);
  bool get passed => response.error == null && response.tests.every((t) => t.passed);
}

const _runnable = {RequestType.http, RequestType.graphql, RequestType.soap, RequestType.grpc};

Future<void> showRunner(BuildContext context, AppState state, {Folder? initial}) =>
    showDialog(context: context, builder: (_) => Dialog(insetPadding: const EdgeInsets.all(24), child: _Runner(state: state, initial: initial)));

class _Runner extends StatefulWidget {
  final AppState state;
  final Folder? initial;
  const _Runner({required this.state, this.initial});

  @override
  State<_Runner> createState() => _RunnerState();
}

class _RunnerState extends State<_Runner> {
  String? _folderId;
  int _iterations = 1;
  int _delay = 0;
  bool _stopOnFail = false;
  bool _running = false;
  bool _cancel = false;
  final Set<String> _excluded = {};
  final List<_RunResult> _results = [];
  _RunResult? _selected;
  HttpEngine? _engine;
  final _sw = Stopwatch();

  @override
  void initState() {
    super.initState();
    _folderId = widget.initial?.id ?? widget.state.collections.firstOrNull?.id;
  }

  List<(ApiRequest, String)> _requests(Folder f, [String prefix = '']) => [
        for (final n in f.children)
          if (n is Folder) ..._requests(n, '$prefix${n.name} / ') else if (n is ApiRequest && _runnable.contains(n.type) && !(n.type == RequestType.graphql && n.url.startsWith('ws'))) (n, '$prefix${n.name}'),
      ];

  Future<void> _run() async {
    final folder = widget.state.findNode(_folderId!) as Folder;
    final reqs = _requests(folder).where((e) => !_excluded.contains(e.$1.id)).toList();
    setState(() {
      _running = true;
      _cancel = false;
      _results.clear();
      _selected = null;
    });
    _sw
      ..reset()
      ..start();
    final ex = Executor(widget.state);
    outer:
    for (var i = 1; i <= _iterations; i++) {
      for (final (r, path) in reqs) {
        if (_cancel) break outer;
        ResponseData res;
        if (r.type == RequestType.grpc) {
          try {
            final reg = await ex.loadGrpcSchema(r, r.id);
            res = await ex.grpcUnary(r, r.id, reg);
          } catch (e) {
            res = ResponseData(error: e.toString(), method: 'gRPC', finalUrl: r.url);
          }
        } else {
          _engine = HttpEngine();
          res = await ex.sendHttp(r, r.id, _engine!, local: {'iteration': '$i'});
        }
        if (!mounted) return;
        final rr = _RunResult(i, r, path, res);
        setState(() => _results.add(rr));
        if (_stopOnFail && !rr.passed) break outer;
        if (_delay > 0) await Future.delayed(Duration(milliseconds: _delay));
      }
    }
    _sw.stop();
    if (mounted) setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final folders = <String, String>{};
    void walk(Folder f, String prefix) {
      folders[f.id] = '$prefix${f.name}';
      for (final c in f.children.whereType<Folder>()) {
        walk(c, '$prefix${f.name} / ');
      }
    }

    for (final c in widget.state.collections) {
      walk(c, '');
    }
    final folder = _folderId == null ? null : widget.state.findNode(_folderId!) as Folder?;
    final reqs = folder == null ? <(ApiRequest, String)>[] : _requests(folder);
    final passed = _results.where((r) => r.passed).length;
    final testsTotal = _results.fold<int>(0, (a, r) => a + r.response.tests.length);
    final testsPassed = _results.fold<int>(0, (a, r) => a + r.response.tests.where((t) => t.passed).length);

    return SizedBox(
      width: 1180,
      height: 760,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 8, 8),
          child: Row(children: [
            const Icon(Icons.play_circle_outline, size: 20),
            const SizedBox(width: 8),
            const Text('Collection Runner', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const Spacer(),
            IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => Navigator.pop(context)),
          ]),
        ),
        const Divider(),
        Expanded(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SizedBox(
              width: 360,
              child: ListView(padding: const EdgeInsets.all(14), children: [
                const Text('Run', style: TextStyle(fontSize: 12)),
                const SizedBox(height: 4),
                if (folders.isEmpty)
                  const Text('Create a collection first')
                else
                  CompactDropdown<String>(width: 330, value: _folderId ?? folders.keys.first, items: folders, onChanged: (v) => setState(() => _folderId = v)),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: SyncedTextField(value: '$_iterations', label: 'Iterations', onChanged: (v) => _iterations = (int.tryParse(v) ?? 1).clamp(1, 10000))),
                  const SizedBox(width: 8),
                  Expanded(child: SyncedTextField(value: '$_delay', label: 'Delay (ms)', onChanged: (v) => _delay = (int.tryParse(v) ?? 0).clamp(0, 600000))),
                ]),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: _stopOnFail,
                  title: const Text('Stop run on first failure'),
                  onChanged: (v) => setState(() => _stopOnFail = v ?? false),
                ),
                Text('Environment: ${widget.state.activeEnv?.name ?? 'No environment'}', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                Text('Variables captured by one request are available to the next.', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: folder == null || reqs.isEmpty
                      ? null
                      : _running
                          ? () {
                              _cancel = true;
                              _engine?.cancel();
                            }
                          : _run,
                  icon: Icon(_running ? Icons.stop : Icons.play_arrow, size: 18),
                  label: Text(_running ? 'Stop' : 'Run ${folder?.name ?? ''}'),
                ),
                const SizedBox(height: 16),
                Text('Requests (${reqs.length - reqs.where((e) => _excluded.contains(e.$1.id)).length}/${reqs.length})', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                for (final (r, path) in reqs)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: !_excluded.contains(r.id),
                    onChanged: (v) => setState(() => v == true ? _excluded.remove(r.id) : _excluded.add(r.id)),
                    title: Row(children: [MethodBadge(r), const SizedBox(width: 8), Expanded(child: Text(path, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5)))]),
                  ),
              ]),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: _results.isEmpty && !_running
                  ? const EmptyHint(Icons.playlist_play, 'Choose a collection or folder and click Run.\nHTTP, GraphQL, SOAP and gRPC unary requests are executed in order.')
                  : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(children: [
                          _stat('Requests', '${_results.length}', cs.onSurface),
                          _stat('Passed', '$passed', statusColor(200)),
                          _stat('Failed', '${_results.length - passed}', statusColor(500)),
                          _stat('Tests', '$testsPassed/$testsTotal', cs.onSurface),
                          _stat('Duration', '${_sw.elapsedMilliseconds} ms', cs.onSurface),
                          _stat('Avg. response', _results.isEmpty ? '-' : '${_results.fold<int>(0, (a, r) => a + r.response.timeMs) ~/ _results.length} ms', cs.onSurface),
                          if (_running) const Padding(padding: EdgeInsets.only(left: 12), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))),
                        ]),
                      ),
                      const Divider(),
                      Expanded(
                        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          Expanded(
                            flex: 3,
                            child: ListView.builder(
                              itemCount: _results.length,
                              itemBuilder: (_, i) {
                                final rr = _results[i];
                                final res = rr.response;
                                return InkWell(
                                  onTap: () => setState(() => _selected = rr),
                                  child: Container(
                                    color: _selected == rr ? cs.primary.withValues(alpha: 0.1) : null,
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                                    child: Row(children: [
                                      Icon(rr.passed ? Icons.check_circle : Icons.cancel, size: 16, color: rr.passed ? statusColor(200) : statusColor(500)),
                                      const SizedBox(width: 8),
                                      Text('#${rr.iteration}', style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
                                      MethodBadge(rr.request),
                                      const SizedBox(width: 8),
                                      Expanded(child: Text(rr.path, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
                                      if (res.error != null)
                                        Text('Error', style: TextStyle(fontSize: 12, color: cs.error))
                                      else
                                        Text('${res.status} ${res.statusText}', style: TextStyle(fontSize: 12, color: rr.request.type == RequestType.grpc ? (res.status == 0 ? statusColor(200) : statusColor(500)) : statusColor(res.status))),
                                      const SizedBox(width: 10),
                                      SizedBox(width: 64, child: Text('${res.timeMs} ms', textAlign: TextAlign.right, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant))),
                                      SizedBox(width: 64, child: Text(res.tests.isEmpty ? '' : '${res.tests.where((t) => t.passed).length}/${res.tests.length}', textAlign: TextAlign.right, style: const TextStyle(fontSize: 12))),
                                    ]),
                                  ),
                                );
                              },
                            ),
                          ),
                          if (_selected != null) ...[
                            const VerticalDivider(width: 1),
                            Expanded(flex: 2, child: _detail(_selected!, cs)),
                          ],
                        ]),
                      ),
                    ]),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _stat(String label, String value, Color color) => Padding(
        padding: const EdgeInsets.only(right: 22),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant)),
          Text(value, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: color)),
        ]),
      );

  Widget _detail(_RunResult rr, ColorScheme cs) => ListView(padding: const EdgeInsets.all(12), children: [
        Text(rr.path, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        SelectableText('${rr.response.method} ${rr.response.finalUrl}', style: mono(context, size: 12, color: cs.onSurfaceVariant)),
        if (rr.response.error != null) Padding(padding: const EdgeInsets.only(top: 8), child: SelectableText(rr.response.error!, style: TextStyle(color: cs.error))),
        const SizedBox(height: 10),
        for (final t in rr.response.tests)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(t.passed ? Icons.check : Icons.close, size: 14, color: t.passed ? statusColor(200) : statusColor(500)),
              const SizedBox(width: 6),
              Expanded(child: Text('${t.name}${t.message.isEmpty ? '' : ' — ${t.message}'}', style: const TextStyle(fontSize: 12))),
            ]),
          ),
        const SizedBox(height: 10),
        Text('Response body', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
        const SizedBox(height: 4),
        SelectableText(
          beautify(rr.response.bodyText.length > 20000 ? rr.response.bodyText.substring(0, 20000) : rr.response.bodyText,
              detectLanguage(rr.response.contentType, rr.response.bodyText)),
          style: mono(context, size: 12),
        ),
      ]);
}
