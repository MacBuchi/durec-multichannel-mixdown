/// Small shared number/time formatters for the mixer UI and its dialogs.
library;

/// `m:ss` from seconds (clamped at zero).
String fmtTime(double seconds) {
  final s = seconds.clamp(0, double.infinity);
  final m = s ~/ 60;
  final rest = (s - m * 60).floor();
  return '$m:${rest.toString().padLeft(2, '0')}';
}

/// LUFS with the −70 gating floor shown as −∞.
String fmtLufs(double v) => v <= -70 ? '−∞' : v.toStringAsFixed(1);

/// dB value with an explicit sign, one decimal.
String signedDb(double v) => '${v >= 0 ? '+' : ''}${v.toStringAsFixed(1)}';

/// `m:ss min` from seconds (reference durations in the mastering dialog).
String fmtDuration(double seconds) {
  final m = seconds ~/ 60;
  final s = (seconds % 60).round();
  return '$m:${s.toString().padLeft(2, '0')} min';
}
