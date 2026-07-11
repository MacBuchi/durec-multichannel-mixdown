import 'dart:math' as math;

import 'package:flutter/material.dart';

double _linToDb(double v) => v > 0 ? 20 * math.log(v) / math.ln10 : -60;

/// Horizontal stereo peak meter with a dB scale from −60 to +3.
class StereoPeakMeter extends StatelessWidget {
  const StereoPeakMeter({super.key, required this.peakL, required this.peakR});

  final double peakL; // linear
  final double peakR;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _MeterBar(db: _linToDb(peakL)),
        const SizedBox(height: 2),
        _MeterBar(db: _linToDb(peakR)),
      ],
    );
  }
}

class _MeterBar extends StatelessWidget {
  const _MeterBar({required this.db});

  final double db;

  static const _minDb = -60.0;
  static const _maxDb = 3.0;

  @override
  Widget build(BuildContext context) {
    final frac = ((db - _minDb) / (_maxDb - _minDb)).clamp(0.0, 1.0);
    final over = db > -0.1;
    return SizedBox(
      width: 140,
      height: 6,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(3),
        ),
        child: FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: frac,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: over ? Colors.red : Colors.greenAccent.shade400,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        ),
      ),
    );
  }
}
