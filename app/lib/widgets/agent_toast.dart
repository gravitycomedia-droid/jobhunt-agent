import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'task_toast.dart' show appScaffoldMessengerKey;

/// Phase 3 — the agent completion toast (FLUTTER_GUIDE §7).
///
/// The theme-aware successor to `task_toast.dart`'s `showTaskToast` (whose
/// call-site swap lands in Phase 5). Same contract — a floating, monospace
/// "✓ …/✗ …" toast with an optional Retry — but coloured from `context.c` so
/// it's correct in dark mode. Reuses the app-wide [appScaffoldMessengerKey] so
/// there is still exactly one messenger, wired in main.dart.
void showAgentToast({required bool success, required String message, VoidCallback? onRetry}) {
  final messenger = appScaffoldMessengerKey.currentState;
  if (messenger == null) return; // app not mounted yet — nothing to show on

  messenger.showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      backgroundColor: Colors.transparent,
      elevation: 0,
      padding: EdgeInsets.zero,
      duration: Duration(seconds: success ? 4 : 8),
      content: AgentToastContent(success: success, message: message, onRetry: onRetry),
    ),
  );
}

/// The toast body, split out so the debug gallery can render it inline (a live
/// `SnackBar` can't be shown in a static gallery tile).
class AgentToastContent extends StatelessWidget {
  const AgentToastContent({
    super.key,
    required this.success,
    required this.message,
    this.onRetry,
  });

  final bool success;
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final accent = success ? c.success : c.critical;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent),
      ),
      child: Row(
        children: [
          Icon(success ? Icons.check_circle : Icons.error, size: 18, color: accent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message, style: mono(13, w: FontWeight.w500, color: c.ink)),
          ),
          if (onRetry != null) ...[
            const SizedBox(width: 8),
            GestureDetector(
              onTap: onRetry,
              child: Text('Retry', style: mono(13, w: FontWeight.w700, color: c.accent)),
            ),
          ],
        ],
      ),
    );
  }
}
