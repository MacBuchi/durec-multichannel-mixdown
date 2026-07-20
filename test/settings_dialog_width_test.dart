import 'package:durecmix/ui/dialogs/settings_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The appearance picker is a three-segment button with icon + label. On a
/// narrow phone the dialog is only ~300 dp wide, so this is exactly the
/// shape that overflows if the segments do not shrink.
void main() {
  for (final size in const [Size(320, 640), Size(360, 800), Size(411, 891)]) {
    testWidgets('settings dialog fits at ${size.width.toInt()} dp', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showSettingsDialog(context),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Appearance'), findsOneWidget);
      expect(find.text('About DurecMix'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
