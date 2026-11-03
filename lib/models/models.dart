import 'package:flutter/foundation.dart';

/// A sync pair: one local directory mirrored to one remote directory.
class Pair {
  final int? id;
  final String name;
  final String localPath;
  final String remotePath; // relative to /remote.php/dav/files/<user>/, no leading slash
  final bool enabled;
  final int createdAt;
  final int? lastSyncAt;
  final String? lastResult;

  const Pair({
    this.id,
    required this.name,
    required this.localPath,
    required this.remotePath,
    this.enabled = true,
    required this.createdAt,
    this.lastSyncAt,
    this.lastResult,
  });

  Pair copyWith({
    int? id,
    String? name,
    String? localPath,
    String? remotePath,
    bool? enabled,
    int? lastSyncAt,
    String? lastResult,
  }) =>
      Pair(
        id: id ?? this.id,
        name: name ?? this.name,
        localPath: localPath ?? this.localPath,
        remotePath: remotePath ?? this.remotePath,
        enabled: enabled ?? this.enabled,
        createdAt: createdAt,
        lastSyncAt: lastSyncAt ?? this.lastSyncAt,
        lastResult: lastResult ?? this.lastResult,
      );

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'name': name,
        'local_path': localPath,
        'remote_path': remotePath,
        'enabled': enabled ? 1 : 0,
        'created_at': createdAt,
        'last_sync_at': lastSyncAt,
        'last_result': lastResult,
      };

  static Pair fromMap(Map<String, Object?> m) => Pair(
        id: m['id'] as int?,
        name: m['name'] as String,
        localPath: m['local_path'] as String,
        remotePath: m['remote_path'] as String,
        enabled: (m['enabled'] as int? ?? 1) == 1,
        createdAt: m['created_at'] as int? ?? 0,
        lastSyncAt: m['last_sync_at'] as int?,
        lastResult: m['last_result'] as String?,
      );
}

class RemoteEntry {
  final String path;
  final bool isDir;
  final String? etag;
  final int? mtimeMs;
  final int? size;

  const RemoteEntry({
    required this.path,
    required this.isDir,
    this.etag,
    this.mtimeMs,
    this.size,
  });

  @override
  String toString() => 'R($path, dir=$isDir, etag=$etag, size=$size)';
}

class LocalEntry {
  final String path;
  final bool isDir;
  final int size;
  final int mtimeMs;
  final bool isLink;

  const LocalEntry({
    required this.path,
    required this.isDir,
    required this.size,
    required this.mtimeMs,
    this.isLink = false,
  });

  @override
  String toString() => 'L($path, dir=$isDir, size=$size, mtime=$mtimeMs)';
}

/// Last synced state of a path, used as the three-way merge base.
class Baseline {
  final String path;
  final bool isDir;
  final String? etag;
  final int? remoteMtimeMs;
  final int? remoteSize;
  final int? localMtimeMs;
  final int? localSize;

  const Baseline({
    required this.path,
    required this.isDir,
    this.etag,
    this.remoteMtimeMs,
    this.remoteSize,
    this.localMtimeMs,
    this.localSize,
  });
}

/// How conflicting changes are settled. A single rule is applied consistently,
/// and the result is applied in the same sync pass (no pending questions),
/// except for [ConflictPolicy.ask] and cases that cannot be merged safely.
enum ConflictPolicy {
  /// Newest modification wins (falls back to keeping both on a tie).
  newest,

  /// The device version always wins.
  preferLocal,

  /// The server version always wins.
  preferRemote,

  /// Keep both copies with a conflict suffix.
  keepBoth,

  /// Ask the user per file (shows up in the conflicts list).
  ask,
}

enum ActionKind {
  upload,
  download,
  deleteLocal,
  deleteRemote,
  makeLocalDir,
  makeRemoteDir,
  /// Content identical on both sides (or both directories): only refresh baseline.
  refresh,
  /// Both sides changed: keep both copies.
  keepBoth,
  /// The same file on both sides differs only in the letter case; rename the
  /// remote copy to the local spelling so both sides converge.
  renameRemote,
  /// Cannot be decided automatically; needs a user decision.
  needsDecision,
  /// Both sides are gone; just drop the stored baseline.
  forget,
}

