import 'package:flutter/foundation.dart'
    show LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:durecmix/src/rust/frb_generated.dart';
import 'package:durecmix/state/app_settings.dart';
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
/// integration test pumps [DurecMixApp] directly and never runs `main` — a
/// registration there would be invisible to exactly the test meant to prove
/// it. Guarded because the registry appends, and a second call would list
/// every crate twice.
void registerRustLicenses() {
  if (_rustLicensesRegistered) return;
  _rustLicensesRegistered = true;
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(const [
      'DurecMix Rust engine',
    ], await rootBundle.loadString('assets/licenses/rust-third-party.txt'));
  });
}

bool _rustLicensesRegistered = false;

Future<void> main() async {
  await RustLib.init();
  // Before the first frame, so the stored theme never flashes past.
  await AppSettings.load();
  runApp(const DurecMixApp());
}

class DurecMixApp extends StatefulWidget {
  const DurecMixApp({super.key, this.state});

  /// Test seam: inject a [MixerState] (the caller then owns and disposes
  /// it). The app creates and owns its own state when null.
  final MixerState? state;

  @override
  State<DurecMixApp> createState() => _DurecMixAppState();
}

class _DurecMixAppState extends State<DurecMixApp> {
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
          title: 'DurecMix',
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
