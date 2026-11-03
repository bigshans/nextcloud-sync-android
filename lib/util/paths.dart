import 'package:path/path.dart' as p;

/// Normalize a *relative* path used inside a pair:
/// forward slashes, no leading/trailing slash, collapsed separators.
String normalizeRel(String raw) {
  var s = raw.replaceAll('\\', '/');
  s = s.split('/').where((e) => e.isNotEmpty && e != '.').join('/');
  return s;
}

/// Case-insensitive lookup key. Nextcloud (Linux) is case sensitive, Android
/// shared storage is not; treating names case-insensitively for matching lets
/// us detect "only case differs" situations and raise a conflict instead of
/// silently creating a duplicate.
String pathKey(String path) => normalizeRel(path).toLowerCase();

String parentOf(String path) {
  final i = path.lastIndexOf('/');
  return i < 0 ? '' : path.substring(0, i);
}

String baseName(String path) {
  final i = path.lastIndexOf('/');
  return i < 0 ? path : path.substring(i + 1);
}

bool isUnder(String prefix, String path) =>
    path.startsWith('$prefix/');

/// True if [path] equals [prefix] or is below it.
bool isSameOrUnder(String prefix, String path) =>
    path == prefix || path.startsWith('$prefix/');

/// Join local root + relative (posix) path, producing a platform path.
String localJoin(String root, String rel) =>
    rel.isEmpty ? root : p.joinAll([root, ...rel.split('/')]);

/// Strip the local root prefix from a filesystem path.
String relativeOf(String root, String absPath) {
  final normRoot = p.normalize(root);
  final normPath = p.normalize(absPath);
  if (normPath == normRoot) return '';
  if (normPath.startsWith('$normRoot${p.separator}')) {
    return normalizeRel(
        normPath.substring(normRoot.length + 1).replaceAll(p.separator, '/'));
  }
  return normalizeRel(absPath);
}

/// URI path: percent-encode each segment, keep slashes.
String encodeRel(String rel) => normalizeRel(rel)
    .split('/')
    .where((e) => e.isNotEmpty)
    .map(Uri.encodeComponent)
    .join('/');
