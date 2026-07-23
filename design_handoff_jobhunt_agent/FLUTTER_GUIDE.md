# Flutter Implementation Guide — Job-Hunt Agent

Ready-to-adapt Dart. Structure suggestion:

```
lib/
  theme/app_colors.dart      // token sets + ThemeExtension
  theme/app_theme.dart       // ThemeData light/dark
  widgets/fit_gauge.dart     // CRED-style score gauge (CustomPainter + count anim)
  widgets/agent_mascot.dart  // robot mascot (CustomPainter + bob/blink)
  widgets/hold_button.dart   // press-and-hold-to-confirm
  widgets/source_chip.dart   // brand monogram tile
  screens/…                  // one file per screen
```

Add to `pubspec.yaml`:
```yaml
dependencies:
  flutter:
    sdk: flutter
  google_fonts: ^6.2.1
```

---

## 1. Tokens as a ThemeExtension

Because the palette has more roles than Material's `ColorScheme`, expose them via a `ThemeExtension` so `Theme.of(context).extension<AppColors>()!` works and swaps with the theme.

```dart
// theme/app_colors.dart
import 'package:flutter/material.dart';

@immutable
class AppColors extends ThemeExtension<AppColors> {
  final Color ink, inkSoft, inkFaint, paper, surface, surface2,
      accent, accentSoft, border, success, warning, critical, info;

  const AppColors({
    required this.ink, required this.inkSoft, required this.inkFaint,
    required this.paper, required this.surface, required this.surface2,
    required this.accent, required this.accentSoft, required this.border,
    required this.success, required this.warning, required this.critical,
    required this.info,
  });

  static const light = AppColors(
    ink: Color(0xFF14141C), inkSoft: Color(0xFF5B5B66), inkFaint: Color(0xFF9A9AA3),
    paper: Color(0xFFFAFAF9), surface: Color(0xFFFFFFFF), surface2: Color(0xFFF4F4F3),
    accent: Color(0xFF5750E8), accentSoft: Color(0x1A5750E8), border: Color(0xFFE7E7EA),
    success: Color(0xFF2E9E6B), warning: Color(0xFFB9852F),
    critical: Color(0xFFD2544B), info: Color(0xFF4B78C9),
  );

  static const dark = AppColors(
    ink: Color(0xFFF2F2F5), inkSoft: Color(0xFFA7A7B2), inkFaint: Color(0xFF6A6A76),
    paper: Color(0xFF0E0E13), surface: Color(0xFF17171F), surface2: Color(0xFF1E1E28),
    accent: Color(0xFF7A73FF), accentSoft: Color(0x267A73FF), border: Color(0xFF26262F),
    success: Color(0xFF3FB57F), warning: Color(0xFFD6A24E),
    critical: Color(0xFFE56A61), info: Color(0xFF6E97DE),
  );

  // Gauge arc gradient (same in both themes)
  static const gaugeGradient = [Color(0xFFF5842B), Color(0xFFE0B33A), Color(0xFF2E9E6B)];

  @override
  AppColors copyWith({Color? ink, Color? inkSoft, Color? inkFaint, Color? paper,
      Color? surface, Color? surface2, Color? accent, Color? accentSoft, Color? border,
      Color? success, Color? warning, Color? critical, Color? info}) => AppColors(
        ink: ink ?? this.ink, inkSoft: inkSoft ?? this.inkSoft, inkFaint: inkFaint ?? this.inkFaint,
        paper: paper ?? this.paper, surface: surface ?? this.surface, surface2: surface2 ?? this.surface2,
        accent: accent ?? this.accent, accentSoft: accentSoft ?? this.accentSoft, border: border ?? this.border,
        success: success ?? this.success, warning: warning ?? this.warning,
        critical: critical ?? this.critical, info: info ?? this.info,
      );

  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppColors(
      ink: l(ink, other.ink), inkSoft: l(inkSoft, other.inkSoft), inkFaint: l(inkFaint, other.inkFaint),
      paper: l(paper, other.paper), surface: l(surface, other.surface), surface2: l(surface2, other.surface2),
      accent: l(accent, other.accent), accentSoft: l(accentSoft, other.accentSoft), border: l(border, other.border),
      success: l(success, other.success), warning: l(warning, other.warning),
      critical: l(critical, other.critical), info: l(info, other.info),
    );
  }
}

// Convenience accessor
extension AppColorsX on BuildContext {
  AppColors get c => Theme.of(this).extension<AppColors>()!;
}
```

## 2. Theme + fonts

