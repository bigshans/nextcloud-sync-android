import 'dart:async';
import 'dart:io';

import '../models/models.dart';
import '../nextcloud/client.dart';
import '../store/db.dart';
import '../util/paths.dart';
import 'planner.dart';
import 'scanner.dart';

typedef ProgressSink = void Function(SyncProgress progress);

enum ConflictChoice { keepLocal, keepRemote, keepBoth }

/// Executes one sync pass for a pair: scan both sides, plan a three-way merge
/// and apply the resulting actions.
class SyncEngine {
  SyncEngine({
    required this.db,
    required this.client,
    required this.deviceName,
    this.concurrency = 3,
  });

  final AppDb db;
  final NcClient client;
  final String deviceName;
  final int concurrency;

  /// Remote directories already ensured during the current pass.
  final Set<String> _createdRemoteDirs = {};

  /// Maps a pair-relative path to a path relative to the DAV root.
  static String _remotePath(Pair pair, String rel) {
    final base = normalizeRel(pair.remotePath);
    final r = normalizeRel(rel);
    if (base.isEmpty) return r;
    if (r.isEmpty) return base;
    return '$base/$r';
  }

  // ------------------------------------------------------------------ public

  Future<SyncReport> syncPair(
    Pair pair, {
    ProgressSink? onProgress,
    bool force = false,
  }) async {
    final report = _ReportBuilder(pair);

    void progress(String phase, {int done = 0, int total = 0, String? current}) {
      onProgress?.call(SyncProgress(
        phase: phase,
        done: done,
        total: total,
        current: current,
        pairName: pair.name,
      ));
    }

    try {
      progress('准备');
      _createdRemoteDirs.clear();
      final root = pair.localPath;
      if (!await Directory(root).exists()) {
        await Directory(root).create(recursive: true);
      }

      // 1. The remote root must exist.
      if (await client.stat(pair.remotePath) == null) {
        await client.mkdirs(pair.remotePath);
      }

      // 2. Scan both sides.
      progress('扫描远程');
      final remote = await _scanRemote(pair, progress);
      progress('扫描本地');
      final localScan = await scanLocal(root, onCount: (c) {
        progress('扫描本地', done: c);
      });
      report.errors += localScan.errors.length;
      for (final e in localScan.errors.take(5)) {
        await db.log(pair.id, 'warn', e);
      }
      for (final c in localScan.caseCollisions.entries) {
        final row = await db.addConflict(
          pairId: pair.id!,
          path: c.value,
          kind: 'case',
          detail: '本地存在仅大小写不同的同名文件，无法安全同步',
        );
        report.conflicts++;
        await db.log(pair.id, 'warn', '大小写冲突 ${c.value} (#$row)');
      }

      // 3. Three-way merge.
      final baseline = await db.loadBaselines(pair.id!);
      final pending = await db.pendingConflictPaths(pair.id!);
      final plan = planSync(
        local: localScan.entries,
        remote: remote,
        baseline: baseline,
        pendingConflicts: pending,
      );

      // 4. Safety valve against accidental mass deletion.
      final deleteCount = plan.actions
          .where((a) =>
              a.kind == ActionKind.deleteLocal ||
              a.kind == ActionKind.deleteRemote)
          .length;
      if (!force &&
          baseline.isNotEmpty &&
          deleteCount > 20 &&
          deleteCount > baseline.length * 0.5) {
        final msg = '检测到 $deleteCount 个删除操作（基线 ${baseline.length} 项），'
            '为避免误删已中止。如确认无误，请手动触发强制同步。';
        await db.log(pair.id, 'error', msg);
        report.fatalError = msg;
        return report.finish();
      }

      // 5. Execute.
      var done = 0;
      final total = plan.actions.length;
      final rows = <Map<String, Object?>>[];
      final dropKeys = <String>{...plan.dropKeys};
      final dropPrefixes = <String>{...plan.dropPrefixes};

      Future<void> flush() async {
        if (rows.isEmpty && dropKeys.isEmpty && dropPrefixes.isEmpty) return;
        for (final key in dropKeys) {
          await db.deleteBaseline(pair.id!, key);
        }
        for (final prefix in dropPrefixes) {
          await db.deleteBaselinesUnder(pair.id!, prefix);
        }
        await db.saveBaselines(pair.id!, rows);
        rows.clear();
        dropKeys.clear();
        dropPrefixes.clear();
      }

      for (final action in plan.actions) {
        progress('同步',
            done: done, total: total, current: '${_verb(action.kind)} /${action.path}');
        try {
          switch (action.kind) {
            case ActionKind.upload:
              await _doUpload(pair, action, baseline, rows, dropKeys);
              report.uploaded++;
              break;
            case ActionKind.download:
              await _doDownload(pair, action, remote, rows, dropKeys);
              report.downloaded++;
              break;
            case ActionKind.makeRemoteDir:
              await _ensureRemoteDir(pair, action.path);
              final r = await client.stat(_remotePath(pair, action.path));
              rows.add(_row(action.path,
                  isDir: true,
                  l: localScan.entries[pathKey(action.path)],
                  r: r));
              break;
            case ActionKind.makeLocalDir:
              final abs = localJoin(pair.localPath, action.path);
              await Directory(abs).create(recursive: true);
              rows.add(_row(action.path,
                  isDir: true,
                  r: remote[pathKey(action.path)]));
              break;
            case ActionKind.deleteLocal:
              final abs = localJoin(pair.localPath, action.path);
              if (action.isDir) {
                final d = Directory(abs);
                if (await d.exists()) await d.delete(recursive: true);
                dropPrefixes.add(pathKey(action.path));
              } else {
                final f = File(abs);
                if (await f.exists()) await f.delete();
                dropKeys.add(pathKey(action.path));
              }
              report.deleted++;
              break;
            case ActionKind.deleteRemote:
              await client.delete(_remotePath(pair, action.path));
              if (action.isDir) {
                dropPrefixes.add(pathKey(action.path));
              } else {
                dropKeys.add(pathKey(action.path));
              }
              report.deleted++;
              break;
            case ActionKind.refresh:
              rows.add(_row(action.path,
                  isDir: action.isDir,
                  l: localScan.entries[pathKey(action.path)],
                  r: remote[pathKey(action.path)]));
              break;
            case ActionKind.keepBoth:
              await _keepBoth(pair, action, localScan.entries, remote, rows);
              report.conflicts++;
              break;
            case ActionKind.needsDecision:
              await db.addConflict(
                pairId: pair.id!,
                path: action.path,
                kind: 'manual',
                detail: action.reason,
              );
              await db.log(pair.id, 'warn',
                  '需要人工处理: /${action.path} — ${action.reason ?? ''}');
              report.conflicts++;
              break;
            case ActionKind.forget:
              dropKeys.add(pathKey(action.path));
              break;
          }
        } catch (e) {
          report.errors++;
          await db.log(pair.id, 'error',
              '${_verb(action.kind)} /${action.path} 失败: $e');
          if (e is NcException && e.isAuth) {
            report.fatalError = '认证失败，请重新登录';
            await flush();
            return report.finish();
          }
        }
        done++;
        if (rows.length >= 100 ||
            dropKeys.length + dropPrefixes.length >= 100) {
          await flush();
        }
      }

      await flush();
      progress('完成', done: total, total: total);

      if (report.errors == 0 && report.fatalError == null) {
        await db.setPairResult(pair.id!,
            DateTime.now().millisecondsSinceEpoch, report.summary);
      } else {
        await db.setPairResult(pair.id!, null, report.summary);
      }
      await db.log(pair.id, 'info', '同步完成：${report.summary}');
      return report.finish();
    } catch (e, st) {
      report.fatalError = '$e';
      report.errors++;
      await db.log(pair.id, 'error', '同步中断: $e\n$st');
      return report.finish();
    }
  }

