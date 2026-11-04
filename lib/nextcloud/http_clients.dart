import 'dart:io';

import 'package:cronet_http/cronet_http.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// Shared HTTP clients.
///
/// On Android we prefer Cronet: it speaks HTTP/2 (and QUIC), multiplexes many
/// requests over one connection and keeps them warm — the same transport the
/// official clients use. If Cronet is unavailable (no Play Services / missing
/// native lib) we transparently fall back to dart:io's HTTP/1.1 client with a
/// connection pool wide enough for the transfer pool.
class HttpClients {
  static http.Client? _io;
  static http.Client? _cronet;
  static bool _cronetTried = false;
  static bool _cronetBroken = false;

  static http.Client io() => _io ??= IOClient(
        HttpClient()
          ..maxConnectionsPerHost = 16
          ..connectionTimeout = const Duration(seconds: 20)
          // Keep sockets warm between syncs: TLS handshakes are the main
          // per-file cost for lots of tiny files.
          ..idleTimeout = const Duration(minutes: 5),
      );

  static bool get cronetAvailable => _cronetTried && _cronet != null;

  static http.Client? cronet() {
    if (!Platform.isAndroid || _cronetBroken) return null;
    if (_cronetTried) return _cronet;
    _cronetTried = true;
    try {
      final engine = CronetEngine.build(
        cacheMode: CacheMode.disabled,
        enableHttp2: true,
        enableQuic: true,
        enableBrotli: true,
        userAgent: 'NextcloudSync-Android/1.0',
      );
      _cronet = CronetClient.fromCronetEngine(engine, closeEngine: true);
    } catch (_) {
      _cronet = null;
      _cronetBroken = true;
    }
    return _cronet;
  }

  /// Called when a Cronet request failed in a way that suggests the native
  /// stack is unusable on this device; all further traffic uses dart:io.
  static void markCronetBroken() {
    _cronetBroken = true;
    _cronet = null;
  }
}
