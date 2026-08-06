import 'package:flutter/material.dart';

import '../services/haptic_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_metrics.dart';
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
/// the right. Colours from `context.c`, sizing from app_metrics — no hardcoded
/// hex/px.
class PageHeader extends StatelessWidget implements PreferredSizeWidget {
  const PageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.showBack = false,
    this.embedded = false,
    this.actions = const [],
    this.backgroundColor,
    this.foregroundColor,
  });

  final String title;
  final String? subtitle;
  final bool showBack;

  /// True when placed inside a tab body's Column (no surface/hairline of
  /// its own — the shell provides the chrome); false in the appBar slot.
  final bool embedded;

  final List<Widget> actions;

  /// Null everywhere except the Smart Apply in-app browser, which sets both
  /// to stand out from the rest of the app AND from the website loaded below
  /// it — a plain `context.c.surface` header there reads as part of the
  /// page, not as this app's own chrome. [foregroundColor] must be passed
  /// whenever [backgroundColor] is, since the title/subtitle text has no
  /// color of its own otherwise (it inherits the ambient default, which
  /// assumes the ordinary `context.c.surface` background every other screen
  /// uses) — [HeaderActionButton] doesn't need one, it already paints its
  /// own opaque circle behind each icon regardless of what's behind it.
  final Color? backgroundColor;
  final Color? foregroundColor;

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
            onPressed: () {
              HapticService.instance.selection();
              Navigator.of(context).pop();
            },
          ),
          const SizedBox(width: AppSpacing.space3),
        ],
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: AppTypography.headingSm.copyWith(color: foregroundColor),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (subtitle != null)
                Text(
                  subtitle!,
                  style: AppTypography.caption.copyWith(color: foregroundColor ?? context.c.inkSoft),
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
      decoration: BoxDecoration(
        color: backgroundColor ?? context.c.surface,
        // A hairline matching the neutral border colour would look like a
        // rendering mistake against a solid accent fill — omit it there.
        border: backgroundColor == null ? Border(bottom: BorderSide(color: context.c.border)) : null,
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
    this.showDot = false,
  });

  final AppIconName icon;
  final String tooltip;
  final VoidCallback? onPressed;

  /// Replaces the glyph with a small spinner and disables taps — for
  /// actions that start background tasks (refresh, re-rank).
  final bool busy;

  /// A small brand dot in the top-right corner — the "a filter is active"
  /// indicator on the Jobs filter button (§4.3). Suppressed while [busy].
  final bool showDot;

  @override
  Widget build(BuildContext context) {
    final button = IconButton(
      tooltip: tooltip,
      onPressed: busy || onPressed == null
          ? null
          : () {
              HapticService.instance.selection();
              onPressed!();
            },
      icon: busy
          ? SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: context.c.accent),
            )
          : AppIcon(icon, size: 18, color: context.c.inkSoft),
      style: IconButton.styleFrom(
        backgroundColor: context.c.surface,
        side: BorderSide(color: context.c.border),
        shape: const CircleBorder(),
      ),
    );
    if (!showDot || busy) return button;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        button,
        Positioned(
          top: 2,
          right: 2,
          child: Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              color: context.c.accent,
              shape: BoxShape.circle,
              border: Border.all(color: context.c.surface, width: 1.5),
            ),
          ),
        ),
      ],
    );
  }
}