  static String _verb(ActionKind k) => switch (k) {
        ActionKind.upload => '上传',
        ActionKind.download => '下载',
        ActionKind.makeRemoteDir => '创建远程目录',
        ActionKind.makeLocalDir => '创建本地目录',
        ActionKind.deleteLocal => '删除本地',
        ActionKind.deleteRemote => '删除远程',
        ActionKind.refresh => '检查',
        ActionKind.keepBoth => '冲突保留两份',
        ActionKind.needsDecision => '待处理',
        ActionKind.forget => '清理',
      };

  // -------------------------------------------------------- conflict actions

  Future<void> resolveConflict(
    ConflictRow conflict,
    ConflictChoice choice,
  ) async {
    final pair = await db.getPair(conflict.pairId);
    if (pair == null) {
      await db.resolveConflict(conflict.id);
      return;
    }
    final path = normalizeRel(conflict.path);
    final abs = localJoin(pair.localPath, path);
    final localFile = File(abs);
    final localExists = await localFile.exists();
    final remotePath = _remotePath(pair, path);

    switch (choice) {
      case ConflictChoice.keepLocal:
        // Keep the device side. When the local file is gone the local intent
        // was a deletion, so delete the remote copy.
        if (!localExists) {
          await client.delete(remotePath);
          await db.deleteBaseline(pair.id!, path);
          await db.resolveConflict(conflict.id);
          await db.log(pair.id, 'debug', '冲突处理：本地已删除，已删除远程 /$path');
          return;
        }
        await _ensureRemoteDir(pair, parentOf(path));
        final uploaded = await client.upload(localFile, remotePath);
        final localStat = await localFile.stat();
        await db.saveBaselines(pair.id!, [
          _row(path,
              isDir: false,
              l: LocalEntry(
                  path: path,
                  isDir: false,
                  size: localStat.size,
                  mtimeMs: localStat.modified.millisecondsSinceEpoch),
              r: uploaded)
        ]);
        break;
      case ConflictChoice.keepRemote:
        final remote = await client.stat(remotePath);
        if (remote == null) {
          // The remote side was deleted: honour that locally.
          if (localExists) {
            await localFile.delete();
          } else {
            final dir = Directory(abs);
            if (await dir.exists()) await dir.delete(recursive: true);
          }
          await db.deleteBaseline(pair.id!, path);
          await db.resolveConflict(conflict.id);
          await db.log(pair.id, 'debug', '冲突处理：远程已删除，已删除本地 /$path');
          return;
        }
        if (remote.isDir) {
          if (localExists) await localFile.delete();
          await Directory(abs).create(recursive: true);
        } else {
          if (localExists) await localFile.delete();
          await client.download(remotePath, localFile);
        }
        final st = await FileStat.stat(abs);
        await db.saveBaselines(pair.id!, [
          _row(path,
              isDir: remote.isDir,
              l: LocalEntry(
                  path: path,
                  isDir: remote.isDir,
                  size: remote.isDir ? 0 : st.size,
                  mtimeMs: st.modified.millisecondsSinceEpoch),
              r: remote)
        ]);
        break;
      case ConflictChoice.keepBoth:
        final l = localExists
            ? LocalEntry(
                path: path,
                isDir: false,
                size: await localFile.length(),
                mtimeMs:
                    (await localFile.stat()).modified.millisecondsSinceEpoch)
            : null;
        final r = await client.stat(remotePath);
        if (l == null || r == null) {
          await db.log(pair.id, 'error', '无法保留两份：/$path 有一侧已不存在');
          return;
        }
        final rows = <Map<String, Object?>>[];
        await _keepBoth(pair, SyncAction(ActionKind.keepBoth, path),
            {pathKey(path): l}, {pathKey(path): r}, rows);
        await db.saveBaselines(pair.id!, rows);
        break;
    }
    await db.resolveConflict(conflict.id);
    await db.log(pair.id, 'info', '已处理冲突 /$path (${choice.name})');
  }

