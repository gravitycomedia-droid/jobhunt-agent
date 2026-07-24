import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_metrics.dart';

/// Phase 2 start-of-task dialog: tells the user a long operation kicked off
/// and runs in the background, then gets out of the way. Informational
/// only — it never blocks the task (which is already running server-side)
/// and is dismissible by tap-outside or the "Got it" button.
Future<void> showBackgroundTaskDialog(BuildContext context, String title, String message) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: context.c.surface,
      shape: RoundedRectangleBorder(borderRadius: AppRadius.lgRadius),
      title: Row(
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2.5, color: context.c.accent),
          ),
          const SizedBox(width: AppSpacing.space3),
          Expanded(child: Text(title, style: AppTypography.title)),
        ],
      ),
      content: Text(message, style: AppTypography.bodySm.copyWith(color: context.c.inkSoft)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Got it'),
        ),
      ],
    ),
  );
}
