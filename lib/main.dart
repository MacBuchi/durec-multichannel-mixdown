import 'package:flutter/material.dart';
import 'package:durecmix/src/rust/frb_generated.dart';
import 'package:durecmix/state/mixer_scope.dart';
import 'package:durecmix/state/mixer_state.dart';
import 'package:durecmix/ui/mixer_screen.dart';

Future<void> main() async {
  await RustLib.init();
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
      child: MaterialApp(
        title: 'DurecMix',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF00B4D8),
            brightness: Brightness.dark,
          ),
          sliderTheme: const SliderThemeData(
            trackHeight: 3,
            thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: RoundSliderOverlayShape(overlayRadius: 12),
          ),
          visualDensity: VisualDensity.compact,
        ),
        home: const MixerScreen(),
      ),
    );
  }
}
