import 'package:durecmix/state/changelog.dart';
import 'package:durecmix/ui/dialogs/changelog_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Long bold-lead-in bullets are exactly what overflows on a ~300 dp dialog
/// if the bullet rows do not wrap (see settings_dialog_width_test.dart).
const _entries = [
  ChangelogEntry(
    version: '9.9.9',
    date: '2026-07-25',
    sections: [
      ChangelogSection(
        title: 'Added',
        items: [
          '**A very long bold lead-in that must wrap:** followed by enough '
              'plain text to overflow any narrow phone dialog whose bullet '
              'rows are not width-constrained.',
        ],
      ),
    ],
  ),
];

void main() {
  for (final size in const [Size(320, 640), Size(360, 800), Size(411, 891)]) {
    testWidgets('changelog dialog fits at ${size.width.toInt()} dp', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showChangelogDialog(context, entries: _entries),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('9.9.9 — 2026-07-25'), findsOneWidget);
      expect(find.textContaining('wrap', findRichText: true), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