```dart
// theme/app_theme.dart
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'app_colors.dart';

TextTheme _text(Color ink) => GoogleFonts.interTextTheme().apply(bodyColor: ink, displayColor: ink);

ThemeData _base(AppColors c, Brightness b) => ThemeData(
      brightness: b,
      scaffoldBackgroundColor: c.paper,
      colorScheme: ColorScheme.fromSeed(seedColor: c.accent, brightness: b)
          .copyWith(primary: c.accent, surface: c.surface, error: c.critical),
      textTheme: _text(c.ink),
      extensions: [c],
    );

final appLight = _base(AppColors.light, Brightness.light);
final appDark = _base(AppColors.dark, Brightness.dark);

// Monospace for numerals; serif for the hero score
TextStyle mono(double size, {FontWeight w = FontWeight.w500, Color? color}) =>
    GoogleFonts.jetBrainsMono(fontSize: size, fontWeight: w, color: color);
TextStyle serifScore(double size, Color color) =>
    GoogleFonts.playfairDisplay(fontSize: size, fontWeight: FontWeight.w800, color: color, height: 1);
```

Wire it: `MaterialApp(theme: appLight, darkTheme: appDark, themeMode: _mode)` and flip `_mode` from the Profile toggle.

## 3. Fit gauge (CRED-style) — CustomPainter + count-and-correct animation

270° arc opening at the bottom, gradient stroke, live-tracking fill, serif number that overshoots then settles.

```dart
// widgets/fit_gauge.dart
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

class FitGauge extends StatefulWidget {
  final int target;        // e.g. 92
  final int delta;         // e.g. 4  (shows +4 ↑)
  final bool play;         // trigger the reveal when true
  const FitGauge({super.key, required this.target, this.delta = 0, this.play = true});
  @override State<FitGauge> createState() => _FitGaugeState();
}

class _FitGaugeState extends State<FitGauge> with SingleTickerProviderStateMixin {
  late final AnimationController _ac =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1420));
  double _val = 0;

  @override void initState() {
    super.initState();
    _ac.addListener(_tick);
    if (widget.play) _start();
  }
  void _start() { _ac..reset()..forward(); }
  void _tick() {
    // 0..900ms ease-out to overshoot(97); 900..1420ms ease-in-out down to target(92)
    final ms = _ac.value * 1420;
    final over = (widget.target + 5).toDouble();
    double v;
    if (ms < 900) { final k = ms / 900; v = over * (1 - math.pow(1 - k, 3)); }
    else { final k = ((ms - 900) / 520).clamp(0, 1).toDouble();
      final e = k < .5 ? 2*k*k : 1 - math.pow(-2*k + 2, 2) / 2; v = over + (widget.target - over) * e; }
    setState(() => _val = v);
  }
  @override void dispose() { _ac.dispose(); super.dispose(); }

  @override Widget build(BuildContext context) {
    final c = context.c;
    return SizedBox(width: 260, height: 200, child: Stack(alignment: Alignment.center, children: [
      CustomPaint(size: const Size(260, 200), painter: _GaugePainter(_val / 100, c.border)),
      Column(mainAxisSize: MainAxisSize.min, children: [
        if (widget.delta != 0) Row(mainAxisSize: MainAxisSize.min, children: [
          Text('+${widget.delta}', style: mono(13, w: FontWeight.w600, color: c.success)),
          Icon(Icons.arrow_upward, size: 12, color: c.success),
        ]),
        Text('${_val.round()}', style: serifScore(82, c.ink)),
        Text('FIT SCORE', style: mono(12, w: FontWeight.w600, color: c.accent).copyWith(letterSpacing: 2)),
      ]),
      Positioned(left: 8, bottom: 30, child: Text('0', style: mono(12, color: c.inkFaint))),
      Positioned(right: 8, bottom: 30, child: Text('100', style: mono(12, color: c.inkFaint))),
    ]));
  }
}

class _GaugePainter extends CustomPainter {
  final double frac; final Color track;
  _GaugePainter(this.frac, this.track);
  @override void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2 + 8);
    final r = 92.0;
    const start = math.pi * 0.75;      // 135°
    const sweep = math.pi * 1.5;       // 270°
    final rect = Rect.fromCircle(center: center, radius: r);
    final base = Paint()..style = PaintingStyle.stroke..strokeWidth = 9
      ..strokeCap = StrokeCap.round..color = track;
    canvas.drawArc(rect, start, sweep, false, base);
    final grad = Paint()..style = PaintingStyle.stroke..strokeWidth = 9..strokeCap = StrokeCap.round
      ..shader = const SweepGradient(startAngle: start, endAngle: start + sweep,
        colors: AppColors.gaugeGradient).createShader(rect);
    canvas.drawArc(rect, start, sweep * frac.clamp(0, 1), false, grad);
  }
  @override bool shouldRepaint(_GaugePainter o) => o.frac != frac || o.track != track;
}
```
For Matches cards use a plain small ring (`CircularProgressIndicator(value: score/100)` styled, or a tiny `_GaugePainter` at 360°) — the big animated gauge was intentionally removed from Matches.

