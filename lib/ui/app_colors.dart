import 'package:flutter/material.dart';

/// Central color tokens of the mixer UI, one set per brightness.
///
/// Everything that used to be a scattered `Colors.*` / hex literal lives
/// here. Registered as a [ThemeExtension] on both themes, so a widget reads
/// its tokens with `AppColors.of(context)` and follows the active theme
/// automatically. Structural surfaces keep coming from
/// `Theme.of(context).colorScheme`.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.accent,
    required this.dim,
    required this.faint,
    required this.outline,
    required this.warning,
    required this.error,
    required this.polarity,
    required this.solo,
    required this.inMix,
    required this.success,
    required this.errorSoft,
    required this.meterOk,
  });

  /// Active/selected controls: link chips, snapshot slots, EQ labels.
  final Color accent;

  /// Secondary text: meter readouts, hints, file metadata.
  final Color dim;

  /// Inactive toggles and icons.
  final Color faint;

  /// Borders of switched-off chips.
  final Color outline;

  /// Stale mastering preview warning.
  final Color warning;

  /// Error text; also the mute chip.
  final Color error;

  // Track-strip toggle chips.
  final Color polarity;
  final Color solo;
  final Color inMix;

  /// Success marks (finished multi-export rows, LUFS readouts).
  final Color success;

  /// Softened error text on list rows (probe/render failures).
  final Color errorSoft;

  /// Lower stereo peak meter segment (the safe range).
  final Color meterOk;

  // ── brightness-independent tokens ──────────────────────────────────────
  // Deliberately NOT part of the extension: these must not flip with the
  // theme.

  /// Clipping meter segment — red means red in any theme.
  static const meterOver = Colors.red;

  /// Dimming scrim behind the take-switch loading overlay. Stays dark in
  /// both themes, so [overlayText] on top of it stays light in both — a
  /// scrim that inverted would need its label to invert in lockstep.
  static const scrim = Colors.black54;

  /// Loading overlay text, always on top of [scrim].
  static const overlayText = Colors.white70;

  // Banners above the mixer (PilzBuddy-style fixed colors, and the only
  // surfaces carrying their own background).
  static const updateBanner = Color(0xFF2E7D32);
  static const updateBannerFg = Colors.white;
  static const feedbackBanner = Color(0xFFFFF8E1);
  static const feedbackBannerFg = Color(0xFF6D4C41);

  /// The dark set — the app's original look, unchanged.
  static const dark = AppColors(
    accent: Colors.lightBlueAccent,
    dim: Colors.white54,
    faint: Colors.white38,
    outline: Colors.white24,
    warning: Colors.amberAccent,
    error: Colors.redAccent,
    polarity: Colors.purpleAccent,
    solo: Colors.amber,
    inMix: Colors.greenAccent,
    success: Colors.greenAccent,
    errorSoft: Color(0xFFFF8A80), // redAccent.shade100
    meterOk: Color(0xFF00E676), // greenAccent.shade400
  );

  /// The light set. The accent family moves to the 600–800 shades: the
  /// neon-ish dark tones (`lightBlueAccent`, `greenAccent`) carry almost no
  /// contrast against a white surface.
  static const light = AppColors(
    accent: Color(0xFF0277BD), // blue.shade800
    dim: Colors.black54,
    faint: Colors.black38,
    outline: Colors.black26,
    warning: Color(0xFFEF6C00), // orange.shade800
    error: Color(0xFFC62828), // red.shade800
    polarity: Color(0xFF6A1B9A), // purple.shade800
    solo: Color(0xFFEF6C00), // orange.shade800
    inMix: Color(0xFF2E7D32), // green.shade800
    success: Color(0xFF2E7D32), // green.shade800
    errorSoft: Color(0xFFE53935), // red.shade600
    meterOk: Color(0xFF43A047), // green.shade600
  );

  /// Tokens of the active theme. Falls back to [dark] so a widget pumped
  /// without the extension (a bare `ThemeData()` in a test) still renders.
  static AppColors of(BuildContext context) =>
      Theme.of(context).extension<AppColors>() ?? dark;

  @override
  AppColors copyWith({
    Color? accent,
    Color? dim,
    Color? faint,
    Color? outline,
    Color? warning,
    Color? error,
    Color? polarity,
    Color? solo,
    Color? inMix,
    Color? success,
    Color? errorSoft,
    Color? meterOk,
  }) {
    return AppColors(
      accent: accent ?? this.accent,
      dim: dim ?? this.dim,
      faint: faint ?? this.faint,
      outline: outline ?? this.outline,
      warning: warning ?? this.warning,
      error: error ?? this.error,
      polarity: polarity ?? this.polarity,
      solo: solo ?? this.solo,
      inMix: inMix ?? this.inMix,
      success: success ?? this.success,
      errorSoft: errorSoft ?? this.errorSoft,
      meterOk: meterOk ?? this.meterOk,
    );
  }

  @override
  AppColors lerp(covariant AppColors? other, double t) {
    if (other == null) return this;
    return AppColors(
      accent: Color.lerp(accent, other.accent, t)!,
      dim: Color.lerp(dim, other.dim, t)!,
      faint: Color.lerp(faint, other.faint, t)!,
      outline: Color.lerp(outline, other.outline, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      error: Color.lerp(error, other.error, t)!,
      polarity: Color.lerp(polarity, other.polarity, t)!,
      solo: Color.lerp(solo, other.solo, t)!,
      inMix: Color.lerp(inMix, other.inMix, t)!,
      success: Color.lerp(success, other.success, t)!,
      errorSoft: Color.lerp(errorSoft, other.errorSoft, t)!,
      meterOk: Color.lerp(meterOk, other.meterOk, t)!,
    );
  }
}
