import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloud_sync/models/models.dart';
import 'package:nextcloud_sync/sync/scanner.dart';
import 'package:nextcloud_sync/util/paths.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('turbo');
    Directory('${root.path}/a').createSync();
    Directory('${root.path}/b').createSync();
    File('${root.path}/a/one.txt').writeAsStringSync('v1');
    File('${root.path}/b/two.txt').writeAsStringSync('v1');
  });

  tearDown(() => root.deleteSync(recursive: true));

  Map<String, Baseline> cacheOf(Map<String, LocalEntry> entries) => {
        for (final e in entries.values)
          pathKey(e.path): Baseline(
            path: e.path,
            isDir: e.isDir,
            localMtimeMs: e.mtimeMs,
            localSize: e.size,
          ),
      };

  test('turbo reuses unchanged folders and sees structural changes', () async {
    final first = await scanLocal(root.path);
    final cache = cacheOf(first.entries);
    expect(first.entries.length, 4); // a, b, a/one.txt, b/two.txt

    // Content edit: directory mtime is unchanged, so turbo keeps the cached
    // metadata (this is the documented tradeoff; a full scan catches it).
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    File('${root.path}/a/one.txt').writeAsStringSync('a much longer content');

    final turbo1 = await scanLocal(root.path, turbo: true, cache: cache);
    expect(turbo1.entries[pathKey('a/one.txt')]!.size,
        first.entries[pathKey('a/one.txt')]!.size);

    final full1 = await scanLocal(root.path);
    expect(full1.entries[pathKey('a/one.txt')]!.size,
        greaterThan(first.entries[pathKey('a/one.txt')]!.size));

    // New file changes the folder mtime -> turbo sees it.
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    File('${root.path}/b/three.txt').writeAsStringSync('new');
    final turbo2 =
        await scanLocal(root.path, turbo: true, cache: cacheOf(full1.entries));
    expect(turbo2.entries.keys, contains(pathKey('b/three.txt')));

    // Deletion changes the folder mtime too.
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    File('${root.path}/b/two.txt').deleteSync();
    final turbo3 =
        await scanLocal(root.path, turbo: true, cache: cacheOf(full1.entries));
    expect(turbo3.entries.keys, isNot(contains(pathKey('b/two.txt'))));
  });
}
