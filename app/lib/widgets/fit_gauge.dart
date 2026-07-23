import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// Phase 3 (frontend rebuild v2) — the CRED-style "fit score" gauge.
///
/// A 270° arc that opens at the bottom, stroked with the shared
/// [AppColors.gaugeGradient], plus a serif number that *overshoots* the target
/// by +5 then eases back down — the signature reveal from FLUTTER_GUIDE §3.
///
/// Timings are exact per the plan / §8: 0–900ms `easeOutCubic` up to
/// `target + 5`, then 900–1420ms `easeInOut` correct-down to `target`.
///
/// Dart notes for the FlutterFlow builder:
/// - `with SingleTickerProviderStateMixin` gives us one `AnimationController`
///   "ticker" — the equivalent of a FlutterFlow animation timeline.
/// - `late final` = initialised once, lazily, non-null after that.
class FitGauge extends StatefulWidget {
  const FitGauge({super.key, required this.target, this.delta = 0, this.play = true});

  /// The final score to settle on, e.g. 92.
  final int target;

  /// Optional "+N ↑" badge above the number (0 hides it).
  final int delta;

  /// Play the reveal animation when true; false shows the settled value.
  final bool play;

  @override
  State<FitGauge> createState() => _FitGaugeState();
}

class _FitGaugeState extends State<FitGauge> with SingleTickerProviderStateMixin {
  // 1420ms total = 900ms count-up + 520ms correct-down.
  late final AnimationController _ac =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1420));
  double _val = 0;

  @override
  void initState() {
    super.initState();
    _ac.addListener(_tick);
    if (widget.play) {
      _start();
    } else {
      _val = widget.target.toDouble();
    }
  }

  @override
  void didUpdateWidget(covariant FitGauge old) {
    super.didUpdateWidget(old);
    // Let the gallery (or a screen) re-trigger the reveal by flipping `play`.
    if (widget.play && !old.play) _start();
    if (!widget.play && old.play) {
      _ac.stop();
      setState(() => _val = widget.target.toDouble());
    }
  }

  void _start() => _ac
    ..reset()
    ..forward();

  void _tick() {
    final ms = _ac.value * 1420;
    final over = (widget.target + 5).toDouble();
    double v;
    if (ms < 900) {
      // easeOutCubic up to the overshoot value.
      final k = ms / 900;
      v = over * (1 - math.pow(1 - k, 3).toDouble());
    } else {
      // easeInOut back down from overshoot to the true target.
      final k = ((ms - 900) / 520).clamp(0.0, 1.0);
      final e = k < .5 ? 2 * k * k : 1 - math.pow(-2 * k + 2, 2).toDouble() / 2;
      v = over + (widget.target - over) * e;
    }
    setState(() => _val = v);
  }

  @override
  void dispose() {
    _ac.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return SizedBox(
      width: 260,
      height: 200,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: const Size(260, 200),
            painter: _GaugePainter(_val / 100, c.border),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.delta != 0)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('+${widget.delta}', style: mono(13, w: FontWeight.w600, color: c.success)),
                    Icon(Icons.arrow_upward, size: 12, color: c.success),
                  ],
                ),
              Text('${_val.round()}', style: serifScore(82, c.ink)),
              Text(
                'FIT SCORE',
                style: mono(12, w: FontWeight.w600, color: c.accent).copyWith(letterSpacing: 2),
              ),
            ],
          ),
          Positioned(left: 8, bottom: 30, child: Text('0', style: mono(12, color: c.inkFaint))),
          Positioned(right: 8, bottom: 30, child: Text('100', style: mono(12, color: c.inkFaint))),
        ],
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  _GaugePainter(this.frac, this.track);

  final double frac;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2 + 8);
    const r = 92.0;
    const start = math.pi * 0.75; // 135°
    const sweep = math.pi * 1.5; // 270°
    final rect = Rect.fromCircle(center: center, radius: r);

    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9
      ..strokeCap = StrokeCap.round
      ..color = track;
    canvas.drawArc(rect, start, sweep, false, base);

    final grad = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9
      ..strokeCap = StrokeCap.round
      ..shader = const SweepGradient(
        startAngle: start,
        endAngle: start + sweep,
        colors: AppColors.gaugeGradient,
      ).createShader(rect);
    canvas.drawArc(rect, start, sweep * frac.clamp(0.0, 1.0), false, grad);
  }

  @override
  bool shouldRepaint(_GaugePainter o) => o.frac != frac || o.track != track;
}
