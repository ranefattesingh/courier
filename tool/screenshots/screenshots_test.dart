// Renders real screenshots of Courier for the website.
//
//   flutter test tool/screenshots/screenshots_test.dart   (writes build/screenshots/*.png)
//   python3 tool/screenshots/optimize.py                  (converts them to website/img/*.webp)
//
// The app is driven exactly like a user would: requests are really sent through the HTTP,
// GraphQL and WebSocket engines to small local servers started by this script, so every
// response shown is genuine. Real fonts (Roboto, DejaVu Sans Mono, Material Icons) are
// loaded so the text renders as it does in the app. Not part of `flutter test` in CI
// because it lives outside test/.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:courier/main.dart';
import 'package:courier/models/models.dart';
import 'package:courier/state/app_state.dart';
import 'package:courier/ui/dialogs/runner.dart';
import 'package:courier/ui/editors/actions.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

const outDir = 'build/screenshots'; // then: python3 tool/screenshots/optimize.py
const size = Size(1440, 900);
const pixelRatio = 1.5;

Future<void> loadFonts() async {
  final flutterRoot = File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.parent.path;
  final material = '$flutterRoot/bin/cache/artifacts/material_fonts';
  Future<void> family(String name, List<String> files) async {
    final loader = FontLoader(name);
    for (final f in files) {
      final file = File(f);
      if (!file.existsSync()) continue;
      loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    }
    await loader.load();
  }

  final roboto = [for (final w in ['Regular', 'Medium', 'Bold', 'Light']) '$material/Roboto-$w.ttf'];
  // 'Ahem' / 'FlutterTest' are the test framework's default (box glyph) fonts for text whose
  // style has no family; map them to Roboto like the app's real default.
  for (final name in ['Roboto', 'Ahem', 'FlutterTest']) {
    await family(name, roboto);
  }
  await family('MaterialIcons', ['$material/MaterialIcons-Regular.otf']);
  const mono = ['/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf', '/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf'];
  await family('monospace', mono);
  await family('DejaVu Sans Mono', mono);
}

/// Small local servers that the screenshots talk to.
Future<HttpServer> startServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final path = req.uri.path;
    if (path == '/ws' && WebSocketTransformer.isUpgradeRequest(req)) {
      final ws = await WebSocketTransformer.upgrade(req);
      ws.listen((m) => ws.add(m));
      return;
    }
    final body = await utf8.decoder.bind(req).join();
    final res = req.response..headers.contentType = ContentType.json;
    res.headers.set('server', 'demo-api/1.4');
    res.headers.set('x-request-id', '7f3c9a12-5e41-4b8a-9d0e-2c6b1f8a4e77');
    res.headers.set('cache-control', 'no-store');
    Map<String, String> hdrs() => {
          for (final h in ['accept', 'user-agent', 'x-request-id', 'content-type', 'authorization'])
            if (req.headers.value(h) != null) h: req.headers.value(h)!,
        };
    if (path == '/graphql') {
      res.write(jsonEncode({
        'data': {
          'country': {'name': 'India', 'capital': 'New Delhi', 'currency': 'INR', 'phone': '91', 'continent': {'name': 'Asia'},
            'languages': [{'name': 'Hindi'}, {'name': 'English'}]}
        }
      }));
    } else if (path == '/users') {
      res.write(jsonEncode({
        'page': int.tryParse(req.uri.queryParameters['page'] ?? '1'),
        'limit': int.tryParse(req.uri.queryParameters['limit'] ?? '10'),
        'total': 3,
        'users': [
          {'id': 101, 'name': 'Aarav Sharma', 'email': 'aarav@example.com', 'role': 'admin', 'active': true},
          {'id': 102, 'name': 'Diya Patel', 'email': 'diya@example.com', 'role': 'editor', 'active': true},
          {'id': 103, 'name': 'Kabir Rao', 'email': 'kabir@example.com', 'role': 'viewer', 'active': false},
        ],
      }));
    } else {
      res.statusCode = path == '/post' ? 201 : 200;
      res.write(jsonEncode({
        'args': req.uri.queryParameters,
        'headers': hdrs(),
        if (body.isNotEmpty) 'json': jsonDecode(body),
        'url': req.uri.toString(),
      }));
    }
    await res.close();
  });
  return server;
}

