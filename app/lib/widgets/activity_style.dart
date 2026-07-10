import 'package:flutter/material.dart';

import '../models/activity_item.dart';
import '../theme/app_tokens.dart';
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

ActivityGlyph activityGlyphFor(ActivityItem item) {
  if (item.type == 'followup') {
    return const ActivityGlyph(AppIconName.bell, AppColors.infoSoft, AppColors.infoText);
  }
  if (item.type == 'tailored') {
    return const ActivityGlyph(AppIconName.fileText, AppColors.brandSoft, AppColors.brand700);
  }
  // stage_change
  switch (item.stage) {
    case 'offer':
      return const ActivityGlyph(AppIconName.check, AppColors.successSoft, AppColors.successText);
    case 'rejected':
      return const ActivityGlyph(AppIconName.x, AppColors.criticalSoft, AppColors.criticalText);
    case 'interview':
    case 'replied':
      return const ActivityGlyph(AppIconName.arrowUpRight, AppColors.infoSoft, AppColors.infoText);
    case 'applied':
      return const ActivityGlyph(AppIconName.check, AppColors.infoSoft, AppColors.infoText);
    case 'saved':
    default:
      return const ActivityGlyph(AppIconName.bookmark, AppColors.neutralSoft, AppColors.neutralText);
  }
}