## 4. Agent mascot — CustomPainter + bob & blink

```dart
// widgets/agent_mascot.dart
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

class AgentMascot extends StatefulWidget {
  final double size;
  const AgentMascot({super.key, this.size = 64});
  @override State<AgentMascot> createState() => _AgentMascotState();
}
class _AgentMascotState extends State<AgentMascot> with TickerProviderStateMixin {
  late final _bob = AnimationController(vsync: this, duration: const Duration(milliseconds: 2600))..repeat(reverse: true);
  late final _blink = AnimationController(vsync: this, duration: const Duration(milliseconds: 3600))..repeat();
  @override void dispose() { _bob.dispose(); _blink.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) {
    final accent = context.c.accent;
    return AnimatedBuilder(animation: Listenable.merge([_bob, _blink]), builder: (_, __) {
      final dy = -6 * (0.5 - (0.5 - _bob.value).abs()) * 2; // simple up/down
      final t = _blink.value;
      final eyeH = (t > 0.94 && t < 0.98) ? 0.15 : 1.0; // quick blink
      return Transform.translate(offset: Offset(0, dy),
        child: CustomPaint(size: Size(widget.size, widget.size), painter: _MascotPainter(accent, eyeH)));
    });
  }
}
class _MascotPainter extends CustomPainter {
  final Color accent; final double eyeH;
  _MascotPainter(this.accent, this.eyeH);
  @override void paint(Canvas canvas, Size s) {
    final u = s.width / 64; Paint p(Color col) => Paint()..color = col;
    // antenna
    canvas.drawLine(Offset(32*u,5*u), Offset(32*u,14*u), Paint()..color=accent..strokeWidth=3*u..strokeCap=StrokeCap.round);
    canvas.drawCircle(Offset(32*u,4*u), 3.2*u, p(accent));
    // ears + head
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(8*u,25*u,4*u,12*u), Radius.circular(2*u)), p(accent));
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(52*u,25*u,4*u,12*u), Radius.circular(2*u)), p(accent));
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(12*u,14*u,40*u,35*u), Radius.circular(13*u)), p(accent));
    // visor
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(17*u,21*u,30*u,20*u), Radius.circular(10*u)), p(const Color(0x47000000)));
    // eyes (scaleY = eyeH)
    final eye = p(Colors.white);
    void drawEye(double cx) {
      canvas.save(); canvas.translate(cx*u, 30*u); canvas.scale(1, eyeH);
      canvas.drawCircle(Offset.zero, 3.4*u, eye); canvas.restore();
    }
    drawEye(26); drawEye(38);
    // smile
    final smile = Path()..moveTo(27*u,37*u)..quadraticBezierTo(32*u,40.5*u,37*u,37*u);
    canvas.drawPath(smile, Paint()..color=Colors.white..style=PaintingStyle.stroke..strokeWidth=2*u..strokeCap=StrokeCap.round);
  }
  @override bool shouldRepaint(_MascotPainter o) => o.eyeH != eyeH || o.accent != accent;
}
```
Use the mascot for: **loading states** (with a caption below — no skeletons), **pull-to-refresh** (wrap in `Transform.scale(scale: 0.45 + pull*0.55)`), **chat greeting**, **about** center tile. The breathing "orb" for onboarding/tailoring is a `Container` with a radial-gradient `BoxDecoration` scaled by a repeating controller (1.0↔1.05).

## 5. Press-and-hold to confirm

```dart
// widgets/hold_button.dart
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

class HoldButton extends StatefulWidget {
  final String idleLabel, activeLabel;
  final VoidCallback onComplete;
  const HoldButton({super.key, required this.idleLabel, this.activeLabel = 'Keep holding…', required this.onComplete});
  @override State<HoldButton> createState() => _HoldButtonState();
}
class _HoldButtonState extends State<HoldButton> with SingleTickerProviderStateMixin {
  late final _ac = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))
    ..addStatusListener((s) { if (s == AnimationStatus.completed) widget.onComplete(); })
    ..addListener(() => setState(() {}));
  void _down(_) => _ac.forward();
  void _up([_]) { if (!_ac.isCompleted) _ac.reverse(); }  // springs back over ~200ms
  @override void dispose() { _ac.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) {
    final c = context.c; final p = _ac.value;
    return GestureDetector(onTapDown: _down, onTapUp: _up, onTapCancel: _up,
      child: Container(height: 56, decoration: BoxDecoration(
        color: c.surface, border: Border.all(color: c.accent), borderRadius: BorderRadius.circular(15)),
        clipBehavior: Clip.antiAlias, alignment: Alignment.center,
        child: Stack(alignment: Alignment.center, children: [
          FractionallySizedBox(widthFactor: p, alignment: Alignment.centerLeft,
            child: Container(color: c.accent.withOpacity(0.16))),
          Text(p > 0 ? widget.activeLabel : widget.idleLabel,
            style: TextStyle(color: c.accent, fontWeight: FontWeight.w600, fontSize: 15)),
        ])));
  }
}
```
Use for: submit application, apply-as-is, approve-all-tailoring, submit-form. **Never** use a plain button for these.

