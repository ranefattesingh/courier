import 'package:material_ui/material_ui.dart';

import '../../core/sessions.dart';
import '../../state/executor.dart';
import '../widgets/common.dart';
import '../widgets/message_log.dart';
import 'actions.dart';
import 'shared.dart';

/// Compose panel + message log layout shared by streaming protocols.
Widget _streamLayout(EditorCtx ctx, {required List<String> labels, required List<Widget Function()> builders, required String emptyText}) =>
    requestResponseSplit(
      ctx,
      initial: 0.48,
      request: SimpleTabs(key: ValueKey('st${ctx.tab.id}${ctx.r.type}'), labels: labels, builders: builders),
      response: MessageLog(messages: ctx.tab.logs, onClear: () => {ctx.tab.logs.clear(), ctx.tab.touch()}, emptyText: emptyText),
    );

Widget _composer(EditorCtx ctx, {required Widget actions, String language = 'json', String hint = 'Compose message'}) => Builder(
      builder: (context) => Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: CodeEditor(
              value: ctx.r.message,
              language: language,
              hint: hint,
              scope: ctx.scope,
              fontSize: ctx.state.settings.editorFontSize,
              onChanged: (v) {
                ctx.r.message = v;
                ctx.changed();
              },
            ),
          ),
          const SizedBox(height: 8),
          actions,
        ]),
      ),
    );

String _resolved(EditorCtx ctx, String s) => ctx.scope().resolve(s);

// ============================================================================ WebSocket

class WebSocketEditor extends StatelessWidget {
  final EditorCtx ctx;
  const WebSocketEditor(this.ctx, {super.key});

  @override
  Widget build(BuildContext context) {
    final s = ctx.tab.session;
    final connected = s is WebSocketSession && s.connected;
    final busy = s?.busy == true;
    final lang = ctx.r.opt('wsFormat', 'json');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      RequestTitleBar(ctx),
      UrlBar(ctx,
          hint: 'ws://localhost:8080 or wss://…',
          buttonLabel: busy ? 'Connecting…' : 'Connect',
          activeLabel: 'Disconnect',
          active: connected,
          onPrimary: busy ? null : () => runPrimaryAction(ctx.state, ctx.tab)),
      Expanded(
        child: _streamLayout(ctx, emptyText: 'Connect to start exchanging messages', labels: [
          'Message',
          'Params',
          'Headers',
          'Authorization',
          'Settings',
          'Docs',
        ], builders: [
          () => _composer(
                ctx,
                language: lang == 'binary' ? 'text' : lang,
                hint: lang == 'binary' ? 'Base64-encoded binary payload' : 'Compose message',
                actions: Row(children: [
                  CompactDropdown<String>(
                    value: lang,
                    items: const {'text': 'Text', 'json': 'JSON', 'xml': 'XML', 'html': 'HTML', 'binary': 'Binary (Base64)'},
                    onChanged: (v) {
                      ctx.r.opts['wsFormat'] = v;
                      ctx.changed();
                    },
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: connected ? () => (s).send(_resolved(ctx, ctx.r.message), binary: lang == 'binary') : null,
                    child: const Text('Send'),
                  ),
                ]),
              ),
          () => paramsTab(ctx),
          () => headersTab(ctx, showAuto: false),
          () => authTab(ctx, only: const {'apikey', 'bearer', 'basic', 'oauth2', 'jwt', 'awsv4', 'hawk', 'akamai', 'oauth1'}),
          () => Column(children: [
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: FieldRow(
                    'Sub-protocols',
                    SyncedTextField(
                      value: ctx.r.opt('wsProtocols'),
                      hint: 'comma separated, e.g. graphql-ws, mqtt',
                      onChanged: (v) {
                        ctx.r.opts['wsProtocols'] = v;
                        ctx.changed();
                      },
                    ),
                  ),
                ),
                Expanded(child: SettingsTab(ctx, redirects: false, timeout: false)),
              ]),
          () => descriptionTab(ctx),
        ]),
      ),
    ]);
  }
}

// ============================================================================ Socket.IO

class SocketIoEditor extends StatelessWidget {
  final EditorCtx ctx;
  const SocketIoEditor(this.ctx, {super.key});

