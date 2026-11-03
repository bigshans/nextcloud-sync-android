import 'dart:io';

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
/// * symlinks are followed for the *content* (a link to a file syncs the file
///   content), links to directories are recorded but not traversed, which
///   prevents symlink loops
/// * names are matched case-insensitively (`pathKey`) since Android shared
///   storage is case-insensitive while Nextcloud is not
Future<LocalScanResult> scanLocal(
  String root, {
  void Function(int count)? onCount,
  int maxEntries = 200000,
}) async {
  final entries = <String, LocalEntry>{};
  final errors = <String>[];
  final collisions = <String, String>{};
  var count = 0;

  Future<void> walk(String dirAbs) async {
    Directory dir;
    try {
      dir = Directory(dirAbs);
      if (!await dir.exists()) return;
    } catch (e) {
      errors.add('无法读取目录 $dirAbs: $e');
      return;
    }

    final List<FileSystemEntity> children;
    try {
      children = await dir.list(followLinks: false).toList();
    } catch (e) {
      errors.add('无法列出目录 $dirAbs: $e');
      return;
    }

    for (final entity in children) {
      if (count >= maxEntries) {
        errors.add('扫描条目超过上限 $maxEntries，已停止');
        return;
      }
      final absPath = entity.path;
      final name = baseName(absPath);
      if (_isInternalTemp(name)) continue;
      final rel = relativeOf(root, absPath);
      if (rel.isEmpty) continue;

      try {
        final type =
            await FileSystemEntity.type(absPath, followLinks: false);
        if (type == FileSystemEntityType.link) {
          final target = await Link(absPath).resolveSymbolicLinks();
          final stat = await FileStat.stat(target);
          if (stat.type == FileSystemEntityType.notFound) {
            errors.add('符号链接目标不存在: $rel -> $target');
            continue;
          }
          final isDir = stat.type == FileSystemEntityType.directory;
          count++;
          _add(entries, collisions, LocalEntry(
            path: rel,
            isDir: isDir,
            size: isDir ? 0 : stat.size,
            mtimeMs: stat.modified.millisecondsSinceEpoch,
            isLink: true,
          ));
          // Do not descend into symlinked directories (loop protection).
          onCount?.call(count);
          continue;
        }

        if (type == FileSystemEntityType.directory) {
          final stat = await FileStat.stat(absPath);
          count++;
          _add(entries, collisions, LocalEntry(
              path: rel,
              isDir: true,
              size: 0,
              mtimeMs: stat.modified.millisecondsSinceEpoch));
          onCount?.call(count);
          await walk(absPath);
        } else if (type == FileSystemEntityType.file) {
          final stat = await FileStat.stat(absPath);
          count++;
          _add(entries, collisions, LocalEntry(
            path: rel,
            isDir: false,
            size: stat.size,
            mtimeMs: stat.modified.millisecondsSinceEpoch,
          ));
          onCount?.call(count);
        }
      } catch (e) {
        errors.add('读取失败 $rel: $e');
      }
    }
  }

  await walk(root);
  return LocalScanResult(
      entries: entries, errors: errors, caseCollisions: collisions);
}

void _add(
  Map<String, LocalEntry> entries,
  Map<String, String> collisions,
  LocalEntry entry,
) {
  final key = pathKey(entry.path);
  final existing = entries[key];
  if (existing == null) {
    entries[key] = entry;
  } else if (existing.path != entry.path) {
    // Two names differing only by case: Android can usually not create this,
    // but external storage providers can. Keep the first and report it.
    collisions[key] = '${existing.path} / ${entry.path}';
  }
}