void main() {
  testWidgets('website screenshots', (tester) async {
    // flutter_test replaces HttpClient with a mock; the screenshots use real local servers.
    HttpOverrides.global = null;
    await tester.runAsync(loadFonts);
    tester.view.physicalSize = size * pixelRatio;
    tester.view.devicePixelRatio = pixelRatio;
    addTearDown(tester.view.reset);

    final server = (await tester.runAsync(startServer))!;
    final base = 'http://127.0.0.1:${server.port}';
    final dir = Directory.systemTemp.createTempSync('courier_shots');
    final state = AppState();
    await tester.runAsync(() => state.load(dir: dir));
    final boundary = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
      key: boundary,
      child: ChangeNotifierProvider.value(value: state, child: const CourierApp()),
    ));
    await tester.pumpAndSettle();
    // Decode both logo variants before the first capture.
    await tester.runAsync(() async {
      final ctx = find.byType(Scaffold).evaluate().first;
      for (final v in ['dark', 'light']) {
        await precacheImage(AssetImage('assets/icons/courier_$v.png'), ctx);
      }
    });
    await tester.pumpAndSettle();

    Future<void> shot(String name) async {
      debugPrint('shot $name');
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final ro = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final img = await ro.toImage(pixelRatio: pixelRatio);
        final png = await img.toByteData(format: ui.ImageByteFormat.png);
        Directory(outDir).createSync(recursive: true);
        File('$outDir/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
    }

    Future<void> send(RequestTab tab) async {
      await tester.runAsync(() => runPrimaryAction(state, tab));
      await tester.pumpAndSettle();
    }

    final dev = state.environments.first;
    dev.variables.firstWhere((v) => v.key == 'baseUrl').value = base;

    // Close the default untitled tab so the strip looks like a real session.
    for (final t in [...state.tabs]) {
      await tester.runAsync(() => state.closeTab(t));
    }
    await tester.pumpAndSettle();

    ApiRequest saved(String name) {
      ApiRequest? found;
      void walk(List<Node> nodes) {
        for (final n in nodes) {
          if (n is ApiRequest && n.name == name) found = n;
          if (n is Folder) walk(n.children);
        }
      }

      walk(state.collections);
      return found!;
    }

    // 1. HTTP request + JSON response, dark, side by side.
    final list = saved('Get with query params')
      ..url = '{{baseUrl}}/users?page=1&limit=10'
      ..tests = [
        TestRule(source: 'status', op: 'eq', expected: '200'),
        TestRule(source: 'jsonPath', property: r'$.users.length', op: 'eq', expected: '3'),
        TestRule(source: 'jsonPath', property: r'$.users[0].role', op: 'eq', expected: 'admin'),
      ];
    state.openRequest(saved('Create user (JSON)'));
    state.openRequest(list);
    await tester.pumpAndSettle();
    await send(state.currentTab!);
    state.updateSettings((s) => s.responsePane = 'right');
    await shot('http-dark');

    // 2. Same in light theme, stacked.
    state.updateSettings((s) {
      s.darkMode = false;
      s.responsePane = 'bottom';
    });
    await shot('http-light');
    state.updateSettings((s) => s.darkMode = true);

    // 3. GraphQL.
    final gql = saved('Countries (GraphQL)')
      ..url = '{{baseUrl}}/graphql'
      ..body.gqlQuery = 'query Country(\$code: ID!) {\n  country(code: \$code) {\n    name\n    capital\n    currency\n    phone\n    continent { name }\n    languages { name }\n  }\n}';
    state.openRequest(gql);
    await tester.pumpAndSettle();
    await send(state.currentTab!);
    state.updateSettings((s) => s.responsePane = 'right');
    await shot('graphql');

    // 4. WebSocket message log.
    dev.variables.add(KV(key: 'wsUrl', value: base.replaceFirst('http', 'ws')));
    final ws = saved('Echo WebSocket')..url = '{{wsUrl}}/ws';
    state.openRequest(ws);
    await tester.pumpAndSettle();
    final wsTab = state.currentTab!;
    await send(wsTab);
    for (final m in ['{"type": "subscribe", "channel": "orders"}', '{"type": "ping"}', 'hello from Courier']) {
      await tester.runAsync(() async {
        (wsTab.session! as dynamic).send(m);
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
    }
    await tester.pumpAndSettle();
    await shot('websocket');
    await tester.runAsync(() => wsTab.session!.close());

    // 5. Kafka producer form.
    state.openRequest(saved('Kafka orders topic'));
    await shot('kafka');

    // 6. Environments + editor dialog.
    dev.variables.removeWhere((v) => v.key == 'wsUrl');
    dev.variables.firstWhere((v) => v.key == 'baseUrl').value = 'https://api.dev.example.com';
    state.openRequest(list);
    state
      ..sidebarSection = 'environments'
      ..changed(save: false);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Development').last);
    await tester.pumpAndSettle();
    await shot('environments');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    state
      ..sidebarSection = 'collections'
      ..changed(save: false);

    // 7. Import dialog.
    await tester.tap(find.text('Import').first);
    await tester.pumpAndSettle();
    await shot('import');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    // 8. Test results for the list request.
    state.openRequest(list);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Test Results').first);
    await shot('tests');
    await tester.tap(find.text('Body').last);

    // 9. OAuth 2.0 authorization.
    state.updateSettings((s) => s.responsePane = 'bottom');
    state.newTab(RequestType.http);
    final oauth = state.currentTab!.draft
      ..name = 'List repositories'
      ..url = 'https://api.github.com/user/repos'
      ..auth = AuthConfig(type: 'oauth2', p: {
        'grantType': 'authorization_code_pkce',
        'authUrl': 'https://github.com/login/oauth/authorize',
        'tokenUrl': 'https://github.com/login/oauth/access_token',
        'clientId': '{{githubClientId}}',
        'scope': 'repo read:org',
      });
    state.markDirty(state.currentTab!);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Authorization').first);
    await shot('auth');
    expect(oauth.auth.type, 'oauth2');

    // 10. Collection runner over the Users Service folder, with real requests.
    final users = state.collections.first.children.whereType<Folder>().firstWhere((f) => f.name == 'Users Service');
    dev.variables.firstWhere((v) => v.key == 'baseUrl').value = base;
    final ctx = find.byType(Scaffold).evaluate().first;
    showRunner(ctx, state, initial: users);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Run Users Service'));
    for (var i = 0; i < 40 && find.textContaining('Stop').evaluate().isNotEmpty || i < 3; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    await shot('runner');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      await state.saveNow();
      await server.close(force: true);
    });
  });
}
