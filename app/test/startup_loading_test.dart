import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jobhunt_agent/screens/startup_loading_screen.dart';
import 'package:jobhunt_agent/theme/app_theme.dart';

/// The `/loading` route is what a signed-in user sees while the routing
/// decision is pending. It used to be a bare loader on near-white `paper`,
/// which is what "the app went white" actually was (ADR-051). These tests pin
/// the two properties that make it not-a-blank-screen.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pump(WidgetTester tester, ThemeData theme) => tester.pumpWidget(
        MaterialApp(theme: theme, home: const StartupLoadingScreen()),
      );

  testWidgets('says what it is doing from the first frame', (tester) async {
    await pump(tester, appLight);
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Getting things ready…'), findsOneWidget);
    // No escape hatch yet — a normal, quick start must not look like a failure.
    expect(find.text('Try again'), findsNothing);
  });

  testWidgets('offers a way out once the wait is clearly not normal', (tester) async {
    await pump(tester, appDark);
    await tester.pump(const Duration(seconds: 9));

    expect(find.text('Still getting things ready…'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.text('Sign in again'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