class SyncAction {
  final ActionKind kind;
  final String path;
  final bool isDir;
  final String? reason;

  /// Target path for rename actions.
  final String? newPath;

  const SyncAction(this.kind, this.path,
      {this.isDir = false, this.reason, this.newPath});

  @override
  String toString() => '$kind($path)${reason == null ? '' : ' [$reason]'}';
}

class ConflictRow {
  final int id;
  final int pairId;
  final String path;
  final String kind;
  final String? detail;
  final int createdAt;
  final int resolved;

  const ConflictRow({
    required this.id,
    required this.pairId,
    required this.path,
    required this.kind,
    this.detail,
    required this.createdAt,
    required this.resolved,
  });
}

class LogRow {
  final int id;
  final int? pairId;
  final int ts;
  final String level;
  final String message;
  const LogRow({
    required this.id,
    required this.pairId,
    required this.ts,
    required this.level,
    required this.message,
  });
}

class SyncReport {
  final int pairId;
  final String pairName;
  final int uploaded;
  final int downloaded;
  final int deleted;
  final int conflicts;
  final int errors;
  final int elapsedMs;
  final String? fatalError;
  final bool paused;
  final int processed;
  final int total;
  final List<String> messages;

  const SyncReport({
    required this.pairId,
    required this.pairName,
    this.uploaded = 0,
    this.downloaded = 0,
    this.deleted = 0,
    this.conflicts = 0,
    this.errors = 0,
    this.elapsedMs = 0,
    this.fatalError,
    this.paused = false,
    this.processed = 0,
    this.total = 0,
    this.messages = const [],
  });

  bool get ok => fatalError == null;

  String get summary {
    if (fatalError != null) return '失败：$fatalError';
    if (paused) {
      return '已暂停（$processed/$total），可随时继续';
    }
    if (uploaded + downloaded + deleted + conflicts + errors == 0) {
      return '已是最新';
    }
    final parts = <String>[
      if (uploaded > 0) '上传 $uploaded',
      if (downloaded > 0) '下载 $downloaded',
      if (deleted > 0) '删除 $deleted',
      if (conflicts > 0) '冲突 $conflicts',
      if (errors > 0) '错误 $errors',
    ];
    return parts.join('，');
  }
}

/// Cooperative pause token shared between the UI and the sync engine.
class SyncCancelToken {
  bool _paused = false;
  bool _cancelled = false;

  bool get isPaused => _paused;
  bool get isCancelled => _cancelled;

  void pause() => _paused = true;
  void cancel() {
    _cancelled = true;
    _paused = true;
  }
}

class SyncProgress {
  final String phase;
  final int done;
  final int total;
  final String? current;
  final String? pairName;
  const SyncProgress({
    required this.phase,
    this.done = 0,
    this.total = 0,
    this.current,
    this.pairName,
  });
  double? get fraction => total > 0 ? done / total : null;
}

@immutable
class AppSettings {
  final String deviceName;
  final int intervalMinutes;
  final bool wifiOnly;
  final bool notify;
  final ConflictPolicy conflictPolicy;
  final bool fastScan;
  final bool autoBackup;

  const AppSettings({
    this.deviceName = 'Android',
    this.intervalMinutes = 15,
    this.wifiOnly = false,
    this.notify = true,
    this.conflictPolicy = ConflictPolicy.newest,
    this.fastScan = true,
    this.autoBackup = true,
  });

  AppSettings copyWith({
    String? deviceName,
    int? intervalMinutes,
    bool? wifiOnly,
    bool? notify,
    ConflictPolicy? conflictPolicy,
    bool? fastScan,
    bool? autoBackup,
  }) =>
      AppSettings(
        deviceName: deviceName ?? this.deviceName,
        intervalMinutes: intervalMinutes ?? this.intervalMinutes,
        wifiOnly: wifiOnly ?? this.wifiOnly,
        notify: notify ?? this.notify,
        conflictPolicy: conflictPolicy ?? this.conflictPolicy,
        fastScan: fastScan ?? this.fastScan,
        autoBackup: autoBackup ?? this.autoBackup,
      );
}
