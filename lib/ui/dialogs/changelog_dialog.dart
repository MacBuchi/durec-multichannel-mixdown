import 'package:flutter/material.dart';

import '../../state/changelog.dart';

/// "What's new" dialog: the bundled CHANGELOG.md as a scrollable version
/// history. [entries] can be injected by tests to skip asset loading.
Future<void> showChangelogDialog(
  BuildContext context, {
  List<ChangelogEntry>? entries,
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text("What's new"),
      content: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.sizeOf(dialogContext).height * 0.6,
        child: entries != null
            ? _ChangelogList(entries: entries)
            : FutureBuilder<List<ChangelogEntry>>(
                future: loadChangelog(),
                builder: (context, snap) => snap.hasData
                    ? _ChangelogList(entries: snap.data!)
                    : const Center(child: CircularProgressIndicator()),
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

class _ChangelogList extends StatelessWidget {
  const _ChangelogList({required this.entries});

  final List<ChangelogEntry> entries;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView.separated(
      itemCount: entries.length,
      separatorBuilder: (_, _) => const Divider(height: 24),
      itemBuilder: (context, index) {
        final entry = entries[index];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${entry.version} — ${entry.date}',
              style: theme.textTheme.titleMedium,
            ),
            for (final section in entry.sections) ...[
              const SizedBox(height: 8),
              Text(
                section.title,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
              for (final item in section.items)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('•  '),
                      Expanded(child: _Bullet(text: item)),
                    ],
                  ),
                ),
            ],
          ],
        );
      },
    );
  }
}

/// Renders one bullet, honouring the changelog's `**bold**` lead-ins.
class _Bullet extends StatelessWidget {
  const _Bullet({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final parts = text.replaceAll('`', '').split('**');
    return Text.rich(
      TextSpan(
        children: [
          // Odd split indices sat between `**` pairs, so they are bold.
          for (var i = 0; i < parts.length; i++)
            if (parts[i].isNotEmpty)
              TextSpan(
                text: parts[i],
                style: i.isOdd
                    ? const TextStyle(fontWeight: FontWeight.bold)
                    : null,
              ),
        ],
      ),
    );
  }
}
