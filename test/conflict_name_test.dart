import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloud_sync/sync/conflict_name.dart';

void main() {
  final at = DateTime(2026, 11, 3, 14, 30, 5);

  test('matches the Nextcloud desktop format', () {
    expect(conflictFileName('a.txt', 'Pixel', at),
        'a (conflicted copy Pixel 2026-11-03 143005).txt');
    expect(conflictFileName('dir/b.md', 'Pixel', at),
        'dir/b (conflicted copy Pixel 2026-11-03 143005).md');
  });

  test('handles names without extension and dotfiles', () {
    expect(conflictFileName('README', 'Pixel', at),
        'README (conflicted copy Pixel 2026-11-03 143005)');
    expect(conflictFileName('.hidden', 'Pixel', at),
        '.hidden (conflicted copy Pixel 2026-11-03 143005)');
  });

  test('sanitizes the device name like the official client', () {
    expect(sanitizeDeviceName('my/pc (2)'), 'mypc _2_');
    expect(conflictFileName('a.txt', '', at),
        'a (conflicted copy 2026-11-03 143005).txt');
  });

  test('sequence numbers stay inside the tag', () {
    expect(conflictFileName('a.txt', 'Pixel', at, sequence: 2),
        'a (conflicted copy Pixel 2026-11-03 143005 2).txt');
  });

  test('recognises conflict files', () {
    expect(isConflictFileName('a (conflicted copy Pixel 2026-11-03 143005).txt'),
        isTrue);
    expect(isConflictFileName('a_conflict-20260101-120000.txt'), isTrue);
    expect(isConflictFileName('a.txt'), isFalse);
  });
}
