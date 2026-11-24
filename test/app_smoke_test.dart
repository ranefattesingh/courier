import 'dart:io';

import 'package:courier/main.dart';
import 'package:courier/models/models.dart';
import 'package:courier/state/app_state.dart';
import 'package:courier/ui/widgets/common.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('app boots and renders every editor, panel and dialog', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final dir = Directory.systemTemp.createTempSync('courier_test');
    final state = AppState();
    await tester.runAsync(() => state.load(dir: dir));
    await tester.pumpWidget(ChangeNotifierProvider.value(value: state, child: const CourierApp()));
    await tester.pumpAndSettle();

    expect(find.text('Courier'), findsWidgets);
    expect(find.text('Sample API Collection'), findsOneWidget);

    // Every protocol editor renders.
    for (final t in RequestType.values) {
      state.newTab(t);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: t.label);
    }

    // Open a saved request from the tree.
    await tester.tap(find.text('Get with query params'));
    await tester.pumpAndSettle();
    expect(state.currentTab!.draft.name, 'Get with query params');

    // Switch through request sub-tabs of an HTTP request.
    for (final label in ['Authorization', 'Body', 'Tests', 'Settings', 'Docs']) {
      final f = find.textContaining(label);
      if (f.evaluate().isNotEmpty) {
        await tester.tap(f.first);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: label);
      }
    }

    // Edit the URL and verify params sync + dirty state.
    state.currentTab!.draft.url = '{{baseUrl}}/get?x=1';
    state.markDirty(state.currentTab!);
    await tester.pumpAndSettle();
    expect(state.currentTab!.dirty, isTrue);

    // Sidebar sections.
    await tester.tap(find.text('Environments').first);
    await tester.pumpAndSettle();
    expect(find.text('Development'), findsWidgets);
    await tester.tap(find.text('History').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Collections').first);
    await tester.pumpAndSettle();

    // Dialogs: settings, runner, import, cookies, console.
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Dark theme'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(Dialog), matching: find.byIcon(Icons.close)).first);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Runner'));
    await tester.pumpAndSettle();
    expect(find.text('Collection Runner'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(Dialog), matching: find.byIcon(Icons.close)).first);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Import').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, "curl -X POST https://example.com/api -H 'X-A: 1' -d '{\"a\":1}'");
    await tester.tap(find.widgetWithText(FilledButton, 'Import'));
    await tester.pumpAndSettle();
    expect(state.currentTab!.draft.method, 'POST');
    expect(state.currentTab!.draft.body.raw, '{"a":1}');

    await tester.tap(find.byTooltip('Cookies'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(Dialog), matching: find.byIcon(Icons.close)).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Console'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(Dialog), matching: find.byIcon(Icons.close)).first);
    await tester.pumpAndSettle();

    // Collection settings dialog via context menu action.
    await tester.tap(find.text('Sample API Collection'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit collection (auth, variables)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Variables'));
    await tester.pumpAndSettle();
    expect(find.text('baseUrl'), findsWidgets);
    await tester.tap(find.descendant(of: find.byType(Dialog), matching: find.byIcon(Icons.close)).first);
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsNothing);

    // Request/response layout: stacked by default, toggle to side by side and back.
    SplitView split() => tester.widget<SplitView>(find.byType(SplitView).first);
    expect(split().axis, Axis.vertical);
    await tester.tap(find.byTooltip('Response below — switch to side-by-side view'));
    await tester.pumpAndSettle();
    expect(state.settings.responsePane, 'right');
    expect(split().axis, Axis.horizontal);
    for (final t in RequestType.values) {
      state.newTab(t);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'side-by-side ${t.label}');
    }
    await tester.tap(find.text('Side by side'));
    await tester.pumpAndSettle();
    expect(split().axis, Axis.vertical);

    // Export dialog.
    await tester.tap(find.widgetWithText(OutlinedButton, 'Export'));
    await tester.pumpAndSettle();
    expect(find.text('Courier JSON'), findsOneWidget);
    await tester.tap(find.text('Postman Collection v2.1 JSON'));
    await tester.pumpAndSettle();
    expect(find.textContaining('will be left out'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // Light theme renders too.
    state.updateSettings((s) => s.darkMode = false);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // Keyboard shortcut: new tab.
    final before = state.tabs.length;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(state.tabs.length, before + 1);

    // Persistence round trip.
    await tester.runAsync(state.saveNow);
    final reloaded = AppState();
    await tester.runAsync(() => reloaded.load(dir: dir));
    expect(reloaded.collections.first.name, 'Sample API Collection');
    expect(reloaded.tabs.length, state.tabs.length);
    expect(reloaded.settings.darkMode, isFalse);
    expect(reloaded.settings.responsePane, 'bottom');
    dir.deleteSync(recursive: true);
  });
}
