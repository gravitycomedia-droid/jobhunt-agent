import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:jobhunt_agent/main.dart';
import 'package:jobhunt_agent/screens/jobs_list_body.dart';
import 'package:jobhunt_agent/widgets/loading_skeleton.dart';

void main() {
  // Brick 9: AuthGate reads Supabase.instance as soon as it's built, so
  // every widget test needs a real (if fake-backed) Supabase client —
  // otherwise `Supabase.instance` throws before any widget even renders.
  // SharedPreferences.setMockInitialValues avoids touching the platform
  // channel supabase_flutter's local-session persistence normally uses.
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'https://test.supabase.co', anonKey: 'test-anon-key');
  });

  testWidgets('App shows the splash screen when there is no session',
      (WidgetTester tester) async {
    await tester.pumpWidget(const JobHuntAgentApp());

    expect(find.text('Get started'), findsOneWidget);
  });

  testWidgets('Splash screen leads to the auth screen', (WidgetTester tester) async {
    await tester.pumpWidget(const JobHuntAgentApp());
    await tester.tap(find.text('Get started'));
    await tester.pump();

    expect(find.text('Continue with Google'), findsOneWidget);
  });

  testWidgets('Jobs list body shows loading skeletons before jobs load',
      (WidgetTester tester) async {
    // No `await tester.pumpAndSettle()` here on purpose: the real HTTP call
    // never resolves in a widget test (no server running), so we only assert
    // the initial loading state renders without throwing.
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: JobsListBody())));

    expect(find.byType(LoadingSkeleton), findsWidgets);
  });
}
