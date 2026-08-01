import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'agent_mascot.dart';

/// Which story the scene tells. Both come straight from the design handoff's
/// `_scene(kind)` (JobHuntAgent.dc.html): the agent at work, surrounded by the
/// artefacts it's working on.
enum AgentSceneKind {
  /// "Hunting fresh roles" — job cards drift in around the agent while it
  /// pulls tokens (skills, sources, your résumé) in out of the ether.
  searching,

  /// "Matching you to roles" — the agent shuffles two job cards side to side
  /// and sparks as it scores them.
  matching,
}

/// The animated agent scene used on the full-screen "the agent is working"
/// moments — first-run matching, cold job hunts.
///
/// Three layers, one 3.2s controller driving all of them (Flutter note: one
/// [AnimationController] repainting a subtree is far cheaper than a controller
/// per element, and every element below derives its own phase from the shared
/// `t` plus a fixed per-element offset):
///
///  1. **Job cards** — two mini cards that float ([AgentSceneKind.searching])
///     or shuffle ([AgentSceneKind.matching]) beside the agent.
///  2. **Tokens** — mono glyphs and source badges that fly *inward* and shrink
///     into the agent (the handoff's `suckin` keyframes): the agent visibly
///     grabbing your details.
///  3. **The mascot** — [AgentMascot], bobbing and blinking on top, so the
///     tokens disappear behind it.
///
/// Everything is deterministic (the "random" scatter is a fixed table), so the
/// scene is stable across rebuilds and reproducible in a widget test.
class AgentScene extends StatefulWidget {
  const AgentScene({
    super.key,
    this.kind = AgentSceneKind.matching,
    this.size = 220,
    this.animate = true,
  });

  final AgentSceneKind kind;

  /// Width AND height of the square the scene draws in.
  final double size;

  /// Disable motion (reduced-motion, or a still gallery thumbnail).
  final bool animate;

  @override
  State<AgentScene> createState() => _AgentSceneState();
}

/// One inbound token: what it says, where it starts (angle + radius, in the
/// scene's 220-unit design space), and how it's phased against the loop.
class _Token {
  const _Token(this.label, this.angle, this.radius, this.delay, {this.badge = false});

  final String label;
  final double angle; // radians
  final double radius; // distance from centre at the start of its flight
  final double delay; // 0..1 phase offset within the shared loop
  final bool badge; // true = filled source chip, false = mono glyph
}

// Fixed scatter — see the class doc on why this isn't Random(). Radii stay
// under half the 220-unit box so tokens start inside the scene rather than
// bleeding over the caption underneath it.
const _tokens = <_Token>[
  _Token('Dart', 0.30, 100, 0.00),
  _Token('LI', 0.95, 108, 0.12, badge: true),
  _Token('SQL', 1.55, 92, 0.24),
  _Token('PDF', 2.20, 104, 0.36),
  _Token('IN', 2.85, 96, 0.48, badge: true),
  _Token('★', 3.45, 106, 0.60),
  _Token('JS', 4.05, 90, 0.10),
  _Token('UN', 4.70, 102, 0.22, badge: true),
  _Token('AWS', 5.30, 98, 0.34),
  _Token('TS', 5.90, 106, 0.46),
];

