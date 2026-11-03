import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nextcloud_sync/nextcloud/client.dart';

/// Live test against the configured Nextcloud instance.
/// Credentials are read from ~/.config/ncsync/test_creds.json (written by the
/// Login Flow v2 helper). Skipped when that file does not exist.
void main() {
  final credFile = File('${Platform.environment['HOME']}/.config/ncsync/test_creds.json');
  final creds = credFile.existsSync()
      ? jsonDecode(credFile.readAsStringSync()) as Map<String, dynamic>
      : null;

  final server = creds?['server'] as String?;
  final user = creds?['loginName'] as String?;
  final pass = creds?['appPassword'] as String?;

  group('live', () {
    late NcClient client;
    late String root;

    setUpAll(() {
      if (creds == null) return;
      client = NcClient(server: server!, username: user!, appPassword: pass!);
      root = 'ncsync-test-${DateTime.now().millisecondsSinceEpoch}';
    });

    tearDownAll(() async {
      if (creds == null) return;
      try {
        await client.delete(root);
      } catch (_) {}
      client.close();
    });

    test('status.php', () async {
      if (creds == null) return;
      final status = await NcClient.serverStatus(server!, http.Client());
      expect(status['installed'], isTrue);
      expect(status['versionstring'], isNotEmpty);
    }, skip: creds == null ? 'no credentials' : false);

    test('credentials verify', () async {
      if (creds == null) return;
      await client.verify();
    }, skip: creds == null ? 'no credentials' : false);

    test('full file lifecycle with utf-8 names', () async {
      if (creds == null) return;
      final dir = Directory('/tmp/ncsync-live')..createSync(recursive: true);
      try {
        await client.mkdir(root);
        await client.mkdirs('$root/子目录');
        expect((await client.stat(root))?.isDir, isTrue);
        expect(await client.stat('$root/missing.txt'), isNull);

        final f = File('${dir.path}/a b#c.txt')
          ..writeAsStringSync('hello 世界');
        final entry = await client.upload(f, '$root/a b#c.txt');
        expect(entry?.etag, isNotNull);

        final listed = await client.list(root);
        expect(listed.map((e) => e.path), contains('$root/a b#c.txt'));
        expect(
            listed.firstWhere((e) => e.path == '$root/子目录').isDir, isTrue);

        final down = File('${dir.path}/down.txt');
        await client.download('$root/a b#c.txt', down);
        expect(down.readAsStringSync(), 'hello 世界');

        await client.move('$root/a b#c.txt', '$root/moved.txt',
            overwrite: false);
        expect(await client.stat('$root/a b#c.txt'), isNull);
        expect(await client.stat('$root/moved.txt'), isNotNull);

        // Conditional upload: wrong etag must be rejected with 412.
        await expectLater(
          client.upload(File('${dir.path}/down.txt'), '$root/moved.txt',
              ifMatch: 'definitely-wrong'),
          throwsA(isA<NcException>()
              .having((e) => e.statusCode, 'statusCode', 412)),
        );

        await client.delete(root);
        expect(await client.stat(root), isNull);
      } finally {
        await dir.delete(recursive: true);
      }
    }, skip: creds == null ? 'no credentials' : false);

    test('bad password is rejected', () async {
      if (creds == null) return;
      final bad =
          NcClient(server: server!, username: user!, appPassword: 'wrong');
      await expectLater(bad.verify(),
          throwsA(isA<NcException>().having((e) => e.isAuth, 'isAuth', true)));
      bad.close();
    }, skip: creds == null ? 'no credentials' : false);
  });
}
