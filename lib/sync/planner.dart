import '../models/models.dart';

class SyncPlan {
  final List<SyncAction> actions;
  /// Baseline keys that must be dropped (path no longer exists on either side).
  final Set<String> dropKeys;
  /// Baseline prefixes that must be dropped (deleted directories).
  final Set<String> dropPrefixes;

  const SyncPlan({
    required this.actions,
    required this.dropKeys,
    required this.dropPrefixes,
  });
}

int _depth(String key) => '/'.allMatches(key).length;

bool _localChanged(LocalEntry l, Baseline b) {
  if (b.isDir != l.isDir) return true;
  if (l.isDir) {
    return b.localMtimeMs != null && b.localMtimeMs != l.mtimeMs;
  }
  return b.localSize != l.size || b.localMtimeMs != l.mtimeMs;
}

bool _remoteChanged(RemoteEntry r, Baseline b) {
  if (b.isDir != r.isDir) return true;
  if (b.etag != null && r.etag != null) return b.etag != r.etag;
  if (r.isDir) return false;
  if (b.remoteSize != null && r.size != null && b.remoteSize != r.size) {
    return true;
  }
  if (b.remoteMtimeMs != null && r.mtimeMs != null) {
    return (r.mtimeMs! - b.remoteMtimeMs!).abs() > 2000;
  }
  // Unknown: be conservative and assume it changed.
  return true;
}

bool _sameContent(LocalEntry l, RemoteEntry r) {
  if (l.isDir || r.isDir) return false;
  if (l.size != r.size) return false;
  if (r.mtimeMs == null) return false;
  // FAT/ext4 store ms, WebDAV reports seconds: allow a 2s window.
  return ((r.mtimeMs! - l.mtimeMs).abs() <= 2000);
}

/// Three-way merge of local state, remote state and the last synced baseline.
///
/// The planner is pure: it makes no I/O and can be unit tested.
SyncPlan planSync({
  required Map<String, LocalEntry> local,
  required Map<String, RemoteEntry> remote,
  required Map<String, Baseline> baseline,
  Set<String> pendingConflicts = const {},
  bool syncDeletions = true,
}) {
  final actions = <SyncAction>[];
  final dropKeys = <String>{};
  final dropPrefixes = <String>{};
  final skipPrefixes = <String>{...pendingConflicts};

  /// A directory itself has no meaningful mtime: it changes when children are
  /// added/removed, including when *we* delete them. Consider a directory
  /// locally modified only when it contains a child that is new or edited
  /// compared to the baseline.
  bool dirLocalChanged(String dirKey) {
    final prefix = '$dirKey/';
    for (final entry in local.entries) {
      if (!entry.key.startsWith(prefix)) continue;
      final b = baseline[entry.key];
      if (b == null) return true;
      if (_localChanged(entry.value, b)) return true;
    }
    return false;
  }

  bool skipped(String key) =>
      skipPrefixes.any((p) => p.isEmpty || key == p || key.startsWith('$p/'));

  final keys = <String>{...local.keys, ...remote.keys, ...baseline.keys}
      .toList()
    ..sort((a, b) {
      final d = _depth(a).compareTo(_depth(b));
      return d != 0 ? d : a.compareTo(b);
    });

  for (final key in keys) {
    if (skipped(key)) continue;
    final l = local[key];
    final r = remote[key];
    final b = baseline[key];
    final path = l?.path ?? r?.path ?? b!.path;

    // -------------------------------------------------- gone from both sides
    if (l == null && r == null) {
      dropKeys.add(key);
      if (b != null && b.isDir) dropPrefixes.add(key);
      continue;
    }

    // ------------------------------------------------------- only local side
    if (r == null) {
      if (b == null) {
        actions.add(l!.isDir
            ? SyncAction(ActionKind.makeRemoteDir, path, isDir: true)
            : SyncAction(ActionKind.upload, path));
        continue;
      }
      if (!syncDeletions) {
        // Deletion propagation disabled: re-create the remote side.
        actions.add(l!.isDir
            ? SyncAction(ActionKind.makeRemoteDir, path, isDir: true)
            : SyncAction(ActionKind.upload, path,
                reason: '远程已删除，按设置保留本地'));
        continue;
      }
      final changed =
          l!.isDir ? dirLocalChanged(key) : _localChanged(l, b);
      if (changed) {
        actions.add(SyncAction(ActionKind.needsDecision, path,
            isDir: l.isDir, reason: '远程已删除，但本地有修改'));
        skipPrefixes.add(key);
      } else {
        actions.add(SyncAction(ActionKind.deleteLocal, path, isDir: l.isDir));
        if (l.isDir) {
          skipPrefixes.add(key);
          dropPrefixes.add(key);
        } else {
          dropKeys.add(key);
        }
      }
      continue;
    }

    // ------------------------------------------------------ only remote side
    if (l == null) {
      if (b == null) {
        actions.add(r.isDir
            ? SyncAction(ActionKind.makeLocalDir, path, isDir: true)
            : SyncAction(ActionKind.download, path));
        continue;
      }
      if (!syncDeletions) {
        actions.add(r.isDir
            ? SyncAction(ActionKind.makeLocalDir, path, isDir: true)
            : SyncAction(ActionKind.download, path,
                reason: '本地已删除，按设置保留远程'));
        continue;
      }
      final changed = _remoteChanged(r, b);
      if (changed) {
        actions.add(SyncAction(ActionKind.needsDecision, path,
            isDir: r.isDir, reason: '本地已删除，但远程有修改'));
        skipPrefixes.add(key);
      } else {
        actions.add(SyncAction(ActionKind.deleteRemote, path, isDir: r.isDir));
        if (r.isDir) {
          skipPrefixes.add(key);
          dropPrefixes.add(key);
        } else {
          dropKeys.add(key);
        }
      }
      continue;
    }

    // ------------------------------------------------------ both sides exist
    if (l.isDir != r.isDir) {
      actions.add(SyncAction(ActionKind.needsDecision, path,
          reason: '一边是目录、一边是文件'));
      skipPrefixes.add(key);
      continue;
    }
    if (l.path != r.path) {
      actions.add(SyncAction(ActionKind.needsDecision, path,
          isDir: l.isDir, reason: '仅大小写不同：本地 ${l.path} / 远程 ${r.path}'));
      skipPrefixes.add(key);
      continue;
    }
    if (l.isDir) {
      // Directories converge through their children; only keep the etag fresh.
      actions.add(SyncAction(ActionKind.refresh, path, isDir: true));
      continue;
    }

    if (b == null) {
      if (_sameContent(l, r)) {
        actions.add(SyncAction(ActionKind.refresh, path));
      } else {
        actions.add(SyncAction(ActionKind.keepBoth, path,
            reason: '两边都有新文件且内容不同'));
      }
      continue;
    }

    final localChanged = _localChanged(l, b);
    final remoteChanged = _remoteChanged(r, b);
    if (!localChanged && !remoteChanged) {
      actions.add(SyncAction(ActionKind.refresh, path));
    } else if (localChanged && !remoteChanged) {
      actions.add(SyncAction(ActionKind.upload, path));
    } else if (!localChanged && remoteChanged) {
      actions.add(SyncAction(ActionKind.download, path));
    } else if (_sameContent(l, r)) {
      actions.add(SyncAction(ActionKind.refresh, path));
    } else {
      actions.add(SyncAction(ActionKind.keepBoth, path,
          reason: '两边都修改过'));
    }
  }

  return SyncPlan(
    actions: actions,
    dropKeys: dropKeys,
    dropPrefixes: dropPrefixes,
  );
}
