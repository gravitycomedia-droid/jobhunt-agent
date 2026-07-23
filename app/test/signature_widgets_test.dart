import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jobhunt_agent/screens/debug_gallery_screen.dart';
import 'package:jobhunt_agent/theme/app_theme.dart';
import 'package:jobhunt_agent/widgets/fit_gauge.dart';
import 'package:jobhunt_agent/widgets/hold_button.dart';
import 'package:jobhunt_agent/widgets/source_chip.dart';

/// Phase 3 acceptance tests for the signature widget library.
///
/// NB: several widgets (mascot, orb) run *infinite* repeating animations, so
/// these tests must `pump(Duration)` and never `pumpAndSettle()` — the latter
/// would time out waiting for animations that never end.
Widget _host(Widget child, {required ThemeData theme}) =>
    MaterialApp(theme: theme, home: Scaffold(body: child));

void main() {
  // appLight/appDark are top-level finals that call GoogleFonts on first
  // access, which needs the binding — so initialise it before any theme is read.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DebugGalleryScreen renders in both themes', () {
    for (final name in ['light', 'dark']) {
      testWidgets('builds without error — $name', (tester) async {
        final theme = name == 'dark' ? appDark : appLight;
        await tester.pumpWidget(MaterialApp(theme: theme, home: const DebugGalleryScreen()));
        // Advance the infinite mascot/orb/gauge animations a few frames.
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(milliseconds: 1000));

        expect(tester.takeException(), isNull);
        expect(find.text('Widget Gallery'), findsOneWidget);
        // FitGauge sits at the top of the lazy ListView, so it's built; the
        // lower sections (SourceChip etc.) are exercised in their own groups.
        expect(find.byType(FitGauge), findsOneWidget);
      });
    }

    testWidgets('in-gallery theme toggle flips without error', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: DebugGalleryScreen()));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byType(Switch));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
    });
  });

  group('SourceChip', () {
    testWidgets('renders a known brand, an unknown source, and empty without crashing',
        (tester) async {
      await tester.pumpWidget(_host(
        const Wrap(children: [
          SourceChip(source: 'LinkedIn'), // case-insensitive known
          SourceChip(source: 'some_brand_new_board'), // unknown → fallback
          SourceChip(source: ''), // empty → '?' fallback
        ]),
        theme: appLight,
      ));
      expect(tester.takeException(), isNull);
      expect(find.byType(SourceChip), findsNWidgets(3));
      expect(find.text('in'), findsOneWidget); // LinkedIn monogram
      expect(find.text('?'), findsOneWidget); // empty fallback
    });
  });

  group('HoldButton', () {
    testWidgets('fires onComplete only after the full 1100ms hold', (tester) async {
      var completed = false;
      await tester.pumpWidget(_host(
        HoldButton(idleLabel: 'Hold to submit', onComplete: () => completed = true),
        theme: appLight,
      ));

      final gesture = await tester.startGesture(tester.getCenter(find.byType(HoldButton)));
      await tester.pump(); // let onTapDown resolve and start the fill controller
      await tester.pump(const Duration(milliseconds: 500));
      expect(completed, isFalse, reason: 'must not fire before the hold completes');

      await tester.pump(const Duration(milliseconds: 700)); // total 1200ms > 1100ms
      expect(completed, isTrue);
      await gesture.up();
      await tester.pump();
    });

    testWidgets('releasing early does not fire onComplete', (tester) async {
      var completed = false;
      await tester.pumpWidget(_host(
        HoldButton(idleLabel: 'Hold to submit', onComplete: () => completed = true),
        theme: appLight,
      ));

      final gesture = await tester.startGesture(tester.getCenter(find.byType(HoldButton)));
      await tester.pump(); // let onTapDown resolve
      await tester.pump(const Duration(milliseconds: 400));
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 400)); // let it spring back
      expect(completed, isFalse);
    });
  });

  group('FitGauge', () {
    testWidgets('play:false shows the target value immediately', (tester) async {
      await tester.pumpWidget(_host(
        const FitGauge(target: 87, play: false),
        theme: appLight,
      ));
      await tester.pump();
      expect(find.text('87'), findsOneWidget);
    });
  });
}
