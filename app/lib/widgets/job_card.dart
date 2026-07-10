import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';
import 'app_icon.dart';

/// Base job card — logo, title, company, location, source chip, plus
/// optional salary/posted date. Used directly for Jobs List and
/// Shortlist rows; [trailing] (a ScoreRing) and [children] (chips,
/// verdict pill) let MatchCard extend it without duplicating layout.
///
/// ```dart
/// JobCard(
///   title: 'Senior Product Designer',
///   company: 'Northwind',
///   location: 'San Francisco · Remote',
///   source: 'LinkedIn',
///   salary: r'$145K–$180K',
///   postedAt: '2 days ago',
///   bookmarked: true,
///   onBookmark: toggle,
/// )
/// ```
class JobCard extends StatelessWidget {
  const JobCard({
    super.key,
    required this.title,
    required this.company,
    this.location,
    this.source,
    this.salary,
    this.postedAt,
    this.logoUrl,
    this.bookmarked = false,
    this.onBookmark,
    this.onPress,
    this.trailing,
    this.children,
  });

  final String title;
  final String company;
  final String? location;

  /// Source name shown as an info chip, e.g. "Adzuna".
  final String? source;

  /// Compensation string, rendered in mono, e.g. "\$145K–\$180K".
  final String? salary;

  /// Posted-date string, e.g. "2 days ago".
  final String? postedAt;

  /// Company logo URL; falls back to a brand-tinted initial tile.
  final String? logoUrl;

  final bool bookmarked;

  /// When set, the default trailing bookmark button renders (unless
  /// [trailing] overrides the slot).
  final VoidCallback? onBookmark;

  final VoidCallback? onPress;

  /// Replaces the top-right slot — pass a ScoreRing here for MatchCard.
  final Widget? trailing;

  /// Extra content rendered below the meta row (chips, verdict pill,
  /// expandable body).
  final List<Widget>? children;

  @override
  Widget build(BuildContext context) {
    final hasMetaRow = location != null || postedAt != null || salary != null || source != null;

    return Material(
      color: AppColors.surface,
      borderRadius: AppRadius.lgRadius,
      child: InkWell(
        onTap: onPress,
        borderRadius: AppRadius.lgRadius,
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.border),
            borderRadius: AppRadius.lgRadius,
            boxShadow: AppElevation.e1,
          ),
          padding: const EdgeInsets.all(AppSpacing.space4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Logo(company: company, logoUrl: logoUrl),
                  const SizedBox(width: AppSpacing.space3),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: AppTypography.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 1),
                        Text(
                          company,
                          style: AppTypography.bodySm.copyWith(
                            color: AppColors.textSecondary,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 2),
                  trailing ?? (onBookmark != null ? _BookmarkButton(bookmarked: bookmarked, onTap: onBookmark!) : const SizedBox.shrink()),
                ],
              ),
              if (hasMetaRow) ...[
                const SizedBox(height: AppSpacing.space3),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (location != null) _Meta(icon: AppIconName.mapPin, text: location!),
                    if (postedAt != null) _Meta(icon: AppIconName.clock, text: postedAt!),
                    if (salary != null) _Meta(text: salary!, mono: true),
                    if (source != null) _SourceChip(source: source!),
                  ],
                ),
              ],
              if (children != null && children!.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.space3),
                ...children!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo({required this.company, this.logoUrl});

  final String company;
  final String? logoUrl;

  @override
  Widget build(BuildContext context) {
    final initial = company.trim().isEmpty ? '?' : company.trim()[0].toUpperCase();
    return Container(
      width: 42,
      height: 42,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: logoUrl == null ? AppColors.brandSoft : null,
        borderRadius: AppRadius.mdRadius,
        border: Border.all(color: AppColors.border),
        image: logoUrl != null ? DecorationImage(image: NetworkImage(logoUrl!), fit: BoxFit.cover) : null,
      ),
      child: logoUrl == null
          ? Text(
              initial,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18, color: AppColors.brand700),
            )
          : null,
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta({this.icon, required this.text, this.mono = false});

  final AppIconName? icon;
  final String text;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          AppIcon(icon!, size: 13, color: AppColors.textTertiary),
          const SizedBox(width: 4),
        ],
        Text(
          text,
          style: mono
              ? AppTypography.caption.copyWith(fontFamily: AppTypography.monoData.fontFamily, color: AppColors.textPrimary, fontWeight: FontWeight.w500)
              : AppTypography.caption,
        ),
      ],
    );
  }
}

class _SourceChip extends StatelessWidget {
  const _SourceChip({required this.source});

  final String source;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.infoSoft,
        border: Border.all(color: AppColors.infoBorder),
        borderRadius: AppRadius.pillRadius,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const AppIcon(AppIconName.externalLink, size: 11, color: AppColors.infoText),
            const SizedBox(width: 4),
            Text(
              source,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.infoText),
            ),
          ],
        ),
      ),
    );
  }
}

class _BookmarkButton extends StatelessWidget {
  const _BookmarkButton({required this.bookmarked, required this.onTap});

  final bool bookmarked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onTap,
      padding: const EdgeInsets.all(4),
      constraints: const BoxConstraints(),
      icon: AppIcon(
        AppIconName.bookmark,
        size: 20,
        color: bookmarked ? AppColors.brand600 : AppColors.neutral400,
      ),
    );
  }
}