  // -------------------------------------------------------------- remote scan

  Future<Map<String, RemoteEntry>> _scanRemote(
    Pair pair,
    void Function(String phase, {int done, int total, String? current})
        progress,
  ) async {
    final out = <String, RemoteEntry>{};
    final rootPrefix = normalizeRel(pair.remotePath);
    final queue = <String>[rootPrefix];
    var listed = 0;

    String toRelative(String full) {
      if (rootPrefix.isEmpty) return full;
      if (full == rootPrefix) return '';
      if (full.startsWith('$rootPrefix/')) {
        return full.substring(rootPrefix.length + 1);
      }
      return full;
    }

    while (queue.isNotEmpty) {
      final batch = <String>[];
      while (queue.isNotEmpty && batch.length < concurrency) {
        batch.add(queue.removeLast());
      }
      // A failed listing must abort the sync: treating it as "empty remote"
      // would plan a deletion of every local file.
      final results = await Future.wait(batch.map((dir) async {
        try {
          return await client.list(dir);
        } catch (e) {
          await db.log(pair.id, 'error', '列目录失败 /$dir: $e');
          rethrow;
        }
      }));
      for (final entries in results) {
        for (final e in entries) {
          final rel = toRelative(e.path);
          if (rel.isEmpty) continue;
          final key = pathKey(rel);
          final existing = out[key];
          if (existing != null && existing.path != rel) {
            // Nextcloud allows names that differ only by case; Android cannot
            // store both, so let the user decide.
            final row = await db.addConflict(
              pairId: pair.id!,
              path: rel,
              kind: 'case',
              detail: '远程存在仅大小写不同的同名文件：'
                  '${existing.path} / $rel',
            );
            await db.log(pair.id, 'warn', '远程大小写冲突 (#$row) $rel');
            continue;
          }
          out[key] = RemoteEntry(
            path: rel,
            isDir: e.isDir,
            etag: e.etag,
            mtimeMs: e.mtimeMs,
            size: e.size,
          );
          if (e.isDir) queue.add(e.path);
        }
        listed++;
      }
      progress('扫描远程', done: out.length);
    }
    await db.log(
        pair.id, 'debug', '远程扫描完成：$listed 个目录，${out.length} 项');
    return out;
  }

