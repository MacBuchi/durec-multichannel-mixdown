import 'package:flutter_test/flutter_test.dart';
import 'package:durecmix/main.dart';
import 'package:durecmix/src/rust/frb_generated.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => await RustLib.init());
  testWidgets('App starts with empty mixer view', (WidgetTester tester) async {
    await tester.pumpWidget(const DurecMixApp());
    expect(find.text('Open recording'), findsOneWidget);
  });
}
