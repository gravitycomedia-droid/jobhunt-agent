import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/haptic_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// Phase 3 — the celebration modal (FLUTTER_GUIDE §7/§8).
///
/// A pop-in card (350–400ms overshoot) under a burst of falling confetti
/// (~2200ms easeIn) — fired when a card lands in the Offer column, an
/// application is submitted, etc. Confetti is hand-painted (no extra package),
/// coloured from the theme + the shared gauge gradient.
class CelebrationModal extends StatefulWidget {
  const CelebrationModal({
    super.key,
    this.title = 'Offer! 🎉',
    this.message = 'One step closer to your first role.',
    this.buttonLabel = 'Nice',
    this.onDismiss,
  });

  final String title;
  final String message;
  final String buttonLabel;
  final VoidCallback? onDismiss;

  @override
  State<CelebrationModal> createState() => _CelebrationModalState();
}

class _CelebrationModalState extends State<CelebrationModal> with TickerProviderStateMixin {
  late final AnimationController _pop =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 400))..forward();
  late final AnimationController _fall =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 2200))..forward();

  late final List<_Confetto> _pieces;

  @override
  void initState() {
    super.initState();
    HapticService.instance.heavy(); // policy: celebration = one heavy tick
    final rnd = math.Random(7); // fixed seed → deterministic gallery/tests
    const palette = [
      Color(0xFFF5842B), Color(0xFFE0B33A), Color(0xFF2E9E6B), // gauge gradient
      Color(0xFF5750E8), Color(0xFF4B78C9),
    ];
    _pieces = List.generate(40, (i) {
      return _Confetto(
        x: rnd.nextDouble(),
        delay: rnd.nextDouble() * 0.35,
        drift: (rnd.nextDouble() - 0.5) * 0.25,
        rotSpeed: (rnd.nextDouble() - 0.5) * 8,
        size: 6 + rnd.nextDouble() * 6,
        color: palette[rnd.nextInt(palette.length)],
      );
    });
  }

  @override
  void dispose() {
    _pop.dispose();
    _fall.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: _fall,
              builder: (_, _) => CustomPaint(painter: _ConfettiPainter(_pieces, _fall.value)),
            ),
          ),
        ),
        Center(
          child: ScaleTransition(
            scale: CurvedAnimation(parent: _pop, curve: const Cubic(.2, 1.3, .4, 1)),
            child: Container(
              width: 300,
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: c.border),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(widget.title, textAlign: TextAlign.center, style: serifScore(30, c.ink)),
                  const SizedBox(height: 10),
                  Text(
                    widget.message,
                    textAlign: TextAlign.center,
                    style: mono(13, w: FontWeight.w500, color: c.inkSoft),
                  ),
                  const SizedBox(height: 22),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: widget.onDismiss,
                      style: FilledButton.styleFrom(
                        backgroundColor: c.accent,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      child: Text(widget.buttonLabel),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Fires [CelebrationModal] as a modal dialog.
Future<void> showCelebration(
  BuildContext context, {
  String title = 'Offer! 🎉',
  String message = 'One step closer to your first role.',
}) {
  return showDialog(
    context: context,
    barrierColor: Colors.black54,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: EdgeInsets.zero,
      child: CelebrationModal(
        title: title,
        message: message,
        onDismiss: () => Navigator.of(ctx).pop(),
      ),
    ),
  );
}

class _Confetto {
  _Confetto({
    required this.x,
    required this.delay,
    required this.drift,
    required this.rotSpeed,
    required this.size,
    required this.color,
  });

  final double x; // 0..1 start column
  final double delay; // 0..1 of the timeline
  final double drift; // horizontal drift fraction
  final double rotSpeed;
  final double size;
  final Color color;
}

class _ConfettiPainter extends CustomPainter {
  _ConfettiPainter(this.pieces, this.t);

  final List<_Confetto> pieces;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    for (final p in pieces) {
      final local = ((t - p.delay) / (1 - p.delay)).clamp(0.0, 1.0);
      if (local <= 0) continue;
      final eased = local * local; // easeIn
      final dx = (p.x + p.drift * eased) * size.width;
      final dy = eased * (size.height + 40) - 20;
      canvas.save();
      canvas.translate(dx, dy);
      canvas.rotate(p.rotSpeed * eased);
      final paint = Paint()..color = p.color.withValues(alpha: 1 - eased * 0.3);
      canvas.drawRect(
        Rect.fromCenter(center: Offset.zero, width: p.size, height: p.size * 0.5),
        paint,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ConfettiPainter o) => o.t != t;
}
