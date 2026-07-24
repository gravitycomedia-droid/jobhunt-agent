import 'package:flutter/material.dart';

import '../models/activity_item.dart';
import '../theme/app_colors.dart';
import 'app_icon.dart';

/// Icon + colors for one [ActivityItem], shared between
/// [ActivityLogScreen]'s full feed and Home's "Recent activity" teaser —
/// same tone-map pattern as [StatusPill]'s stage colors, just rendered as
/// a glyph circle instead of a pill.
class ActivityGlyph {
  const ActivityGlyph(this.icon, this.bg, this.fg);
  final AppIconName icon;
  final Color bg;
  final Color fg;
}

/// Colours come from the active theme, so glyphs flip with dark mode. Soft
/// backgrounds are the role tint at 12% (mirrors the old `*Soft` aliases).
ActivityGlyph activityGlyphFor(BuildContext context, ActivityItem item) {
  final c = context.c;
  ActivityGlyph glyph(AppIconName icon, Color role) =>
      ActivityGlyph(icon, role.withValues(alpha: 0.12), role);

  if (item.type == 'followup') {
    return glyph(AppIconName.bell, c.info);
  }
  if (item.type == 'tailored') {
    return glyph(AppIconName.fileText, c.accent);
  }
  // stage_change
  switch (item.stage) {
    case 'offer':
      return glyph(AppIconName.check, c.success);
    case 'rejected':
      return glyph(AppIconName.x, c.critical);
    case 'interview':
    case 'replied':
      return glyph(AppIconName.arrowUpRight, c.info);
    case 'applied':
      return glyph(AppIconName.check, c.info);
    case 'saved':
    default:
      return glyph(AppIconName.bookmark, c.inkSoft);
  }
}
