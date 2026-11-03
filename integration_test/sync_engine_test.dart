import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nextcloud_sync/models/models.dart';
import 'package:nextcloud_sync/nextcloud/client.dart';
import 'package:nextcloud_sync/store/db.dart';
import 'package:nextcloud_sync/sync/engine.dart';
import 'package:path_provider/path_provider.dart';

/// Real end-to-end test of the sync engine on a device, against a live
/// Nextcloud server.
///
/// `flutter test integration_test/sync_engine_test.dart -d <device>`
/// plus `--dart-define=NC_SERVER=... --dart-define=NC_USER=... --dart-define=NC_PASS=...`
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const server = String.fromEnvironment('NC_SERVER');
  const user = String.fromEnvironment('NC_USER');
  const pass = String.fromEnvironment('NC_PASS');

  // Safety guard: `flutter test -d <device>` uninstalls the app afterwards,
  // which wipes user data. Only run this on an emulator or a spare device.
  const deviceTestOk = bool.fromEnvironment('NC_DEVICE_TEST_OK');

  test('sync lifecycle', () async {
    if (!deviceTestOk) {
      // ignore: avoid_print
      print('SKIP: pass --dart-define=NC_DEVICE_TEST_OK=true to run');
      return;
    }
    if (pass.isEmpty) return;

    final ext = await getExternalStorageDirectory();
    expect(ext, isNotNull);
    final localRoot = '${ext!.path}/ncsync-it';
    final work = Directory('${ext.path}/ncsync-it-work')
      ..createSync(recursive: true);
    final local = Directory(localRoot);
    if (local.existsSync()) local.deleteSync(recursive: true);
    local.createSync(recursive: true);

    final remoteRoot = 'ncsync-it-${DateTime.now().millisecondsSinceEpoch}';
    final client = NcClient(server: server, username: user, appPassword: pass);
    final db = AppDb.instance;
    final engine =
        SyncEngine(db: db, client: client, deviceName: 'integration-test');
    final pair = Pair(
      name: 'integration-test',
      localPath: localRoot,
      remotePath: remoteRoot,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    final id = await db.insertPair(pair);
    final p = pair.copyWith(id: id);

    File tmp(String name, String content) =>
        File('${work.path}/$name')..writeAsStringSync(content);

    try {
      // 1. Initial upload (files only; directories are not counted).
      File('$localRoot/a.txt').writeAsStringSync('v1');
      Directory('$localRoot/sub').createSync();
      File('$localRoot/sub/中文 文件.md').writeAsStringSync('中文内容');
      File('$localRoot/.hidden').writeAsStringSync('hidden');
      var r = await engine.syncPair(p);
      expect(r.fatalError, isNull, reason: r.summary);
      expect(r.uploaded, 3, reason: r.summary);
      expect((await client.list('$remoteRoot/sub')).map((e) => e.path),
          contains('$remoteRoot/sub/中文 文件.md'));
      expect((await client.list(remoteRoot)).map((e) => e.path),
          contains('$remoteRoot/.hidden'));

      // 2. Second run is a no-op.
      r = await engine.syncPair(p);
      expect(r.uploaded + r.downloaded + r.deleted, 0, reason: r.summary);
      expect(r.conflicts, 0);

      // 3. Remote change downloads.
      await client.upload(tmp('edit.txt', 'remote edit'),
          '$remoteRoot/from-remote.txt');
      r = await engine.syncPair(p);
      expect(r.downloaded, 1, reason: r.summary);
      expect(File('$localRoot/from-remote.txt').readAsStringSync(),
          'remote edit');

      // 4. Local change uploads.
      File('$localRoot/a.txt').writeAsStringSync('v2 local edit');
      r = await engine.syncPair(p);
      expect(r.uploaded, 1, reason: r.summary);
      final down = File('${work.path}/down.txt');
      await client.download('$remoteRoot/a.txt', down);
      expect(down.readAsStringSync(), 'v2 local edit');

      // 5. Conflicting edits keep both copies.
      File('$localRoot/a.txt').writeAsStringSync('local conflict version');
      await client.upload(
          tmp('rc.txt', 'remote conflict version'), '$remoteRoot/a.txt');
      r = await engine.syncPair(p);
      expect(r.conflicts, greaterThanOrEqualTo(1), reason: r.summary);
      expect(File('$localRoot/a.txt').readAsStringSync(),
          'local conflict version');
      expect(
          (await client.list(remoteRoot))
              .where((e) => e.path.contains('conflict')),
          isNotEmpty);
      expect(local.listSync().where((e) => e.path.contains('conflict')),
          isNotEmpty);

      // 6. Local delete propagates.
      File('$localRoot/from-remote.txt').deleteSync();
      r = await engine.syncPair(p);
      expect(r.deleted, 1, reason: r.summary);
      expect(await client.stat('$remoteRoot/from-remote.txt'), isNull);

      // 7. Remote delete propagates.
      await client.delete('$remoteRoot/sub/中文 文件.md');
      r = await engine.syncPair(p);
      expect(r.deleted, 1, reason: r.summary);
      expect(File('$localRoot/sub/中文 文件.md').existsSync(), isFalse);

      // 8. Directory deletion propagates.
      await client.delete('$remoteRoot/sub');
      r = await engine.syncPair(p);
      expect(r.fatalError, isNull, reason: r.summary);
      expect(Directory('$localRoot/sub').existsSync(), isFalse);

      // 9. Local delete + remote edit needs a decision, then resolves.
      File('$localRoot/manual.txt').writeAsStringSync('initial');
      r = await engine.syncPair(p);
      expect(r.uploaded, 1, reason: r.summary);
      File('$localRoot/manual.txt').deleteSync();
      await client.upload(
          tmp('m2.txt', 'remote changed'), '$remoteRoot/manual.txt');
      r = await engine.syncPair(p);
      expect(r.conflicts, 1, reason: r.summary);
      final pending = await db.conflicts(id, resolved: false);
      expect(pending, isNotEmpty);
      await engine.resolveConflict(pending.first, ConflictChoice.keepRemote);
      expect(File('$localRoot/manual.txt').readAsStringSync(),
          'remote changed');
    } finally {
      try {
        await client.delete(remoteRoot);
      } catch (_) {}
      try {
        await db.deletePair(id);
      } catch (_) {}
      if (local.existsSync()) local.deleteSync(recursive: true);
      if (work.existsSync()) work.deleteSync(recursive: true);
      client.close();
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
