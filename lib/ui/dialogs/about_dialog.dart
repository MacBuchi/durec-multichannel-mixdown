import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../state/app_info.dart';
import '../../state/update_check.dart';
import '../app_banners.dart';

/// About dialog: installed version + update status, project links, and a
/// shortcut into the feedback flow.
Future<void> showAboutDurecMixDialog(BuildContext context) {
  Future<void> openUrl(String url) =>
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('About DurecMix'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FutureBuilder<String>(
              future: AppInfo.version(),
              builder: (context, snap) => Text('Version ${snap.data ?? '…'}',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            const SizedBox(height: 4),
            // Best-effort, never blocks: shows the update status once the
            // release check returns (silent on failure / when offline).
            FutureBuilder<UpdateInfo?>(
              future: UpdateCheck.check(),
              builder: (context, snap) {
                final text = snap.connectionState != ConnectionState.done
                    ? 'Checking for updates…'
                    : snap.data != null
                        ? 'Update available: v${snap.data!.latestVersion} '
                            '— see the banner on the mixer.'
                        : "You're up to date.";
                return Text(text,
                    style: Theme.of(context).textTheme.bodySmall);
              },
            ),
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.code),
              title: const Text('GitHub project'),
              subtitle: const Text(AppInfo.githubUrl),
              onTap: () => openUrl(AppInfo.githubUrl),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.menu_book),
              title: const Text('User guide'),
              onTap: () => openUrl(AppInfo.guideUrl),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.feedback_outlined),
              title: const Text('Request a feature or report a bug'),
              onTap: () {
                Navigator.of(dialogContext).pop();
                showFeedbackDialog(context);
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}
