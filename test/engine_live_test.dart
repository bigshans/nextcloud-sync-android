import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloud_sync/models/models.dart';
import 'package:nextcloud_sync/nextcloud/client.dart';
import 'package:nextcloud_sync/store/db.dart';
import 'package:nextcloud_sync/sync/engine.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'live_creds.dart';

/// Full engine test against the real Nextcloud server, running on the host.
/// Uses an ffI sqlite database and a temporary local folder.
///
/// Credentials come from ~/.config/ncsync/test_creds.json; the group is skipped
/// when the file is absent.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final creds = LiveCreds.load();

  group('engine live', () {
    late NcClient client;
    late AppDb db;
    late SyncEngine engine;
    late Directory local;
    late String remoteRoot;
    late int pairId;
    late Pair pair;

    setUpAll(() async {
      if (creds == null) return;
      final work = Directory.systemTemp.createTempSync('ncsync-engine');
      db = AppDb.withDirectory(work.path);
      client = NcClient(
        server: creds.server,
        username: creds.username,
        appPassword: creds.appPassword,
      );
      engine = SyncEngine(
        db: db,
        client: client,
        deviceName: 'host-test',
        conflictPolicy: ConflictPolicy.keepBoth,
      );
      local = Directory('${work.path}/local')..createSync(recursive: true);
      remoteRoot = 'ncsync-host-${DateTime.now().millisecondsSinceEpoch}';
      pair = Pair(
        name: 'host-test',
        localPath: local.path,
        remotePath: remoteRoot,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );
      pairId = await db.insertPair(pair);
      pair = pair.copyWith(id: pairId);
      addTearDown(() async {
        try {
          await client.delete(remoteRoot);
        } catch (_) {}
        client.close();
        local.parent.deleteSync(recursive: true);
      });
    });

    test('upload, no-op, download, delete, conflict', () async {
      if (creds == null) return;

      // 1. Initial upload.
      // ignore: avoid_print
      print('STEP1');
      File('${local.path}/a.txt').writeAsStringSync('v1');
      Directory('${local.path}/sub').createSync();
      File('${local.path}/sub/中文 文件.md').writeAsStringSync('中文内容');
      File('${local.path}/.hidden').writeAsStringSync('hidden');
      final sw = Stopwatch()..start();
      var r = await engine.syncPair(pair, onProgress: (p) {
        // ignore: avoid_print
        print('${sw.elapsedMilliseconds}ms ${p.phase} ${p.done}/${p.total} '
            '${p.current ?? ''}');
      });
      expect(r.fatalError, isNull, reason: r.summary);
      expect(r.uploaded, 3, reason: r.summary);
      expect((await client.list('$remoteRoot/sub')).map((e) => e.path),
          contains('$remoteRoot/sub/中文 文件.md'));
      expect((await client.list(remoteRoot)).map((e) => e.path),
          contains('$remoteRoot/.hidden'));

      for (final l in (await db.recentLogs(limit: 20)).reversed) {
        // ignore: avoid_print
        print('LOG ${l.level} ${l.message}');
      }
      // 2. Second run must be a no-op (baseline / etag bookkeeping).
      r = await engine.syncPair(pair);
      for (final l in (await db.recentLogs(limit: 20)).reversed) {
        // ignore: avoid_print
        print('LOG2 ${l.level} ${l.message}');
      }
      expect(r.uploaded + r.downloaded + r.deleted, 0,
          reason: 'second sync should be a no-op: ${r.summary}');
      expect(r.conflicts, 0);

      // 3. Remote change -> download.
      // ignore: avoid_print
      print('STEP3');
      final tmp = File('${local.parent.path}/tmp-edit.txt')
        ..writeAsStringSync('remote edit');
      await client.upload(tmp, '$remoteRoot/from-remote.txt');
      r = await engine.syncPair(pair);
      expect(r.downloaded, 1, reason: r.summary);
      expect(File('${local.path}/from-remote.txt').readAsStringSync(),
          'remote edit');

      // 4. Local change -> upload.
      // ignore: avoid_print
      print('STEP4');
      File('${local.path}/a.txt').writeAsStringSync('v2 local edit');
      r = await engine.syncPair(pair);
      expect(r.uploaded, 1, reason: r.summary);
      final down = File('${local.parent.path}/down.txt');
      await client.download('$remoteRoot/a.txt', down);
      expect(down.readAsStringSync(), 'v2 local edit');

      // 5. Both changed differently -> keep both copies.
      // ignore: avoid_print
      print('STEP5');
      File('${local.path}/a.txt').writeAsStringSync('local conflict version');
      await client.upload(
          File('${local.parent.path}/rc.txt')
            ..writeAsStringSync('remote conflict version'),
          '$remoteRoot/a.txt');
      r = await engine.syncPair(pair);
      if (r.conflicts < 1) {
        for (final l in (await db.recentLogs(limit: 15)).reversed) {
          // ignore: avoid_print
          print('LOG5 ${l.level} ${l.message}');
        }
      }
      expect(r.conflicts, greaterThanOrEqualTo(1), reason: r.summary);
      expect(File('${local.path}/a.txt').readAsStringSync(),
          'local conflict version');
      final conflictNames = (await client.list(remoteRoot))
          .where((e) => e.path.contains('conflict'))
          .toList();
      expect(conflictNames, isNotEmpty,
          reason: 'a conflict copy should exist remotely');
      expect(
          local
              .listSync()
              .where((e) => e.path.contains('conflict'))
              .toList(),
          isNotEmpty,
          reason: 'a conflict copy should exist locally');

      // 6. Local delete propagates to the remote.
      // ignore: avoid_print
      print('STEP6');
      File('${local.path}/from-remote.txt').deleteSync();
      r = await engine.syncPair(pair);
      expect(r.deleted, 1, reason: r.summary);
      expect(await client.stat('$remoteRoot/from-remote.txt'), isNull);

      // 7. Remote delete propagates to the local side.
      // ignore: avoid_print
      print('STEP7');
      await client.delete('$remoteRoot/sub/中文 文件.md');
      r = await engine.syncPair(pair);
      expect(r.deleted, 1, reason: r.summary);
      expect(File('${local.path}/sub/中文 文件.md').existsSync(), isFalse);

      // 8. Directory deletion.
      // ignore: avoid_print
      print('STEP8');
      await client.delete('$remoteRoot/sub');
      r = await engine.syncPair(pair);
      expect(r.fatalError, isNull, reason: r.summary);
      expect(Directory('${local.path}/sub').existsSync(), isFalse);

      // 9. Manual conflict resolution.
      // ignore: avoid_print
      print('STEP9');
      File('${local.path}/manual.txt').writeAsStringSync('initial');
      r = await engine.syncPair(pair);
      expect(r.uploaded, 1, reason: r.summary);
      File('${local.path}/manual.txt').deleteSync();
      await client.upload(
          File('${local.parent.path}/m2.txt')
            ..writeAsStringSync('remote changed'),
          '$remoteRoot/manual.txt');
      // keepBoth cannot keep two copies when one side was deleted, so it
      // restores the surviving version instead of asking.
      r = await engine.syncPair(pair);
      expect(r.downloaded, 1, reason: r.summary);
      expect(File('${local.path}/manual.txt').readAsStringSync(),
          'remote changed');
      expect(await db.conflicts(pairId, resolved: false), isEmpty);

      // 10. The "ask" policy defers the same case and the user resolves it.
      final askEngine = SyncEngine(
        db: db,
        client: client,
        deviceName: 'host-test',
        conflictPolicy: ConflictPolicy.ask,
      );
      File('${local.path}/ask.txt').writeAsStringSync('v1');
      r = await askEngine.syncPair(pair);
      expect(r.uploaded, 1, reason: r.summary);
      File('${local.path}/ask.txt').deleteSync();
      await client.upload(
          File('${local.parent.path}/ask2.txt')
            ..writeAsStringSync('remote v2'),
          '$remoteRoot/ask.txt');
      r = await askEngine.syncPair(pair);
      expect(r.conflicts, 1, reason: r.summary);
      final deferred = await db.conflicts(pairId, resolved: false);
      final askConflict = deferred.firstWhere((c) => c.path == 'ask.txt');
      await askEngine.resolveConflict(askConflict, ConflictChoice.keepRemote);
      expect(File('${local.path}/ask.txt').readAsStringSync(), 'remote v2');
    }, timeout: const Timeout(Duration(minutes: 10)));
  }, skip: creds == null ? 'no credentials' : false);
}
