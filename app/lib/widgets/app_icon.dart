import 'package:flutter/material.dart';

/// The design system's `Icon` primitive substitutes Lucide line glyphs
/// (custom SVG paths — no Flutter equivalent shipped). Rather than hand
/// -painting 24 custom `Path`s, this maps each design-system icon name
/// to the closest stock Material "outlined" icon, which already reads
/// as thin-stroke/line-style and needs no extra package. The design
/// system's own readme flags the Lucide set as swappable for exactly
/// this reason.
enum AppIconName {
  // ---- Bottom-nav destinations ----
  home,
  briefcase,
  target,
  columns,
  user,
  // ---- Meta / chrome ----
  mapPin,
  building,
  externalLink,
  search,
  bell,
  bookmark,
  // ---- Verdict / guardrail / status glyphs ----
  check,
  x,
  minus,
  arrowUpRight,
  alertTriangle,
  info,
  // ---- Structure / interaction ----
  chevronDown,
  chevronRight,
  chevronLeft,
  refresh,
  plus,
  clock,
  bot,
  upload,
  fileText,
  dollarSign,
  trendingUp,
  settings,
}

const Map<AppIconName, IconData> _iconMap = {
  AppIconName.home: Icons.home_outlined,
  AppIconName.briefcase: Icons.work_outline,
  AppIconName.target: Icons.track_changes_outlined,
  AppIconName.columns: Icons.view_column_outlined,
  AppIconName.user: Icons.person_outline,
  AppIconName.mapPin: Icons.location_on_outlined,
  AppIconName.building: Icons.business_outlined,
  AppIconName.externalLink: Icons.open_in_new,
  AppIconName.search: Icons.search,
  AppIconName.bell: Icons.notifications_outlined,
  AppIconName.bookmark: Icons.bookmark_outline,
  AppIconName.check: Icons.check,
  AppIconName.x: Icons.close,
  AppIconName.minus: Icons.remove,
  AppIconName.arrowUpRight: Icons.north_east,
  AppIconName.alertTriangle: Icons.warning_amber_outlined,
  AppIconName.info: Icons.info_outline,
  AppIconName.chevronDown: Icons.keyboard_arrow_down,
  AppIconName.chevronRight: Icons.chevron_right,
  AppIconName.chevronLeft: Icons.chevron_left,
  AppIconName.refresh: Icons.refresh,
  AppIconName.plus: Icons.add,
  AppIconName.clock: Icons.access_time,
  AppIconName.bot: Icons.smart_toy_outlined,
  AppIconName.upload: Icons.upload_outlined,
  AppIconName.fileText: Icons.description_outlined,
  AppIconName.dollarSign: Icons.attach_money,
  AppIconName.trendingUp: Icons.trending_up,
  AppIconName.settings: Icons.settings_outlined,
};

/// Line-icon primitive — use for all in-app iconography instead of
/// reaching for `Icons.*` directly, so a future glyph-set swap is a
/// one-file change.
///
/// ```dart
/// AppIcon(AppIconName.briefcase, size: 22)
/// AppIcon(AppIconName.check, color: AppColors.successFill)
/// ```
class AppIcon extends StatelessWidget {
  const AppIcon(this.name, {super.key, this.size = 20, this.color});

  final AppIconName name;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Icon(_iconMap[name], size: size, color: color);
  }
}
