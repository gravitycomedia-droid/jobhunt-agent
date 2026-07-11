import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';
import 'app_icon.dart';

/// Phase 3A: the one header every screen uses instead of the old
/// "Job Hunt Agent"-branded AppBar. Two placements:
///
/// - **Tab roots** (Jobs/Matches/Track/Profile bodies): embedded as the
///   first child of the body Column, no back button — bottom-nav roots
///   have nowhere to pop to.
/// - **Pushed sub-screens**: passed to `Scaffold(appBar: ...)` (it
///   implements [PreferredSizeWidget]) with `showBack: true`, giving every
///   pushed screen the same back affordance via [Navigator.pop].
///
/// Large title, optional subtitle/count line, contextual action icons on
/// the right. All values from app_tokens — no hardcoded hex/px.
class PageHeader extends StatelessWidget implements PreferredSizeWidget {
  const PageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.showBack = false,
    this.embedded = false,
    this.actions = const [],
  });

  final String title;
  final String? subtitle;
  final bool showBack;

  /// True when placed inside a tab body's Column (no surface/hairline of
  /// its own — the shell provides the chrome); false in the appBar slot.
  final bool embedded;

  final List<Widget> actions;

  @override
  Size get preferredSize => const Size.fromHeight(AppSpacing.headerH);

  @override
  Widget build(BuildContext context) {
    final content = Row(
      children: [
        if (showBack) ...[
          HeaderActionButton(
            icon: AppIconName.chevronLeft,
            tooltip: 'Back',
            onPressed: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: AppSpacing.space3),
        ],
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: AppTypography.headingSm, maxLines: 1, overflow: TextOverflow.ellipsis),
              if (subtitle != null)
                Text(
                  subtitle!,
                  style: AppTypography.caption.copyWith(color: AppColors.textSecondary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
        for (final action in actions) ...[
          const SizedBox(width: AppSpacing.space2),
          action,
        ],
      ],
    );

    // In the appBar slot (pushed sub-screens) we paint our own surface +
    // hairline; embedded in a tab body the shell's background already
    // matches, so it's just the row.
    if (embedded) {
      return SizedBox(height: AppSpacing.headerH, child: content);
    }
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadX),
          child: content,
        ),
      ),
    );
  }
}

/// Circular bordered icon button used in [PageHeader.actions] — same look
/// as Home's activity bell so header actions read as one family.
class HeaderActionButton extends StatelessWidget {
  const HeaderActionButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.busy = false,
  });

  final AppIconName icon;
  final String tooltip;
  final VoidCallback? onPressed;

  /// Replaces the glyph with a small spinner and disables taps — for
  /// actions that start background tasks (refresh, re-rank).
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: busy ? null : onPressed,
      icon: busy
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.brand),
            )
          : AppIcon(icon, size: 18, color: AppColors.textSecondary),
      style: IconButton.styleFrom(
        backgroundColor: AppColors.surface,
        side: const BorderSide(color: AppColors.border),
        shape: const CircleBorder(),
      ),
    );
  }
}
