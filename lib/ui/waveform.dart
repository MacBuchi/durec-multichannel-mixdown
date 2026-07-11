import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Mini min/max envelope plot for one channel. Amplitude is scaled by the
/// track's current fader gain so tracks stay visually comparable (parity with
/// the old tool), and dimmed when the track is excluded from the mix.
class WaveformView extends StatelessWidget {
  const WaveformView({
    super.key,
    required this.min,
    required this.max,
    required this.gainLinear,
    required this.active,
  });

  final Float32List min;
  final Float32List max;
  final double gainLinear;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = active
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.25);
    return CustomPaint(
      painter: _WaveformPainter(min, max, gainLinear.clamp(0.0, 1.0), color),
      size: const Size.fromHeight(36),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter(this.min, this.max, this.scale, this.color);

  final Float32List min;
  final Float32List max;
  final double scale;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (min.isEmpty) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.0;
    final midY = size.height / 2;
    final n = min.length;
    for (var x = 0; x < size.width.floor(); x++) {
      final b = (x * n / size.width).floor().clamp(0, n - 1);
      final yMax = midY - max[b] * scale * midY;
      final yMin = midY - min[b] * scale * midY;
      canvas.drawLine(
        Offset(x.toDouble(), math.min(yMax, midY - 0.5)),
        Offset(x.toDouble(), math.max(yMin, midY + 0.5)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.min != min || old.scale != scale || old.color != color;
}
