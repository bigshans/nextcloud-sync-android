import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

import '../models/models.dart';
import '../nextcloud/client.dart';
import '../nextcloud/login_flow.dart';
import '../store/auth_store.dart';
import '../store/backup.dart';
import '../store/db.dart';
import '../store/settings_store.dart';
import '../sync/engine.dart';
import '../sync/notifications.dart';
import '../sync/scheduler.dart';
import '../util/network.dart';

class AppState extends ChangeNotifier {
  AppState({
    AppDb? db,
    AuthStore? auth,
  })  : db = db ?? AppDb.instance,
        auth = auth ?? AuthStore();

  final AppDb db;
  final AuthStore auth;

  Account? account;
  AppSettings settings = const AppSettings();
  List<Pair> pairs = [];
  int pendingConflicts = 0;
  int? lastAutoBackupAt;
  bool initialized = false;
  bool syncing = false;
  SyncProgress? progress;
  SyncReport? lastReport;
  String? lastError;

  /// The pass currently running / the pass that was paused.
  Pair? activePair;
  Pair? pausedPair;
  SyncCancelToken? _token;

  bool get paused => pausedPair != null && !syncing;

  NcClient? _client;
  SyncEngine? _engine;

  bool get loggedIn => account != null;

  NcClient get client {
    final a = account;
    if (a == null) throw StateError('not logged in');
    return _client ??= NcClient(
      server: a.server,
      username: a.username,
      appPassword: a.appPassword,
    );
  }

  SyncEngine get engine {
    final a = account;
    if (a == null) throw StateError('not logged in');
    return _engine ??= SyncEngine(
      db: db,
      client: client,
      deviceName: settings.deviceName,
      conflictPolicy: settings.conflictPolicy,
      fastScan: settings.fastScan,
    );
  }

  Future<void> init() async {
    try {
      account = await auth.load();
      settings = await SettingsStore(db).load();
      pairs = await db.listPairs();
      final backupTs = int.tryParse(await db.getSetting('last_auto_backup') ?? '');
      if (backupTs != null) lastAutoBackupAt = backupTs;
      pendingConflicts = (await db.allPendingConflicts()).length;
    } catch (e) {
      lastError = '初始化失败：$e';
    } finally {
      initialized = true;
      notifyListeners();
    }
  }

  Future<void> refreshPendingCount() async {
    pendingConflicts = (await db.allPendingConflicts()).length;
    notifyListeners();
  }

  Future<void> reloadPairs() async {
    pairs = await db.listPairs();
    notifyListeners();
  }

  // ------------------------------------------------------------- auto backup

  /// Writes a password-less copy of the configuration to
  /// `/storage/emulated/0/Documents/NextcloudSync/ncsync-config.json` (or the
  /// app folder when shared storage is not writable). Survives reinstalling —
  /// unlike anything stored inside the app sandbox.
  Future<String?> autoBackupNow() async {
    if (!settings.autoBackup) return null;
    try {
      final json = await exportConfig(includeCredentials: false);
      final path = await writeAutoBackup(json);
      if (path != null) {
        lastAutoBackupAt = DateTime.now().millisecondsSinceEpoch;
        await db.setSetting('last_auto_backup', '$lastAutoBackupAt');
        notifyListeners();
      }
      return path;
    } catch (_) {
      return null;
    }
  }

  void _scheduleAutoBackup() {
    // Fire and forget: never slow down a user action for a backup.
    unawaited(autoBackupNow());
  }

  // ------------------------------------------------------------------- login

  Future<LoginFlowSession> startLoginFlow(String server) async {
    final normalized = _normalizeServer(server);
    final status = await NcClient.serverStatus(normalized, http.Client());
    if (status['installed'] != true) {
      throw NcException('该地址不是可用的 Nextcloud 服务器');
    }
    return LoginFlow(http.Client()).start(normalized);
  }

  Future<void> finishLoginFlow(LoginFlowSession session) async {
    final result =
        await LoginFlow(http.Client()).waitForApproval(session);
    await _storeAccount(result.server, result.loginName, result.appPassword);
  }

  Future<void> manualLogin(
      String server, String username, String password) async {
    final normalized = _normalizeServer(server);
    final c = NcClient(
      server: normalized,
      username: username.trim(),
      appPassword: password.trim(),
    );
    await c.verify();
    c.close();
    await _storeAccount(normalized, username.trim(), password.trim());
  }

  Future<void> _storeAccount(
      String server, String username, String password) async {
    final existing = await auth.load();
    account = Account(
      server: _normalizeServer(server),
      username: username,
      appPassword: password,
      deviceId: existing?.deviceId ?? '',
    );
    await auth.save(account!);
    _client = null;
    _engine = null;
    await refreshPendingCount();
    await Scheduler.schedule(settings);
    notifyListeners();
  }

  Future<void> logout() async {
    await Scheduler.cancel();
    await Scheduler.init();
    await auth.clear();
    account = null;
    _client?.close();
    _client = null;
    _engine = null;
    pairs = [];
    notifyListeners();
  }

  static String _normalizeServer(String raw) {
    var s = raw.trim();
    if (!s.startsWith('http://') && !s.startsWith('https://')) {
      s = 'https://$s';
    }
    return s.replaceAll(RegExp(r'/+$'), '');
  }

  // ------------------------------------------------------------------- pairs

