import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'agent_mascot.dart';

/// Phase 3 — the standard loading state (FLUTTER_GUIDE §4).
///
/// The bobbing [AgentMascot] over a caption. This is what replaces the grey
/// skeleton shimmers at every call site (that rewiring happens in Phase 5 —
/// Phase 3 only builds the widget). Centres itself in whatever space it's given.
class MascotLoader extends StatelessWidget {
  const MascotLoader({super.key, this.caption = 'Working on it…', this.size = 72});

  final String caption;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AgentMascot(size: size),
          const SizedBox(height: 16),
          Text(
            caption,
            textAlign: TextAlign.center,
            style: mono(13, w: FontWeight.w500, color: c.inkSoft),
          ),
        ],
      ),
    );
  }
}
