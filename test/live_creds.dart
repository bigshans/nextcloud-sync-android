import 'dart:convert';
import 'dart:io';

/// Credentials for the optional live tests.
///
/// Read from the environment first (`NC_SERVER`, `NC_USER`, `NC_PASS`), then
/// from `~/.config/ncsync/test_creds.json` (never committed). Returns null when
/// none are configured; the tests then skip themselves.
class LiveCreds {
  final String server;
  final String username;
  final String appPassword;
  const LiveCreds(this.server, this.username, this.appPassword);

  static LiveCreds? load() {
    final env = Platform.environment;
    final server = env['NC_SERVER'];
    final user = env['NC_USER'];
    final pass = env['NC_PASS'];
    if (server != null && user != null && pass != null && pass.isNotEmpty) {
      return LiveCreds(server, user, pass);
    }
    try {
      final file = File(
          '${env['HOME']}/.config/ncsync/test_creds.json');
      if (!file.existsSync()) return null;
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final s = json['server'] as String?;
      final u = json['loginName'] as String?;
      final p = json['appPassword'] as String?;
      if (s == null || u == null || p == null) return null;
      return LiveCreds(s, u, p);
    } catch (_) {
      return null;
    }
  }
}