  @override
  Widget build(BuildContext context) {
    final s = ctx.tab.session;
    final connected = s is SocketIoSession && s.connected;
    final busy = s?.busy == true;
    final r = ctx.r;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      RequestTitleBar(ctx),
      UrlBar(ctx,
          hint: 'http://localhost:3000 (namespace path allowed, e.g. /chat)',
          buttonLabel: 'Connect',
          activeLabel: busy && !connected ? 'Cancel' : 'Disconnect',
          active: connected || busy,
          onPrimary: () => runPrimaryAction(ctx.state, ctx.tab)),
      Expanded(
        child: _streamLayout(ctx, emptyText: 'Connect to receive events. All events are captured automatically.', labels: [
          'Message',
          'Params',
          'Headers',
          'Authorization',
          'Settings',
          'Docs',
        ], builders: [
          () => _composer(
                ctx,
                hint: 'Event arguments as JSON (an array is spread into multiple args)',
                actions: Row(children: [
                  SizedBox(
                    width: 200,
                    child: SyncedTextField(value: r.opt('sioEvent', 'message'), hint: 'Event name', onChanged: (v) => {r.opts['sioEvent'] = v, ctx.changed()}),
                  ),
                  const SizedBox(width: 8),
                  Row(children: [
                    Checkbox(value: r.optBool('sioAck'), onChanged: (v) => {r.opts['sioAck'] = '${v ?? false}', ctx.changed()}),
                    const Text('Ack', style: TextStyle(fontSize: 13)),
                  ]),
                  const Spacer(),
                  FilledButton(
                    onPressed: connected ? () => s.emit(_resolved(ctx, r.opt('sioEvent', 'message')), _resolved(ctx, r.message), ack: r.optBool('sioAck')) : null,
                    child: const Text('Send'),
                  ),
                ]),
              ),
          () => paramsTab(ctx),
          () => headersTab(ctx, showAuto: false),
          () => authTab(ctx, only: const {'apikey', 'bearer', 'basic', 'oauth2', 'jwt'}),
          () => ListView(padding: const EdgeInsets.all(14), children: [
                FieldRow('Handshake path', SyncedTextField(value: r.opt('sioPath', '/socket.io'), onChanged: (v) => {r.opts['sioPath'] = v, ctx.changed()})),
                FieldRow(
                  'Transport',
                  Align(
                    alignment: Alignment.centerLeft,
                    child: CompactDropdown<String>(
                      value: r.opt('sioTransport', 'websocket'),
                      items: const {'websocket': 'WebSocket only', 'polling': 'HTTP long-polling only', 'both': 'Polling with WebSocket upgrade'},
                      onChanged: (v) => {r.opts['sioTransport'] = v, ctx.changed()},
                    ),
                  ),
                ),
                FieldRow('Handshake auth (JSON)', SyncedTextField(value: r.opt('sioAuth'), hint: '{"token": "{{token}}"}', multiline: true, scope: ctx.scope, onChanged: (v) => {r.opts['sioAuth'] = v, ctx.changed()})),
                SizedBox(height: 140, child: SettingsTab(ctx, redirects: false, timeout: false)),
              ]),
          () => descriptionTab(ctx),
        ]),
      ),
    ]);
  }
}

// ============================================================================ MQTT

class MqttEditor extends StatelessWidget {
  final EditorCtx ctx;
  const MqttEditor(this.ctx, {super.key});

