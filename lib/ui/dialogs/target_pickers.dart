import 'package:flutter/material.dart';

import '../../src/rust/api/mixer.dart' as rust;
import '../../state/mixer_state.dart';
import 'custom_lufs_dialog.dart';

/// Loudness-target chooser (phone overflow menu and the browser's export
/// bar — the wide app bar uses an inline dropdown instead).
Future<void> pickLoudnessDialog(BuildContext context, MixerState state) async {
  final choice = await showDialog<LoudnessChoice>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('Loudness target'),
      children: [
        for (final c in LoudnessChoice.values)
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(c),
            child: Text(
              c == LoudnessChoice.lufsCustom &&
                      state.loudness == LoudnessChoice.lufsCustom
                  ? '${state.customLufs.toStringAsFixed(1)} LUFS'
                  : c.label,
              style: TextStyle(
                fontWeight:
                    c == state.loudness ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
      ],
    ),
  );
  if (choice == null || !context.mounted) return;
  if (choice == LoudnessChoice.lufsCustom) {
    final v = await askCustomLufs(context, state.customLufs);
    if (v == null) return;
    state.customLufs = v;
  }
  state.setLoudness(choice);
}

/// Output-format chooser, same surfaces as [pickLoudnessDialog].
Future<void> pickFormatDialog(BuildContext context, MixerState state) async {
  final choice = await showDialog<rust.ApiFormat>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('Export format'),
      children: [
        for (final f in rust.ApiFormat.values)
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(f),
            child: Text(
              formatLabels[f]!,
              style: TextStyle(
                fontWeight:
                    f == state.format ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
      ],
    ),
  );
  if (choice != null) state.setFormat(choice);
}