## 6. Source chip (brand monogram tile)

```dart
// widgets/source_chip.dart — swap monogram for a real logo asset when available
final brand = {
  'LinkedIn': (const Color(0xFF0A66C2), 'in'), 'Indeed': (const Color(0xFF2557A7), 'Id'),
  'Unstop': (const Color(0xFF5B3DF6), 'U'), 'Internshala': (const Color(0xFF0087C5), 'i'),
  'Naukri': (const Color(0xFF4A76BC), 'N'),
};
Widget logoTile(String name, {double size = 18}) {
  final (col, mono) = brand[name]!;
  return Container(width: size, height: size, alignment: Alignment.center,
    decoration: BoxDecoration(color: col, borderRadius: BorderRadius.circular(size * 0.28)),
    child: Text(mono, style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: size * 0.5)));
}
```

## 7. Signature layout pieces (map from the prototype)

- **Bottom nav**: a floating rounded pill (`Container` radius 26, `surface`, shadow) with 5 items; the active item's icon sits in a raised `accentSoft` circle translated up 3px. Chat **FAB** = 54px accent circle positioned above the pill's right edge.
- **Cards**: `surface` bg, `1px border` (`border`), radius 14–18, shadow `0 6–14 18–34 -8…-14 black@.3`.
- **State pills** (Populated/Loading/Empty/Error): active = `ink` bg + `paper` text; inactive = `surface` + `border` + `inkSoft`.
- **Salary chip / any numeral**: mono font, `surface2` bg, `border`, radius 8.
- **Wallet card**: `LinearGradient(accent → accent·60%·#111)`, white text, two soft translucent circles, white "Top up" + outline "Manage".
- **Filter sheet**: `showModalBottomSheet` (isScrollControlled), radius-24 top; source cards horizontal `ListView`; work-type = segmented `Row`; salary = a `RangeSlider`/`Slider` under a 17-bar histogram `Row` (bars past the value → `accent`, else `border`); location chips with landmark icons.
- **Kanban**: `Row` of 4 columns; use `Draggable`/`DragTarget` per card/column; dropping in Offer → confetti.
- **Progress bars / résumé completion**: hatched remainder = a `DecoratedBox` with a repeating diagonal gradient, filled portion an `accent` bar.

## 8. Animation reference (durations & curves)

| Motion | Duration | Curve |
|---|---|---|
| Score count-up | 900ms | easeOutCubic |
| Score correct-down | 520ms | easeInOut |
| Press-and-hold fill | 1100ms fwd / 200ms back | linear / easeOut |
| Card enter (riseup) | 400–450ms | cubic(.2,.9,.2,1) |
| Pop-in (modals) | 350–400ms | cubic(.2,1.3,.4,1) (overshoot) |
| Mascot bob | 2600ms | easeInOut, reverse-repeat |
| Mascot blink | 3600ms loop | quick scaleY dip |
| Orb breathe | 3000ms | easeInOut, reverse-repeat, scale 1↔1.05 |
| Spinner (agent working) | 1000ms | linear loop |
| Sheet slide-up | 300ms | cubic(.2,.9,.2,1) |
| Confetti fall | 1600–2900ms | easeIn |

## 9. Screen scaffold pattern

```dart
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});
  @override Widget build(BuildContext context) {
    final c = context.c;
    return Scaffold(
      backgroundColor: c.paper,
      body: SafeArea(child: ListView(padding: const EdgeInsets.fromLTRB(20, 14, 20, 96), children: [
        // greeting row + bell …
        // state pills …
        Center(child: FitGauge(target: 92, delta: 4)),
        // dark "refresh now" pill, "LAST UPDATED …"
        // top-match card, "New jobs today", "Agent activity"
      ])),
    );
  }
}
```
Keep the router simple (a `StatefulWidget` holding `screen` + `IndexedStack`, or `go_router`). The prototype's left "Jump to" rail is a review aid — omit it.

---

**Fidelity reminder:** match colors/spacing/type to the tokens above; when unsure, open `JobHuntAgent.dc.html` — every value is inline. Replace drawn logo/landmark glyphs with real assets. All data is mocked; wire the flagged backend endpoints (see README "Backend notes").
