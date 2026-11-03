import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nextcloud_sync/main.dart';
import 'package:nextcloud_sync/nextcloud/client.dart';
import 'package:nextcloud_sync/state/app_state.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

/// Drives the real UI: login with an app password, add a pair, run a sync.
///
/// `flutter test integration_test/ui_flow_test.dart -d <device>`
/// plus `--dart-define=NC_SERVER=... --dart-define=NC_USER=... --dart-define=NC_PASS=...`
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const server = String.fromEnvironment('NC_SERVER');
  const user = String.fromEnvironment('NC_USER');
  const pass = String.fromEnvironment('NC_PASS');

  testWidgets('login, add pair and sync', (tester) async {
    if (pass.isEmpty) return;

    final state = AppState();
    await state.init();
    // Never destroy the real login that is already on this device: remember it
    // and restore it at the end of the test.
    final previousAccount = state.account;
    if (state.loggedIn) {
      await state.logout();
    }
    await state.init();

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const NextcloudSyncApp(),
      ),
    );
    await tester.pumpAndSettle();

    // ------------------------------------------------------------- login page
    expect(find.text('使用浏览器授权登录'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField).first, server);
    await tester.tap(find.text('改为手动输入应用密码'));
    await tester.pumpAndSettle();

    final fields = find.byType(TextFormField);
    expect(fields, findsNWidgets(3));
    await tester.enterText(fields.at(1), user);
    await tester.enterText(fields.at(2), pass);
    await tester.tap(find.widgetWithText(FilledButton, '登录'));
    await tester.pump();

    // Wait for the home page (network can be slow).
    final deadline = DateTime.now().add(const Duration(minutes: 4));
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 500));
      if (state.loggedIn) break;
    }
    expect(state.loggedIn, isTrue, reason: state.lastError ?? '登录超时');
    await tester.pumpAndSettle();
    expect(find.text('添加同步'), findsWidgets);

    // -------------------------------------------------------------- add a pair
    final ext = await getExternalStorageDirectory();
    final localRoot = '${ext!.path}/ui-local';
    final local = Directory(localRoot)..createSync(recursive: true);
    File('$localRoot/hello.txt').writeAsStringSync('hello from ui test');
    await local.create(recursive: true);
    final remoteRoot = 'ncsync-ui-${DateTime.now().millisecondsSinceEpoch}';

    await tester.tap(find.text('添加同步').last);
    await tester.pumpAndSettle();
    expect(find.text('同步规则'), findsOneWidget);

    final editFields = find.byType(TextField);
    await tester.enterText(editFields.at(0), 'ui-test');
    await tester.enterText(editFields.at(1), localRoot);
    await tester.enterText(editFields.at(2), remoteRoot);
    final saveButton = find.text('添加');
    await tester.scrollUntilVisible(saveButton, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(saveButton);
    await tester.pumpAndSettle();

    expect(state.pairs.length, 1);
    final pairId = state.pairs.single.id!;

    // ------------------------------------------------------------------- sync
    await tester.tap(find.byIcon(Icons.sync).first);
    final syncDeadline = DateTime.now().add(const Duration(minutes: 4));
    while (DateTime.now().isBefore(syncDeadline)) {
      await tester.pump(const Duration(milliseconds: 500));
      if (!state.syncing &&
          state.lastReport != null &&
          state.lastReport!.pairId == pairId) {
        break;
      }
    }
    expect(state.lastReport, isNotNull);
    expect(state.lastReport!.fatalError, isNull,
        reason: state.lastReport!.summary);
    expect(state.lastReport!.uploaded, greaterThanOrEqualTo(1),
        reason: state.lastReport!.summary);

    final client =
        NcClient(server: server, username: user, appPassword: pass);
    try {
      final remote = await client.stat('$remoteRoot/hello.txt');
      expect(remote, isNotNull, reason: 'file should exist on the server');
    } finally {
      try {
        await client.delete(remoteRoot);
      } catch (_) {}
      client.close();
    }

    // ---------------------------------------------------------------- cleanup
    await state.deletePair(pairId);
    await tester.pumpAndSettle();
    if (local.existsSync()) local.deleteSync(recursive: true);
    if (previousAccount != null) {
      await state.auth.save(previousAccount);
      await state.init();
    } else {
      await state.logout();
    }
  }, timeout: const Timeout(Duration(minutes: 15)));
}
