import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:ota_update/ota_update.dart';
import 'package:url_launcher/url_launcher.dart';

import '../state/feedback.dart';
import '../state/update_check.dart';
import 'app_colors.dart';

/// Banner stack above the mixer: update notification (green) and the
/// feedback bar (cream). Dismissals are deliberately session-only — the
/// gentle once-per-start reminder mirrors PilzBuddy's behaviour.
class AppBanners extends StatefulWidget {
  const AppBanners({super.key});

  @override
  State<AppBanners> createState() => _AppBannersState();
}

class _AppBannersState extends State<AppBanners> {
  UpdateInfo? _update;
  bool _updateDismissed = false;
  bool _feedbackDismissed = false;

  @override
  void initState() {
    super.initState();
    unawaited(
      UpdateCheck.check().then((info) {
        if (mounted && info != null) setState(() => _update = info);
      }),
    );
  }

  Future<void> _openUpdateDialog(UpdateInfo info) {
    return showDialog<void>(
      context: context,
      builder: (context) => _UpdateDialog(info: info),
    );
  }

  // Sending does NOT hide the bar: one wish is rarely the last one, and a
  // bar that vanishes on its own reads as "you already had your turn".
  // Only the ✕ dismisses it (for the session).
  Future<void> _openFeedbackDialog() => showFeedbackDialog(context);

  Widget _banner({
    required Color background,
    required Color foreground,
    required Widget content,
    VoidCallback? onTap,
    VoidCallback? onDismiss,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Material(
        color: background,
        borderRadius: BorderRadius.circular(12),
        elevation: 2,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: DefaultTextStyle(
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium!.copyWith(color: foreground),
                    child: content,
                  ),
                ),
                if (onDismiss != null) ...[
                  const SizedBox(width: 4),
                  InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: onDismiss,
                    child: Icon(Icons.close, size: 18, color: foreground),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final update = _update;
    if ((update == null || _updateDismissed) && _feedbackDismissed) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (update != null && !_updateDismissed)
            _banner(
              background: AppColors.updateBanner,
              foreground: AppColors.updateBannerFg,
              onTap: () => _openUpdateDialog(update),
              onDismiss: () => setState(() => _updateDismissed = true),
              content: Text('🔄 Update to v${update.latestVersion} available'),
            ),
          if (!_feedbackDismissed)
            _banner(
              background: AppColors.feedbackBanner,
              foreground: AppColors.feedbackBannerFg,
              onTap: _openFeedbackDialog,
              onDismiss: () => setState(() => _feedbackDismissed = true),
              content: const Text('💡 Request a feature or report a bug!'),
            ),
        ],
      ),
    );
  }
}

/// Update dialog: on Android the APK downloads in-app with a progress bar
/// and hands over to the installer; desktops open the release page.
class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({required this.info});

  final UpdateInfo info;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

enum _UpdatePhase { idle, downloading, installing, error }

class _UpdateDialogState extends State<_UpdateDialog> {
  _UpdatePhase _phase = _UpdatePhase.idle;
  double _progress = 0;
  StreamSubscription<OtaEvent>? _subscription;

  bool get _inAppInstall => Platform.isAndroid && widget.info.apkUrl != null;

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  void _startAndroidInstall() {
    setState(() => _phase = _UpdatePhase.downloading);
    try {
      _subscription = OtaUpdate()
          .execute(
            widget.info.apkUrl!,
            destinationFilename: 'durecmix-update.apk',
          )
          .listen(
            (event) {
              if (!mounted) return;
              switch (event.status) {
                case OtaStatus.DOWNLOADING:
                  setState(() {
                    _phase = _UpdatePhase.downloading;
                    _progress = (double.tryParse(event.value ?? '') ?? 0) / 100;
                  });
                case OtaStatus.INSTALLING:
                  setState(() => _phase = _UpdatePhase.installing);
                default:
                  setState(() => _phase = _UpdatePhase.error);
              }
            },
            onError: (Object _) {
              if (mounted) setState(() => _phase = _UpdatePhase.error);
            },
          );
    } catch (_) {
      setState(() => _phase = _UpdatePhase.error);
    }
  }

