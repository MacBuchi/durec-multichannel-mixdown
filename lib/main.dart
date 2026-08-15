import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart'
    show FlutterError, LicenseEntryWithLineBreaks, LicenseRegistry, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:durecmix/io/platform_shim.dart' show initPlatformStorage;
import 'package:durecmix/src/rust/api/simple.dart' as rust_simple;
import 'package:durecmix/src/rust/frb_generated.dart';
import 'package:durecmix/state/app_settings.dart';
import 'package:durecmix/state/debug_log.dart';
import 'package:durecmix/state/mixer_scope.dart';
import 'package:durecmix/state/mixer_state.dart';
import 'package:durecmix/ui/app_colors.dart';
import 'package:durecmix/ui/mixer_screen.dart';

/// Feed the Rust crates' notices into the same registry `showLicensePage`
/// reads. Flutter collects the Dart/Flutter side on its own but knows
/// nothing about what the engine links in — LAME (LGPL) and the MPL-2.0
/// Symphonia family both require their notices to ship with the binary.
///
/// Lazy by construction: [LicenseRegistry] only calls this when the licence
/// page is opened, so the 300+ KiB asset never touches a normal start.
///
/// Registered from the widget rather than from `main`, because the
/// integration test pumps [MixstackApp] directly and never runs `main` — a
/// registration there would be invisible to exactly the test meant to prove
/// it. Guarded because the registry appends, and a second call would list
/// every crate twice.
void registerRustLicenses() {
  if (_rustLicensesRegistered) return;
  _rustLicensesRegistered = true;
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(const [
      'Mixstack Rust engine',
    ], await rootBundle.loadString('assets/licenses/rust-third-party.txt'));
  });
}

bool _rustLicensesRegistered = false;

Future<void> main() async {
  // First thing in main, before anything can fail: an app that ships past the
  // stores gets no crash reports handed to it, so an unhandled error that is
  // not written down here is gone. Both hooks are needed — `FlutterError`
  // catches the framework's own, `PlatformDispatcher` everything else,
  // including errors from futures nobody awaited.
  FlutterError.onError = (details) {
    DebugLog.error('flutter', details.exception, details.stack);
    // Keep the console behaviour of a debug run: the red screen and the
    // framework's own dump are useful and must not disappear.
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    DebugLog.error('uncaught', error, stack);
    return true; // handled — do not take the isolate down with it
  };

  await RustLib.init();
  if (kIsWeb) {
    // Boot beacon for the PWA track (docs/PLAN-PWA.md S1): proves in the
    // browser console that the wasm engine answers through the bridge.
    DebugLog.info(
      'DURECMIX_WEB_BOOT ${rust_simple.greet(name: 'wasm engine')}',
    );
  }
  // Fills the app container from browser storage on the web (a no-op with a
  // real filesystem). Must come before the first read of it — the settings
  // below are one, and the saved mix of the take the user opens next another.
  await initPlatformStorage();
  // Before the first frame, so the stored theme never flashes past.
  await AppSettings.load();
  runApp(const MixstackApp());
}

class MixstackApp extends StatefulWidget {
  const MixstackApp({super.key, this.state});

  /// Test seam: inject a [MixerState] (the caller then owns and disposes
  /// it). The app creates and owns its own state when null.
  final MixerState? state;

  @override
  State<MixstackApp> createState() => _MixstackAppState();
}

class _MixstackAppState extends State<MixstackApp> {
  late final MixerState _state = widget.state ?? MixerState();

  @override
  void initState() {
    super.initState();
    registerRustLicenses();
  }

  static const _seed = Color(0xFF00B4D8);

  ThemeData _theme(Brightness brightness, AppColors colors) => ThemeData(
    brightness: brightness,
    colorScheme: ColorScheme.fromSeed(seedColor: _seed, brightness: brightness),
    sliderTheme: const SliderThemeData(
      trackHeight: 3,
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
      overlayShape: RoundSliderOverlayShape(overlayRadius: 12),
    ),
    visualDensity: VisualDensity.compact,
    extensions: [colors],
  );

  @override
  void dispose() {
    if (widget.state == null) _state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The scope sits ABOVE the MaterialApp so dialog routes (which live on
    // the app's navigator) can still see it.
    return MixerScope(
      state: _state,
      child: ValueListenableBuilder<ThemeMode>(
        valueListenable: AppSettings.themeMode,
        builder: (context, themeMode, _) => MaterialApp(
          title: 'Mixstack',
          debugShowCheckedModeBanner: false,
          theme: _theme(Brightness.light, AppColors.light),
          darkTheme: _theme(Brightness.dark, AppColors.dark),
          themeMode: themeMode,
          home: const MixerScreen(),
        ),
      ),
    );
  }
}
