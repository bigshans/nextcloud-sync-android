import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloud_sync/models/models.dart';
import 'package:nextcloud_sync/sync/planner.dart';
import 'package:nextcloud_sync/util/paths.dart';

LocalEntry lf(String path, {int size = 10, int mtime = 1000}) =>
    LocalEntry(path: path, isDir: false, size: size, mtimeMs: mtime);

LocalEntry ld(String path, {int mtime = 1000}) =>
    LocalEntry(path: path, isDir: true, size: 0, mtimeMs: mtime);

RemoteEntry rf(String path,
        {String etag = 'e1', int size = 10, int? mtime = 1000}) =>
    RemoteEntry(path: path, isDir: false, etag: etag, mtimeMs: mtime, size: size);

RemoteEntry rd(String path, {String etag = 'd1'}) =>
    RemoteEntry(path: path, isDir: true, etag: etag);

Baseline bf(String path,
        {String etag = 'e1',
        int size = 10,
        int mtime = 1000,
        int rsize = 10}) =>
    Baseline(
        path: path,
        isDir: false,
        etag: etag,
        remoteSize: rsize,
        remoteMtimeMs: mtime,
        localSize: size,
        localMtimeMs: mtime);

Baseline bd(String path, {String etag = 'd1', int mtime = 1000}) =>
    Baseline(
        path: path,
        isDir: true,
        etag: etag,
        localMtimeMs: mtime,
        remoteMtimeMs: mtime);

SyncPlan plan({
  Map<String, LocalEntry> local = const {},
  Map<String, RemoteEntry> remote = const {},
  Map<String, Baseline> baseline = const {},
  Set<String> pending = const {},
  bool syncDeletions = true,
}) =>
    planSync(
      local: {for (final e in local.values) pathKey(e.path): e},
      remote: {for (final e in remote.values) pathKey(e.path): e},
      baseline: {for (final e in baseline.values) pathKey(e.path): e},
      pendingConflicts: pending,
      syncDeletions: syncDeletions,
    );

List<ActionKind> kinds(SyncPlan p) => p.actions.map((a) => a.kind).toList();

