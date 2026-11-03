import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One step of a connectivity check (DNS / TCP / TLS / HTTPS).
class DiagStep {
  final String name;
  final bool ok;
  final String detail;
  final int ms;

  const DiagStep(this.name, this.ok, this.detail, this.ms);

  @override
  String toString() => '$name: ${ok ? 'OK' : 'FAIL'} ($ms ms) $detail';
}

class DiagResult {
  final List<DiagStep> steps;
  final Map<String, dynamic>? status;
  const DiagResult(this.steps, this.status);

  bool get ok => steps.every((s) => s.ok);
}

/// Pinpoints *where* a connection to [server] fails. Useful when the user sees
/// a generic "connection failed" and the cause is DNS, a captive portal or a
/// middlebox resetting the TLS handshake.
Future<DiagResult> diagnoseServer(String server) async {
  final steps = <DiagStep>[];
  Map<String, dynamic>? status;

  final base = server.trim().replaceAll(RegExp(r'/+$'), '');
  final normalized =
      base.startsWith('http://') || base.startsWith('https://')
          ? base
          : 'https://$base';

  final Uri uri;
  try {
    uri = Uri.parse(normalized);
    steps.add(DiagStep('解析地址', true, uri.host, 0));
  } catch (e) {
    steps.add(DiagStep('解析地址', false, '$e', 0));
    return DiagResult(steps, null);
  }

  // 1. DNS
  final sw = Stopwatch()..start();
  List<InternetAddress> addresses = const [];
  try {
    addresses = await InternetAddress.lookup(uri.host)
        .timeout(const Duration(seconds: 10));
    steps.add(DiagStep(
        'DNS 解析', addresses.isNotEmpty, addresses.map((a) => a.address).join(', '),
        sw.elapsedMilliseconds));
  } catch (e) {
    steps.add(
        DiagStep('DNS 解析', false, '$e', sw.elapsedMilliseconds));
  }

  final port = uri.hasPort ? uri.port : (uri.scheme == 'http' ? 80 : 443);

  // 2. TCP
  sw.reset();
  Socket? socket;
  try {
    socket = await Socket.connect(uri.host, port,
        timeout: const Duration(seconds: 10));
    steps.add(DiagStep('TCP 连接', true, '${uri.host}:$port',
        sw.elapsedMilliseconds));
  } catch (e) {
    steps.add(DiagStep('TCP 连接', false, '$e', sw.elapsedMilliseconds));
  } finally {
    socket?.destroy();
  }

  // 3. TLS
  if (uri.scheme == 'https') {
    sw.reset();
    try {
      final secure = await SecureSocket.connect(uri.host, port,
          timeout: const Duration(seconds: 15));
      final cert = secure.peerCertificate;
      steps.add(DiagStep(
          'TLS 握手',
          true,
          cert == null ? '' : '证书: ${cert.subject} / ${cert.issuer}',
          sw.elapsedMilliseconds));
      secure.destroy();
    } catch (e) {
      steps.add(DiagStep('TLS 握手', false, '$e', sw.elapsedMilliseconds));
    }
  }

  // 4. HTTPS request
  sw.reset();
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..userAgent = 'NextcloudSync-Android/1.0';
  try {
    final req = await client
        .getUrl(Uri.parse('$normalized/status.php'))
        .timeout(const Duration(seconds: 20));
    final resp = await req.close().timeout(const Duration(seconds: 20));
    final body = await resp
        .transform(const Utf8Decoder(allowMalformed: true))
        .join()
        .timeout(const Duration(seconds: 20));
    if (resp.statusCode == 200 && body.contains('"installed"')) {
      steps.add(DiagStep('HTTPS 请求', true, 'status.php 正常',
          sw.elapsedMilliseconds));
      final match = RegExp(r'"versionstring"\s*:\s*"([^"]+)"')
          .firstMatch(body);
      status = {
        'version': match?.group(1) ?? '',
      };
    } else {
      steps.add(DiagStep(
          'HTTPS 请求',
          false,
          'HTTP ${resp.statusCode}: ${body.length > 120 ? body.substring(0, 120) : body}',
          sw.elapsedMilliseconds));
    }
  } catch (e) {
    steps.add(DiagStep('HTTPS 请求', false, '$e', sw.elapsedMilliseconds));
  } finally {
    client.close(force: true);
  }

  return DiagResult(steps, status);
}
