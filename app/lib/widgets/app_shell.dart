import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

import '../services/haptic_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_metrics.dart';
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

/// The floating nav pill's own height (icon puck + label + its inner padding).
const double kNavPillHeight = 60.0;

/// Gap between the content's last row and the top of the floating pill.
const double kNavPillTopGap = 4.0;

/// Gap between the pill and the bottom edge (the "floating" part). A fraction
/// of the device's own home-indicator inset is added *below* this — see
/// [navBottomInset].
const double kNavPillBottomGap = 6.0;

/// Height the scrollable content must leave clear at the bottom: exactly the
/// nav cluster's footprint (top gap + pill + bottom gap), nothing more. It
/// deliberately does NOT reserve room for the chat FAB — the FAB floats *over*
/// the content like the prototype does, so reserving for it left a band of dead
/// paper above the bar. The device inset is added on top via [navBottomInset].
const double kFloatingNavClearance = kNavPillTopGap + kNavPillHeight + kNavPillBottomGap;

/// How much of the device's bottom inset the pill sits above.
///
/// Honouring the *full* home-indicator inset (34pt on a modern iPhone) floated
/// the pill visibly up the screen and cost the content that much again. 60%
/// keeps the touch targets clear of the indicator's gesture strip while
/// reclaiming the rest for content.
double navBottomInset(BuildContext context) =>
    MediaQuery.viewPaddingOf(context).bottom * 0.6;

/// The full bottom gutter the nav cluster occupies on this device. One
/// definition shared by the content padding, the pill and the FAB, so they can
/// never drift apart.
double navClusterHeight(BuildContext context) =>
    kFloatingNavClearance + navBottomInset(context);

/// Portrait-first app frame: optional top app-bar, a scrollable content
/// region, the floating 5-destination bottom nav, and the agent-chat FAB.
///
/// The nav is a **floating pill** (prototype `showNav`): a rounded `surface`
/// capsule inset from the bottom and side edges, outlined with a hairline
/// border and lifted on a soft shadow, with the active item raised into an
/// `accentSoft` puck. On iOS the capsule is frosted (liquid glass) so whatever
/// sits behind it blurs through; on Android it's opaque `surface`. A 54px
/// accent **chat FAB** floats above the pill's right end and opens the career
/// agent from every primary screen ([onChatTap]).
class AppShell extends StatelessWidget {
  const AppShell({
    super.key,
    required this.child,
    this.active = 'home',
    this.onNavigate,
    this.onChatTap,
    this.destinations = kDefaultDestinations,
    this.title,
    this.trailing,
    this.showHeader = true,
  });

  /// Active destination key, matched against [AppDestination.key].
  final String active;

  /// Called with the tapped destination's key.
  final ValueChanged<String>? onNavigate;

  /// Opens the career-agent chat (the floating FAB). Null hides the FAB.
  final VoidCallback? onChatTap;

  final List<AppDestination> destinations;

  /// Top app-bar title. Ignored when [showHeader] is false.
  final String? title;

  /// Right-aligned header slot (icon buttons, etc).
  final Widget? trailing;

