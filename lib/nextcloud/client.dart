import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../models/models.dart';
import '../util/paths.dart';

class NcException implements Exception {
  final int? statusCode;
  final String message;
  final String? body;

  NcException(this.message, {this.statusCode, this.body});

  bool get isAuth => statusCode == 401;
  bool get isNotFound => statusCode == 404;
  bool get isPreconditionFailed => statusCode == 412;

  @override
  String toString() =>
      'NcException($message${statusCode == null ? '' : ', HTTP $statusCode'})';
}

class NcClient {
  NcClient({
    required String server,
    required this.username,
    required this.appPassword,
    http.Client? httpClient,
  })  : server = server.replaceAll(RegExp(r'/+$'), ''),
        _http = httpClient ?? http.Client();

  static final RegExp _trailingSlash = RegExp(r'/+$');

  final String server;
  final String username;
  final String appPassword;
  final http.Client _http;

  String get _basicAuth =>
      'Basic ${base64Encode(utf8.encode('$username:$appPassword'))}';

  /// Path part of the DAV root, without trailing slash.
  String get basePath =>
      '${Uri.parse(server).path.replaceAll(_trailingSlash, '')}'
      '/remote.php/dav/files/${Uri.encodeComponent(username)}';

  String get baseUrl => '$server$basePath';

  Uri uriFor(String relPath) {
    final rel = normalizeRel(relPath);
    return Uri.parse(rel.isEmpty ? '$baseUrl/' : '$baseUrl/${encodeRel(rel)}');
  }

  Map<String, String> _headers([Map<String, String>? extra]) => {
        'Authorization': _basicAuth,
        'OCS-APIRequest': 'true',
        'User-Agent': 'NextcloudSync-Android/1.0',
        ...?extra,
      };

  void close() => _http.close();

  // ------------------------------------------------------------------ helpers

  static bool _retryable(Object e) =>
      e is TimeoutException ||
      e is SocketException ||
      e is HttpException ||
      e is IOException ||
      e is http.ClientException ||
      e is HandshakeException;

  Future<http.StreamedResponse> _send(
    http.BaseRequest Function() build, {
    int attempts = 3,
    Duration timeout = const Duration(seconds: 45),
  }) async {
    Object? lastError;
    for (var i = 0; i < attempts; i++) {
      try {
        final resp = await _http.send(build()).timeout(timeout);
        if (resp.statusCode >= 500 && i < attempts - 1) {
          await resp.stream.drain<void>();
          await Future<void>.delayed(Duration(milliseconds: 400 * (i + 1)));
          continue;
        }
        return resp;
      } catch (e) {
        if (!_retryable(e) || i == attempts - 1) {
          throw NcException('网络请求失败: $e');
        }
        lastError = e;
      }
      await Future<void>.delayed(Duration(milliseconds: 500 * (i + 1)));
    }
    throw NcException('网络请求失败: $lastError');
  }

  Future<String> _readBody(http.StreamedResponse resp) async =>
      utf8.decode(await resp.stream.toBytes(), allowMalformed: true);

  Never _fail(http.StreamedResponse resp, String body, String what) {
    throw NcException(what, statusCode: resp.statusCode, body: body);
  }

  Future<http.StreamedResponse> _simple(
    String method,
    String relPath, {
    Map<String, String>? headers,
    List<int>? bodyBytes,
    int attempts = 3,
  }) {
    return _send(
      () {
        final req = http.Request(method, uriFor(relPath))
          ..headers.addAll(_headers(headers));
        if (bodyBytes != null) req.bodyBytes = bodyBytes;
        return req;
      },
      attempts: attempts,
    );
  }

  // ---------------------------------------------------------------- discovery

