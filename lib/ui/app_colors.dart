import 'package:flutter/material.dart';

/// Central color tokens of the (dark) mixer UI.
///
/// Everything that used to be a scattered `Colors.*` / hex literal lives
/// here, so a future light theme (PLAN.md: "light optional") only needs a
/// second token set + theme switch instead of a whole-UI sweep. Structural
/// surfaces keep coming from `Theme.of(context).colorScheme`.
abstract final class AppColors {
  /// Active/selected controls: link chips, snapshot slots, EQ labels.
  static const accent = Colors.lightBlueAccent;

  /// Secondary text: meter readouts, hints, file metadata.
  static const dim = Colors.white54;

  /// Inactive toggles and icons.
  static const faint = Colors.white38;

  /// Borders of switched-off chips.
  static const outline = Colors.white24;

  /// Stale mastering preview warning.
  static const warning = Colors.amberAccent;

  /// Error text; also the mute chip.
  static const error = Colors.redAccent;

  // Track-strip toggle chips.
  static const polarity = Colors.purpleAccent;
  static const solo = Colors.amber;
  static const inMix = Colors.greenAccent;

  // Banners above the mixer (PilzBuddy-style fixed colors).
  static const updateBanner = Color(0xFF2E7D32);
  static const updateBannerFg = Colors.white;
  static const feedbackBanner = Color(0xFFFFF8E1);
  static const feedbackBannerFg = Color(0xFF6D4C41);
}
