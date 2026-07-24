import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:jobhunt_agent/main.dart';
import 'package:jobhunt_agent/screens/jobs_list_body.dart';
import 'package:jobhunt_agent/theme/app_theme.dart';
import 'package:jobhunt_agent/widgets/app_loader.dart';

void main() {
  // Brick 9: AuthGate reads Supabase.instance as soon as it's built, so
  // every widget test needs a real (if fake-backed) Supabase client —
  // otherwise `Supabase.instance` throws before any widget even renders.
  // SharedPreferences.setMockInitialValues avoids touching the platform
  // channel supabase_flutter's local-session persistence normally uses.
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'https://test.supabase.co', publishableKey: 'test-anon-key');
  });

  testWidgets('App shows the splash screen when there is no session',
      (WidgetTester tester) async {
    await tester.pumpWidget(const JobHuntAgentApp());

    expect(find.text('Get started'), findsOneWidget);
  });

  testWidgets('Splash screen leads to the auth screen', (WidgetTester tester) async {
    await tester.pumpWidget(const JobHuntAgentApp());
    await tester.tap(find.text('Get started'));
    // go_router navigation is an async route transition (the old AuthGate
    // switched synchronously via setState). Pump through the transition rather
    // than pumpAndSettle, which would hang on the splash's continuous animation.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('Continue with Google'), findsOneWidget);
  });

  testWidgets('Jobs list body shows the loader before jobs load',
      (WidgetTester tester) async {
    // No `await tester.pumpAndSettle()` here on purpose: the real HTTP call
    // never resolves in a widget test (no server running), so we only assert
    // the initial loading state renders without throwing.
    // JobsListBody reads Riverpod providers (Phase 2c), so it needs a
    // ProviderScope ancestor even in this render-only smoke test.
    await tester.pumpWidget(
      // Phase 10: JobsListBody now reads theme-aware `context.c`, so the test
      // MaterialApp must carry `appLight` (which registers the AppColors
      // ThemeExtension) — a bare MaterialApp has no extension and would throw.
      ProviderScope(child: MaterialApp(theme: appLight, home: const Scaffold(body: JobsListBody()))),
    );

    // Phase 5 (§Phase 5 acceptance): no skeleton survives in the tabs — a cold
    // load shows the brand AppLoader instead.
    expect(find.byType(AppLoader), findsOneWidget);
  });
}
