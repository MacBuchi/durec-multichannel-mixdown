import java.io.FileInputStream
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

android {
    namespace = "de.mcbuchi.mixstack"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

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
        applicationId = "de.mcbuchi.mixstack"
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

    // Two distribution channels, one app (pattern from PilzBuddy/
    // Fahrgemeinschaft): the GitHub APK self-updates and keeps
    // REQUEST_INSTALL_PACKAGES for that; the Play bundle must not carry it
    // (Play forbids self-updates as "Device and Network Abuse") —
    // src/play/AndroidManifest.xml removes it via tools:node="remove". Both
    // flavors share the same applicationId (no applicationIdSuffix — that
    // would make github/play two different Android apps, exactly what
    // Fahrgemeinschaft's own bundle-id move cost them once).
    //
    // The point of a flavor over a dart-define switch: every build now
    // needs an explicit --flavor, and Gradle refuses to build without one.
    // A forgotten flag used to produce a silently wrong but buildable
    // artifact — that's what shipped REQUEST_INSTALL_PACKAGES to Play once
    // already. A forgotten --flavor just fails the build.
    flavorDimensions += "distribution"
    productFlavors {
        create("github") { dimension = "distribution" }
        create("play") { dimension = "distribution" }
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