class _AgentSceneState extends State<AgentScene> with SingleTickerProviderStateMixin {
  late final AnimationController _ac =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 3200));

  @override
  void initState() {
    super.initState();
    if (widget.animate) _ac.repeat();
  }

  @override
  void dispose() {
    _ac.dispose();
    super.dispose();
  }

  /// Design-space (220pt) → actual size.
  double _u(double v) => v * widget.size / 220;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _ac,
        builder: (context, _) {
          final t = _ac.value;
          return Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              ..._cards(t),
              ..._flyingTokens(t),
              AgentMascot(size: _u(64), animate: widget.animate),
              ..._sparks(t),
            ],
          );
        },
      ),
    );
  }

  // ── 1. the job cards beside the agent ───────────────────────────────────
  List<Widget> _cards(double t) {
    final isMatching = widget.kind == AgentSceneKind.matching;
    // A triangle wave 0→1→0 so both motions ease back to where they started.
    double wave(double phase) {
      final p = (t + phase) % 1.0;
      return p < 0.5 ? p * 2 : (1 - p) * 2;
    }

    Widget card(double left, double top, double phase, double tilt) {
      final w = wave(phase);
      return Positioned(
        left: _u(left),
        top: _u(top),
        child: Transform.translate(
          // Matching shuffles sideways; searching floats up and down.
          offset: isMatching ? Offset(_u(7 * w), 0) : Offset(0, _u(-9 * w)),
          child: Transform.rotate(
            angle: (isMatching ? 4 * w : tilt) * math.pi / 180,
            child: _MiniCard(width: _u(58), height: _u(52)),
          ),
        ),
      );
    }

    // The mascot owns the middle of the box (64pt centred ≈ 146–210 across,
    // 78–142 down), so the props sit clear of it: matching puts its two cards
    // in the bottom corners, searching floats three around the head.
    return isMatching
        ? [
            card(0, 152, 0.0, -6),
            card(162, 152, 0.3, 6),
          ]
        : [
            card(0, 4, 0.0, -8),
            card(162, 20, 0.3, 7),
            card(150, 156, 0.6, 4),
          ];
  }

  // ── 2. tokens flying into the agent ─────────────────────────────────────
  List<Widget> _flyingTokens(double t) {
    final c = context.c;
    return [
      for (final token in _tokens) ...[
        Builder(builder: (context) {
          final p = (t + token.delay) % 1.0;
          // Ease-in: slow drift, then a quick snap into the agent.
          final travelled = Curves.easeIn.transform(p);
          final start = Offset(
            math.cos(token.angle) * _u(token.radius),
            math.sin(token.angle) * _u(token.radius),
          );
          // Fade in over the first 18%, hold, fade out over the last 22% —
          // the handoff's `suckin` opacity ramp.
          final opacity = p < 0.18
              ? p / 0.18
              : p > 0.78
                  ? (1 - p) / 0.22
                  : 1.0;
          return Transform.translate(
            offset: Offset.lerp(start, Offset.zero, travelled)!,
            child: Transform.scale(
              scale: 1 - 0.75 * travelled,
              child: Opacity(
                opacity: opacity.clamp(0.0, 1.0),
                child: token.badge
                    ? Container(
                        width: _u(22),
                        height: _u(22),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: c.accent,
                          borderRadius: BorderRadius.circular(_u(6)),
                        ),
                        child: Text(
                          token.label,
                          style: mono(_u(9), w: FontWeight.w700, color: context.onAccent),
                        ),
                      )
                    : Text(
                        token.label,
                        style: mono(_u(15), w: FontWeight.w600, color: c.accent),
                      ),
              ),
            ),
          );
        }),
      ],
    ];
  }

  // ── 3. the scoring sparks (matching only) ───────────────────────────────
  List<Widget> _sparks(double t) {
    if (widget.kind != AgentSceneKind.matching) return const [];
    return [
      for (var i = 0; i < 3; i++)
        Positioned(
          // Between the two cards, under the mascot — the "scoring" spark.
          left: _u(88 + i * 22),
          top: _u(160 + (i.isOdd ? -14 : 8)),
          child: Opacity(
            // 0.3 ↔ 1 pulse, each spark a beat behind the last (`zap`).
            opacity: 0.3 + 0.7 * (0.5 - (0.5 - ((t + i * 0.25) % 1.0)).abs()) * 2,
            child: Icon(Icons.auto_awesome, size: _u(13), color: context.c.accent),
          ),
        ),
    ];
  }
}

/// The little "job card" prop: a surface tile with two placeholder text lines.
class _MiniCard extends StatelessWidget {
  const _MiniCard({required this.width, required this.height});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    Widget line(double widthFactor, Color color) => FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: widthFactor,
          child: Container(
            height: 4,
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
          ),
        );

    return Container(
      width: width,
      height: height,
      padding: const EdgeInsets.all(7),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(8),
        boxShadow: const [
          BoxShadow(color: Color(0x4D000000), offset: Offset(0, 6), blurRadius: 14, spreadRadius: -8),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          line(0.70, c.accentSoft),
          const SizedBox(height: 5),
          line(0.45, c.border),
          const SizedBox(height: 5),
          line(0.58, c.border),
        ],
      ),
    );
  }
}
