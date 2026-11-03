import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloud_sync/models/models.dart';
import 'package:nextcloud_sync/store/auth_store.dart';
import 'package:nextcloud_sync/store/backup.dart';
import 'package:nextcloud_sync/store/db.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tmp;
  late AppDb db;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('ncsync-backup');
    db = AppDb.withDirectory(tmp.path);
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  Pair pair(String name, String local, String remote) => Pair(
        name: name,
        localPath: local,
        remotePath: remote,
        createdAt: 1,
      );

  test('json round trip keeps account, settings and pairs', () {
    final bundle = buildBundle(
      account: const Account(
          server: 'https://cloud.example.com',
          username: 'alice',
          appPassword: 'secret',
          deviceId: 'dev1'),
      settings: const AppSettings(
          deviceName: 'Pixel', intervalMinutes: 60, wifiOnly: true),
      pairs: [
        pair('notes', '/storage/emulated/0/Notes', 'Notes'),
        pair('docs', '/storage/emulated/0/Docs', 'Work/Docs'),
      ],
      includeCredentials: true,
    );
    final parsed = BackupBundle.parse(bundle.toJson());
    expect(parsed.server, 'https://cloud.example.com');
    expect(parsed.username, 'alice');
    expect(parsed.appPassword, 'secret');
    expect(parsed.settings.deviceName, 'Pixel');
    expect(parsed.settings.intervalMinutes, 60);
    expect(parsed.settings.wifiOnly, isTrue);
    expect(parsed.pairs.map((p) => p.name), ['notes', 'docs']);
    expect(parsed.pairs.last.remotePath, 'Work/Docs');
  });

  test('export without credentials omits the account', () {
    final json = buildBundle(
      account: const Account(
          server: 'https://x', username: 'u', appPassword: 'p', deviceId: 'd'),
      settings: const AppSettings(),
      pairs: [],
      includeCredentials: false,
    ).toJson();
    expect(json.contains('appPassword'), isFalse);
    final parsed = BackupBundle.parse(json);
    expect(parsed.hasCredentials, isFalse);
  });

  test('merge keeps existing pairs and skips duplicates', () async {
    await db.insertPair(pair('old', '/local/a', 'A'));
    final bundle = BackupBundle.parse(buildBundle(
      account: null,
      settings: const AppSettings(),
      pairs: [
        pair('dup', '/local/a', 'A'),
        pair('new', '/local/b', 'B'),
      ],
      includeCredentials: false,
    ).toJson());
    final summary = await importBundle(db, bundle, replace: false);
    expect(summary.added, 1);
    expect(summary.skipped, 1);
    expect((await db.listPairs()).length, 2);
  });

  test('replace removes existing pairs', () async {
    await db.insertPair(pair('old', '/local/a', 'A'));
    await db.insertPair(pair('old2', '/local/c', 'C'));
    final bundle = BackupBundle.parse(buildBundle(
      account: null,
      settings: const AppSettings(),
      pairs: [pair('new', '/local/b', 'B')],
      includeCredentials: false,
    ).toJson());
    final summary = await importBundle(db, bundle, replace: true);
    expect(summary.removed, 2);
    expect(summary.added, 1);
    final pairs = await db.listPairs();
    expect(pairs.length, 1);
    expect(pairs.single.name, 'new');
  });

  test('settings are applied on import', () async {
    final bundle = BackupBundle.parse(buildBundle(
      account: null,
      settings: const AppSettings(
          deviceName: 'Tablet', intervalMinutes: 120, notify: false),
      pairs: [],
      includeCredentials: false,
    ).toJson());
    await importBundle(db, bundle, replace: false);
    final rows = await db.getSetting('device_name');
    expect(rows, 'Tablet');
    expect(await db.getSetting('interval_minutes'), '120');
    expect(await db.getSetting('notify'), '0');
  });

  test('rejects foreign or malformed files', () {
    expect(() => BackupBundle.parse('{"schema":"other"}'),
        throwsA(isA<FormatException>()));
    expect(() => BackupBundle.parse('not json'),
        throwsA(isA<FormatException>()));
    expect(
        () => BackupBundle.parse(
            '{"schema":"nextcloud-sync-config","version":99}'),
        throwsA(isA<FormatException>()));
  });
}
