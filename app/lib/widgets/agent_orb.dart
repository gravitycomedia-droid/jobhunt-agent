import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// Phase 3 — the breathing "agent" orb (FLUTTER_GUIDE §4 tail + §8).
///
/// A radial-gradient circle that breathes by scaling 1.0 ↔ 1.05 on a 3000ms
/// ease-in-out reverse-repeat loop. Used behind onboarding / tailoring "agent
/// is thinking" moments. Colours come from the theme accent, so it's correct in
/// both light and dark.
class AgentOrb extends StatefulWidget {
  const AgentOrb({super.key, this.size = 120, this.animate = true});

  final double size;
  final bool animate;

  @override
  State<AgentOrb> createState() => _AgentOrbState();
}

class _AgentOrbState extends State<AgentOrb> with SingleTickerProviderStateMixin {
  late final AnimationController _ac =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 3000));
  late final Animation<double> _scale =
      Tween(begin: 1.0, end: 1.05).animate(CurvedAnimation(parent: _ac, curve: Curves.easeInOut));

  @override
  void initState() {
    super.initState();
    if (widget.animate) _ac.repeat(reverse: true);
  }

  @override
  void dispose() {
    _ac.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return ScaleTransition(
      scale: _scale,
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [c.accent, c.accent.withValues(alpha: 0.55), c.accentSoft],
            stops: const [0.0, 0.6, 1.0],
          ),
          boxShadow: [
            BoxShadow(
              color: c.accent.withValues(alpha: 0.35),
              blurRadius: widget.size * 0.3,
              spreadRadius: widget.size * 0.02,
            ),
          ],
        ),
      ),
    );
  }
}
