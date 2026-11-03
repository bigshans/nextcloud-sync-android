/// Builds conflict file names using the exact format of the official
/// Nextcloud desktop client:
///
///   `<base> (conflicted copy <device> yyyy-MM-dd hhmmss)<ext>`
///
/// For example `report.docx` becomes
/// `report (conflicted copy Pixel 2026-11-03 143000).docx`.
///
/// The marker is inserted before the last dot (unless the name is a dotfile or
/// has no extension, in which case it is appended), matching
/// `Utility::makeConflictFileName()` in the Nextcloud client.
String conflictFileName(
  String path,
  String deviceName,
  DateTime at, {
  int sequence = 0,
}) {
  final slash = path.lastIndexOf('/');
  final dir = slash >= 0 ? path.substring(0, slash + 1) : '';
  final name = slash >= 0 ? path.substring(slash + 1) : path;

  var dot = name.lastIndexOf('.');
  // Dotfiles such as ".hidden" (and names without an extension) get the marker
  // appended instead of inserted.
  if (dot <= 0) dot = name.length;

  final stamp = '${at.year.toString().padLeft(4, '0')}-'
      '${_two(at.month)}-${_two(at.day)} '
      '${_two(at.hour)}${_two(at.minute)}${_two(at.second)}';
  final device = sanitizeDeviceName(deviceName);
  final suffix = sequence > 0 ? ' $sequence' : '';
  final marker = ' (conflicted copy'
      '${device.isEmpty ? '' : ' $device'} $stamp$suffix)';

  return '$dir${name.substring(0, dot)}$marker${name.substring(dot)}';
}

/// Device names end up inside parentheses in the conflict tag; the official
/// client strips file name specials and replaces parentheses so the tag can be
/// parsed back.
String sanitizeDeviceName(String name) {
  final cleaned = name
      .replaceAll(RegExp(r'[/?<>\\:*|"]'), '')
      .replaceAll('(', '_')
      .replaceAll(')', '_')
      .trim();
  return cleaned.length > 40 ? cleaned.substring(0, 40) : cleaned;
}

/// Mirrors `Utility::isConflictFile()` of the desktop client.
bool isConflictFileName(String name) {
  final base = name.split('/').last;
  return base.contains('_conflict-') || base.contains('(conflicted copy');
}

String _two(int v) => v.toString().padLeft(2, '0');