  @override
  Widget build(BuildContext context) {
    final s = ctx.tab.session;
    final connected = s is MqttSession && s.connected;
    final busy = s?.busy == true;
    final r = ctx.r;
    final cs = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      RequestTitleBar(ctx),
      UrlBar(ctx,
          hint: 'mqtt://broker:1883, mqtts://broker:8883, ws://broker/mqtt, wss://…',
          syncParams: false,
          buttonLabel: busy ? 'Connecting…' : 'Connect',
          activeLabel: 'Disconnect',
          active: connected,
          onPrimary: busy ? null : () => runPrimaryAction(ctx.state, ctx.tab)),
      Expanded(
        child: _streamLayout(ctx, emptyText: 'Connect to publish and receive messages', labels: [
          'Message',
          'Topics (${r.subscriptions.where((e) => e.enabled && e.key.isNotEmpty).length})',
          'Connection',
          'Docs',
        ], builders: [
          () => _composer(
                ctx,
                hint: 'Payload',
                actions: Row(children: [
                  Expanded(child: SyncedTextField(value: r.opt('mqttTopic'), hint: 'Publish topic', scope: ctx.scope, onChanged: (v) => {r.opts['mqttTopic'] = v, ctx.changed()})),
                  const SizedBox(width: 8),
                  CompactDropdown<String>(value: r.opt('mqttQos', '0'), items: const {'0': 'QoS 0', '1': 'QoS 1', '2': 'QoS 2'}, onChanged: (v) => {r.opts['mqttQos'] = v, ctx.changed()}),
                  Checkbox(value: r.optBool('mqttRetain'), onChanged: (v) => {r.opts['mqttRetain'] = '${v ?? false}', ctx.changed()}),
                  const Text('Retain', style: TextStyle(fontSize: 13)),
                  const SizedBox(width: 10),
                  FilledButton(
                    onPressed: connected ? () => s.publish(_resolved(ctx, r.opt('mqttTopic')), _resolved(ctx, r.message), r.optInt('mqttQos'), r.optBool('mqttRetain')) : null,
                    child: const Text('Publish'),
                  ),
                ]),
              ),
          () => ListView(padding: const EdgeInsets.all(14), children: [
                Text('Subscriptions (key = topic filter, value = QoS 0/1/2). Applied on connect; use the buttons to change live.',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                const SizedBox(height: 8),
                KvTable(rows: r.subscriptions, keyHint: 'Topic filter', valueHint: 'QoS', showDescription: false, scope: ctx.scope, onChanged: ctx.changed),
                const SizedBox(height: 8),
                if (connected)
                  Wrap(spacing: 8, children: [
                    for (final t in r.subscriptions.where((e) => e.enabled && e.key.isNotEmpty)) ...[
                      ActionChip(label: Text('Subscribe ${t.key}'), onPressed: () => s.subscribe(_resolved(ctx, t.key), int.tryParse(t.value) ?? 0)),
                      ActionChip(label: Text('Unsubscribe ${t.key}'), onPressed: () => s.unsubscribe(_resolved(ctx, t.key))),
                    ],
                  ]),
              ]),
          () => ListView(padding: const EdgeInsets.all(14), children: [
                FieldRow('Client ID', SyncedTextField(value: r.opt('mqttClientId'), hint: 'auto-generated', scope: ctx.scope, onChanged: (v) => {r.opts['mqttClientId'] = v, ctx.changed()})),
                FieldRow('Username', SyncedTextField(value: r.opt('mqttUser'), scope: ctx.scope, onChanged: (v) => {r.opts['mqttUser'] = v, ctx.changed()})),
                FieldRow('Password', SyncedTextField(value: r.opt('mqttPass'), obscure: true, scope: ctx.scope, onChanged: (v) => {r.opts['mqttPass'] = v, ctx.changed()})),
                FieldRow('Keep alive (s)', SyncedTextField(value: r.opt('mqttKeepAlive', '60'), onChanged: (v) => {r.opts['mqttKeepAlive'] = v, ctx.changed()})),
                FieldRow(
                  'Clean session',
                  Align(alignment: Alignment.centerLeft, child: Switch(value: r.optBool('mqttClean', true), onChanged: (v) => {r.opts['mqttClean'] = '$v', ctx.changed()})),
                ),
                FieldRow('Last-will topic', SyncedTextField(value: r.opt('mqttWillTopic'), onChanged: (v) => {r.opts['mqttWillTopic'] = v, ctx.changed()})),
                FieldRow('Last-will message', SyncedTextField(value: r.opt('mqttWillMessage'), onChanged: (v) => {r.opts['mqttWillMessage'] = v, ctx.changed()})),
                SizedBox(height: 90, child: SettingsTab(ctx, redirects: false, timeout: false)),
              ]),
          () => descriptionTab(ctx),
        ]),
      ),
    ]);
  }
}

// ============================================================================ SSE

class SseEditor extends StatelessWidget {
  final EditorCtx ctx;
  const SseEditor(this.ctx, {super.key});

  @override
  Widget build(BuildContext context) {
    final s = ctx.tab.session;
    final connected = s is SseSession && (s.connected || s.busy);
    final r = ctx.r;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      RequestTitleBar(ctx),
      UrlBar(ctx,
          showMethod: true,
          hint: 'https://example.com/events',
          buttonLabel: 'Connect',
          activeLabel: 'Disconnect',
          active: connected,
          onPrimary: () => runPrimaryAction(ctx.state, ctx.tab)),
      Expanded(
        child: _streamLayout(ctx, emptyText: 'Connect to start receiving server-sent events', labels: [
          'Params',
          'Authorization',
          'Headers',
          'Body',
          'Settings',
          'Docs',
        ], builders: [
          () => paramsTab(ctx),
          () => authTab(ctx),
          () => headersTab(ctx),
          () => Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(children: [
                    const Text('Raw body (sent with POST/PUT, e.g. streaming LLM APIs)', style: TextStyle(fontSize: 12)),
                    const Spacer(),
                    CompactDropdown<String>(
                      value: r.body.mode == 'raw' ? r.body.rawLang : 'none',
                      items: const {'none': 'No body', 'json': 'JSON', 'text': 'Text', 'xml': 'XML'},
                      onChanged: (v) {
                        if (v == 'none') {
                          r.body.mode = 'none';
                        } else {
                          r.body.mode = 'raw';
                          r.body.rawLang = v;
                        }
                        ctx.changed();
                      },
                    ),
                  ]),
                  const SizedBox(height: 6),
                  Expanded(child: CodeEditor(value: r.body.raw, language: r.body.rawLang, scope: ctx.scope, onChanged: (v) => {r.body.raw = v, ctx.changed()})),
                ]),
              ),
          () => SettingsTab(ctx, redirects: false, timeout: false),
          () => descriptionTab(ctx),
        ]),
      ),
    ]);
  }
}

