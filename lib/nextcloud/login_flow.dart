import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'client.dart';

class LoginFlowSession {
  final String server;
  final String loginUrl;
  final String pollEndpoint;
  final String token;

  const LoginFlowSession({
    required this.server,
    required this.loginUrl,
    required this.pollEndpoint,
    required this.token,
  });
}

class LoginFlowResult {
  final String server;
  final String loginName;
  final String appPassword;

  const LoginFlowResult({
    required this.server,
    required this.loginName,
    required this.appPassword,
  });
}

/// Nextcloud Login Flow v2: the user approves the app in the browser and the
/// app receives an app password without ever seeing the account password.
class LoginFlow {
  LoginFlow(this._http);
  final http.Client _http;

  Future<Map<String, dynamic>> _postJson(Uri uri, {String? body}) async {
    final resp = await _http
        .post(
          uri,
          headers: {
            'OCS-APIRequest': 'true',
            'Accept': 'application/json',
            if (body != null)
              'Content-Type': 'application/x-www-form-urlencoded',
          },
          body: body,
        )
        .timeout(const Duration(seconds: 30));
    if (resp.statusCode != 200) {
      throw NcException('无法启动登录流程', statusCode: resp.statusCode);
    }
    return jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  Future<LoginFlowSession> start(String server) async {
    final base = server.replaceAll(RegExp(r'/+$'), '');
    final data = await _postJson(Uri.parse('$base/index.php/login/v2'));
    final poll = data['poll'] as Map<String, dynamic>?;
    final login = data['login'] as String?;
    if (poll == null || login == null) {
      throw NcException('服务器不支持 Login Flow v2，请使用手动登录');
    }
    return LoginFlowSession(
      server: base,
      loginUrl: login,
      pollEndpoint: poll['endpoint'] as String,
      token: poll['token'] as String,
    );
  }

  /// Polls until the user approved the login in the browser.
  Future<LoginFlowResult> waitForApproval(
    LoginFlowSession session, {
    Duration timeout = const Duration(minutes: 15),
    void Function()? onPoll,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(seconds: 2));
      onPoll?.call();
      try {
        final resp = await _http
            .post(
              Uri.parse(session.pollEndpoint),
              headers: {
                'OCS-APIRequest': 'true',
                'Content-Type': 'application/x-www-form-urlencoded',
              },
              body: 'token=${Uri.encodeQueryComponent(session.token)}',
            )
            .timeout(const Duration(seconds: 20));
        if (resp.statusCode == 200) {
          final data =
              jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
          return LoginFlowResult(
            server: (data['server'] as String?) ?? session.server,
            loginName: data['loginName'] as String,
            appPassword: data['appPassword'] as String,
          );
        }
        if (resp.statusCode != 404) {
          throw NcException('登录轮询失败', statusCode: resp.statusCode);
        }
      } on NcException {
        rethrow;
      } catch (_) {
        // Transient network hiccup: keep polling.
      }
    }
    throw NcException('等待授权超时，请重试');
  }
}