  /// GET /status.php — works without authentication.
  static Future<Map<String, dynamic>> serverStatus(
      String server, http.Client httpClient) async {
    final base = server.replaceAll(_trailingSlash, '');
    final resp = await httpClient
        .get(Uri.parse('$base/status.php'))
        .timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) {
      throw NcException('无法访问服务器 /status.php', statusCode: resp.statusCode);
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// Validates credentials. Throws [NcException] with 401 on bad credentials.
  Future<void> verify() async {
    final resp = await _simple('PROPFIND', '', headers: {'Depth': '0'});
    final body = await _readBody(resp);
    if (resp.statusCode == 401) {
      throw NcException('用户名或应用密码错误', statusCode: 401, body: body);
    }
    if (resp.statusCode >= 400) {
      _fail(resp, body, '服务器拒绝了请求');
    }
  }

  // ----------------------------------------------------------------- listing

  static const _propfindBody = '''<?xml version="1.0" encoding="UTF-8"?>
<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <d:prop>
    <d:resourcetype/>
    <d:getetag/>
    <d:getlastmodified/>
    <d:getcontentlength/>
  </d:prop>
</d:propfind>''';

  /// List the direct children of [relPath] (Depth: 1), excluding itself.
  Future<List<RemoteEntry>> list(String relPath) async {
    final entries = await _propfind(relPath, depth: 1);
    final self = pathKey(normalizeRel(relPath));
    return entries.where((e) => pathKey(e.path) != self).toList();
  }

  /// Stat a single path. Returns null when it does not exist.
  Future<RemoteEntry?> stat(String relPath) async {
    final entries = await _propfind(relPath, depth: 0, allowMissing: true);
    return entries.isEmpty ? null : entries.first;
  }

  Future<List<RemoteEntry>> _propfind(String relPath,
      {required int depth, bool allowMissing = false}) async {
    final resp = await _simple('PROPFIND', relPath, headers: {
      'Depth': '$depth',
      'Content-Type': 'application/xml; charset=utf-8',
    }, bodyBytes: utf8.encode(_propfindBody));
    final body = await _readBody(resp);
    if (resp.statusCode == 404 && allowMissing) return const [];
    if (resp.statusCode == 401) {
      throw NcException('认证失败', statusCode: 401, body: body);
    }
    if (resp.statusCode == 207) {
      return _parseMultiStatus(body);
    }
    if (resp.statusCode == 404) {
      throw NcException('远程路径不存在: /${normalizeRel(relPath)}',
          statusCode: 404, body: body);
    }
    _fail(resp, body, '列目录失败 (/${normalizeRel(relPath)})');
  }

  List<RemoteEntry> _parseMultiStatus(String body) {
    final out = <RemoteEntry>[];
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(body);
    } catch (e) {
      throw NcException('无法解析服务器返回的 XML: $e');
    }
    final prefix = '${basePath.replaceAll(_trailingSlash, '')}/';
    const dav = 'DAV:';
    for (final response in doc.findAllElements('response', namespace: dav)) {
      final hrefEl = _first(response.findElements('href', namespace: dav));
      if (hrefEl == null) continue;
      String href;
      try {
        href = Uri.decodeComponent(hrefEl.innerText.trim());
      } catch (_) {
        href = hrefEl.innerText.trim();
      }
      if (!href.startsWith(prefix)) continue;
      final isDir = href.endsWith('/');
      final rel = normalizeRel(href.substring(prefix.length));
      final prop = _first(response.findAllElements('prop', namespace: dav));
      String? etag;
      int? mtime;
      int? size;
      if (prop != null) {
        final e = _first(prop.findElements('getetag', namespace: dav));
        if (e != null) etag = _stripQuotes(e.innerText.trim());
        final m = _first(prop.findElements('getlastmodified', namespace: dav));
        if (m != null) {
          try {
            mtime = HttpDate.parse(m.innerText.trim()).millisecondsSinceEpoch;
          } catch (_) {}
        }
        final s = _first(prop.findElements('getcontentlength', namespace: dav));
        if (s != null && s.innerText.trim().isNotEmpty) {
          size = int.tryParse(s.innerText.trim());
        }
      }
      out.add(RemoteEntry(
          path: rel, isDir: isDir, etag: etag, mtimeMs: mtime, size: size));
    }
    return out;
  }

  static XmlElement? _first(Iterable<XmlElement> elements) =>
      elements.isEmpty ? null : elements.first;

