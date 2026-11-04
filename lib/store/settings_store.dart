import '../models/models.dart';
import 'db.dart';

class SettingsStore {
  SettingsStore(this._db);
  final AppDb _db;

  Future<AppSettings> load() async {
    final deviceName =
        await _db.getSetting('device_name') ?? 'Android';
    final interval = int.tryParse(
            await _db.getSetting('interval_minutes') ?? '') ??
        15;
    final wifiOnly = (await _db.getSetting('wifi_only') ?? '0') == '1';
    final notify = (await _db.getSetting('notify') ?? '1') == '1';
    final fastScan = (await _db.getSetting('fast_scan') ?? '1') == '1';
    final autoBackup = (await _db.getSetting('auto_backup') ?? '1') == '1';
    final autoSync = (await _db.getSetting('auto_sync') ?? '1') == '1';
    final concurrency =
        int.tryParse(await _db.getSetting('transfer_concurrency') ?? '') ?? 0;
    final turboScan = (await _db.getSetting('turbo_scan') ?? '0') == '1';
    final turboMinutes = int.tryParse(
            await _db.getSetting('turbo_full_scan_minutes') ?? '') ??
        60;
    final policyName = await _db.getSetting('conflict_policy');
    final policy = ConflictPolicy.values.firstWhere(
      (p) => p.name == policyName,
      orElse: () => ConflictPolicy.newest,
    );
    return AppSettings(
      deviceName: deviceName,
      intervalMinutes: interval.clamp(15, 1440),
      wifiOnly: wifiOnly,
      notify: notify,
      conflictPolicy: policy,
      fastScan: fastScan,
      autoBackup: autoBackup,
      autoSync: autoSync,
      transferConcurrency: concurrency.clamp(0, 32),
      turboScan: turboScan,
      turboFullScanMinutes: turboMinutes.clamp(15, 1440),
    );
  }

  Future<void> save(AppSettings s) async {
    await _db.setSetting('device_name', s.deviceName);
    await _db.setSetting('interval_minutes', s.intervalMinutes.toString());
    await _db.setSetting('wifi_only', s.wifiOnly ? '1' : '0');
    await _db.setSetting('notify', s.notify ? '1' : '0');
    await _db.setSetting('conflict_policy', s.conflictPolicy.name);
    await _db.setSetting('fast_scan', s.fastScan ? '1' : '0');
    await _db.setSetting('auto_backup', s.autoBackup ? '1' : '0');
    await _db.setSetting('auto_sync', s.autoSync ? '1' : '0');
    await _db.setSetting(
        'transfer_concurrency', s.transferConcurrency.toString());
    await _db.setSetting('turbo_scan', s.turboScan ? '1' : '0');
    await _db.setSetting(
        'turbo_full_scan_minutes', s.turboFullScanMinutes.toString());
  }
}
