import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/models.dart';
import '../util/paths.dart';
import 'auth_store.dart';
import 'db.dart';
import 'settings_store.dart';

/// Portable configuration: everything needed to restore the app on another
/// device, optionally including the app password.
class BackupBundle {
  final String? server;
  final String? username;
  final String? appPassword;
  final AppSettings settings;
  final List<Pair> pairs;

  const BackupBundle({
    this.server,
    this.username,
    this.appPassword,
    required this.settings,
    required this.pairs,
  });

  bool get hasCredentials =>
      server != null && username != null && appPassword != null;

  Map<String, Object?> toMap() => {
        'schema': 'nextcloud-sync-config',
        'version': 1,
        'exportedAt': DateTime.now().toUtc().toIso8601String(),
        if (hasCredentials) 'account': {
          'server': server,
          'username': username,
          'appPassword': appPassword,
        },
        'settings': {
          'deviceName': settings.deviceName,
          'intervalMinutes': settings.intervalMinutes,
          'wifiOnly': settings.wifiOnly,
          'notify': settings.notify,
          'conflictPolicy': settings.conflictPolicy.name,
          'fastScan': settings.fastScan,
          'autoBackup': settings.autoBackup,
          'turboScan': settings.turboScan,
          'turboFullScanMinutes': settings.turboFullScanMinutes,
        },
        'pairs': [
          for (final p in pairs)
            {
              'name': p.name,
              'localPath': p.localPath,
              'remotePath': p.remotePath,
              'enabled': p.enabled,
            }
        ],
      };

  String toJson({bool pretty = true}) =>
      pretty ? const JsonEncoder.withIndent('  ').convert(toMap()) : jsonEncode(toMap());

  static BackupBundle parse(String raw) {
    final Object? decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('配置文件格式不正确');
    }
    if (decoded['schema'] != 'nextcloud-sync-config') {
      throw const FormatException('不是 Nextcloud 同步的配置文件');
    }
    final version = decoded['version'];
    if (version is! int || version > 1) {
      throw const FormatException('配置文件版本过新，请升级应用');
    }
    final account = decoded['account'];
    String? server;
    String? username;
    String? password;
    if (account is Map<String, dynamic>) {
      server = account['server'] as String?;
      username = account['username'] as String?;
      password = account['appPassword'] as String?;
      if (server == null || username == null || password == null) {
        throw const FormatException('账号信息不完整');
      }
    }
    final s = decoded['settings'];
    var settings = const AppSettings();
    if (s is Map<String, dynamic>) {
      final policyName = s['conflictPolicy'] as String?;
      settings = AppSettings(
        deviceName: (s['deviceName'] as String?) ?? 'Android',
        intervalMinutes:
            ((s['intervalMinutes'] as num?)?.toInt() ?? 15).clamp(15, 1440),
        wifiOnly: (s['wifiOnly'] as bool?) ?? false,
        notify: (s['notify'] as bool?) ?? true,
        conflictPolicy: ConflictPolicy.values.firstWhere(
          (p) => p.name == policyName,
          orElse: () => ConflictPolicy.newest,
        ),
        fastScan: (s['fastScan'] as bool?) ?? true,
        autoBackup: (s['autoBackup'] as bool?) ?? true,
        turboScan: (s['turboScan'] as bool?) ?? false,
        turboFullScanMinutes:
            ((s['turboFullScanMinutes'] as num?)?.toInt() ?? 60)
                .clamp(15, 1440),
      );
    }
    final pairs = <Pair>[];
    final rawPairs = decoded['pairs'];
    if (rawPairs is List) {
      for (final entry in rawPairs) {
        if (entry is! Map<String, dynamic>) continue;
        final local = (entry['localPath'] as String?)?.trim() ?? '';
        if (!local.startsWith('/')) continue;
        pairs.add(Pair(
          name: (entry['name'] as String?)?.trim().isNotEmpty == true
              ? entry['name'] as String
              : baseName(local),
          localPath: local,
          remotePath: normalizeRel((entry['remotePath'] as String?) ?? ''),
          enabled: (entry['enabled'] as bool?) ?? true,
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ));
      }
    }
    return BackupBundle(
      server: server,
      username: username,
      appPassword: password,
      settings: settings,
      pairs: pairs,
    );
  }
}

class ImportSummary {
  final int added;
  final int skipped;
  final int removed;
  final bool credentialsImported;

  const ImportSummary({
    this.added = 0,
    this.skipped = 0,
    this.removed = 0,
    this.credentialsImported = false,
  });

  String get message => [
        if (credentialsImported) '已导入账号',
        '新增配对 $added',
        if (skipped > 0) '跳过重复 $skipped',
        if (removed > 0) '移除旧配对 $removed',
      ].join('，');
}

/// Writes the bundle into the database. Existing pairs are kept (duplicates
/// skipped) unless [replace] is set.
Future<ImportSummary> importBundle(
  AppDb db,
  BackupBundle bundle, {
  required bool replace,
}) async {
  var added = 0;
  var skipped = 0;
  var removed = 0;

  final existing = await db.listPairs();
  if (replace) {
    for (final p in existing) {
      await db.deletePair(p.id!);
      removed++;
    }
  }
  final seen = <String>{
    for (final p in existing)
      if (!replace) '${p.localPath}\u0000${p.remotePath}',
  };

  for (final p in bundle.pairs) {
    final key = '${p.localPath}\u0000${p.remotePath}';
    if (seen.contains(key)) {
      skipped++;
      continue;
    }
    await db.insertPair(p);
    seen.add(key);
    added++;
  }

  await SettingsStore(db).save(bundle.settings);
  return ImportSummary(
    added: added,
    skipped: skipped,
    removed: removed,
    credentialsImported: bundle.hasCredentials,
  );
}

/// Builds a bundle from the current state.
BackupBundle buildBundle({
  required Account? account,
  required AppSettings settings,
  required List<Pair> pairs,
  required bool includeCredentials,
}) =>
    BackupBundle(
      server: includeCredentials ? account?.server : null,
      username: includeCredentials ? account?.username : null,
      appPassword: includeCredentials ? account?.appPassword : null,
      settings: settings,
      pairs: pairs,
    );

/// Writes an automatic backup of the configuration (without the password).
/// Prefers a user visible folder so it survives reinstalling the app; falls
/// back to the app's external files directory.
Future<String?> writeAutoBackup(String json) async {
  Directory? target;
  try {
    final docs = Directory('/storage/emulated/0/Documents/NextcloudSync');
    await docs.create(recursive: true);
    target = docs;
  } catch (_) {
    target = null;
  }
  if (target == null) {
    final ext = await getExternalStorageDirectory();
    if (ext == null) return null;
    target = Directory('${ext.path}/backup');
    await target.create(recursive: true);
  }
  final file = File('${target.path}/ncsync-config.json');
  await file.writeAsString(json, flush: true);
  return file.path;
}