  static String? _stripQuotes(String? v) {
    if (v == null) return null;
    if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
      return v.substring(1, v.length - 1);
    }
    return v;
  }

  // ---------------------------------------------------------------- mutation

  Future<void> mkdir(String relPath) async {
    final resp = await _simple('MKCOL', relPath, attempts: 2);
    if (resp.statusCode == 201 || resp.statusCode == 405) {
      await resp.stream.drain<void>();
      return;
    }
    final body = await _readBody(resp);
    _fail(resp, body, '创建远程目录失败: /${normalizeRel(relPath)}');
  }

  Future<void> mkdirs(String relPath) async {
    final parts = normalizeRel(relPath).split('/').where((e) => e.isNotEmpty);
    var current = '';
    for (final part in parts) {
      current = current.isEmpty ? part : '$current/$part';
      await mkdir(current);
    }
  }

  /// Upload [file] to [relPath]. Returns the resulting remote entry (ETag and
  /// metadata). When [ifMatch] is set the server rejects the write with 412 if
  /// the remote file changed meanwhile (optimistic concurrency).
  Future<RemoteEntry?> upload(
    File file,
    String relPath, {
    String? ifMatch,
    void Function(int sent, int total)? onProgress,
  }) async {
    final length = await file.length();
    if (length > 32 * 1024 * 1024) {
      return _uploadStreaming(file, relPath,
          ifMatch: ifMatch, onProgress: onProgress);
    }
    final bytes = await file.readAsBytes();
    final resp = await _send(
      () => http.Request('PUT', uriFor(relPath))
        ..headers.addAll(_headers({
          'Content-Type': 'application/octet-stream',
          if (ifMatch != null) 'If-Match': '"$ifMatch"',
        }))
        ..bodyBytes = bytes,
      timeout: const Duration(hours: 2),
    );
    await resp.stream.drain<void>();
    onProgress?.call(length, length);
    if (resp.statusCode == 200 ||
        resp.statusCode == 201 ||
        resp.statusCode == 204) {
      final etag = _stripQuotes(resp.headers['etag']);
      if (etag == null) return stat(relPath);
      return RemoteEntry(
          path: normalizeRel(relPath),
          isDir: false,
          etag: etag,
          size: length);
    }
    throw NcException('上传失败: /${normalizeRel(relPath)}',
        statusCode: resp.statusCode);
  }

  Future<RemoteEntry?> _uploadStreaming(
    File file,
    String relPath, {
    String? ifMatch,
    void Function(int sent, int total)? onProgress,
  }) async {
    final length = await file.length();
    for (var attempt = 0; attempt < 2; attempt++) {
      final req = http.StreamedRequest('PUT', uriFor(relPath))
        ..headers.addAll(_headers({
          'Content-Type': 'application/octet-stream',
          if (ifMatch != null) 'If-Match': '"$ifMatch"',
        }))
        ..contentLength = length;
      try {
        final responseFuture =
            _http.send(req).timeout(const Duration(hours: 6));
        var sent = 0;
        await req.sink.addStream(file.openRead().map((chunk) {
          sent += chunk.length;
          onProgress?.call(sent, length);
          return chunk;
        }));
        await req.sink.close();
        final resp = await responseFuture;
        await resp.stream.drain<void>();
        if (resp.statusCode == 200 ||
            resp.statusCode == 201 ||
            resp.statusCode == 204) {
          final etag = _stripQuotes(resp.headers['etag']);
          if (etag == null) return stat(relPath);
          return RemoteEntry(
              path: normalizeRel(relPath),
              isDir: false,
              etag: etag,
              size: length);
        }
        throw NcException('上传失败: /${normalizeRel(relPath)}',
            statusCode: resp.statusCode);
      } catch (e) {
        if (e is NcException || attempt == 1 || !_retryable(e)) rethrow;
      }
    }
    return null;
  }

  Future<String?> download(
    String relPath,
    File dest, {
    void Function(int received, int total)? onProgress,
  }) async {
    final resp = await _send(
      () => http.Request('GET', uriFor(relPath))..headers.addAll(_headers()),
      timeout: const Duration(hours: 6),
    );
    if (resp.statusCode == 404) {
      await resp.stream.drain<void>();
      throw NcException('远程文件不存在: /${normalizeRel(relPath)}',
          statusCode: 404);
    }
    if (resp.statusCode >= 400) {
      final body = await _readBody(resp);
      _fail(resp, body, '下载失败: /${normalizeRel(relPath)}');
    }
    final total = resp.contentLength ?? 0;
    await dest.parent.create(recursive: true);
    final part =
        File('${dest.path}.part-${DateTime.now().microsecondsSinceEpoch}');
    final sink = part.openWrite();
    var received = 0;
    try {
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
      await sink.close();
      if (await dest.exists()) await dest.delete();
      await part.rename(dest.path);
      final mtime = resp.headers['last-modified'];
      if (mtime != null) {
        try {
          await dest.setLastModified(HttpDate.parse(mtime));
        } catch (_) {}
      }
    } catch (e) {
      try {
        await sink.close();
      } catch (_) {}
      try {
        if (await part.exists()) await part.delete();
      } catch (_) {}
      rethrow;
    }
    return _stripQuotes(resp.headers['etag']);
  }

  Future<void> delete(String relPath) async {
    final resp = await _simple('DELETE', relPath);
    final body = await _readBody(resp);
    if (resp.statusCode == 204 ||
        resp.statusCode == 200 ||
        resp.statusCode == 404) {
      return;
    }
    _fail(resp, body, '删除远程文件失败: /${normalizeRel(relPath)}');
  }

  Future<void> move(String from, String to, {bool overwrite = true}) async {
    final resp = await _send(() => http.Request('MOVE', uriFor(from))
      ..headers.addAll(_headers({
        'Destination': uriFor(to).toString(),
        'Overwrite': overwrite ? 'T' : 'F',
      })));
    final body = await _readBody(resp);
    if (resp.statusCode == 201 ||
        resp.statusCode == 204 ||
        resp.statusCode == 200) {
      return;
    }
    _fail(resp, body, '移动远程文件失败: /${normalizeRel(from)}');
  }
}
