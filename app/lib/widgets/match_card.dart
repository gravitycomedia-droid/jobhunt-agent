import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';
import 'app_icon.dart';
import 'job_card.dart';
import 'score_ring.dart';
import 'status_pill.dart';

enum _ChipTone { strength, gap }

class _Chip extends StatelessWidget {
  const _Chip({required this.tone, required this.label});

  final _ChipTone tone;
  final String label;

  @override
  Widget build(BuildContext context) {
    final (bg, fg, bd) = tone == _ChipTone.strength
        ? (AppColors.successSoft, AppColors.successText, AppColors.successBorder)
        : (AppColors.warningSoft, AppColors.warningText, AppColors.warningBorder);
    return DecoratedBox(
      decoration: BoxDecoration(color: bg, border: Border.all(color: bd), borderRadius: AppRadius.pillRadius),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
        child: Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: fg)),
      ),
    );
  }
}

/// [JobCard] extended with a score ring, verdict pill, and strength/gap
/// chips. Collapses to a summary (2 strengths + 1 gap); expands to the
/// full chip lists and the primary "Tailor resume" action.
///
/// ```dart
/// MatchCard(
///   title: 'Senior Product Designer',
///   company: 'Northwind',
///   score: 82,
///   verdict: 'apply',
///   strengths: const ['5+ yrs Flutter', 'Shipped 2 apps'],
///   gaps: const ['No Kotlin experience'],
///   onTailor: () => ...,
/// )
/// ```
class MatchCard extends StatefulWidget {
  const MatchCard({
    super.key,
    required this.title,
    required this.company,
    required this.score,
    this.location,
    this.source,
    this.sourceUrl,
    this.salary,
    this.postedAt,
    this.logoUrl,
    this.onPress,
    this.verdict,
    this.strengths = const [],
    this.gaps = const [],
    this.defaultExpanded = false,
    this.onTailor,
    this.tailorLabel = 'Tailor resume',
    this.isNew = false,
  });

  final String title;
  final String company;
  final String? location;
  final String? source;
  final String? sourceUrl; // Phase 4A: passed through to JobCard's chip
  final String? salary;
  final String? postedAt;
  final String? logoUrl;
  final VoidCallback? onPress;

  /// Match score 0–100 (drives the ring).
  final num score;

  /// apply | stretch | skip.
  final String? verdict;

  /// Strength chips (green).
  final List<String> strengths;

  /// Gap chips (amber).
  final List<String> gaps;

  final bool defaultExpanded;

  /// Primary-action handler shown when expanded.
  final VoidCallback? onTailor;
  final String tailorLabel;

  /// §4.5: show the "NEW" badge (ranked within the last day).
  final bool isNew;

  @override
  State<MatchCard> createState() => _MatchCardState();
}

class _MatchCardState extends State<MatchCard> {
  late bool _open = widget.defaultExpanded;

  @override
  Widget build(BuildContext context) {
    final shownStrengths = _open ? widget.strengths : widget.strengths.take(2).toList();
    final shownGaps = _open ? widget.gaps : widget.gaps.take(1).toList();
    final hidden = widget.strengths.length + widget.gaps.length - shownStrengths.length - shownGaps.length;

    return JobCard(
      title: widget.title,
      company: widget.company,
      location: widget.location,
      source: widget.source,
      sourceUrl: widget.sourceUrl,
      salary: widget.salary,
      postedAt: widget.postedAt,
      logoUrl: widget.logoUrl,
      onPress: widget.onPress,
      trailing: ScoreRing(score: widget.score, size: 52),
      children: [
        DecoratedBox(
          decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.border))),
          child: Padding(
            padding: const EdgeInsets.only(top: AppSpacing.space3),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    if (widget.isNew) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(color: AppColors.brand600, borderRadius: AppRadius.smRadius),
                        child: const Text(
                          'NEW',
                          style: TextStyle(color: AppColors.textOnBrand, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 0.5),
                        ),
                      ),
                      const SizedBox(width: 6),
                    ],
                    if (widget.verdict != null) StatusPill(context: PillContext.verdict, value: widget.verdict!),
                    const Spacer(),
                    TextButton(
                      onPressed: () => setState(() => _open = !_open),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.all(2),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _open ? 'Less' : (hidden > 0 ? '+$hidden more' : 'Details'),
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textSecondary),
                          ),
                          const SizedBox(width: 3),
                          AnimatedRotation(
                            turns: _open ? 0.5 : 0,
                            duration: const Duration(milliseconds: 150),
                            child: const AppIcon(AppIconName.chevronDown, size: 15, color: AppColors.textSecondary),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.space3),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    ...shownStrengths.map((s) => _Chip(tone: _ChipTone.strength, label: s)),
                    ...shownGaps.map((g) => _Chip(tone: _ChipTone.gap, label: g)),
                  ],
                ),
                if (_open && widget.onTailor != null) ...[
                  const SizedBox(height: AppSpacing.space3),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(onPressed: widget.onTailor, child: Text(widget.tailorLabel)),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}
