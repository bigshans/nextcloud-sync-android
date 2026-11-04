import 'dart:async';
import 'dart:io';

import '../models/models.dart';
import '../nextcloud/client.dart';
import '../store/db.dart';
import '../util/paths.dart';
import 'conflict_name.dart';
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
    this.concurrency = 8,
    this.conflictPolicy = ConflictPolicy.newest,
    this.fastScan = true,
    this.turboScan = false,
    this.turboFullScanMinutes = 60,
  });

  final AppDb db;
  final NcClient client;
  final String deviceName;
  final int concurrency;

  /// Single rule applied to every ambiguous case.
  final ConflictPolicy conflictPolicy;

  /// Reuse cached remote listings for directories whose etag did not change.
  final bool fastScan;

  /// Trust cached local directory mtimes (极速模式).
  final bool turboScan;
  final int turboFullScanMinutes;

  static bool _isUpload(ActionKind k) => k == ActionKind.upload;

  static bool _isTransfer(ActionKind k) =>
      k == ActionKind.upload ||
      k == ActionKind.download ||
      k == ActionKind.keepBoth;

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
    bool fullScan = false,
    SyncCancelToken? cancel,
  }) async {
    final report = _ReportBuilder(pair);
    final active = <String, ActiveTransfer>{};
    var lastDone = 0;
    var lastTotal = 0;
    var lastPhase = '准备';
    var lastEmit = 0;

    void emit({bool force = false}) {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (!force && now - lastEmit < 150) return;
      lastEmit = now;
      onProgress?.call(SyncProgress(
        phase: lastPhase,
        done: lastDone,
        total: lastTotal,
        current: active.values.isEmpty ? null : active.values.first.path,
        pairName: pair.name,
        active: active.values.map((a) => ActiveTransfer(
              a.path,
              a.kind,
              a.done,
              a.total,
            )).toList(),
        uploaded: report.uploaded,
        downloaded: report.downloaded,
        deleted: report.deleted,
        failed: report.errors,
      ));
    }

    void progress(String phase, {int done = 0, int total = 0, String? current}) {
      lastPhase = phase;
      if (done > 0) lastDone = done;
      if (total > 0) lastTotal = total;
      emit(force: true);
    }

    try {
      progress('准备');
      _createdRemoteDirs.clear();
      await db.log(pair.id, 'debug',
          '传输协议: ${client.usingHttp2 ? 'HTTP/2 (Cronet)' : 'HTTP/1.1 (dart:io)'}');
      final root = pair.localPath;
      if (!await Directory(root).exists()) {
        await Directory(root).create(recursive: true);
      }

      // 1. The remote root must exist, and its etag tells us whether anything
      // below it changed at all.
      var rootEntry = await client.stat(pair.remotePath);
      if (rootEntry == null) {
        await client.mkdirs(pair.remotePath);
        rootEntry = await client.stat(pair.remotePath);
      }
      final rootEtagKey = 'root_etag_${pair.id}';
      final cachedRootEtag = await db.getSetting(rootEtagKey);

      // 2. Scan both sides. The last baseline doubles as a remote cache so
      // unchanged directory subtrees can be skipped entirely.
      final baseline = await db.loadBaselines(pair.id!);
      Map<String, RemoteEntry> remote;
      final rootUnchanged = fastScan &&
          rootEntry?.etag != null &&
          cachedRootEtag == rootEntry!.etag &&
          baseline.isNotEmpty;
      if (rootUnchanged) {
        // Nothing changed anywhere below the pair root: reuse the last
        // snapshot instead of listing the tree.
        remote = {
          for (final b in baseline.values)
            pathKey(b.path): RemoteEntry(
              path: b.path,
              isDir: b.isDir,
              etag: b.etag,
              mtimeMs: b.remoteMtimeMs,
              size: b.remoteSize,
            ),
        };
        await db.log(pair.id, 'debug', '远程根 etag 未变，跳过目录扫描');
        progress('扫描远程', done: remote.length);
      } else {
        progress('扫描远程');
        remote = await _scanRemote(pair, progress, cancel, baseline);
        if (report.errors == 0 && cancel?.isPaused != true) {
          await db.setSetting(rootEtagKey, rootEntry?.etag);
        }
      }
      if (cancel?.isPaused == true) {
        report.paused = true;
        return report.finish();
      }
      // 极速模式: reuse cached subtrees whose directory mtime is unchanged.
      // A full scan is forced periodically (and on demand) so edits that do
      // not touch the parent folder's mtime are still picked up eventually.
      final lastFullKey = 'last_full_scan_${pair.id}';
      final cleanKey = 'index_clean_${pair.id}';
      final lastFull = int.tryParse(await db.getSetting(lastFullKey) ?? '') ?? 0;
      final indexClean = (await db.getSetting(cleanKey) ?? '0') == '1';
      final turboDue = turboScan &&
          !fullScan &&
          indexClean &&
          DateTime.now().millisecondsSinceEpoch - lastFull <
              turboFullScanMinutes * 60 * 1000;

      progress('扫描本地');
      final localScanWatch = Stopwatch()..start();
      final localScan = await scanLocal(
        root,
        turbo: turboDue,
        cache: baseline,
        onCount: (c) {
          progress('扫描本地', done: c);
        },
      );
      localScanWatch.stop();
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
      // With an automatic policy, previously deferred conflicts are re-planned
      // and settled in this pass instead of blocking forever.
      final pending = conflictPolicy == ConflictPolicy.ask
          ? await db.pendingConflictPaths(pair.id!)
          : const <String>{};
      final plan = planSync(
        local: localScan.entries,
        remote: remote,
        baseline: baseline,
        pendingConflicts: pending,
        policy: conflictPolicy,
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

      // 5. Execute. File transfers run in parallel; structural changes
      // (mkdir/delete/rename) act as barriers so ordering stays correct.
      var done = 0;
      final total = plan.actions.length;
      final rows = <Map<String, Object?>>[];
      final dropKeys = <String>{...plan.dropKeys};
      final dropPrefixes = <String>{...plan.dropPrefixes};
      var fatal = false;

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

      Future<void> onError(SyncAction action, Object e) async {
        report.errors++;
        await db.log(pair.id, 'error',
            '${_verb(action.kind)} /${action.path} 失败: $e');
        if (e is NcException && e.isAuth) {
          report.fatalError = '认证失败，请重新登录';
          fatal = true;
        }
      }

      Future<void> run(SyncAction action) async {
        switch (action.kind) {
          case ActionKind.upload:
            final becameDownload = await _doUpload(
                pair, action, baseline, rows, dropKeys,
                onBytes: (done, total) {
              final t = active['upload|${action.path}'];
              if (t != null) {
                t.done = done;
                t.total = total;
                emit();
              }
            });
            if (becameDownload) {
              report.downloaded++;
            } else {
              report.uploaded++;
            }
            emit(force: true);
            break;
          case ActionKind.download:
            await _doDownload(pair, action, remote, rows, dropKeys,
                onBytes: (done, total) {
              final t = active['download|${action.path}'];
              if (t != null) {
                t.done = done;
                t.total = total;
                emit();
              }
            });
            report.downloaded++;
            emit(force: true);
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
                isDir: true, r: remote[pathKey(action.path)]));
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
            // Rewriting an unchanged baseline row is pure overhead: with very
            // large trees this used to cost tens of thousands of DB upserts on
            // every sync. Only write when something actually differs.
            final key = pathKey(action.path);
            final b = baseline[key];
            final l = localScan.entries[key];
            final r = remote[key];
            final unchanged = b != null &&
                b.isDir == action.isDir &&
                b.etag == r?.etag &&
                b.localMtimeMs == l?.mtimeMs &&
                (action.isDir ||
                    (b.localSize == l?.size && b.remoteSize == r?.size));
            if (!unchanged) {
              rows.add(_row(action.path,
                  isDir: action.isDir, l: l, r: r));
            }
            break;
          case ActionKind.renameRemote:
            await _renameRemote(pair, action, localScan.entries, remote, rows,
                dropKeys);
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
      }

      final pool = _TaskPool(concurrency);
      for (final action in plan.actions) {
        if (fatal || cancel?.isPaused == true) break;
        if (_isTransfer(action.kind)) {
          await pool.acquire();
          if (fatal || cancel?.isPaused == true) {
            pool.releaseIdle();
            break;
          }
          final key =
              '${_isUpload(action.kind) ? 'upload' : 'download'}|${action.path}';
          active[key] = ActiveTransfer(action.path, _verb(action.kind));
          pool.submit(() async {
            progress('同步',
                done: done,
                total: total,
                current: '${_verb(action.kind)} /${action.path}');
            try {
              await run(action);
            } catch (e) {
              await onError(action, e);
              emit(force: true);
            }
            active.remove(key);
            done++;
            emit(force: true);
          });
        } else {
          // Ordering barrier: let queued transfers finish first.
          await pool.drain();
          if (fatal || cancel?.isPaused == true) break;
          progress('同步',
              done: done,
              total: total,
              current: '${_verb(action.kind)} /${action.path}');
          try {
            await run(action);
          } catch (e) {
            await onError(action, e);
          }
          done++;
          if (rows.length >= 400 ||
              dropKeys.length + dropPrefixes.length >= 400) {
            await flush();
          }
        }
      }
      await pool.drain();
      await flush();
      if (cancel?.isPaused == true) {
        report.paused = true;
        report.processed = done;
        report.total = total;
        await db.log(pair.id, 'info', '同步已暂停（$done/$total）');
        progress('已暂停', done: done, total: total);
        return report.finish();
      }
      if (conflictPolicy != ConflictPolicy.ask && report.errors == 0) {
        // Everything that needed a decision has been settled by the policy.
        await db.resolveAllConflicts(pair.id!);
      }
      report.processed = total;
      report.total = total;
      progress('完成', done: total, total: total);

      if (report.errors == 0 && report.fatalError == null) {
        await db.setPairResult(pair.id!,
            DateTime.now().millisecondsSinceEpoch, report.summary);
      } else {
        await db.setPairResult(pair.id!, null, report.summary);
      }
      if (report.errors == 0) {
        await db.setSetting(cleanKey, '1');
        if (!turboDue) {
          await db.setSetting(lastFullKey, '${DateTime.now().millisecondsSinceEpoch}');
        }
      } else {
        await db.setSetting(cleanKey, '0');
      }
      await db.log(
          pair.id,
          'info',
          '同步完成：${report.summary}'
              '（本地扫描${turboDue ? '·极速' : ''} '
              '${localScanWatch.elapsedMilliseconds}ms，'
              '共 ${localScan.entries.length} 项）');
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
        ActionKind.renameRemote => '统一大小写',
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
    SyncCancelToken? cancel,
    Map<String, Baseline> cache,
  ) async {
    final out = <String, RemoteEntry>{};
    final rootPrefix = normalizeRel(pair.remotePath);
    final queue = <String>[rootPrefix];
    var listed = 0;
    var reusedDirs = 0;

    String toRelative(String full) {
      if (rootPrefix.isEmpty) return full;
      if (full == rootPrefix) return '';
      if (full.startsWith('$rootPrefix/')) {
        return full.substring(rootPrefix.length + 1);
      }
      return full;
    }

    // Cache grouped by parent for cheap expansion of skipped subtrees.
    final cachedChildren = <String, List<Baseline>>{};
    for (final b in cache.values) {
      cachedChildren.putIfAbsent(parentOf(b.path), () => []).add(b);
    }

    void addCachedSubtree(String dirRel) {
      final stack = <String>[normalizeRel(dirRel)];
      while (stack.isNotEmpty) {
        final dir = stack.removeLast();
        for (final b in cachedChildren[dir] ?? const <Baseline>[]) {
          out[pathKey(b.path)] = RemoteEntry(
            path: b.path,
            isDir: b.isDir,
            etag: b.etag,
            mtimeMs: b.remoteMtimeMs,
            size: b.remoteSize,
          );
          if (b.isDir) stack.add(b.path);
        }
      }
    }

    while (queue.isNotEmpty) {
      if (cancel?.isPaused == true) break;
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
          if (e.isDir) {
            // Nextcloud bumps a folder's etag when anything below it changes,
            // so an unchanged etag means the whole subtree is unchanged.
            final cached = cache[key];
            final canReuse = fastScan &&
                cached != null &&
                cached.isDir &&
                cached.etag != null &&
                e.etag != null &&
                cached.etag == e.etag;
            if (canReuse) {
              addCachedSubtree(rel);
              reusedDirs++;
            } else {
              queue.add(e.path);
            }
          }
        }
        listed++;
      }
      progress('扫描远程', done: out.length);
    }
    await db.log(
        pair.id,
        'debug',
        '远程扫描完成：请求 $listed 个目录，复用 $reusedDirs 个未变更目录，'
            '共 ${out.length} 项');
    return out;
  }

  // ------------------------------------------------------------- file actions

  /// Returns true when the file ended up being downloaded instead (a 412 was
  /// resolved in favour of the remote version).
  Future<bool> _doUpload(
    Pair pair,
    SyncAction action,
    Map<String, Baseline> baseline,
    List<Map<String, Object?>> rows,
    Set<String> dropKeys, {
    void Function(int done, int total)? onBytes,
  }) async {
    final path = normalizeRel(action.path);
    final abs = localJoin(pair.localPath, path);
    final file = File(abs);
    if (!await file.exists()) {
      throw NcException('本地文件不存在: /$path');
    }
    await _ensureRemoteDir(pair, parentOf(path));
    final base = baseline[pathKey(path)];
    final ifMatch = base != null && !base.isDir ? base.etag : null;
    RemoteEntry? r;
    var becameDownload = false;
    try {
      r = await client.upload(file, _remotePath(pair, path),
          ifMatch: ifMatch, onProgress: onBytes);
    } on NcException catch (e) {
      // 412 = the remote file changed since our last sync. Resolve it right
      // away with the configured policy instead of failing and retrying on
      // every later pass (that produced a storm of 412s before).
      if (e.statusCode != 412) rethrow;
      r = await _recoverFrom412(pair, path, file,
          onBytes: onBytes,
          onDownloaded: () {
            becameDownload = true;
          });
      if (r == null) {
        throw NcException('冲突处理失败: /$path', statusCode: 412);
      }
    }
    final st = await file.stat();
    rows.add(_row(path,
        isDir: false,
        l: LocalEntry(
            path: path,
            isDir: false,
            size: st.size,
            mtimeMs: st.modified.millisecondsSinceEpoch),
        r: r));
    dropKeys.remove(pathKey(path));
    return becameDownload;
  }

  /// Reconciles a failed conditional upload (HTTP 412).
  Future<RemoteEntry?> _recoverFrom412(
    Pair pair,
    String path,
    File file, {
    void Function(int done, int total)? onBytes,
    required void Function() onDownloaded,
  }) async {
    final remotePath = _remotePath(pair, path);
    final remoteNow = await client.stat(remotePath);
    final st = await file.stat();
    if (remoteNow == null) {
      // The remote copy vanished: just upload.
      return client.upload(file, remotePath, onProgress: onBytes);
    }
    final sameSize = remoteNow.size != null && remoteNow.size == st.size;
    final mtimeClose = remoteNow.mtimeMs == null ||
        (remoteNow.mtimeMs! - st.modified.millisecondsSinceEpoch).abs() <=
            2000;
    if (sameSize && mtimeClose) {
      // Our earlier attempt actually landed (e.g. a retry after a timeout).
      await db.log(
          pair.id, 'debug', '上传 /$path 返回 412，但远端内容一致，按已上传处理');
      return remoteNow;
    }
    final remoteIsNewer = remoteNow.mtimeMs != null &&
        remoteNow.mtimeMs! > st.modified.millisecondsSinceEpoch + 1000;
    final keepRemote = conflictPolicy == ConflictPolicy.preferRemote ||
        (conflictPolicy == ConflictPolicy.newest && remoteIsNewer);
    if (keepRemote) {
      await client.download(remotePath, file);
      onDownloaded();
      await db.log(pair.id, 'info', '上传 /$path 冲突（412），按策略保留远程版本');
      return remoteNow;
    }
    await db.log(pair.id, 'info', '上传 /$path 返回 412，按策略覆盖远程');
    return client.upload(file, remotePath, onProgress: onBytes);
  }

  Future<void> _doDownload(
    Pair pair,
    SyncAction action,
    Map<String, RemoteEntry> remote,
    List<Map<String, Object?>> rows,
    Set<String> dropKeys, {
    void Function(int done, int total)? onBytes,
  }) async {
    final path = normalizeRel(action.path);
    final abs = localJoin(pair.localPath, path);
    final file = File(abs);
    final etag = await client.download(_remotePath(pair, path), file,
        onProgress: onBytes);
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

  /// Renames the remote entry to the local spelling (case-only differences).
  Future<void> _renameRemote(
    Pair pair,
    SyncAction action,
    Map<String, LocalEntry> local,
    Map<String, RemoteEntry> remote,
    List<Map<String, Object?>> rows,
    Set<String> dropKeys,
  ) async {
    final from = normalizeRel(action.path);
    final to = normalizeRel(action.newPath ?? action.path);
    await client.move(_remotePath(pair, from), _remotePath(pair, to));
    dropKeys.add(pathKey(from));
    final r = await client.stat(_remotePath(pair, to));
    final l = local[pathKey(to)];
    if (r != null) {
      rows.add(_row(to,
          isDir: r.isDir,
          l: l,
          r: RemoteEntry(
            path: to,
            isDir: r.isDir,
            etag: r.etag,
            mtimeMs: r.mtimeMs,
            size: r.size,
          )));
    }
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
    // Same naming convention as the official Nextcloud clients:
    //   name (conflicted copy <device> yyyy-MM-dd hhmmss).ext
    var conflictPath = parentOf(path).isEmpty
        ? conflictFileName(path, deviceName, now)
        : conflictFileName(path, deviceName, now);
    conflictPath = await _uniqueRemotePath(pair, conflictPath, path);

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
      Pair pair, String candidate, String original) async {
    var attempt = candidate;
    var i = 1;
    while (await client.stat(_remotePath(pair, attempt)) != null) {
      i++;
      attempt = conflictFileName(original, deviceName, DateTime.now(),
          sequence: i);
    }
    return attempt;
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
  bool paused = false;
  int processed = 0;
  int total = 0;
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
        paused: paused,
        processed: processed,
        total: total,
        messages: List.unmodifiable(messages),
      );
}

/// Runs up to [size] async tasks concurrently. [acquire] applies backpressure
/// so the producer can keep the pipeline full while still honouring a pause
/// request within one transfer.
class _TaskPool {
  _TaskPool(this.size);
  final int size;
  int _active = 0;
  final List<Completer<void>> _waiters = [];
  Completer<void>? _idle;

  Future<void> acquire() {
    if (_active < size) {
      _active++;
      return Future<void>.value();
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    return completer.future;
  }

  /// Gives back a slot that was acquired but never used.
  void releaseIdle() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
      return;
    }
    _active--;
    if (_active == 0) {
      _idle?.complete();
      _idle = null;
    }
  }

  void submit(Future<void> Function() task) {
    Future<void>(() async {
      try {
        await task();
      } catch (_) {
        // Errors are handled inside the task itself.
      }
    }).whenComplete(() {
      if (_waiters.isNotEmpty) {
        // Hand the slot directly to the next waiting task.
        _waiters.removeAt(0).complete();
      } else {
        _active--;
        if (_active == 0) {
          _idle?.complete();
          _idle = null;
        }
      }
    });
  }

  Future<void> drain() {
    if (_active == 0) return Future<void>.value();
    _idle ??= Completer<void>();
    return _idle!.future;
  }
}
