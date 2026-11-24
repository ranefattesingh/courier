import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../state/app_state.dart';
import 'grpc_editor.dart';
import 'http_editor.dart';
import 'shared.dart';
import 'stream_editors.dart';

/// Picks the right editor for the tab's protocol and rebuilds on runtime changes.
class RequestEditor extends StatelessWidget {
  final RequestTab tab;
  const RequestEditor({super.key, required this.tab});

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    return ListenableBuilder(
      listenable: tab,
      builder: (context, _) {
        final ctx = EditorCtx(state, tab);
        return KeyedSubtree(
          key: ValueKey('editor-${tab.id}-${tab.draft.type}'),
          child: switch (tab.draft.type) {
            RequestType.http || RequestType.graphql || RequestType.soap => HttpEditor(ctx),
            RequestType.grpc => GrpcEditor(ctx),
            RequestType.websocket => WebSocketEditor(ctx),
            RequestType.socketio => SocketIoEditor(ctx),
            RequestType.mqtt => MqttEditor(ctx),
            RequestType.sse => SseEditor(ctx),
            RequestType.kafka => KafkaEditor(ctx),
          },
        );
      },
    );
  }
}
