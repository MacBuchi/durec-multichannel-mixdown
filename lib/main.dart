import 'package:flutter/material.dart';
import 'package:durecmix/src/rust/frb_generated.dart';
import 'package:durecmix/ui/mixer_screen.dart';

Future<void> main() async {
  await RustLib.init();
  runApp(const DurecMixApp());
}

class DurecMixApp extends StatelessWidget {
  const DurecMixApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
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
    );
  }
}
