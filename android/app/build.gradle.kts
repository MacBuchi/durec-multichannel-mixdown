import java.io.FileInputStream
import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing: android/key.properties (gitignored) points at the stable
// keystore — locally at ~/durecmix-keys/, in CI decoded from the
// ANDROID_KEYSTORE_* secrets. Without it, builds fall back to debug signing
// so `flutter run --release` and PR CI keep working; only artifacts signed
// with the stable key can update an existing installation.
val keystoreProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) FileInputStream(f).use { load(it) }
}

// Play builds swap in a manifest without the in-app APK updater (see
// src/main/AndroidManifest-play.xml). The switch is driven by the SAME flag
// that closes the Dart paths — `--dart-define=PLAY_STORE=true` — so the two
// halves cannot drift into a build that strips the permission but still shows
// the "Update now" button, or worse, the reverse. Flutter hands dart-defines
// to Gradle base64-encoded in the `dart-defines` property; `-Pplay-store=true`
// is accepted as a fallback for invoking Gradle directly.
val dartDefines: List<String> = (project.findProperty("dart-defines") as String?)
    ?.split(",")
    ?.filter { it.isNotBlank() }
    ?.map { String(Base64.getDecoder().decode(it)) }
    ?: emptyList()
val isPlayBuild = dartDefines.contains("PLAY_STORE=true") ||
    (project.findProperty("play-store") as String?) == "true"

// Printed because the failure mode is silent: a Play build that quietly picked
// the direct manifest only surfaces weeks later as a review rejection.
println("Mixstack Android manifest: " + if (isPlayBuild) "PLAY (no self-update)" else "DIRECT (GitHub APK)")

android {
    namespace = "de.macbuchi.mixstack"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    sourceSets {
        getByName("main") {
            manifest.srcFile(
                if (isPlayBuild) "src/main/AndroidManifest-play.xml"
                else "src/main/AndroidManifest.xml"
            )
        }
    }

    compileOptions {
        // Core library desugaring: required by the ota_update plugin
        // (in-app APK update) on this minSdk.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "de.macbuchi.mixstack"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // cpal live playback uses AAudio, which needs API 26+ (libaaudio is
        // absent from NDK sysroots below that, breaking the Rust link).
        minSdk = maxOf(26, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        // Derived from the semver rather than taken from pubspec's `+N`, which
        // has been `+1` since M0 and which nothing in the release flow bumps.
        // Android tolerates reinstalling the same versionCode, so the GitHub
        // APK never noticed — Play does not: it rejects any upload whose
        // version code was used before, so the SECOND release would be the one
        // that fails. 0.19.0 -> 19000, leaving 999 minors and 999 patches.
        versionCode = flutter.versionName
            .split(".")
            .map { it.toIntOrNull() ?: 0 }
            .let { v ->
                val part = { i: Int -> v.getOrElse(i) { 0 } }
                part(0) * 1_000_000 + part(1) * 1_000 + part(2)
            }
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keystoreProperties.isNotEmpty()) {
            create("release") {
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystoreProperties.isNotEmpty()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
