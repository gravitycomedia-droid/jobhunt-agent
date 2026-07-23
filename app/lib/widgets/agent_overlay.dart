import 'package:flutter/material.dart';

import '../models/background_task.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'agent_orb.dart';
import 'hold_button.dart';

/// Phase 3 — the "agent is working" overlay panel (FLUTTER_GUIDE §4/§7).
///
/// Presentational only: it renders a state derived from a real
/// [BackgroundTask] (`GET /tasks/{id}` → `pending|running|done|failed`). The
/// polling itself is wired at the call sites in Phase 5 — here we just map a
/// task's status to a surface. Drop it into a `Dialog`/`Stack`, or use
/// [showAgentOverlay].
class AgentOverlay extends StatelessWidget {
  const AgentOverlay({
    super.key,
    required this.task,
    this.runningCaption = 'The agent is working…',
    this.doneCaption = 'All done',
    this.onDone,
    this.onRetry,
  });

  /// Null is treated as "just started" (pending).
  final BackgroundTask? task;
  final String runningCaption;
  final String doneCaption;
  final VoidCallback? onDone;
  final VoidCallback? onRetry;

  bool get _failed => task?.status == 'failed';
  bool get _done => task?.status == 'done';

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Center(
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
            _visual(c),
            const SizedBox(height: 20),
            Text(
              _failed ? 'Something went wrong' : (_done ? doneCaption : runningCaption),
              textAlign: TextAlign.center,
              style: mono(14, w: FontWeight.w600, color: c.ink),
            ),
            if (_failed && task?.error != null) ...[
              const SizedBox(height: 8),
              Text(task!.error!, textAlign: TextAlign.center, style: mono(12, color: c.inkSoft)),
            ],
            if (_done || _failed) ...[
              const SizedBox(height: 20),
              if (_failed && onRetry != null)
                HoldButton(idleLabel: 'Hold to retry', onComplete: onRetry!)
              else if (onDone != null)
                HoldButton(idleLabel: 'Done', onComplete: onDone!),
            ],
          ],
        ),
      ),
    );
  }

  Widget _visual(AppColors c) {
    if (_failed) {
      return Icon(Icons.error_outline, size: 64, color: c.critical);
    }
    if (_done) {
      return Icon(Icons.check_circle_outline, size: 64, color: c.success);
    }
    return const AgentOrb(size: 96);
  }
}

/// Shows [AgentOverlay] as a modal barrier. Caller updates it by rebuilding
/// with a fresh [BackgroundTask] (Phase 5 wiring).
Future<void> showAgentOverlay(BuildContext context, {required Widget overlay}) {
  return showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => Dialog(backgroundColor: Colors.transparent, elevation: 0, child: overlay),
  );
}
