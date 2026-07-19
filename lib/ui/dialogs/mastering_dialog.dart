import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../io/ios_files.dart';
import '../../io/saf.dart';
import '../../state/mixer_state.dart';
import '../app_colors.dart';
import '../formats.dart';

/// Reference-mastering dialog: manage the reference set, toggle mastering
/// and the mastered playback preview.
Future<void> showMasteringDialog(BuildContext context, MixerState state) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Reference mastering'),
      content: SizedBox(
        width: 400,
        child: ListenableBuilder(
          listenable: state,
          builder: (context, _) {
            final mastering = state.mastering;
            final profile = mastering.profile;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Matches the export to a reference track: loudness, tone '
                  '(matching EQ) and stereo width. The loudness target is '
                  'ignored while active; the true-peak limiter stays on.',
                  style: TextStyle(fontSize: 12, color: AppColors.dim),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Master to reference'),
                  value: mastering.enabled,
                  onChanged: mastering.references.isEmpty
                      ? null
                      : mastering.setEnabled,
                ),
                if (mastering.references.isEmpty)
                  const ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.library_music, size: 20),
                    title: Text('No reference chosen'),
                  )
                else
                  for (final ref in mastering.references)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.library_music, size: 18),
                      title: Text(ref.name, overflow: TextOverflow.ellipsis),
                      trailing: IconButton(
                        tooltip: 'Remove reference',
                        icon: const Icon(Icons.close, size: 16),
                        onPressed: mastering.analyzingReference
                            ? null
                            : () => mastering.removeReference(ref),
                      ),
                    ),
                Row(
                  children: [
                    TextButton.icon(
                      onPressed: mastering.analyzingReference
                          ? null
                          : () => _pickReference(context, state),
                      icon: const Icon(Icons.add, size: 16),
                      label: Text(mastering.references.isEmpty
                          ? 'Choose reference…'
                          : 'Add reference…'),
                    ),
                    const Spacer(),
                    if (profile != null)
                      Text(
                        '${mastering.references.length > 1 ? 'averaged · ' : ''}'
                        '${fmtDuration(profile.durationSeconds)}'
                        '${profile.sideRms < profile.midRms * 1e-4 ? ' · mono' : ''}',
                        style: const TextStyle(
                            fontSize: 11, color: AppColors.dim),
                      ),
                  ],
                ),
                if (mastering.references.length > 1)
                  const Text(
                    'Multiple references average into one target curve — '
                    'one vote per song.',
                    style: TextStyle(fontSize: 11, color: AppColors.dim),
                  ),
                if (mastering.analyzingReference) ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                      value: mastering.referenceProgress > 0
                          ? mastering.referenceProgress
                          : null),
                  const SizedBox(height: 4),
                  Text(
                      'Analyzing ${mastering.analyzingReferenceLabel.isEmpty ? 'reference' : mastering.analyzingReferenceLabel}…',
                      style: const TextStyle(
                          fontSize: 11, color: AppColors.dim)),
                ],
                const Divider(height: 16),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Preview mastered playback'),
                  subtitle: const Text(
                    'Analyzes the current mix once; meters then show the '
                    'mastered signal',
                    style: TextStyle(fontSize: 11),
                  ),
                  value: mastering.preview,
                  onChanged: !mastering.enabled || mastering.analyzingMix
                      ? null
                      : (v) => v
                          ? _enablePreview(context, state)
                          : mastering.disablePreview(),
                ),
                if (mastering.analyzingMix) ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                      value: mastering.mixAnalysisProgress > 0
                          ? mastering.mixAnalysisProgress
                          : null),
                  const SizedBox(height: 4),
                  const Text('Analyzing mix…',
                      style:
                          TextStyle(fontSize: 11, color: AppColors.dim)),
                ],
                if (mastering.preview && mastering.mixStatsStale)
                  Row(
                    children: [
                      const Icon(Icons.warning_amber,
                          size: 16, color: AppColors.warning),
                      const SizedBox(width: 6),
                      const Expanded(
                        child: Text(
                          'Mix changed — preview uses the old analysis',
                          style: TextStyle(
                              fontSize: 11, color: AppColors.warning),
                        ),
                      ),
                      TextButton(
                        onPressed: mastering.analyzingMix
                            ? null
                            : () => _refreshPreview(context, state),
                        child: const Text('Refresh'),
                      ),
                    ],
                  ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Done'),
        ),
      ],
    ),
  );
}

Future<void> _pickReference(BuildContext context, MixerState state) async {
  final messenger = ScaffoldMessenger.of(context);
  String? path;
  String? name;
  if (Saf.isAvailable) {
    path = await Saf.pickAudio();
    if (path != null) name = await Saf.displayName(path);
  } else if (IosFiles.isAvailable) {
    path = await IosFiles.pickAudio();
  } else {
    const group = XTypeGroup(
        label: 'Audio',
        extensions: ['wav', 'flac', 'mp3', 'ogg', 'WAV', 'FLAC', 'MP3']);
    final file = await openFile(acceptedTypeGroups: [group]);
    path = file?.path;
    name = file?.name;
  }
  if (path == null) return;
  try {
    await state.mastering.addReference(path, name ?? path.split('/').last);
  } catch (e) {
    messenger.showSnackBar(
        SnackBar(content: Text('Reference analysis failed: $e')));
  }
}

Future<void> _enablePreview(BuildContext context, MixerState state) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await state.mastering.enablePreview();
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Mix analysis failed: $e')));
  }
}

Future<void> _refreshPreview(BuildContext context, MixerState state) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await state.mastering.refreshPreview();
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Mix analysis failed: $e')));
  }
}