  Future<Pair> addPair({
    required String name,
    required String localPath,
    required String remotePath,
  }) async {
    final pair = Pair(
      name: name.trim().isEmpty ? localPath.split('/').last : name.trim(),
      localPath: localPath.trim(),
      remotePath: normalizeRemote(remotePath),
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    final id = await db.insertPair(pair);
    await reloadPairs();
    _scheduleAutoBackup();
    return pair.copyWith(id: id);
  }

  Future<void> updatePair(Pair pair) async {
    await db.updatePair(pair);
    await reloadPairs();
    _scheduleAutoBackup();
  }

  Future<void> deletePair(int id) async {
    await db.deletePair(id);
    await reloadPairs();
    _scheduleAutoBackup();
  }

  static String normalizeRemote(String raw) => raw
      .trim()
      .replaceAll('\\', '/')
      .split('/')
      .where((e) => e.isNotEmpty && e != '.')
      .join('/');

  // -------------------------------------------------------------------- sync

  /// Asks the running sync to stop after the current file. Work already
  /// transferred is kept; resuming continues where it left off.
  void pauseSync() {
    _token?.pause();
    notifyListeners();
  }

  Future<SyncReport?> resumeSync() async {
    final pair = pausedPair;
    if (pair == null) return null;
    pausedPair = null;
    return syncPair(pair);
  }

  void dismissPaused() {
    pausedPair = null;
    progress = null;
    notifyListeners();
  }

  Future<void> syncAll({bool force = false}) async {
    final enabled = pairs.where((p) => p.enabled).toList();
    for (final pair in enabled) {
      if (pausedPair != null) break;
      if (!syncing) await syncPair(pair, force: force);
    }
  }

  Future<SyncReport?> syncPair(Pair pair, {bool force = false}) async {
    if (syncing) return null;
    if (!loggedIn) {
      lastError = '请先登录';
      notifyListeners();
      return null;
    }
    if (settings.wifiOnly && !await isOnWifi()) {
      lastError = '已设置为仅在 Wi-Fi 下同步，当前网络不是 Wi-Fi';
      notifyListeners();
      return null;
    }
    if (pausedPair?.id == pair.id) pausedPair = null;
    final token = SyncCancelToken();
    _token = token;
    syncing = true;
    activePair = pair;
    lastError = null;
    progress = null;
    notifyListeners();
    try {
      final report = await engine.syncPair(
        pair,
        force: force,
        cancel: token,
        onProgress: (p) {
          progress = p;
          notifyListeners();
        },
      );
      lastReport = report;
      if (report.paused) {
        pausedPair = pair;
        progress = SyncProgress(
          phase: '已暂停',
          done: report.processed,
          total: report.total,
          pairName: pair.name,
        );
      } else {
        pausedPair = null;
      }
      if (!report.ok && !report.paused) lastError = report.fatalError;
      if (settings.notify &&
          (report.uploaded + report.downloaded + report.deleted > 0 ||
              report.conflicts > 0 ||
              !report.ok)) {
        await Notifications.show(
          '${pair.name}：${report.summary}',
          '上传 ${report.uploaded}，下载 ${report.downloaded}，'
          '删除 ${report.deleted}，冲突 ${report.conflicts}，错误 ${report.errors}',
        );
      }
      await reloadPairs();
      await refreshPendingCount();
      _scheduleAutoBackup();
      return report;
    } finally {
      syncing = false;
      activePair = null;
      _token = null;
      if (pausedPair == null) progress = null;
      notifyListeners();
    }
  }

  Future<List<ConflictRow>> pendingConflictsOf(int pairId) =>
      db.conflicts(pairId, resolved: false);

  Future<void> resolveConflict(
      ConflictRow conflict, ConflictChoice choice) async {
    await engine.resolveConflict(conflict, choice);
    await refreshPendingCount();
  }

  // ---------------------------------------------------------------- settings

  // ------------------------------------------------------------ backup/restore

  Future<String> exportConfig({required bool includeCredentials}) {
    final bundle = buildBundle(
      account: account,
      settings: settings,
      pairs: pairs,
      includeCredentials: includeCredentials,
    );
    return Future.value(bundle.toJson());
  }

  Future<ImportSummary> importConfig(String raw,
      {required bool replace}) async {
    final bundle = BackupBundle.parse(raw);
    final summary = await importBundle(db, bundle, replace: replace);
    if (bundle.hasCredentials) {
      final deviceId = await auth.ensureDeviceId();
      account = Account(
        server: bundle.server!,
        username: bundle.username!,
        appPassword: bundle.appPassword!,
        deviceId: deviceId,
      );
      await auth.save(account!);
      _client = null;
      _engine = null;
    }
    settings = await SettingsStore(db).load();
    pairs = await db.listPairs();
    await refreshPendingCount();
    await Scheduler.schedule(settings);
    _scheduleAutoBackup();
    notifyListeners();
    return summary;
  }

  Future<void> saveSettings(AppSettings s) async {
    settings = s;
    await SettingsStore(db).save(s);
    _engine = null;
    await Scheduler.schedule(s);
    _scheduleAutoBackup();
    notifyListeners();
  }

  Future<String> serverVersion() async {
    final a = account;
    if (a == null) return '';
    final status = await NcClient.serverStatus(a.server, http.Client());
    return (status['versionstring'] as String?) ?? '';
  }

  // ------------------------------------------------------------------ helpers

  static Future<bool> hasAllFilesAccess() async =>
      Permission.manageExternalStorage.isGranted;

  static Future<bool> requestAllFilesAccess() async {
    final status = await Permission.manageExternalStorage.request();
    return status.isGranted;
  }

  static String defaultLocalRoot() {
    if (Platform.isAndroid) return '/storage/emulated/0/NextcloudSync';
    return '${Platform.environment['HOME']}/NextcloudSync';
  }

  @override
  void dispose() {
    _client?.close();
    super.dispose();
  }
}
