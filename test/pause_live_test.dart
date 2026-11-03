import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloud_sync/models/models.dart';
import 'package:nextcloud_sync/nextcloud/client.dart';
import 'package:nextcloud_sync/store/db.dart';
import 'package:nextcloud_sync/sync/engine.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Pausing must stop after the current file, keep the already-synced state and
/// let a later run continue without re-uploading finished files.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final credFile = File(
      '${Platform.environment['HOME']}/.config/ncsync/test_creds.json');
  final creds = credFile.existsSync()
      ? jsonDecode(credFile.readAsStringSync()) as Map<String, dynamic>
      : null;

  test('pause and resume a running sync', () async {
    if (creds == null) return;
    final work = Directory.systemTemp.createTempSync('ncsync-pause');
    final db = AppDb.withDirectory(work.path);
    final client = NcClient(
      server: creds['server'] as String,
      username: creds['loginName'] as String,
      appPassword: creds['appPassword'] as String,
    );
    final engine = SyncEngine(db: db, client: client, deviceName: 'pause-test');
    final local = Directory('${work.path}/local')..createSync(recursive: true);
    for (var i = 0; i < 40; i++) {
      File('${local.path}/f$i.txt').writeAsStringSync('payload $i');
    }
    final remote = 'ncsync-pause-${DateTime.now().millisecondsSinceEpoch}';
    final pair = Pair(
      name: 'pause-test',
      localPath: local.path,
      remotePath: remote,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    final id = await db.insertPair(pair);
    final p = pair.copyWith(id: id);

    try {
      final token = SyncCancelToken();
      var pauseRequested = false;
      final running = engine.syncPair(p, cancel: token, onProgress: (prog) {
        // Stop once a couple of files have been transferred.
        if (!pauseRequested && prog.phase == '同步' && prog.done >= 2) {
          pauseRequested = true;
          token.pause();
        }
      });
      final paused = await running;
      expect(pauseRequested, isTrue,
          reason: 'the test never reached the transfer phase');

      expect(paused.paused, isTrue, reason: paused.summary);
      expect(paused.uploaded, greaterThan(0), reason: paused.summary);
      expect(paused.uploaded, lessThan(40), reason: paused.summary);

      // The second run continues; completed files are not transferred again.
      final resumed = await engine.syncPair(p);
      expect(resumed.fatalError, isNull, reason: resumed.summary);
      expect(resumed.paused, isFalse);
      expect(resumed.uploaded, 40 - paused.uploaded, reason: resumed.summary);

      final listed = await client.list(remote);
      expect(listed.where((e) => !e.isDir).length, 40);
    } finally {
      try {
        await client.delete(remote);
      } catch (_) {}
      client.close();
      work.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
