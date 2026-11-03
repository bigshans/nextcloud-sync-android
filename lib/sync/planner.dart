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
  if (!r.isDir) {
    // Size is checked first: Nextcloud derives a file's etag from its mtime,
    // which has one-second granularity, so two writes within the same second
    // can share an etag even when the content differs.
    if (b.remoteSize != null && r.size != null && b.remoteSize != r.size) {
      return true;
    }
    if (b.etag != null && r.etag != null) {
      if (b.etag != r.etag) return true;
      if (b.remoteMtimeMs != null && r.mtimeMs != null) {
        return (r.mtimeMs! - b.remoteMtimeMs!).abs() > 2000;
      }
      return false;
    }
    if (b.remoteMtimeMs != null && r.mtimeMs != null) {
      return (r.mtimeMs! - b.remoteMtimeMs!).abs() > 2000;
    }
    return true;
  }
  if (b.etag != null && r.etag != null) return b.etag != r.etag;
  return false;
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
/// The planner is pure: it makes no I/O and can be unit tested. [policy]
/// decides every ambiguous case; the result is applied immediately in the same
/// pass unless the policy is [ConflictPolicy.ask] or the situation cannot be
/// merged safely (type mismatches under keep-both/ask).
SyncPlan planSync({
  required Map<String, LocalEntry> local,
  required Map<String, RemoteEntry> remote,
  required Map<String, Baseline> baseline,
  Set<String> pendingConflicts = const {},
  bool syncDeletions = true,
  ConflictPolicy policy = ConflictPolicy.newest,
}) {
  final actions = <SyncAction>[];
  final dropKeys = <String>{};
  final dropPrefixes = <String>{};
  final skipPrefixes = <String>{...pendingConflicts};

  bool localNewer(LocalEntry l, RemoteEntry r) =>
      l.mtimeMs > (r.mtimeMs ?? 0) + 1000;
  bool remoteNewer(LocalEntry l, RemoteEntry r) =>
      (r.mtimeMs ?? 0) > l.mtimeMs + 1000;

  /// Decides who wins when both files were edited.
  SyncAction fileWinner(String path, LocalEntry l, RemoteEntry r,
      String reason) {
    switch (policy) {
      case ConflictPolicy.preferLocal:
        return SyncAction(ActionKind.upload, path, reason: reason);
      case ConflictPolicy.preferRemote:
        return SyncAction(ActionKind.download, path, reason: reason);
      case ConflictPolicy.newest:
        if (remoteNewer(l, r)) {
          return SyncAction(ActionKind.download, path, reason: '$reason（远程较新）');
        }
        if (localNewer(l, r)) {
          return SyncAction(ActionKind.upload, path, reason: '$reason（本地较新）');
        }
        return SyncAction(ActionKind.keepBoth, path,
            reason: '$reason（修改时间相同）');
      case ConflictPolicy.keepBoth:
        return SyncAction(ActionKind.keepBoth, path, reason: reason);
      case ConflictPolicy.ask:
        return SyncAction(ActionKind.needsDecision, path, reason: reason);
    }
  }

  /// The file only exists locally and was edited there, while the remote copy
  /// was deleted.
  List<SyncAction> remoteDeleted(String path, LocalEntry l, String reason) {
    switch (policy) {
      case ConflictPolicy.preferRemote:
        return [SyncAction(ActionKind.deleteLocal, path, isDir: l.isDir)];
      case ConflictPolicy.newest:
      case ConflictPolicy.preferLocal:
      case ConflictPolicy.keepBoth:
        return [
          l.isDir
              ? SyncAction(ActionKind.makeRemoteDir, path, isDir: true)
              : SyncAction(ActionKind.upload, path, reason: '$reason（保留数据）')
        ];
      case ConflictPolicy.ask:
        return [SyncAction(ActionKind.needsDecision, path, reason: reason)];
    }
  }

  /// The file only exists remotely and was edited there, while the local copy
  /// was deleted.
  List<SyncAction> localDeleted(String path, RemoteEntry r, String reason) {
    switch (policy) {
      case ConflictPolicy.preferLocal:
        return [SyncAction(ActionKind.deleteRemote, path, isDir: r.isDir)];
      case ConflictPolicy.newest:
      case ConflictPolicy.preferRemote:
      case ConflictPolicy.keepBoth:
        return [
          r.isDir
              ? SyncAction(ActionKind.makeLocalDir, path, isDir: true)
              : SyncAction(ActionKind.download, path, reason: '$reason（保留数据）')
        ];
      case ConflictPolicy.ask:
        return [SyncAction(ActionKind.needsDecision, path, reason: reason)];
    }
  }

  /// One side is a directory, the other a file.
  List<SyncAction> typeConflict(String path, LocalEntry l, RemoteEntry r) {
    bool localWins;
    switch (policy) {
      case ConflictPolicy.preferLocal:
        localWins = true;
        break;
      case ConflictPolicy.preferRemote:
        localWins = false;
        break;
      case ConflictPolicy.newest:
        if (localNewer(l, r)) {
          localWins = true;
        } else if (remoteNewer(l, r)) {
          localWins = false;
        } else {
          return [
            SyncAction(ActionKind.needsDecision, path,
                reason: '一边是目录、一边是文件，且无法判断新旧')
          ];
        }
        break;
      case ConflictPolicy.keepBoth:
      case ConflictPolicy.ask:
        return [
          SyncAction(ActionKind.needsDecision, path,
              reason: '一边是目录、一边是文件')
        ];
    }
    if (localWins) {
      return [
        SyncAction(ActionKind.deleteRemote, r.path, isDir: r.isDir),
        if (l.isDir)
          SyncAction(ActionKind.makeRemoteDir, l.path, isDir: true)
        else
          SyncAction(ActionKind.upload, l.path, reason: '按策略覆盖远程'),
      ];
    }
    return [
      SyncAction(ActionKind.deleteLocal, l.path, isDir: l.isDir),
      if (r.isDir)
        SyncAction(ActionKind.makeLocalDir, r.path, isDir: true)
      else
        SyncAction(ActionKind.download, r.path, reason: '按策略覆盖本地'),
    ];
  }

  bool skipped(String key) =>
      skipPrefixes.any((p) => p.isEmpty || key == p || key.startsWith('$p/'));

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
        actions.add(l!.isDir
            ? SyncAction(ActionKind.makeRemoteDir, path, isDir: true)
            : SyncAction(ActionKind.upload, path,
                reason: '远程已删除，按设置保留本地'));
        continue;
      }
      final changed =
          l!.isDir ? dirLocalChanged(key) : _localChanged(l, b);
      if (!changed) {
        actions.add(SyncAction(ActionKind.deleteLocal, path, isDir: l.isDir));
        if (l.isDir) {
          skipPrefixes.add(key);
          dropPrefixes.add(key);
        } else {
          dropKeys.add(key);
        }
        continue;
      }
      final resolution =
          remoteDeleted(path, l, '远程已删除，但本地有修改');
      actions.addAll(resolution);
      if (resolution.first.kind == ActionKind.needsDecision) {
        skipPrefixes.add(key);
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
      if (!changed) {
        actions.add(SyncAction(ActionKind.deleteRemote, path, isDir: r.isDir));
        if (r.isDir) {
          skipPrefixes.add(key);
          dropPrefixes.add(key);
        } else {
          dropKeys.add(key);
        }
        continue;
      }
      final resolution = localDeleted(path, r, '本地已删除，但远程有修改');
      actions.addAll(resolution);
      if (resolution.first.kind == ActionKind.needsDecision) {
        skipPrefixes.add(key);
      }
      continue;
    }

    // ------------------------------------------------------ both sides exist
    if (l.isDir != r.isDir) {
      final resolution = typeConflict(path, l, r);
      actions.addAll(resolution);
      if (resolution.first.kind == ActionKind.needsDecision) {
        skipPrefixes.add(key);
      }
      continue;
    }

    if (l.path != r.path) {
      // Same name, different letter case. Directory renames would have to be
      // applied to every descendant, so those stay manual.
      if (l.isDir) {
        actions.add(SyncAction(ActionKind.needsDecision, path,
            isDir: true,
            reason: '仅大小写不同：本地 ${l.path} / 远程 ${r.path}'));
        skipPrefixes.add(key);
        continue;
      }
      if (policy == ConflictPolicy.ask ||
          policy == ConflictPolicy.keepBoth) {
        actions.add(SyncAction(ActionKind.needsDecision, path,
            reason: '仅大小写不同：本地 ${l.path} / 远程 ${r.path}'));
        skipPrefixes.add(key);
        continue;
      }
      // Adopt the local spelling on the remote side, then settle the content
      // according to the policy.
      actions.add(SyncAction(ActionKind.renameRemote, r.path,
          newPath: l.path, reason: '统一大小写为本地名称'));
      if (_sameContent(l, r)) {
        actions.add(SyncAction(ActionKind.refresh, l.path));
      } else if (policy == ConflictPolicy.preferRemote ||
          (policy == ConflictPolicy.newest && remoteNewer(l, r))) {
        actions.add(SyncAction(ActionKind.download, l.path,
            reason: '远程内容较新'));
      } else {
        actions.add(SyncAction(ActionKind.upload, l.path,
            reason: '本地内容较新'));
      }
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
        actions.add(fileWinner(path, l, r, '两边都有新文件且内容不同'));
        if (actions.last.kind == ActionKind.needsDecision) {
          skipPrefixes.add(key);
        }
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
      actions.add(fileWinner(path, l, r, '两边都修改过'));
      if (actions.last.kind == ActionKind.needsDecision) {
        skipPrefixes.add(key);
      }
    }
  }

  return SyncPlan(
    actions: actions,
    dropKeys: dropKeys,
    dropPrefixes: dropPrefixes,
  );
}
