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
    return AppSettings(
      deviceName: deviceName,
      intervalMinutes: interval.clamp(15, 1440),
      wifiOnly: wifiOnly,
      notify: notify,
    );
  }

  Future<void> save(AppSettings s) async {
    await _db.setSetting('device_name', s.deviceName);
    await _db.setSetting('interval_minutes', s.intervalMinutes.toString());
    await _db.setSetting('wifi_only', s.wifiOnly ? '1' : '0');
    await _db.setSetting('notify', s.notify ? '1' : '0');
  }
}
