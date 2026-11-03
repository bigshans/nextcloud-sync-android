import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/models.dart';
import '../util/paths.dart';

class AppDb {
  AppDb._({this.directory});
  static final AppDb instance = AppDb._();

  /// Overrides the database directory (used by host side tests).
  static AppDb withDirectory(String dir) => AppDb._(directory: dir);

  final String? directory;

  Database? _db;
  Future<Database>? _opening;

  Future<Database> get db async {
    if (_db != null) return _db!;
    return _opening ??= _open();
  }

  Future<Database> _open() async {
    final dir = directory ?? await getDatabasesPath();
    final path = p.join(dir, 'ncsync.db');
    final database = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
CREATE TABLE pairs(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  local_path TEXT NOT NULL,
  remote_path TEXT NOT NULL,
  enabled INTEGER NOT NULL DEFAULT 1,
  created_at INTEGER NOT NULL,
  last_sync_at INTEGER,
  last_result TEXT
)''');
        await db.execute('''
CREATE TABLE file_state(
  pair_id INTEGER NOT NULL,
  path TEXT NOT NULL,
  path_key TEXT NOT NULL,
  is_dir INTEGER NOT NULL,
  etag TEXT,
  remote_mtime INTEGER,
  remote_size INTEGER,
  local_mtime INTEGER,
  local_size INTEGER,
  synced_at INTEGER NOT NULL,
  PRIMARY KEY(pair_id, path_key)
)''');
        await db.execute('''
CREATE TABLE conflicts(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  pair_id INTEGER NOT NULL,
  path TEXT NOT NULL,
  path_key TEXT NOT NULL,
  kind TEXT NOT NULL,
  detail TEXT,
  created_at INTEGER NOT NULL,
  resolved INTEGER NOT NULL DEFAULT 0
)''');
        await db.execute(
            'CREATE INDEX idx_conflicts ON conflicts(pair_id, resolved)');
        await db.execute('''
CREATE TABLE logs(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  pair_id INTEGER,
  ts INTEGER NOT NULL,
  level TEXT NOT NULL,
  message TEXT NOT NULL
)''');
        await db.execute('CREATE INDEX idx_logs ON logs(ts)');
        await db.execute(
            'CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT)');
      },
    );
    _db = database;
    return database;
  }

  // ---------------------------------------------------------------- settings

  Future<String?> getSetting(String key) async {
    final d = await db;
    final rows = await d.query('settings',
        columns: ['value'], where: 'key = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> setSetting(String key, String? value) async {
    final d = await db;
    if (value == null) {
      await d.delete('settings', where: 'key = ?', whereArgs: [key]);
    } else {
      await d.insert('settings', {'key': key, 'value': value},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  // ------------------------------------------------------------------- pairs

  Future<List<Pair>> listPairs() async {
    final d = await db;
    final rows = await d.query('pairs', orderBy: 'created_at ASC');
    return rows.map(Pair.fromMap).toList();
  }

  Future<Pair?> getPair(int id) async {
    final d = await db;
    final rows =
        await d.query('pairs', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Pair.fromMap(rows.first);
  }

  Future<int> insertPair(Pair pair) async {
    final d = await db;
    return d.insert('pairs', pair.toMap());
  }

  Future<void> updatePair(Pair pair) async {
    final d = await db;
    await d.update('pairs', pair.toMap(),
        where: 'id = ?', whereArgs: [pair.id]);
  }

  Future<void> deletePair(int id) async {
    final d = await db;
    await d.transaction((txn) async {
      await txn.delete('file_state', where: 'pair_id = ?', whereArgs: [id]);
      await txn.delete('conflicts', where: 'pair_id = ?', whereArgs: [id]);
      await txn.delete('logs', where: 'pair_id = ?', whereArgs: [id]);
      await txn.delete('pairs', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<void> setPairResult(int id, int? syncAt, String result) async {
    final d = await db;
    await d.update(
        'pairs', {'last_sync_at': syncAt, 'last_result': result},
        where: 'id = ?', whereArgs: [id]);
  }

  // --------------------------------------------------------------- baselines

  Future<Map<String, Baseline>> loadBaselines(int pairId) async {
    final d = await db;
    final rows = await d.query('file_state',
        columns: [
          'path',
          'is_dir',
          'etag',
          'remote_mtime',
          'remote_size',
          'local_mtime',
          'local_size',
        ],
        where: 'pair_id = ?',
        whereArgs: [pairId]);
    final out = <String, Baseline>{};
    for (final r in rows) {
      final path = r['path'] as String;
      out[pathKey(path)] = Baseline(
        path: path,
        isDir: (r['is_dir'] as int? ?? 0) == 1,
        etag: r['etag'] as String?,
        remoteMtimeMs: r['remote_mtime'] as int?,
        remoteSize: r['remote_size'] as int?,
        localMtimeMs: r['local_mtime'] as int?,
        localSize: r['local_size'] as int?,
      );
    }
    return out;
  }

  Future<void> saveBaselines(
      int pairId, Iterable<Map<String, Object?>> rows) async {
    if (rows.isEmpty) return;
    final d = await db;
    final batch = d.batch();
    for (final r in rows) {
      batch.insert(
        'file_state',
        {
          'pair_id': pairId,
          'path': r['path'],
          'path_key': pathKey(r['path'] as String),
          'is_dir': r['is_dir'] ?? 0,
          'etag': r['etag'],
          'remote_mtime': r['remote_mtime'],
          'remote_size': r['remote_size'],
          'local_mtime': r['local_mtime'],
          'local_size': r['local_size'],
          'synced_at': DateTime.now().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> deleteBaseline(int pairId, String path) async {
    final d = await db;
    await d.delete('file_state',
        where: 'pair_id = ? AND path_key = ?',
        whereArgs: [pairId, pathKey(path)]);
  }

  Future<void> deleteBaselinesUnder(int pairId, String prefix) async {
    final d = await db;
    await d.delete('file_state',
        where: 'pair_id = ? AND (path_key LIKE ? OR path_key = ?)',
        whereArgs: [pairId, '${pathKey(prefix)}/%', pathKey(prefix)]);
  }

  // ---------------------------------------------------------------- conflicts

  Future<List<ConflictRow>> conflicts(int pairId,
      {bool? resolved}) async {
    final d = await db;
    final rows = await d.query(
      'conflicts',
      where: resolved == null
          ? 'pair_id = ?'
          : 'pair_id = ? AND resolved = ?',
      whereArgs: resolved == null ? [pairId] : [pairId, resolved ? 1 : 0],
      orderBy: 'created_at DESC',
    );
    return rows
        .map((r) => ConflictRow(
              id: r['id'] as int,
              pairId: r['pair_id'] as int,
              path: r['path'] as String,
              kind: r['kind'] as String,
              detail: r['detail'] as String?,
              createdAt: r['created_at'] as int,
              resolved: r['resolved'] as int,
            ))
        .toList();
  }

  Future<List<ConflictRow>> allPendingConflicts() async {
    final d = await db;
    final rows = await d
        .query('conflicts', where: 'resolved = 0', orderBy: 'created_at DESC');
    return rows
        .map((r) => ConflictRow(
              id: r['id'] as int,
              pairId: r['pair_id'] as int,
              path: r['path'] as String,
              kind: r['kind'] as String,
              detail: r['detail'] as String?,
              createdAt: r['created_at'] as int,
              resolved: 0,
            ))
        .toList();
  }

  Future<Set<String>> pendingConflictPaths(int pairId) async {
    final d = await db;
    final rows = await d.query('conflicts',
        columns: ['path'],
        where: 'pair_id = ? AND resolved = 0',
        whereArgs: [pairId]);
    return rows.map((r) => pathKey(r['path'] as String)).toSet();
  }

  Future<int> addConflict({
    required int pairId,
    required String path,
    required String kind,
    String? detail,
    bool resolved = false,
  }) async {
    final d = await db;
    return d.insert('conflicts', {
      'pair_id': pairId,
      'path': path,
      'path_key': pathKey(path),
      'kind': kind,
      'detail': detail,
      'created_at': DateTime.now().millisecondsSinceEpoch,
      'resolved': resolved ? 1 : 0,
    });
  }

  Future<void> resolveConflict(int id) async {
    final d = await db;
    await d.update('conflicts', {'resolved': 1},
        where: 'id = ?', whereArgs: [id]);
  }

  // -------------------------------------------------------------------- logs

  Future<void> log(int? pairId, String level, String message) async {
    final d = await db;
    await d.insert('logs', {
      'pair_id': pairId,
      'ts': DateTime.now().millisecondsSinceEpoch,
      'level': level,
      'message': message,
    });
    // Keep the log table bounded.
    final count = Sqflite.firstIntValue(
            await d.rawQuery('SELECT COUNT(*) FROM logs')) ??
        0;
    if (count > 4000) {
      await d.rawDelete(
          'DELETE FROM logs WHERE id IN (SELECT id FROM logs ORDER BY id ASC LIMIT ?)',
          [count - 3000]);
    }
  }

  Future<List<LogRow>> recentLogs({int limit = 300, int? pairId}) async {
    final d = await db;
    final rows = await d.query(
      'logs',
      where: pairId == null ? null : 'pair_id = ?',
      whereArgs: pairId == null ? null : [pairId],
      orderBy: 'id DESC',
      limit: limit,
    );
    return rows
        .map((r) => LogRow(
              id: r['id'] as int,
              pairId: r['pair_id'] as int?,
              ts: r['ts'] as int,
              level: r['level'] as String,
              message: r['message'] as String,
            ))
        .toList();
  }

  Future<void> clearLogs() async {
    final d = await db;
    await d.delete('logs');
  }
}
