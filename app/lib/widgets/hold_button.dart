import 'package:flutter/material.dart';

import '../services/haptic_service.dart';
import '../theme/app_colors.dart';

/// Phase 3 — press-and-hold to confirm (FLUTTER_GUIDE §5).
///
/// The deliberate friction gate for consequential, hard-to-undo actions:
/// submit application, apply-as-is, approve-all-tailoring, submit-form, delete
/// account. Hold for 1100ms to fire [onComplete]; release early springs the
/// fill back over ~200ms and does nothing.
///
/// Per the plan this widget owns its haptics: a light tick on press-down and a
/// heavy confirm on completion, both routed through [HapticService] so the
/// Settings toggle still governs them.
class HoldButton extends StatefulWidget {
  const HoldButton({
    super.key,
    required this.idleLabel,
    this.activeLabel = 'Keep holding…',
    required this.onComplete,
  });

  final String idleLabel;
  final String activeLabel;
  final VoidCallback onComplete;

  @override
  State<HoldButton> createState() => _HoldButtonState();
}

class _HoldButtonState extends State<HoldButton> with SingleTickerProviderStateMixin {
  late final AnimationController _ac = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
    reverseDuration: const Duration(milliseconds: 200),
  )
    ..addStatusListener(_onStatus)
    ..addListener(() => setState(() {}));

  void _onStatus(AnimationStatus s) {
    if (s == AnimationStatus.completed) {
      HapticService.instance.medium(); // policy: hold-button complete = medium
      widget.onComplete();
    }
  }

  void _down(_) {
    HapticService.instance.light();
    _ac.forward();
  }

  void _up([_]) {
    if (!_ac.isCompleted) _ac.reverse(); // springs back over ~200ms
  }

  @override
  void dispose() {
    _ac.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final p = _ac.value;
    return GestureDetector(
      onTapDown: _down,
      onTapUp: _up,
      onTapCancel: _up,
      child: Container(
        height: 56,
        decoration: BoxDecoration(
          color: c.surface,
          border: Border.all(color: c.accent),
          borderRadius: BorderRadius.circular(15),
        ),
        clipBehavior: Clip.antiAlias,
        alignment: Alignment.center,
        child: Stack(
          alignment: Alignment.center,
          children: [
            FractionallySizedBox(
              widthFactor: p,
              alignment: Alignment.centerLeft,
              child: Container(color: c.accent.withValues(alpha: 0.16)),
            ),
            Text(
              p > 0 ? widget.activeLabel : widget.idleLabel,
              style: TextStyle(color: c.accent, fontWeight: FontWeight.w600, fontSize: 15),
            ),
          ],
        ),
      ),
    );
  }
}