void main() {
  group('planner', () {
    test('new local file uploads', () {
      final p = plan(local: {'a.txt': lf('a.txt')});
      expect(kinds(p), [ActionKind.upload]);
    });

    test('new remote file downloads', () {
      final p = plan(remote: {'a.txt': rf('a.txt')});
      expect(kinds(p), [ActionKind.download]);
    });

    test('new identical file on both sides only refreshes baseline', () {
      final p = plan(
        local: {'a.txt': lf('a.txt', size: 5, mtime: 1000)},
        remote: {'a.txt': rf('a.txt', size: 5, mtime: 1000)},
      );
      expect(kinds(p), [ActionKind.refresh]);
    });

    test('new different file on both sides keeps both', () {
      final p = plan(
        local: {'a.txt': lf('a.txt', size: 5)},
        remote: {'a.txt': rf('a.txt', size: 9)},
      );
      expect(kinds(p), [ActionKind.keepBoth]);
    });

    test('local edit uploads', () {
      final p = plan(
        local: {'a.txt': lf('a.txt', size: 20, mtime: 2000)},
        remote: {'a.txt': rf('a.txt')},
        baseline: {'a.txt': bf('a.txt')},
      );
      expect(kinds(p), [ActionKind.upload]);
    });

    test('remote edit downloads', () {
      final p = plan(
        local: {'a.txt': lf('a.txt')},
        remote: {'a.txt': rf('a.txt', etag: 'e2')},
        baseline: {'a.txt': bf('a.txt')},
      );
      expect(kinds(p), [ActionKind.download]);
    });

    test('both edited keeps both', () {
      final p = plan(
        local: {'a.txt': lf('a.txt', size: 30, mtime: 3000)},
        remote: {'a.txt': rf('a.txt', etag: 'e2', size: 40)},
        baseline: {'a.txt': bf('a.txt')},
      );
      expect(kinds(p), [ActionKind.keepBoth]);
    });

    test('unchanged does nothing', () {
      final p = plan(
        local: {'a.txt': lf('a.txt')},
        remote: {'a.txt': rf('a.txt')},
        baseline: {'a.txt': bf('a.txt')},
      );
      expect(kinds(p), [ActionKind.refresh]);
    });

    test('local delete propagates to remote', () {
      final p = plan(
        remote: {'a.txt': rf('a.txt')},
        baseline: {'a.txt': bf('a.txt')},
      );
      expect(kinds(p), [ActionKind.deleteRemote]);
      expect(p.dropKeys, contains('a.txt'));
    });

    test('remote delete propagates to local', () {
      final p = plan(
        local: {'a.txt': lf('a.txt')},
        baseline: {'a.txt': bf('a.txt')},
      );
      expect(kinds(p), [ActionKind.deleteLocal]);
    });

    test('local delete + remote edit needs a decision', () {
      final p = plan(
        remote: {'a.txt': rf('a.txt', etag: 'e2', size: 99)},
        baseline: {'a.txt': bf('a.txt')},
      );
      expect(kinds(p), [ActionKind.needsDecision]);
      expect(p.dropKeys, isEmpty);
    });

    test('remote delete + local edit needs a decision', () {
      final p = plan(
        local: {'a.txt': lf('a.txt', size: 77, mtime: 5000)},
        baseline: {'a.txt': bf('a.txt')},
      );
      expect(kinds(p), [ActionKind.needsDecision]);
    });

    test('directory deletion skips descendants', () {
      final p = plan(
        local: {'dir': ld('dir'), 'dir/a.txt': lf('dir/a.txt')},
        baseline: {
          'dir': bd('dir'),
          'dir/a.txt': bf('dir/a.txt'),
        },
      );
      // Remote dir and its file are gone; local dir unchanged -> delete local.
      expect(kinds(p), [ActionKind.deleteLocal]);
      expect(p.actions.single.isDir, isTrue);
      expect(p.dropPrefixes, contains('dir'));
    });

    test('case-only difference needs a decision', () {
      final p = plan(
        local: {'readme.md': lf('readme.md')},
        remote: {'README.md': rf('README.md')},
      );
      expect(kinds(p), [ActionKind.needsDecision]);
    });

    test('file vs directory needs a decision', () {
      final p = plan(
        local: {'x': lf('x')},
        remote: {'x': rd('x')},
      );
      expect(kinds(p), [ActionKind.needsDecision]);
    });

    test('pending conflict paths are skipped with their subtree', () {
      final p = plan(
        local: {'dir/a.txt': lf('dir/a.txt', size: 4, mtime: 9999)},
        remote: {'dir/a.txt': rf('dir/a.txt', etag: 'e9', size: 5)},
        pending: {'dir'},
      );
      expect(p.actions, isEmpty);
    });

    test('deletions disabled re-creates the remote file', () {
      final p = plan(
        local: {'a.txt': lf('a.txt', size: 33, mtime: 4000)},
        baseline: {'a.txt': bf('a.txt')},
        syncDeletions: false,
      );
      expect(kinds(p), [ActionKind.upload]);
    });

    test('parent dir is planned before children', () {
      final p = plan(local: {
        'a/b/c.txt': lf('a/b/c.txt'),
        'a': ld('a'),
        'a/b': ld('a/b'),
      });
      expect(kinds(p), [
        ActionKind.makeRemoteDir,
        ActionKind.makeRemoteDir,
        ActionKind.upload,
      ]);
    });
  });

  group('paths', () {
    test('normalizeRel', () {
      expect(normalizeRel('/a//b/'), 'a/b');
      expect(normalizeRel('a/./b'), 'a/b');
      expect(normalizeRel(''), '');
    });
    test('pathKey is case insensitive', () {
      expect(pathKey('Docs/ReadMe.MD'), 'docs/readme.md');
    });
    test('isSameOrUnder', () {
      expect(isSameOrUnder('a', 'a/b'), isTrue);
      expect(isSameOrUnder('a', 'ab'), isFalse);
    });
    test('encodeRel encodes segments but keeps slashes', () {
      expect(encodeRel('a b/c#d.txt'), 'a%20b/c%23d.txt');
    });
  });
}
