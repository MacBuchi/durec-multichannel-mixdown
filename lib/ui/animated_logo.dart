import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The DurecMix logo (six channel lines converging into a stereo pair),
/// drawn live. With [animate] the channel lines carry travelling sine
/// ripples — audio flowing towards the mix — and the stereo terminals
/// pulse gently; without it the painter renders the still logo mark.
class AnimatedLogo extends StatefulWidget {
  const AnimatedLogo({
    super.key,
    this.size = 160,
    this.animate = false,
    this.amplitude = 26,
  });

  final double size;
  final bool animate;

  /// Ripple amplitude in the 1024-unit viewbox space. The default matches
  /// the full-size look; small indicator sizes need more (the swing scales
  /// with [size] and turns subpixel otherwise — ~90 works at 26 px).
  final double amplitude;

  /// Test seam, mirroring `UpdateCheck.enabled`: `pumpAndSettle()` waits for
  /// the frame queue to drain and therefore never returns while a repeating
  /// animation is on screen. Since the start-screen logo runs continuously,
  /// the integration test switches the motion off — the painter still draws
  /// the logo, it just stops asking for frames.
  static bool enabled = true;

  @override
  State<AnimatedLogo> createState() => _AnimatedLogoState();
}

class _AnimatedLogoState extends State<AnimatedLogo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  );

  bool get _shouldAnimate => widget.animate && AnimatedLogo.enabled;

  @override
  void initState() {
    super.initState();
    if (_shouldAnimate) _controller.repeat();
  }

  @override
  void didUpdateWidget(AnimatedLogo old) {
    super.didUpdateWidget(old);
    if (_shouldAnimate && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!_shouldAnimate && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: CustomPaint(
        painter: _LogoPainter(
          repaint: _controller,
          amplitude: widget.amplitude,
        ),
      ),
    );
  }
}

/// Geometry mirrors assets/icon/logo.svg (1024-unit viewbox): each channel
/// runs horizontally from x=140 to x=340, then a cubic bezier converges on
/// one of the two stereo terminals at (866, 442/582).
class _LogoPainter extends CustomPainter {
  _LogoPainter({required this.repaint, required this.amplitude})
    : super(repaint: repaint);

  final Animation<double> repaint;
  final double amplitude;

  static const _channelYs = [252.0, 356.0, 460.0, 564.0, 668.0, 772.0];
  static const _terminalYs = [442.0, 442.0, 442.0, 582.0, 582.0, 582.0];
  static const _faderXs = [236.0, 292.0, 204.0, 308.0, 248.0, 188.0];
  static const _bendX = 340.0;
  static const _endX = 866.0;
  // Per-channel ripple frequency (cycles per loop) — like unrelated signals.
  static const _cycles = [2.0, 3.0, 1.0, 2.0, 4.0, 3.0];

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 1024.0;
    final t = repaint.value;
    final animating =
        repaint is AnimationController &&
        (repaint as AnimationController).isAnimating;

    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 34 * s
      ..strokeCap = StrokeCap.round
      ..shader = const LinearGradient(
        colors: [Color(0xFF3D5A80), Color(0xFF41A7E0), Color(0xFF7FDCFF)],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));

    for (var i = 0; i < 6; i++) {
      final path = Path();
      const samples = 48;
      for (var n = 0; n <= samples; n++) {
        final u = n / samples;
        final (x, y) = _basePoint(i, u);
        final wobble = animating ? _ripple(i, u, t) : 0.0;
        final px = x * s;
        final py = (y + wobble) * s;
        n == 0 ? path.moveTo(px, py) : path.lineTo(px, py);
      }
      canvas.drawPath(path, stroke);
    }

    // Stereo terminals, pulsing slightly while animating.
    final pulse = animating
        ? 1.0 + 0.12 * math.sin(2 * math.pi * (2 * t))
        : 1.0;
    final terminal = Paint()..color = const Color(0xFFEAF7FF);
    canvas.drawCircle(Offset(_endX * s, 442 * s), 40 * s * pulse, terminal);
    canvas.drawCircle(Offset(_endX * s, 582 * s), 40 * s * pulse, terminal);

    // Fader dots ride their (possibly rippling) line.
    final dot = Paint()..color = const Color(0xFFDCE8F5);
    for (var i = 0; i < 6; i++) {
      final u = _uAtX(i, _faderXs[i]);
      final (x, y) = _basePoint(i, u);
      final wobble = animating ? _ripple(i, u, t) : 0.0;
      canvas.drawCircle(Offset(x * s, (y + wobble) * s), 22 * s, dot);
    }
  }

  /// Point on channel `i` at parameter u ∈ [0,1]: straight run to the bend,
  /// then a cubic towards the terminal (control points as in the SVG).
  static (double, double) _basePoint(int i, double u) {
    const startX = 140.0;
    const straightFrac = 0.28; // portion of u spent on the straight run
    final y0 = _channelYs[i];
    final y1 = _terminalYs[i];
    if (u <= straightFrac) {
      return (startX + (_bendX - startX) * (u / straightFrac), y0);
    }
    final v = (u - straightFrac) / (1 - straightFrac);
    // Cubic (340,y0) C (560,y0) (600,y1) (866,y1)
    final x = _cubic(v, _bendX, 560, 600, _endX);
    final y = _cubic(v, y0, y0, y1, y1);
    return (x, y);
  }

  /// Travelling sine, anchored to zero at both ends of the line.
  double _ripple(int i, double u, double t) {
    final envelope = math.sin(math.pi * u);
    final phase = 2 * math.pi * (_cycles[i] * t + i / 6.0 - 2.5 * u);
    return amplitude * envelope * math.sin(phase);
  }

  /// Approximate parameter for a given x on the straight segment (the fader
  /// dots all sit left of the bend).
  static double _uAtX(int i, double x) {
    const startX = 140.0;
    const straightFrac = 0.28;
    return straightFrac * ((x - startX) / (_bendX - startX)).clamp(0.0, 1.0);
  }

  static double _cubic(double v, double p0, double p1, double p2, double p3) {
    final w = 1 - v;
    return w * w * w * p0 +
        3 * w * w * v * p1 +
        3 * w * v * v * p2 +
        v * v * v * p3;
  }

  @override
  bool shouldRepaint(covariant _LogoPainter old) => old.amplitude != amplitude;
}
