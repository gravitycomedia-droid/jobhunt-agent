import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jobhunt_agent/main.dart';
import 'package:jobhunt_agent/screens/jobs_list_screen.dart';

void main() {
  testWidgets('Home screen shows a loading indicator before the server responds',
      (WidgetTester tester) async {
    await tester.pumpWidget(const JobHuntAgentApp());

    // No `await tester.pumpAndSettle()` here on purpose: the real HTTP call
    // never resolves in a widget test (no server running), so we only assert
    // the initial loading state renders without throwing.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('Jobs list screen shows a loading indicator before jobs load',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: JobsListScreen()));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
