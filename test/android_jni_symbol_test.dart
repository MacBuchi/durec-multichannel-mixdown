import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The JNI symbol in `rust/src/android.rs` must spell out the application id.
///
/// This is a release-only trap of the nastiest kind: nothing fails at build
/// time. Gradle is happy, `flutter analyze` is happy, the Rust crate compiles,
/// the APK is produced and signed — and then `MainActivity.onCreate` throws
/// `UnsatisfiedLinkError` on the first launch, because the JVM resolves a
/// `native` method purely by a name that encodes the package path.
///
/// It has already shipped twice. v0.20.0 renamed the id
/// `de.macbuchi.durecmix` -> `de.macbuchi.mixstack` and PR #148 renamed it
/// again -> `de.mcbuchi.mixstack`; both moved the Kotlin package and its
/// directory and left the Rust symbol alone. Every Android release from
/// v0.20.0 to v0.20.5 crashed instantly on launch, v0.20.4 was the "latest"
/// release the in-app update check offered, and the same AAB went to the Play
/// internal track. Found 2026-08-19, by launching a build on the emulator —
/// no test covered the pairing until this one.
void main() {
  final gradle = File('android/app/build.gradle.kts');
  final androidRs = File('rust/src/android.rs');

  test('the Rust JNI export matches the Gradle application id', () {
    final applicationId = RegExp(
      r'applicationId\s*=\s*"([^"]+)"',
    ).firstMatch(gradle.readAsStringSync())?.group(1);
    expect(
      applicationId,
      isNotNull,
      reason:
          'no applicationId found in ${gradle.path} — did the assignment '
          'move or change shape? This test cannot guard the JNI symbol '
          'without it.',
    );

    final expected =
        'Java_${applicationId!.replaceAll('.', '_')}_MainActivity_initNdkContext';

    final exported = RegExp(
      r'extern "system" fn (Java_\w+)\s*\(',
    ).firstMatch(androidRs.readAsStringSync())?.group(1);
    expect(
      exported,
      isNotNull,
      reason:
          'no `extern "system" fn Java_…` export found in '
          '${androidRs.path} — the ndk_context handshake is how cpal gets its '
          'JavaVM, so if this moved, playback is broken too.',
    );

    expect(
      exported,
      expected,
      reason:
          'The JNI symbol and the application id have drifted apart. The '
          'JVM resolves native methods by this exact name, so the app will '
          'throw UnsatisfiedLinkError in MainActivity.onCreate and die on '
          'launch — in a release build, on a real device, with nothing '
          'failing during the build. Rename the function in '
          '${androidRs.path} to "$expected", or change the applicationId '
          'back. Renaming the Kotlin package alone is never enough.',
    );
  });

  test('the Kotlin MainActivity lives where that symbol says it does', () {
    // The symbol encodes the *application id*, but the JVM looks the method up
    // on the class in its own package. Those are two different strings in
    // Gradle (`applicationId` vs `namespace`), and only their agreement makes
    // the lookup succeed — so pin the source file's actual location too.
    final applicationId = RegExp(
      r'applicationId\s*=\s*"([^"]+)"',
    ).firstMatch(gradle.readAsStringSync())!.group(1)!;
    final kotlin = File(
      'android/app/src/main/kotlin/${applicationId.replaceAll('.', '/')}/MainActivity.kt',
    );

    expect(
      kotlin.existsSync(),
      isTrue,
      reason:
          'expected MainActivity.kt at ${kotlin.path} (derived from the '
          'applicationId "$applicationId"). A rename that moves the Kotlin '
          'directory but not the id — or the other way round — breaks the JNI '
          'lookup even when the Rust symbol itself looks right.',
    );
    expect(
      kotlin.readAsStringSync(),
      contains('package $applicationId'),
      reason:
          'the package declaration inside ${kotlin.path} must match the '
          'applicationId "$applicationId" the JNI symbol is built from.',
    );
  });
}
