import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// Phase 3 — the robot "agent" mascot (FLUTTER_GUIDE §4).
///
/// A `CustomPainter` robot that gently bobs (2600ms) and blinks (3600ms loop).
/// Used for loading states (with a caption — see [MascotLoader]), pull-to-
/// refresh, the chat greeting, and the About tile. The body colour follows the
/// theme accent; the visor/eyes are intrinsic features (fixed dark glass + white
/// eyes), not themeable tokens.
class AgentMascot extends StatefulWidget {
  const AgentMascot({super.key, this.size = 64, this.animate = true});

  final double size;

  /// Disable motion (e.g. reduced-motion, or a still gallery thumbnail).
  final bool animate;

  @override
  State<AgentMascot> createState() => _AgentMascotState();
}

class _AgentMascotState extends State<AgentMascot> with TickerProviderStateMixin {
  late final AnimationController _bob =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 2600));
  late final AnimationController _blink =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 3600));

  @override
  void initState() {
    super.initState();
    if (widget.animate) {
      _bob.repeat(reverse: true);
      _blink.repeat();
    }
  }

  @override
  void dispose() {
    _bob.dispose();
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = context.c.accent;
    return AnimatedBuilder(
      animation: Listenable.merge([_bob, _blink]),
      builder: (_, _) {
        final dy = -6 * (0.5 - (0.5 - _bob.value).abs()) * 2; // simple up/down
        final t = _blink.value;
        final eyeH = (t > 0.94 && t < 0.98) ? 0.15 : 1.0; // quick blink dip
        return Transform.translate(
          offset: Offset(0, dy),
          child: CustomPaint(
            size: Size(widget.size, widget.size),
            painter: _MascotPainter(accent, eyeH),
          ),
        );
      },
    );
  }
}

class _MascotPainter extends CustomPainter {
  _MascotPainter(this.accent, this.eyeH);

  final Color accent;
  final double eyeH;

  @override
  void paint(Canvas canvas, Size s) {
    final u = s.width / 64; // draw in a 64-unit space, scale to size
    Paint p(Color col) => Paint()..color = col;

    // antenna
    canvas.drawLine(
      Offset(32 * u, 5 * u),
      Offset(32 * u, 14 * u),
      Paint()
        ..color = accent
        ..strokeWidth = 3 * u
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawCircle(Offset(32 * u, 4 * u), 3.2 * u, p(accent));

    // ears + head
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(8 * u, 25 * u, 4 * u, 12 * u), Radius.circular(2 * u)),
      p(accent),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(52 * u, 25 * u, 4 * u, 12 * u), Radius.circular(2 * u)),
      p(accent),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(12 * u, 14 * u, 40 * u, 35 * u), Radius.circular(13 * u)),
      p(accent),
    );

    // visor (intrinsic dark glass)
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(17 * u, 21 * u, 30 * u, 20 * u), Radius.circular(10 * u)),
      p(const Color(0x47000000)),
    );

    // eyes (scaleY = eyeH for the blink)
    final eye = p(Colors.white);
    void drawEye(double cx) {
      canvas.save();
      canvas.translate(cx * u, 30 * u);
      canvas.scale(1, eyeH);
      canvas.drawCircle(Offset.zero, 3.4 * u, eye);
      canvas.restore();
    }

    drawEye(26);
    drawEye(38);

    // smile
    final smile = Path()
      ..moveTo(27 * u, 37 * u)
      ..quadraticBezierTo(32 * u, 40.5 * u, 37 * u, 37 * u);
    canvas.drawPath(
      smile,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 * u
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_MascotPainter o) => o.eyeH != eyeH || o.accent != accent;
}