  // ------------------------------------------------------------- file actions

  Future<void> _doUpload(
    Pair pair,
    SyncAction action,
    Map<String, Baseline> baseline,
    List<Map<String, Object?>> rows,
    Set<String> dropKeys,
  ) async {
    final path = normalizeRel(action.path);
    final abs = localJoin(pair.localPath, path);
    final file = File(abs);
    if (!await file.exists()) {
      throw NcException('本地文件不存在: /$path');
    }
    await _ensureRemoteDir(pair, parentOf(path));
    final base = baseline[pathKey(path)];
    final ifMatch = base != null && !base.isDir ? base.etag : null;
    final remote = await client.upload(file, _remotePath(pair, path),
        ifMatch: ifMatch);
    final st = await file.stat();
    rows.add(_row(path,
        isDir: false,
        l: LocalEntry(
            path: path,
            isDir: false,
            size: st.size,
            mtimeMs: st.modified.millisecondsSinceEpoch),
        r: remote));
    dropKeys.remove(pathKey(path));
  }

  Future<void> _doDownload(
    Pair pair,
    SyncAction action,
    Map<String, RemoteEntry> remote,
    List<Map<String, Object?>> rows,
    Set<String> dropKeys,
  ) async {
    final path = normalizeRel(action.path);
    final abs = localJoin(pair.localPath, path);
    final file = File(abs);
    final etag = await client.download(_remotePath(pair, path), file);
    final st = await file.stat();
    final snap = remote[pathKey(path)];
    rows.add(_row(path,
        isDir: false,
        l: LocalEntry(
            path: path,
            isDir: false,
            size: st.size,
            mtimeMs: st.modified.millisecondsSinceEpoch),
        r: RemoteEntry(
          path: path,
          isDir: false,
          etag: etag ?? snap?.etag,
          mtimeMs: snap?.mtimeMs,
          size: snap?.size,
        )));
    dropKeys.remove(pathKey(path));
  }