// ============================================================================ Kafka

class KafkaEditor extends StatefulWidget {
  final EditorCtx ctx;
  const KafkaEditor(this.ctx, {super.key});

  @override
  State<KafkaEditor> createState() => _KafkaEditorState();
}

class _KafkaEditorState extends State<KafkaEditor> {
  bool _loadingTopics = false;
  String? _topicError;

  EditorCtx get ctx => widget.ctx;

  KafkaSession _session() {
    final s = ctx.tab.session;
    if (s is KafkaSession) return s;
    final ks = KafkaSession(ctx.tab.addLog, ctx.tab.touch);
    ctx.tab.session = ks;
    return ks;
  }

  Future<void> _loadTopics() async {
    setState(() {
      _loadingTopics = true;
      _topicError = null;
    });
    try {
      final ex = Executor(ctx.state);
      ctx.tab.kafkaTopics = await _session().listTopics(ex.resolve(ctx.r, ctx.tab.sourceId), ex.verifySsl(ctx.r));
    } catch (e) {
      _topicError = e.toString();
    } finally {
      if (mounted) setState(() => _loadingTopics = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = ctx.r;
    final cs = Theme.of(context).colorScheme;
    final s = ctx.tab.session;
    final consuming = s is KafkaSession && s.consuming;
    final busy = s is KafkaSession && s.busy;
    final topics = ctx.tab.kafkaTopics;
    void set(String k, String v) {
      r.opts[k] = v;
      ctx.changed();
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      RequestTitleBar(ctx),
      UrlBar(
        ctx,
        hint: 'Bootstrap servers, e.g. localhost:9092,broker2:9092',
        syncParams: false,
        buttonLabel: busy ? 'Producing…' : 'Produce',
        onPrimary: busy ? null : () => runPrimaryAction(ctx.state, ctx.tab),
        extra: [
          OutlinedButton.icon(
            onPressed: () async {
              final ks = _session();
              if (ks.consuming) {
                await ks.stopConsuming();
              } else {
                final ex = Executor(ctx.state);
                ks.startConsuming(ex.resolve(r, ctx.tab.sourceId), ex.verifySsl(r));
              }
            },
            icon: Icon(consuming ? Icons.stop : Icons.download, size: 16),
            label: Text(consuming ? 'Stop consuming' : 'Consume'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
        child: Row(children: [
          SizedBox(
            width: 280,
            child: SyncedTextField(value: r.opt('kafkaTopic'), hint: 'Topic', scope: ctx.scope, onChanged: (v) => set('kafkaTopic', v)),
          ),
          PopupMenuButton<String>(
            tooltip: 'Pick topic',
            enabled: topics.isNotEmpty,
            icon: const Icon(Icons.arrow_drop_down),
            itemBuilder: (_) => topics.map((t) => PopupMenuItem(value: t, height: 30, child: Text(t))).toList(),
            onSelected: (t) => setState(() => set('kafkaTopic', t)),
          ),
          TextButton.icon(
            onPressed: _loadingTopics ? null : _loadTopics,
            icon: _loadingTopics ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.refresh, size: 15),
            label: Text(topics.isEmpty ? 'List topics' : '${topics.length} topics'),
          ),
          if (_topicError != null) Expanded(child: Text(_topicError!, overflow: TextOverflow.ellipsis, style: TextStyle(color: cs.error, fontSize: 12))),
        ]),
      ),
      Expanded(
        child: _streamLayout(ctx, emptyText: 'Produce a message or start consuming to see records', labels: [
          'Message',
          'Headers',
          'Producer',
          'Consumer',
          'Connection',
          'Docs',
        ], builders: [
          () => _composer(
                ctx,
                hint: 'Record value (any text; JSON is pretty-printed in the log)',
                actions: Row(children: [
                  SizedBox(width: 260, child: SyncedTextField(value: r.opt('kafkaKey'), hint: 'Record key (optional)', scope: ctx.scope, onChanged: (v) => set('kafkaKey', v))),
                  const Spacer(),
                  FilledButton(onPressed: busy ? null : () => runPrimaryAction(ctx.state, ctx.tab), child: const Text('Produce')),
                ]),
              ),
          () => headersTab(ctx, title: 'Record headers', showAuto: false),
          () => ListView(padding: const EdgeInsets.all(14), children: [
                FieldRow('Partition', SyncedTextField(value: r.opt('kafkaPartition', '-1'), onChanged: (v) => set('kafkaPartition', v)),
                    help: '-1 = default partitioner (murmur2 of key, round-robin when no key)'),
                FieldRow(
                  'Acks',
                  Align(
                    alignment: Alignment.centerLeft,
                    child: CompactDropdown<String>(
                      value: r.opt('kafkaAcks', '-1'),
                      items: const {'-1': 'all (-1)', '1': 'leader (1)', '0': 'none (0)'},
                      onChanged: (v) => setState(() => set('kafkaAcks', v)),
                    ),
                  ),
                ),
                FieldRow(
                  'Send null value when empty',
                  Align(alignment: Alignment.centerLeft, child: Switch(value: r.optBool('kafkaNullValue'), onChanged: (v) => setState(() => set('kafkaNullValue', '$v')))),
                  help: 'Tombstone records for compacted topics',
                ),
              ]),
          () => ListView(padding: const EdgeInsets.all(14), children: [
                FieldRow(
                  'Start from',
                  Align(
                    alignment: Alignment.centerLeft,
                    child: CompactDropdown<String>(
                      value: int.tryParse(r.opt('kafkaFrom', 'latest')) != null ? 'offset' : r.opt('kafkaFrom', 'latest'),
                      items: const {'latest': 'Latest (new messages only)', 'earliest': 'Earliest (from beginning)', 'offset': 'Specific offset'},
                      onChanged: (v) => setState(() => set('kafkaFrom', v == 'offset' ? '0' : v)),
                    ),
                  ),
                ),
                if (int.tryParse(r.opt('kafkaFrom', 'latest')) != null)
                  FieldRow('Offset', SyncedTextField(value: r.opt('kafkaFrom'), onChanged: (v) => set('kafkaFrom', int.tryParse(v)?.toString() ?? '0'))),
                FieldRow('Partition', SyncedTextField(value: r.opt('kafkaConsumePartition', '-1'), onChanged: (v) => set('kafkaConsumePartition', v)), help: '-1 = all partitions'),
                Text('Consumption is group-less (no offsets are committed), so it never disturbs your application consumer groups.',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              ]),
          () => ListView(padding: const EdgeInsets.all(14), children: [
                FieldRow(
                  'Security protocol',
                  Align(
                    alignment: Alignment.centerLeft,
                    child: CompactDropdown<String>(
                      value: r.opt('kafkaSecurity', 'PLAINTEXT'),
                      items: const {'PLAINTEXT': 'PLAINTEXT', 'SSL': 'SSL', 'SASL_PLAINTEXT': 'SASL_PLAINTEXT', 'SASL_SSL': 'SASL_SSL'},
                      onChanged: (v) => setState(() => set('kafkaSecurity', v)),
                    ),
                  ),
                ),
                if (r.opt('kafkaSecurity', 'PLAINTEXT').startsWith('SASL')) ...[
                  FieldRow(
                    'SASL mechanism',
                    Align(
                      alignment: Alignment.centerLeft,
                      child: CompactDropdown<String>(
                        value: r.opt('kafkaSaslMechanism', 'PLAIN'),
                        items: const {'PLAIN': 'PLAIN', 'SCRAM-SHA-256': 'SCRAM-SHA-256', 'SCRAM-SHA-512': 'SCRAM-SHA-512'},
                        onChanged: (v) => setState(() => set('kafkaSaslMechanism', v)),
                      ),
                    ),
                  ),
                  FieldRow('Username', SyncedTextField(value: r.opt('kafkaUser'), scope: ctx.scope, onChanged: (v) => set('kafkaUser', v))),
                  FieldRow('Password', SyncedTextField(value: r.opt('kafkaPass'), obscure: true, scope: ctx.scope, onChanged: (v) => set('kafkaPass', v))),
                ],
                FieldRow('Client ID', SyncedTextField(value: r.opt('kafkaClientId', 'courier'), onChanged: (v) => set('kafkaClientId', v))),
                SizedBox(height: 90, child: SettingsTab(ctx, redirects: false, timeout: false)),
              ]),
          () => descriptionTab(ctx),
        ]),
      ),
    ]);
  }
}
