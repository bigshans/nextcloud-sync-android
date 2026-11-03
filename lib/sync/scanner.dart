import 'dart:io';
import 'dart:isolate';

import '../models/models.dart';
import '../util/paths.dart';

class LocalScanResult {
  final Map<String, LocalEntry> entries;
  final List<String> errors;
  final Map<String, String> caseCollisions;

  const LocalScanResult({
    required this.entries,
    required this.errors,
    required this.caseCollisions,
  });
}

bool _isInternalTemp(String name) =>
    name.contains('.ncsync-part-') || name.contains('.ncsync-upload-');

/// Recursively scans [root].
///
/// * hidden files are included
/// * symlinks are followed for the content (a link to a file syncs the file
///   content); links to directories are recorded but not traversed, which
///   prevents symlink loops
/// * names are matched case-insensitively (`pathKey`) since Android shared
///   storage is case-insensitive while Nextcloud is not
/// * large trees are scanned in parallel across isolates
Future<LocalScanResult> scanLocal(
  String root, {
  void Function(int count)? onCount,
  int maxEntries = 200000,
  int? workers,
}) async {
  final workerCount = workers ??
      (Platform.numberOfProcessors >= 4 ? 4 : Platform.numberOfProcessors)
          .clamp(1, 8);

  if (workerCount <= 1) {
    final shard = _scanShard(_ShardJob(root, const [], true));
    return _merge([shard], onCount: onCount, maxEntries: maxEntries);
  }

  // Partition the top-level directories across isolates; the root's own files
  // are handled by the first shard.
  final List<FileSystemEntity> top;
  try {
    top = Directory(root).listSync(followLinks: false);
  } catch (e) {
    return LocalScanResult(
      entries: const {},
      errors: ['无法列出目录 $root: $e'],
      caseCollisions: const {},
    );
  }

  // Every top level non-file entry is owned by exactly one shard; the first
  // shard also reports the files living directly in the root.
  final jobs = <List<String>>[<String>[]];
  for (final e in top) {
    final type = FileSystemEntity.typeSync(e.path, followLinks: false);
    if (type == FileSystemEntityType.file) continue;
    if (jobs.last.length >= 8) jobs.add(<String>[]);
    jobs.last.add(e.path);
  }

  final results = await Future.wait([
    for (var i = 0; i < jobs.length; i++)
      Isolate.run(() => _scanShard(_ShardJob(root, jobs[i], i == 0))),
  ]);
  return _merge(results, onCount: onCount, maxEntries: maxEntries);
}

LocalScanResult _merge(
  List<_ShardResult> shards, {
  void Function(int count)? onCount,
  required int maxEntries,
}) {
  final entries = <String, LocalEntry>{};
  final errors = <String>[];
  final collisions = <String, String>{};
  var count = 0;
  for (final shard in shards) {
    errors.addAll(shard.errors);
    count += shard.entries.length;
    for (final e in shard.entries) {
      final key = pathKey(e.path);
      final existing = entries[key];
      if (existing == null) {
        entries[key] = e;
      } else if (existing.path != e.path) {
        collisions[key] = '${existing.path} / ${e.path}';
      }
    }
    onCount?.call(count);
  }
  if (count > maxEntries) {
    errors.add('扫描条目超过上限 $maxEntries，已截断');
  }
  return LocalScanResult(
      entries: entries, errors: errors, caseCollisions: collisions);
}

class _ShardJob {
  final String root;
  final List<String> dirs;
  final bool includeRootFiles;
  const _ShardJob(this.root, this.dirs, this.includeRootFiles);
}

class _ShardResult {
  final List<LocalEntry> entries;
  final List<String> errors;
  const _ShardResult(this.entries, this.errors);
}

/// Runs inside an isolate: synchronous syscalls are faster than the async
/// event-loop round trips and scale across workers.
_ShardResult _scanShard(_ShardJob job) {
  final entries = <LocalEntry>[];
  final errors = <String>[];

  void walk(String dirAbs) {
    final List<FileSystemEntity> children;
    try {
      children = Directory(dirAbs).listSync(followLinks: false);
    } catch (e) {
      errors.add('无法列出目录 $dirAbs: $e');
      return;
    }
    for (final entity in children) {
      final abs = entity.path;
      final name = baseName(abs);
      if (_isInternalTemp(name)) continue;

      FileStat stat;
      try {
        // stat() follows symlinks: this is what we want for the content.
        stat = FileStat.statSync(abs);
      } catch (e) {
        errors.add('读取失败 $abs: $e');
        continue;
      }
      if (stat.type == FileSystemEntityType.notFound) {
        // Broken symlink.
        if (FileSystemEntity.typeSync(abs, followLinks: false) ==
            FileSystemEntityType.link) {
          errors.add('符号链接目标不存在: $abs');
        }
        continue;
      }
      final rel = relativeOf(job.root, abs);
      if (rel.isEmpty) continue;

      if (stat.type == FileSystemEntityType.directory) {
        final isLink = FileSystemEntity.typeSync(abs, followLinks: false) ==
            FileSystemEntityType.link;
        entries.add(LocalEntry(
            path: rel,
            isDir: true,
            size: 0,
            mtimeMs: stat.modified.millisecondsSinceEpoch,
            isLink: isLink));
        // Do not descend into symlinked directories (loop protection).
        if (!isLink) walk(abs);
      } else if (stat.type == FileSystemEntityType.file) {
        entries.add(LocalEntry(
            path: rel,
            isDir: false,
            size: stat.size,
            mtimeMs: stat.modified.millisecondsSinceEpoch,
            isLink: FileSystemEntity.typeSync(abs, followLinks: false) ==
                FileSystemEntityType.link));
      }
    }
  }

  if (job.includeRootFiles) {
    try {
      for (final entity in Directory(job.root).listSync(followLinks: false)) {
        final name = baseName(entity.path);
        if (_isInternalTemp(name)) continue;
        final type =
            FileSystemEntity.typeSync(entity.path, followLinks: false);
        if (type != FileSystemEntityType.file) continue;
        final stat = FileStat.statSync(entity.path);
        entries.add(LocalEntry(
          path: relativeOf(job.root, entity.path),
          isDir: false,
          size: stat.size,
          mtimeMs: stat.modified.millisecondsSinceEpoch,
        ));
      }
    } catch (e) {
      errors.add('无法列出目录 ${job.root}: $e');
    }
  }

  for (final dir in job.dirs) {
    final rel = relativeOf(job.root, dir);
    if (rel.isEmpty) continue;
    final FileStat stat;
    try {
      stat = FileStat.statSync(dir);
    } catch (e) {
      errors.add('读取失败 $dir: $e');
      continue;
    }
    final isLink = FileSystemEntity.typeSync(dir, followLinks: false) ==
        FileSystemEntityType.link;
    if (stat.type == FileSystemEntityType.notFound) continue;
    final isDir = stat.type == FileSystemEntityType.directory;
    entries.add(LocalEntry(
      path: rel,
      isDir: isDir,
      size: isDir ? 0 : stat.size,
      mtimeMs: stat.modified.millisecondsSinceEpoch,
      isLink: isLink,
    ));
    if (isDir && !isLink) walk(dir);
  }
  return _ShardResult(entries, errors);
}