  Future<void> _keepBoth(
    Pair pair,
    SyncAction action,
    Map<String, LocalEntry> local,
    Map<String, RemoteEntry> remote,
    List<Map<String, Object?>> rows,
  ) async {
    final path = normalizeRel(action.path);
    final l = local[pathKey(path)];
    final r = remote[pathKey(path)];
    if (l == null || r == null) {
      throw NcException('冲突路径已变化: /$path');
    }
    final now = DateTime.now();
    final stamp = '${now.year}-${_two(now.month)}-${_two(now.day)} '
        '${_two(now.hour)}${_two(now.minute)}';
    final suffix = ' (conflict $stamp from $deviceName)';
    final conflictName = '${_stem(path)}$suffix${_ext(path)}';
    var conflictPath =
        parentOf(path).isEmpty ? conflictName : '${parentOf(path)}/$conflictName';
    conflictPath = await _uniqueRemotePath(pair, conflictPath, suffix, path);

    // 1. Move the remote version aside.
    await client.move(_remotePath(pair, path), _remotePath(pair, conflictPath),
        overwrite: false);

    // 2. Upload the local version to the original path.
    final file = File(localJoin(pair.localPath, path));
    final uploaded = await client.upload(file, _remotePath(pair, path));
    final st = await file.stat();
    rows.add(_row(path,
        isDir: false,
        l: LocalEntry(
            path: path,
            isDir: false,
            size: st.size,
            mtimeMs: st.modified.millisecondsSinceEpoch),
        r: uploaded));

    // 3. Pull the remote version down next to it, keeping both copies.
    final localConflictAbs = localJoin(pair.localPath, conflictPath);
    await client.download(
        _remotePath(pair, conflictPath), File(localConflictAbs));
    final cst = await File(localConflictAbs).stat();
    final cr = await client.stat(_remotePath(pair, conflictPath));
    rows.add(_row(conflictPath,
        isDir: false,
        l: LocalEntry(
            path: conflictPath,
            isDir: false,
            size: cst.size,
            mtimeMs: cst.modified.millisecondsSinceEpoch),
        r: cr));

    await db.addConflict(
      pairId: pair.id!,
      path: path,
      kind: 'auto-both',
      detail: '${action.reason ?? '两边都修改过'}；已保留两份：/$conflictPath',
      resolved: true,
    );
    await db.log(
        pair.id, 'warn', '冲突已自动保留两份: /$path 与 /$conflictPath');
  }

  Future<String> _uniqueRemotePath(
      Pair pair, String candidate, String suffix, String original) async {
    var attempt = candidate;
    var i = 1;
    while (await client.stat(_remotePath(pair, attempt)) != null) {
      i++;
      final name = '${_stem(original)}$suffix-$i${_ext(original)}';
      attempt = parentOf(original).isEmpty
          ? name
          : '${parentOf(original)}/$name';
    }
    return attempt;
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  static String _stem(String path) {
    final name = baseName(path);
    final dot = name.lastIndexOf('.');
    return dot <= 0 ? name : name.substring(0, dot);
  }

  static String _ext(String path) {
    final name = baseName(path);
    final dot = name.lastIndexOf('.');
    return dot <= 0 ? '' : name.substring(dot);
  }

  Future<void> _ensureRemoteDir(Pair pair, String relPath) async {
    final rel = normalizeRel(relPath);
    if (rel.isEmpty) return;
    final full = _remotePath(pair, rel);
    if (_createdRemoteDirs.contains(full)) return;
    await client.mkdirs(full);
    _createdRemoteDirs.add(full);
  }

  static Map<String, Object?> _row(
    String path, {
    required bool isDir,
    LocalEntry? l,
    RemoteEntry? r,
  }) =>
      {
        'path': path,
        'is_dir': isDir ? 1 : 0,
        'etag': r?.etag,
        'remote_mtime': r?.mtimeMs,
        'remote_size': r?.size,
        'local_mtime': l?.mtimeMs,
        'local_size': l?.size,
      };
}

class _ReportBuilder {
  _ReportBuilder(this.pair);
  final Pair pair;
  int uploaded = 0;
  int downloaded = 0;
  int deleted = 0;
  int conflicts = 0;
  int errors = 0;
  String? fatalError;
  final List<String> messages = [];
  final Stopwatch _watch = Stopwatch()..start();

  String get summary => finish().summary;

  SyncReport finish() => SyncReport(
        pairId: pair.id ?? -1,
        pairName: pair.name,
        uploaded: uploaded,
        downloaded: downloaded,
        deleted: deleted,
        conflicts: conflicts,
        errors: errors,
        elapsedMs: _watch.elapsedMilliseconds,
        fatalError: fatalError,
        messages: List.unmodifiable(messages),
      );
}
