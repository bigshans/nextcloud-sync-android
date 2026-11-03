import 'dart:ui';

import 'package:workmanager/workmanager.dart';

import '../models/models.dart';
import '../nextcloud/client.dart';
import '../store/auth_store.dart';
import '../store/db.dart';
import '../store/settings_store.dart';
import 'engine.dart';
import '../util/network.dart';
import 'notifications.dart';

const String kSyncTask = 'ncsync-sync';
const String kPeriodicUnique = 'ncsync-periodic';

class Scheduler {
  static bool _initialized = false;

  static Future<void> init() async {
    if (_initialized) return;
    await Workmanager().initialize(callbackDispatcher);
    _initialized = true;
  }

  /// (Re-)registers the periodic background sync.
  static Future<void> schedule(AppSettings settings) async {
    await init();
    await Workmanager().cancelByUniqueName(kPeriodicUnique);
    await Workmanager().registerPeriodicTask(
      kPeriodicUnique,
      kSyncTask,
      frequency: Duration(minutes: settings.intervalMinutes.clamp(15, 1440)),
      constraints: Constraints(
        networkType: NetworkType.connected,
        requiresBatteryNotLow: false,
      ),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.replace,
    );
  }

  static Future<void> cancel() async {
    await init();
    await Workmanager().cancelByUniqueName(kPeriodicUnique);
  }

  /// Runs one sync pass for all enabled pairs. Used by the background isolate.
  static Future<String> runBackgroundSync() async {
    final db = AppDb.instance;
    final account = await AuthStore().load();
    if (account == null) return '未登录';
    final settings = await SettingsStore(db).load();
    final pairs = (await db.listPairs()).where((p) => p.enabled).toList();
    if (pairs.isEmpty) return '没有启用的同步目录';
    if (settings.wifiOnly && !await isOnWifi()) return '非 Wi-Fi 网络';

    final client = NcClient(
      server: account.server,
      username: account.username,
      appPassword: account.appPassword,
    );
    final engine = SyncEngine(
      db: db,
      client: client,
      deviceName: settings.deviceName,
      conflictPolicy: settings.conflictPolicy,
      fastScan: settings.fastScan,
    );
    var changed = 0;
    var conflicts = 0;
    var failures = 0;
    try {
      for (final pair in pairs) {
        final report = await engine.syncPair(pair);
        if (!report.ok) {
          failures++;
          continue;
        }
        changed += report.uploaded + report.downloaded + report.deleted;
        conflicts += report.conflicts;
        if (report.errors > 0) failures++;
      }
    } finally {
      client.close();
    }

    if (settings.notify && (changed > 0 || conflicts > 0 || failures > 0)) {
      final parts = <String>[
        if (changed > 0) '同步 $changed 项更改',
        if (conflicts > 0) '$conflicts 个冲突待处理',
        if (failures > 0) '$failures 个目录同步失败',
      ];
      await Notifications.show('Nextcloud 同步', parts.join('，'));
    }
    return failures == 0 ? 'ok' : 'partial';
  }
}

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    DartPluginRegistrant.ensureInitialized();
    try {
      await Notifications.init();
      final result = await Scheduler.runBackgroundSync();
      return result != '未登录';
    } catch (_) {
      return false;
    }
  });
}
