import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'state/app_state.dart';
import 'ui/home.dart';
import 'ui/theme.dart';
import 'ui/widgets/motion.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final state = AppState();
  await state.load();
  runApp(ChangeNotifierProvider.value(value: state, child: const CourierApp()));
}

class CourierApp extends StatefulWidget {
  const CourierApp({super.key});

  @override
  State<CourierApp> createState() => _CourierAppState();
}

class _CourierAppState extends State<CourierApp> with WidgetsBindingObserver {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    final state = context.read<AppState>();
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        await state.saveNow();
        return AppExitResponse.exit;
      },
      onPause: state.saveNow,
      onHide: state.saveNow,
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = context.select<AppState, bool>((s) => s.settings.darkMode);
    Motion.enabled = context.select<AppState, bool>((s) => s.settings.animations);
    return MaterialApp(
      title: 'Courier',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(false),
      darkTheme: buildTheme(true),
      themeMode: dark ? ThemeMode.dark : ThemeMode.light,
      home: const HomePage(),
    );
  }
}
