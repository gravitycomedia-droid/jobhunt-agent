import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';
import 'app_icon.dart';

/// One bottom-nav tab: a stable [key] (matched against [AppShell.active]),
/// the [label] shown under the icon, and the [icon] glyph.
class AppDestination {
  const AppDestination({required this.key, required this.label, required this.icon});

  final String key;
  final String label;
  final AppIconName icon;
}

const List<AppDestination> kDefaultDestinations = [
  AppDestination(key: 'home', label: 'Home', icon: AppIconName.home),
  AppDestination(key: 'jobs', label: 'Jobs', icon: AppIconName.briefcase),
  AppDestination(key: 'matches', label: 'Matches', icon: AppIconName.target),
  AppDestination(key: 'applications', label: 'Track', icon: AppIconName.columns),
  AppDestination(key: 'profile', label: 'Profile', icon: AppIconName.user),
];

/// Portrait-first app frame: optional top app-bar, a scrollable content
/// region, and the 5-destination bottom nav. Every screen composes on
/// top of this — it's the structural piece nothing else works without.
///
/// FlutterFlow analogy: this replaces FlutterFlow's Page Scaffold +
/// Bottom Navigation Bar widget combo, built by hand so every screen
/// shares one definition instead of each page configuring its own bar.
///
/// ```dart
/// AppShell(
///   active: 'jobs',
///   title: 'Jobs',
///   onNavigate: (key) => ...,
///   child: JobsListBody(),
/// )
/// ```
class AppShell extends StatelessWidget {
  const AppShell({
    super.key,
    required this.child,
    this.active = 'home',
    this.onNavigate,
    this.destinations = kDefaultDestinations,
    this.title,
    this.trailing,
    this.showHeader = true,
  });

  /// Active destination key, matched against [AppDestination.key].
  final String active;

  /// Called with the tapped destination's key. Destinations without a
  /// live screen yet can still render (greyed via [active] mismatch)
  /// but the caller decides what happens on tap — e.g. show a "coming
  /// in Brick N" message instead of navigating.
  final ValueChanged<String>? onNavigate;

  final List<AppDestination> destinations;

  /// Top app-bar title. Ignored when [showHeader] is false.
  final String? title;

  /// Right-aligned header slot (icon buttons, etc).
  final Widget? trailing;

  /// Hide the top app-bar when a screen supplies its own hero header
  /// (e.g. Home's greeting). Default true.
  final bool showHeader;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: showHeader
          ? PreferredSize(
              preferredSize: const Size.fromHeight(AppSpacing.headerH),
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  color: AppColors.surface,
                  border: Border(bottom: BorderSide(color: AppColors.border)),
                ),
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadX),
                    child: Row(
                      children: [
                        Text(title ?? '', style: AppTypography.headingSm),
                        const Spacer(),
                        ?trailing,
                      ],
                    ),
                  ),
                ),
              ),
            )
          : null,
      body: SafeArea(
        top: !showHeader,
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.screenPadX,
            AppSpacing.space4,
            AppSpacing.screenPadX,
            AppSpacing.space6,
          ),
          child: child,
        ),
      ),
      bottomNavigationBar: _BottomNav(
        active: active,
        destinations: destinations,
        onNavigate: onNavigate,
      ),
    );
  }
}

class _BottomNav extends StatelessWidget {
  const _BottomNav({required this.active, required this.destinations, this.onNavigate});

  final String active;
  final List<AppDestination> destinations;
  final ValueChanged<String>? onNavigate;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border)),
        boxShadow: AppElevation.e3,
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: AppSpacing.bottomNavH,
          child: Row(
            children: destinations.map((d) {
              final isActive = d.key == active;
              return Expanded(
                child: _NavButton(
                  destination: d,
                  isActive: isActive,
                  onTap: onNavigate == null ? null : () => onNavigate!(d.key),
                ),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({required this.destination, required this.isActive, this.onTap});

  final AppDestination destination;
  final bool isActive;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = isActive ? AppColors.navActive : AppColors.navInactive;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 40,
              height: 24,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isActive ? AppColors.brandSoft : Colors.transparent,
                borderRadius: AppRadius.pillRadius,
              ),
              child: AppIcon(destination.icon, size: 21, color: color),
            ),
            const SizedBox(height: 3),
            Text(
              destination.label,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: isActive ? FontWeight.w700 : FontWeight.w600,
                letterSpacing: 0.11,
                color: color,
                fontFamily: AppTypography.label.fontFamily,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
