import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Release-only traps, pinned by reading the files.
///
/// None of this fails in a debug run, in `flutter analyze` or in the
/// integration test — the manifest only matters on a user's device and in a
/// Play review, which is exactly the class of bug the house rule about
/// configuration regression tests exists for.
void main() {
  final mainManifest = File('android/app/src/main/AndroidManifest.xml');
  final play = File('android/app/src/play/AndroidManifest.xml');
  final gradle = File('android/app/build.gradle.kts');

  /// Every `<uses-permission …/>` element, keyed by permission name, with the
  /// full element text as value so the caller can look for `tools:node`.
  Map<String, String> permissions(File manifest) {
    final xml = manifest.readAsStringSync();
    final result = <String, String>{};
    for (final match in RegExp(
      r'<uses-permission\b[^>]*/>',
      dotAll: true,
    ).allMatches(xml)) {
      final element = match.group(0)!;
      final name = RegExp(
        r'android:name="([^"]+)"',
      ).firstMatch(element)?.group(1);
      if (name != null) result[name] = element;
    }
    return result;
  }

  /// The permissions a Play build has to shed: ours for the in-app update, the
  /// ones the ota_update plugin manifest injects on its own, and the storage
  /// read that the merger implies from them.
  const installPermissions = {
    'android.permission.REQUEST_INSTALL_PACKAGES',
    'android.permission.INSTALL_PACKAGES',
    'android.permission.WRITE_EXTERNAL_STORAGE',
    'android.permission.ACCESS_NETWORK_STATE',
    'android.permission.ACCESS_WIFI_STATE',
    'android.permission.READ_EXTERNAL_STORAGE',
  };

  group('main manifest (github flavor)', () {
    test('keeps the four pieces the in-app install needs together', () {
      final xml = mainManifest.readAsStringSync();
      expect(
        permissions(mainManifest),
        contains('android.permission.REQUEST_INSTALL_PACKAGES'),
        reason: 'without it the installer hand-over is refused outright',
      );
      expect(
        xml,
        contains(r'android:authorities="${applicationId}.ota_update_provider"'),
        reason:
            'ota_update calls FileProvider.getUriForFile() with exactly this '
            'authority — a mismatch throws IllegalArgumentException at 100 % '
            'download, on a user first update and never in a debug run (#56)',
      );
      expect(
        File('android/app/src/main/res/xml/filepaths.xml').existsSync(),
        isTrue,
        reason: 'the provider resolves its paths through this resource',
      );
    });
  });

  group('play manifest', () {
    test('removes every permission the installer path pulled in', () {
      final declared = permissions(play);
      for (final permission in installPermissions) {
        expect(
          declared[permission],
          isNotNull,
          reason:
              '$permission has to be listed with tools:node="remove" — the '
              'ota_update plugin manifest declares it, so the merger adds it '
              'to any build with the plugin on the classpath and simply not '
              'declaring it ourselves changes nothing',
        );
        expect(
          declared[permission],
          contains('tools:node="remove"'),
          reason:
              '$permission is declared instead of removed — Play rejects '
              'REQUEST_INSTALL_PACKAGES for an app whose core purpose is not '
              'installing packages, and INSTALL_PACKAGES is signature-level',
        );
      }
    });

    test('declares nothing beyond the six removals', () {
      // A flavor manifest is merged on top of the main one, not swapped in
      // for it — it never needs to (and must never) repeat the main
      // manifest's <application>, activities or providers. That's what
      // makes the file structurally unable to drift from it: there's
      // nothing here that could drift.
      final xml = play.readAsStringSync();
      for (final foreign in const [
        '<application',
        '.MainActivity',
        '.ExportService',
        'ota_update_provider',
        'flutterEmbedding',
      ]) {
        expect(
          xml,
          isNot(contains(foreign)),
          reason:
              '$foreign has no place in a flavor-only manifest — it belongs '
              'in android/app/src/main/AndroidManifest.xml, where the '
              'github and play flavors both already get it from the merge',
        );
      }
    });
  });

  group('both manifests', () {
    test('carry no double hyphen inside an XML comment', () {
      // `--` is illegal inside `<!-- -->`, so writing a flag like the
      // dart-define into a comment makes the manifest merger fail with a bare
      // "Error parsing" and no line number. Cheap to pin, annoying to find.
      for (final manifest in [mainManifest, play]) {
        for (final comment in RegExp(
          r'<!--(.*?)-->',
          dotAll: true,
        ).allMatches(manifest.readAsStringSync())) {
          expect(
            comment.group(1),
            isNot(contains('--')),
            reason:
                '${manifest.path} has a comment containing "--" — the '
                'manifest merger rejects the file and only says "Error '
                'parsing", without pointing at the line',
          );
        }
      }
    });
  });

  group('build wiring', () {
    test('declares both distribution flavors sharing one applicationId', () {
      final kts = gradle.readAsStringSync();
      expect(
        kts,
        contains('create("github")'),
        reason: 'the direct-distribution flavor is missing',
      );
      expect(
        kts,
        contains('create("play")'),
        reason:
            'the Play flavor is missing — nothing would pick up '
            'src/play/AndroidManifest.xml',
      );
      expect(
        kts,
        isNot(contains(RegExp(r'applicationIdSuffix\s*='))),
        reason:
            'a suffix would make github and play two different Android '
            'apps — Fahrgemeinschaft paid for exactly that lesson once, in '
            'their own bundle-id move (mentioning the word in a comment, '
            'like this file already does to explain why, is fine — only an '
            'actual assignment is the regression)',
      );
    });
  });
}
