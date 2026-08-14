import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Release-only traps, pinned by reading the files.
///
/// None of this fails in a debug run, in `flutter analyze` or in the
/// integration test — the manifest only matters on a user's device and in a
/// Play review, which is exactly the class of bug the house rule about
/// configuration regression tests exists for.
void main() {
  final direct = File('android/app/src/main/AndroidManifest.xml');
  final play = File('android/app/src/main/AndroidManifest-play.xml');
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

  group('direct-distribution manifest', () {
    test('keeps the four pieces the in-app install needs together', () {
      final xml = direct.readAsStringSync();
      expect(
        permissions(direct),
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

  group('Play Store manifest', () {
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

    test('ships no ota_update FileProvider', () {
      expect(
        play.readAsStringSync(),
        isNot(contains('ota_update_provider')),
        reason:
            'nothing downloads an APK in a Play build, and a provider for an '
            'installer path is what a review looks for',
      );
    });

    test('carries everything the direct manifest carries besides the '
        'installer', () {
      final directPermissions = permissions(direct).keys.toSet();
      final playPermissions = permissions(play);
      for (final permission in directPermissions.difference(
        installPermissions,
      )) {
        expect(
          playPermissions[permission],
          allOf(isNotNull, isNot(contains('tools:node="remove"'))),
          reason:
              '$permission was added to the direct manifest but not to the '
              'Play one — the two are maintained by hand and this is the '
              'drift that leaves a Play build without its foreground service '
              'or its network access',
        );
      }

      final xml = play.readAsStringSync();
      for (final required in const [
        '.MainActivity',
        '.ExportService',
        'flutterEmbedding',
        'android.intent.action.VIEW',
      ]) {
        expect(
          xml,
          contains(required),
          reason:
              '$required is missing from the Play manifest — the app would '
              'not launch, would lose background export, or would silently '
              'fail to open the feedback form in a browser',
        );
      }
    });
  });

  group('both manifests', () {
    test('carry no double hyphen inside an XML comment', () {
      // `--` is illegal inside `<!-- -->`, so writing a flag like the
      // dart-define into a comment makes the manifest merger fail with a bare
      // "Error parsing" and no line number. Cheap to pin, annoying to find.
      for (final manifest in [direct, play]) {
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
    test('Gradle picks the Play manifest from the same flag Dart reads', () {
      final kts = gradle.readAsStringSync();
      expect(
        kts,
        contains('AndroidManifest-play.xml'),
        reason: 'the twin manifest exists but nothing selects it',
      );
      expect(
        kts,
        contains('PLAY_STORE=true'),
        reason:
            'the manifest swap must hang off the same --dart-define that sets '
            'isPlayStoreBuild — two separate flags is how you get a build '
            'that strips the permission and still shows "Update now"',
      );
    });
  });
}