  /// Hide the top app-bar when a screen supplies its own hero header.
  final bool showHeader;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.c.paper,
      appBar: showHeader
          ? PreferredSize(
              preferredSize: const Size.fromHeight(AppSpacing.headerH),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: context.c.surface,
                  border: Border(bottom: BorderSide(color: context.c.border)),
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
      // The floating nav overlays the content, so the body fills the frame and
      // the content itself keeps `kFloatingNavClearance` of bottom padding.
      body: SafeArea(
        top: !showHeader,
        bottom: false,
        child: Stack(
          children: [
            Padding(
              // Bottom reserves exactly the pill's footprint (the tab bodies
              // scroll with EdgeInsets.zero and lean on this gutter), so the
              // last row stops right at the pill instead of leaving a band of
              // empty paper above it. The FAB overlaps content by design.
              padding: EdgeInsets.fromLTRB(
                AppSpacing.screenPadX,
                AppSpacing.space4,
                AppSpacing.screenPadX,
                navClusterHeight(context),
              ),
              child: child,
            ),
            // The pill and the FAB are siblings in THIS (full-screen) Stack, not
            // nested. A child positioned outside its parent's bounds still
            // paints under `Clip.none` but is NOT hit-testable — nesting the
            // FAB above a pill-sized Stack made it visible and untappable.
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  AppSpacing.space3,
                  kNavPillTopGap,
                  AppSpacing.space3,
                  kNavPillBottomGap + navBottomInset(context),
                ),
                child: _FloatingNav(
                  active: active,
                  destinations: destinations,
                  onNavigate: onNavigate,
                ),
              ),
            ),
            if (onChatTap != null)
              Positioned(
                right: AppSpacing.space5,
                // Rides above the pill's top edge, floating over the content.
                bottom: navClusterHeight(context) + AppSpacing.space2,
                child: _ChatFab(onTap: onChatTap!),
              ),
          ],
        ),
      ),
    );
  }
}

/// 54px accent chat FAB — opens the career agent from any primary screen.
class _ChatFab extends StatelessWidget {
  const _ChatFab({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Ask the career agent',
      child: Material(
        color: context.c.accent,
        shape: const CircleBorder(),
        elevation: 6,
        shadowColor: Colors.black.withValues(alpha: 0.35),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () {
            HapticService.instance.light();
            onTap();
          },
          child: SizedBox(
            width: 54,
            height: 54,
            child: Center(child: AppIcon(AppIconName.messageCircle, size: 24, color: context.onAccent)),
          ),
        ),
      ),
    );
  }
}

/// The floating nav pill — a rounded `surface` capsule with a hairline border
/// and a soft drop shadow, inset from the screen edges. iOS frosts it (liquid
/// glass) so content blurs through; Android keeps it opaque.
class _FloatingNav extends StatelessWidget {
  const _FloatingNav({required this.active, required this.destinations, this.onNavigate});

  final String active;
  final List<AppDestination> destinations;
  final ValueChanged<String>? onNavigate;

  @override
  Widget build(BuildContext context) {
    final isIOS = defaultTargetPlatform == TargetPlatform.iOS;
    final radius = BorderRadius.circular(26);

    final row = SizedBox(
      height: kNavPillHeight,
      child: Row(
        children: destinations.map((d) {
          return Expanded(
            child: _NavButton(
              destination: d,
              isActive: d.key == active,
              onTap: onNavigate == null ? null : () => onNavigate!(d.key),
            ),
          );
        }).toList(),
      ),
    );

    final border = Border.all(color: context.c.border);

    // The shadow has to live on a widget *outside* the clip, otherwise
    // ClipRRect eats it.
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: const [
          BoxShadow(color: Color(0x40000000), offset: Offset(0, 14), blurRadius: 34, spreadRadius: -14),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: isIOS
            ? BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: context.c.surface.withValues(alpha: 0.82),
                    borderRadius: radius,
                    border: border,
                  ),
                  child: row,
                ),
              )
            : DecoratedBox(
                decoration: BoxDecoration(
                  color: context.c.surface,
                  borderRadius: radius,
                  border: border,
                ),
                child: row,
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
    final color = isActive ? context.c.accent : context.c.inkFaint;
    return InkWell(
      onTap: onTap,
      borderRadius: AppRadius.pillRadius,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Active icon rides up 2px in a raised accentSoft puck (§7).
            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              transform: Matrix4.translationValues(0, isActive ? -2 : 0, 0),
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isActive ? context.c.accentSoft : Colors.transparent,
                shape: BoxShape.circle,
                boxShadow: isActive
                    ? [
                        BoxShadow(
                          color: context.c.accent.withValues(alpha: 0.28),
                          offset: const Offset(0, 8),
                          blurRadius: 16,
                          spreadRadius: -8,
                        ),
                      ]
                    : null,
              ),
              child: AppIcon(destination.icon, size: 21, color: color),
            ),
            const SizedBox(height: 2),
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
