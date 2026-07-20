import 'package:flutter/material.dart';

import '../../src/rust/api/mixer.dart' as rust;
import '../../state/mixer_state.dart';
import '../app_colors.dart';
import 'custom_lufs_dialog.dart';

/// Edit the batch queue (one job = loudness target + format of the current
/// mix). Returns true when the user confirms the export.
Future<bool?> showBatchExportDialog(BuildContext context, MixerState state) {
  return showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: const Text('Batch export'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Each job renders the current mix at its own loudness '
                  'target and format, auto-named into one folder.',
                  style: TextStyle(fontSize: 12, color: AppColors.of(context).dim),
                ),
              ),
              const SizedBox(height: 8),
              for (final job in List.of(state.exporter.batchQueue))
                Row(
                  children: [
                    Expanded(
                        child: _jobLoudnessDropdown(context, job,
                            setDialogState)),
                    const SizedBox(width: 8),
                    _jobFormatDropdown(job, setDialogState),
                    IconButton(
                      icon: const Icon(Icons.remove_circle_outline, size: 18),
                      onPressed: () => setDialogState(
                          () => state.exporter.removeBatchJob(job)),
                    ),
                  ],
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setDialogState(state.exporter.addBatchJob),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add job'),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: state.exporter.batchQueue.isEmpty
                ? null
                : () => Navigator.of(context).pop(true),
            child: const Text('Export all…'),
          ),
        ],
      ),
    ),
  );
}

Widget _jobLoudnessDropdown(
    BuildContext context, BatchJob job, StateSetter setDialogState) {
  return DropdownButton<LoudnessChoice>(
    value: job.loudness,
    isExpanded: true,
    underline: const SizedBox.shrink(),
    items: LoudnessChoice.values
        .map((c) => DropdownMenuItem(
            value: c,
            child: Text(
                c == LoudnessChoice.lufsCustom && job.loudness == c
                    ? '${job.customLufs.toStringAsFixed(1)} LUFS'
                    : c.label,
                style: const TextStyle(fontSize: 13))))
        .toList(),
    onChanged: (c) async {
      if (c == null) return;
      if (c == LoudnessChoice.lufsCustom) {
        final v = await askCustomLufs(context, job.customLufs);
        if (v == null) return;
        job.customLufs = v;
      }
      setDialogState(() => job.loudness = c);
    },
  );
}

Widget _jobFormatDropdown(BatchJob job, StateSetter setDialogState) {
  return DropdownButton<rust.ApiFormat>(
    value: job.format,
    underline: const SizedBox.shrink(),
    items: rust.ApiFormat.values
        .map((f) => DropdownMenuItem(
            value: f,
            child:
                Text(formatLabels[f]!, style: const TextStyle(fontSize: 13))))
        .toList(),
    onChanged: (f) => f != null ? setDialogState(() => job.format = f) : null,
  );
}