  Future<void> _openReleasePage() async {
    await launchUrl(
      Uri.parse(widget.info.htmlUrl),
      mode: LaunchMode.externalApplication,
    );
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _browserFallback() async {
    await launchUrl(
      Uri.parse(widget.info.apkUrl ?? widget.info.htmlUrl),
      mode: LaunchMode.externalApplication,
    );
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    return AlertDialog(
      title: Text('Update to v${info.latestVersion}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            switch (_phase) {
              _UpdatePhase.idle => Text(
                _inAppInstall
                    ? 'The update downloads inside the app and then opens the '
                          'Android installer — your mixes are kept. Android asks '
                          'for permission once.'
                    : 'Opens the GitHub release page — download the package '
                          'for your platform there.',
              ),
              _UpdatePhase.downloading => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Downloading … ${(_progress * 100).round()} %'),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: _progress > 0 ? _progress : null,
                  ),
                ],
              ),
              _UpdatePhase.installing => const Text(
                'Download finished — Android now asks whether to update '
                'DurecMix. Just confirm!',
              ),
              _UpdatePhase.error => const Text(
                'The direct download failed. You can load the update via '
                'your browser instead — tap the file in the notification '
                'after the download.',
              ),
            },
            if (_phase == _UpdatePhase.idle &&
                info.releaseNotes != null &&
                info.releaseNotes!.trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                "What's new:",
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              Text(
                info.releaseNotes!.trim(),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (_phase == _UpdatePhase.idle) ...[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Later'),
          ),
          FilledButton.icon(
            onPressed: _inAppInstall ? _startAndroidInstall : _openReleasePage,
            icon: Icon(
              _inAppInstall ? Icons.download : Icons.open_in_browser,
              size: 18,
            ),
            label: Text(_inAppInstall ? 'Update now' : 'Open download page'),
          ),
        ] else if (_phase == _UpdatePhase.error) ...[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
          FilledButton.icon(
            onPressed: _browserFallback,
            icon: const Icon(Icons.open_in_browser, size: 18),
            label: const Text('Load in browser'),
          ),
        ] else
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
      ],
    );
  }
}

/// Show the feedback dialog, file the result, and report via SnackBar.
/// The outcome is communicated by the SnackBar alone — no caller changes
/// its own visibility because of it. Reused by the banner and the About
/// dialog.
Future<void> showFeedbackDialog(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  final input = await showDialog<(FeedbackType, String)>(
    context: context,
    builder: (context) => const _FeedbackDialog(),
  );
  if (input == null) return;
  final (type, message) = input;
  try {
    final direct = await submitFeedback(type, message);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          direct
              ? (type == FeedbackType.bug
                    ? 'Thanks for the report — filed as an issue! 🐛'
                    : 'Thanks for your idea — filed as an issue! 💡')
              : 'Almost done — finish the pre-filled issue in your browser.',
        ),
      ),
    );
  } catch (_) {
    messenger.showSnackBar(
      const SnackBar(content: Text('Sending failed. Are you online?')),
    );
  }
}

class _FeedbackDialog extends StatefulWidget {
  const _FeedbackDialog();

  @override
  State<_FeedbackDialog> createState() => _FeedbackDialogState();
}

class _FeedbackDialogState extends State<_FeedbackDialog> {
  FeedbackType _type = FeedbackType.feature;
  final _textController = TextEditingController();

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _textController.text.trim();
    if (text.length < 3) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please write a few more words. 🙂')),
      );
      return;
    }
    Navigator.of(context).pop((_type, text));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Make a wish!'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<FeedbackType>(
              segments: const [
                ButtonSegment(
                  value: FeedbackType.feature,
                  label: Text('💡 Feature'),
                ),
                ButtonSegment(value: FeedbackType.bug, label: Text('🐛 Bug')),
              ],
              selected: {_type},
              onSelectionChanged: (selection) =>
                  setState(() => _type = selection.first),
            ),
            const SizedBox(height: 12),
            Text(
              _type == FeedbackType.bug
                  ? 'What went wrong? Briefly describe what you did and '
                        'what happened instead.'
                  : 'What is missing, what is annoying, what would be '
                        'practical? Every idea lands directly with the '
                        'developer.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _textController,
              autofocus: true,
              maxLines: 4,
              maxLength: 2000,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: _type == FeedbackType.bug
                    ? 'What happened?'
                    : 'Your wish',
                hintText: _type == FeedbackType.bug
                    ? 'e.g. "Export stops at 50% when the take is trimmed"'
                    : 'e.g. "A spectrum view while playing would be great!"',
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Send')),
      ],
    );
  }
}
