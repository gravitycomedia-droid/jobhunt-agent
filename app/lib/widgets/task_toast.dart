import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_metrics.dart';
import 'app_shell.dart' show navClusterHeight;

/// Phase 2: one ScaffoldMessenger for the whole app, attached to
/// [MaterialApp.scaffoldMessengerKey] in main.dart. Completion toasts fire
/// from TaskCenter (a service with no BuildContext), and must land on
/// whatever screen the user is on now — not the tab that started the task.
final GlobalKey<ScaffoldMessengerState> appScaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

/// Console/status-line style completion toast (Phase 2): monospace text,
/// "✓ Re-rank complete — 8 new, 12 skipped" / "✗ Job refresh failed" with
/// an optional Retry action.
///
/// Legibility fix: the fill used to be the accent at 12% alpha, which let
/// whatever sat underneath (usually the floating nav pill) read straight
/// through the toast. The floating nav is an overlay *inside* AppShell — not a
/// Scaffold `bottomNavigationBar` — so the messenger has no idea it exists and
/// can't route around it. Hence: an opaque fill, and a bottom margin equal to
/// the nav cluster's own height so the toast always sits clear above it.
void showTaskToast({required bool success, required String message, VoidCallback? onRetry}) {
  final messenger = appScaffoldMessengerKey.currentState;
  if (messenger == null) return; // app not mounted yet — nothing to show on

  // The messenger carries a BuildContext, so the toast can read theme-aware
  // colours even though it's fired from a service with no context of its own.
  final context = messenger.context;
  final c = context.c;
  final accent = success ? c.success : c.critical;

  // alphaBlend flattens the tint onto the surface so the result is fully
  // opaque — same tinted look, but nothing shows through it any more.
  final bg = Color.alphaBlend(accent.withValues(alpha: 0.14), c.surface);

  messenger.hideCurrentSnackBar(); // don't queue behind a stale toast
  messenger.showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      backgroundColor: bg,
      elevation: 6, // lifts it off the nav pill / cards underneath
      margin: EdgeInsets.fromLTRB(
        AppSpacing.space4,
        0,
        AppSpacing.space4,
        navClusterHeight(context) + AppSpacing.space2,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.mdRadius,
        side: BorderSide(color: accent, width: 1),
      ),
      duration: Duration(seconds: success ? 4 : 8),
      content: Row(
        children: [
          // The glyph keeps the status colour; the message itself uses primary
          // ink, which carries far more contrast against the tinted fill.
          Text(
            success ? '✓' : '✗',
            style: AppTypography.monoData.copyWith(fontSize: 14, color: accent, fontWeight: FontWeight.w700),
          ),
          const SizedBox(width: AppSpacing.space2),
          Expanded(
            child: Text(
              message,
              style: AppTypography.monoData.copyWith(fontSize: 13, color: c.ink),
            ),
          ),
        ],
      ),
      action: onRetry == null
          ? null
          : SnackBarAction(
              label: 'Retry',
              textColor: c.critical,
              onPressed: onRetry,
            ),
    ),
  );
}
