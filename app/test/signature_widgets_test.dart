import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jobhunt_agent/screens/debug_gallery_screen.dart';
import 'package:jobhunt_agent/theme/app_theme.dart';
import 'package:jobhunt_agent/widgets/activity_log_item.dart';
import 'package:jobhunt_agent/widgets/agent_scene.dart';
import 'package:jobhunt_agent/widgets/app_banner.dart';
import 'package:jobhunt_agent/widgets/app_shell.dart';
import 'package:jobhunt_agent/widgets/app_loader.dart';
import 'package:jobhunt_agent/widgets/celebration_modal.dart';
import 'package:jobhunt_agent/widgets/fit_gauge.dart';
import 'package:jobhunt_agent/widgets/hatched_progress.dart';
import 'package:jobhunt_agent/widgets/hold_button.dart';
import 'package:jobhunt_agent/widgets/score_ring.dart';
import 'package:jobhunt_agent/widgets/source_chip.dart';
import 'package:jobhunt_agent/widgets/status_pill.dart';

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

    testWidgets('renders a signed delta badge', (tester) async {
      await tester.pumpWidget(_host(
        const FitGauge(target: 80, delta: 5, play: false),
        theme: appLight,
      ));
      await tester.pump();
      expect(find.text('+5'), findsOneWidget);
    });
  });

  // Phase 10: the token migration made every signature widget theme-aware.
  // These smoke both light and dark to prove `context.c` resolves in each
  // (a missing ThemeExtension would throw a null-check) and that nothing
  // paints out of bounds.
  group('theme-aware widgets build in light and dark', () {
    Future<void> pumpBoth(WidgetTester tester, Widget child) async {
      for (final theme in [appLight, appDark]) {
        await tester.pumpWidget(_host(child, theme: theme));
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
      }
    }

    testWidgets('StatusPill across all three contexts', (tester) async {
      await pumpBoth(
        tester,
        const Column(children: [
          StatusPill(context: PillContext.verdict, value: 'apply'),
          StatusPill(context: PillContext.guardrail, value: 'fail'),
          StatusPill(context: PillContext.stage, value: 'interview'),
        ]),
      );
      expect(find.text('Apply'), findsOneWidget);
    });

    testWidgets('AppBanner tones', (tester) async {
      await pumpBoth(
        tester,
        const AppBanner(tone: BannerTone.warning, title: 'Heads up', message: 'A note.'),
      );
      expect(find.text('Heads up'), findsOneWidget);
    });

    testWidgets('ScoreRing shows the rounded score', (tester) async {
      await pumpBoth(tester, const ScoreRing(score: 82));
      // The score renders as a RichText ('82' + '%' spans), so match on
      // contained text with findRichText (default finders skip RichText).
      expect(find.textContaining('82', findRichText: true), findsOneWidget);
    });

    testWidgets('AppLoader (indeterminate) does not crash', (tester) async {
      await pumpBoth(tester, const AppLoader());
      expect(find.byType(AppLoader), findsOneWidget);
    });

    testWidgets('ActivityLogItem by kind', (tester) async {
      await pumpBoth(
        tester,
        const ActivityLogItem(
          kind: ActivityKind.agent,
          title: 'Daily pipeline ran',
          detail: '5 new matches',
          timestamp: '2h ago',
          last: true,
        ),
      );
      expect(find.text('Daily pipeline ran'), findsOneWidget);
    });

    testWidgets('HatchedProgress at partial fill', (tester) async {
      await pumpBoth(tester, const HatchedProgress(value: 0.6));
      expect(find.byType(HatchedProgress), findsOneWidget);
    });

    testWidgets('CelebrationModal renders its confetti burst', (tester) async {
      await pumpBoth(tester, const CelebrationModal(title: 'Offer! 🎉'));
      expect(find.text('Offer! 🎉'), findsOneWidget);
    });

    testWidgets('AgentScene runs both kinds without crashing', (tester) async {
      for (final kind in AgentSceneKind.values) {
        await pumpBoth(tester, AgentScene(kind: kind, size: 200));
        // Cross the loop boundary so the token fade-out and wrap-around are
        // exercised, not just the first frames.
        await tester.pump(const Duration(milliseconds: 3300));
        expect(tester.takeException(), isNull);
      }
    });
  });

  group('AppShell floating nav', () {
    testWidgets('leaves the content exactly the pill\'s footprint, no more', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: appLight,
        home: AppShell(
          onChatTap: () {},
          onNavigate: (_) {},
          child: const SizedBox.expand(child: Text('content')),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      expect(tester.takeException(), isNull);
      // The gutter under the content is the nav cluster's own footprint —
      // regression guard for the dead band the docked bar used to leave.
      expect(kFloatingNavClearance, kNavPillTopGap + kNavPillHeight + kNavPillBottomGap);

      final contentBottom = tester.getRect(find.text('content')).bottom;
      final navTop = tester.getRect(find.byType(InkWell).first).top;
      // Content stops at (or just above) the pill — never a screen-height gap.
      expect(navTop - contentBottom, lessThan(kNavPillHeight));
    });

    testWidgets('the chat FAB is tappable where it is painted', (tester) async {
      // Regression guard: the FAB floats ABOVE the pill. Parented under a
      // pill-sized Stack it painted (Clip.none) but sat outside that box, and
      // Flutter does not hit-test outside a parent's bounds — so it looked fine
      // and did nothing. It must be a sibling of the pill in the full-screen
      // Stack.
      var chatTaps = 0;
      var navTaps = 0;
      await tester.pumpWidget(MaterialApp(
        theme: appLight,
        home: AppShell(
          onChatTap: () => chatTaps++,
          onNavigate: (_) => navTaps++,
          child: const SizedBox.expand(),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.bySemanticsLabel('Ask the career agent'));
      await tester.pump();
      expect(chatTaps, 1);

      await tester.tap(find.text('Matches'));
      await tester.pump();
      expect(navTaps, 1);
    });
  });
}
