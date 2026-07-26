import 'package:durecmix/state/session_paths.dart';
import 'package:flutter_test/flutter_test.dart';

/// The FNV-1a hash names every session file and cache entry on disk. The
/// implementation moved to 32-bit limb math for the web build (dart2js has
/// no 64-bit ints); these vectors come from the original 64-bit VM
/// implementation — if any of them changes, shipped apps lose every saved
/// mix and cache on update.
void main() {
  const vectors = {
    '': 'cbf29ce484222325',
    'a': 'af63dc4c8601ec8c',
    'UFX33_00_DuesPaid.WAV': '9d09130c2b4eb507',
    '/Volumes/MacStore/Durec_Export/2025_10_23/UFX32_00_WTF.WAV':
        '4c3065277680acc9',
    'primary:Music/DUREC/UFX33_00_DuesPaid.WAV': '1246d608679601ab',
    'übergroß ✓': '15f3e396849c71f6',
  };

  test('sourceHashFor matches the historical 64-bit FNV-1a values', () {
    vectors.forEach((input, expected) {
      expect(
        sourceHashFor(input),
        expected,
        reason: 'hash of "$input" drifted — session/cache filenames break',
      );
    });
  });

  test('SAF picker and tree URIs of the same document hash identically', () {
    const picker =
        'content://com.android.externalstorage.documents'
        '/document/primary%3AMusic%2FDUREC%2Ftake.WAV';
    const tree =
        'content://com.android.externalstorage.documents'
        '/tree/primary%3AMusic/document/primary%3AMusic%2FDUREC%2Ftake.WAV';
    expect(sourceHashFor(picker), sourceHashFor(tree));
  });
}
