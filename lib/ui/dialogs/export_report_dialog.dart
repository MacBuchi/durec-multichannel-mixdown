import 'package:flutter/material.dart';

import '../../src/rust/api/mixer.dart' as rust;
import '../../state/mixer_state.dart';
import '../app_colors.dart';
import '../formats.dart';

/// Detail view of the last export's loudness report (the status line above
/// the transport bar opens it — the phone's hover replacement).
void showExportReportDialog(
    BuildContext context, MixerState state, rust.ApiRenderReport report) {
  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Last export'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _row(context, 'Loudness', '${fmtLufs(report.integratedLufs)} LUFS-I'),
          _row(context, 'True peak', '${report.truePeakDbtp.toStringAsFixed(2)} dBTP'),
          _row(context, 'Loudness range', '${report.lraLu.toStringAsFixed(1)} LU'),
          if (report.masteringApplied)
            _row(
                context,
                'Mastering',
                'matched to ${state.mastering.referenceName} '
                    '(${signedDb(report.masteringGainDb)} dB)')
          else
            _row(context, 'Gain', '${signedDb(report.gainAppliedDb)} dB'),
          _row(context, 'Source loudness',
              '${fmtLufs(report.sourceIntegratedLufs)} LUFS-I'),
          _row(context, 'Duration', fmtTime(report.durationSeconds)),
          const SizedBox(height: 8),
          SelectableText(
            state.exporter.lastOutputPath ?? '',
            style: TextStyle(fontSize: 11, color: AppColors.of(context).dim),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

Widget _row(BuildContext context, String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 130,
            child: Text(label,
                style: TextStyle(fontSize: 12, color: AppColors.of(context).dim)),
          ),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 12))),
        ],
      ),
    );
