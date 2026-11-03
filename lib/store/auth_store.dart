import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class Account {
  final String server; // e.g. https://cloud.example.com  (no trailing slash)
  final String username;
  final String appPassword;
  final String deviceId;

  const Account({
    required this.server,
    required this.username,
    required this.appPassword,
    required this.deviceId,
  });

  Account copyWith({String? server, String? username, String? appPassword}) =>
      Account(
        server: server ?? this.server,
        username: username ?? this.username,
        appPassword: appPassword ?? this.appPassword,
        deviceId: deviceId,
      );

  @override
  String toString() => 'Account($server, $username)';
}

/// Credentials live in the Android Keystore backed encrypted preferences,
/// never in the sqlite database.
class AuthStore {
  AuthStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  final FlutterSecureStorage _storage;

  static const _kServer = 'nc_server';
  static const _kUser = 'nc_user';
  static const _kPass = 'nc_app_password';
  static const _kDevice = 'device_id';

  Future<Account?> load() async {
    final server = await _storage.read(key: _kServer);
    final user = await _storage.read(key: _kUser);
    final pass = await _storage.read(key: _kPass);
    if (server == null || user == null || pass == null) return null;
    final deviceId = await _deviceId();
    return Account(
        server: server, username: user, appPassword: pass, deviceId: deviceId);
  }

  Future<void> save(Account account) async {
    await _storage.write(key: _kServer, value: account.server);
    await _storage.write(key: _kUser, value: account.username);
    await _storage.write(key: _kPass, value: account.appPassword);
    await _storage.write(key: _kDevice, value: account.deviceId);
  }

  Future<void> clear() async {
    final deviceId = await _deviceId();
    await _storage.delete(key: _kServer);
    await _storage.delete(key: _kUser);
    await _storage.delete(key: _kPass);
    await _storage.write(key: _kDevice, value: deviceId);
  }

  /// Stable random id for this installation (used in conflict file names).
  Future<String> ensureDeviceId() => _deviceId();

  Future<String> _deviceId() async {
    var id = await _storage.read(key: _kDevice);
    if (id == null || id.isEmpty) {
      id = _randomId();
      await _storage.write(key: _kDevice, value: id);
    }
    return id;
  }

  static String _randomId() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rnd = Random.secure();
    return List.generate(10, (_) => chars[rnd.nextInt(chars.length)]).join();
  }
}
