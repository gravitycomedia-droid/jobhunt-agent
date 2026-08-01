import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/job.dart';
import '../services/job_filter.dart';
import '../theme/app_colors.dart';
import '../theme/app_metrics.dart';
import 'app_icon.dart';
import 'source_chip.dart';

/// Opens the Jobs filter sheet (§4.4). [pool] is the already-loaded shared job
/// list — the sheet reads it for its counts, salary histogram, and live
/// "Show N" total, and **never fetches** (master-plan Phase-6 acceptance: "the
/// sheet triggers no fetch"). Filter state lives entirely in [jobFilterProvider],
/// so what the user toggles here is the same state the list and header read.
Future<void> showJobFilterSheet(BuildContext context, {required List<Job> pool}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.c.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
    ),
    builder: (_) => _JobFilterSheet(pool: pool),
  );
}

const _kWorkTypes = <(String?, String)>[
  (null, 'Any'),
  ('remote', 'Remote'),
  ('hybrid', 'Hybrid'),
  ('onsite', 'Onsite'),
];

const _kSalaryBuckets = 17; // §4.4 "17 bars"

class _JobFilterSheet extends ConsumerStatefulWidget {
  const _JobFilterSheet({required this.pool});
  final List<Job> pool;

  @override
  ConsumerState<_JobFilterSheet> createState() => _JobFilterSheetState();
}

class _JobFilterSheetState extends ConsumerState<_JobFilterSheet> {
  /// In-flight slider position, held locally so the drag stays smooth and the
  /// live count updates per frame; committed to the provider on release.
  RangeValues? _salaryDraft;

  List<double> get _salaries => [
        for (final j in widget.pool)
          if (jobSalaryValue(j) != null) jobSalaryValue(j)!,
      ];

  @override
  Widget build(BuildContext context) {
    final filter = ref.watch(jobFilterProvider);
    final notifier = ref.read(jobFilterProvider.notifier);

    final salaries = _salaries..sort();
    final hasSalary = salaries.length > 1 && salaries.first < salaries.last;
    final domainMin = hasSalary ? salaries.first : 0.0;
    final domainMax = hasSalary ? salaries.last : 0.0;

    // The salary the count/preview should use: the in-flight drag if any, else
    // the committed filter. A drag spanning the full domain means "no salary
    // constraint", same as clearing it.
    final SalaryRange? previewSalary = _salaryDraft != null
        ? (_isFullDomain(_salaryDraft!, domainMin, domainMax)
            ? null
            : SalaryRange(_salaryDraft!.start, _salaryDraft!.end))
        : filter.salary;
    final preview = JobFilter(
      sources: filter.sources,
      workType: filter.workType,
      salary: previewSalary,
      locations: filter.locations,
    );
    final shownCount = widget.pool.where(preview.matches).length;
    final canClear = filter.isActive || _salaryDraft != null;

    // Source → count, busiest first (mirrors the server facets ordering).
    final sourceCounts = <String, int>{};
    for (final j in widget.pool) {
      sourceCounts[j.source] = (sourceCounts[j.source] ?? 0) + 1;
    }
    final sources = sourceCounts.keys.toList()..sort((a, b) => sourceCounts[b]!.compareTo(sourceCounts[a]!));

    return SafeArea(
      child: Padding(
        // viewInsets keeps the footer above the keyboard — none here, but cheap
        // insurance if a field is ever added.
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: AppSpacing.space3),
            _grabber(),
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.space5, AppSpacing.space4, AppSpacing.space5, 0),
              child: Row(
                children: [
                  Text('Filter jobs', style: AppTypography.headingSm),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: AppIcon(AppIconName.x, size: 20, color: context.c.inkSoft),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(AppSpacing.space5, AppSpacing.space4, AppSpacing.space5, AppSpacing.space5),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Category leads the sheet (ADR-003 v3): it's now the axis
                    // that decides most of what the user sees, since the pool
                    // spans every discipline rather than just their target role.
                    _sectionLabel('Category'),
                    _categoryChips(filter, notifier),
                    const SizedBox(height: AppSpacing.space6),
                    _sectionLabel('Source'),
                    _sourceRow(sources, sourceCounts, filter, notifier),
                    const SizedBox(height: AppSpacing.space6),
                    _sectionLabel('Work type'),
                    _workTypeControl(filter, notifier),
                    if (hasSalary) ...[
                      const SizedBox(height: AppSpacing.space6),
                      _sectionLabel('Salary'),
                      _salarySection(filter, notifier, domainMin, domainMax),
                    ],
                    const SizedBox(height: AppSpacing.space6),
                    _sectionLabel('Location'),
                    _locationChips(filter, notifier),
                  ],
                ),
              ),
            ),
            _footer(shownCount, canClear, notifier),
          ],
        ),
      ),
    );
  }

  Widget _grabber() => Container(
        width: 40,
        height: 4,
        decoration: BoxDecoration(color: context.c.border, borderRadius: AppRadius.pillRadius),
      );

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.space3),
        child: Text(text.toUpperCase(), style: AppTypography.label.copyWith(color: context.c.inkFaint, letterSpacing: 0.6)),
      );

  // ── Source cards ──────────────────────────────────────────────────────────
  Widget _sourceRow(List<String> sources, Map<String, int> counts, JobFilter filter, JobFilterNotifier notifier) {
    if (sources.isEmpty) {
      return Text('No sources in the current pool', style: AppTypography.bodySm.copyWith(color: context.c.inkFaint));
    }
    return SizedBox(
      height: 96,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        itemCount: sources.length,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.space3),
        itemBuilder: (_, i) {
          final s = sources[i];
          final selected = filter.sources.contains(s);
          return _SourceCard(
            source: s,
            count: counts[s] ?? 0,
            selected: selected,
            onTap: () => notifier.toggleSource(s),
          );
        },
      ),
    );
  }

  // ── Work type segmented control ─────────────────────────────────────────────
  Widget _workTypeControl(JobFilter filter, JobFilterNotifier notifier) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: context.c.surface2, borderRadius: AppRadius.pillRadius),
      child: Row(
        children: [
          for (final (value, label) in _kWorkTypes)
            Expanded(
              child: GestureDetector(
                onTap: () => notifier.setWorkType(value),
                behavior: HitTestBehavior.opaque,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: filter.workType == value ? context.c.surface : Colors.transparent,
                    borderRadius: AppRadius.pillRadius,
                    boxShadow: filter.workType == value ? AppElevation.e1 : null,
                  ),
                  child: Text(
                    label,
                    style: AppTypography.bodySm.copyWith(
                      fontWeight: FontWeight.w600,
                      color: filter.workType == value ? context.c.accent : context.c.inkSoft,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ── Salary histogram + range slider ─────────────────────────────────────────
  Widget _salarySection(JobFilter filter, JobFilterNotifier notifier, double domainMin, double domainMax) {
    final current = _salaryDraft ??
        (filter.salary != null
            ? RangeValues(filter.salary!.min.clamp(domainMin, domainMax), filter.salary!.max.clamp(domainMin, domainMax))
            : RangeValues(domainMin, domainMax));

    // 17 buckets over the domain; a bar is "active" when its centre falls in the
    // selected range so the histogram reads as the slider's live selection.
    final bucketWidth = (domainMax - domainMin) / _kSalaryBuckets;
    final buckets = List<int>.filled(_kSalaryBuckets, 0);
    for (final v in _salaries) {
      final idx = bucketWidth == 0 ? 0 : ((v - domainMin) / bucketWidth).floor().clamp(0, _kSalaryBuckets - 1);
      buckets[idx]++;
    }
    final peak = buckets.fold<int>(1, (m, c) => c > m ? c : m);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 56,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < _kSalaryBuckets; i++) ...[
                if (i > 0) const SizedBox(width: 3),
                Expanded(
                  child: _histogramBar(
                    fraction: buckets[i] / peak,
                    active: _bucketInRange(i, bucketWidth, domainMin, current),
                  ),
                ),
              ],
            ],
          ),
        ),
        RangeSlider(
          values: current,
          min: domainMin,
          max: domainMax,
          activeColor: context.c.accent,
          inactiveColor: context.c.border,
          labels: RangeLabels(_formatInr(current.start), _formatInr(current.end)),
          onChanged: (v) => setState(() => _salaryDraft = v),
          onChangeEnd: (v) => notifier.setSalary(_isFullDomain(v, domainMin, domainMax) ? null : SalaryRange(v.start, v.end)),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(_formatInr(current.start), style: AppTypography.monoData.copyWith(fontSize: 12, color: context.c.inkSoft)),
            Text(_formatInr(current.end), style: AppTypography.monoData.copyWith(fontSize: 12, color: context.c.inkSoft)),
          ],
        ),
      ],
    );
  }

  Widget _histogramBar({required double fraction, required bool active}) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: FractionallySizedBox(
        heightFactor: fraction <= 0 ? 0.04 : fraction, // keep an empty bucket faintly visible
        child: Container(
          decoration: BoxDecoration(
            color: active ? context.c.accent : context.c.border,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(2)),
          ),
        ),
      ),
    );
  }

  // ── Category chips ──────────────────────────────────────────────────────────
  /// The one filter that REFETCHES rather than narrowing in memory — the server
  /// applies it before pagination (see JobFilter.categories). So this section
  /// warns the user that it costs a load, and offers an explicit "All" rather
  /// than relying on them clearing every chip (an empty set means "everything"
  /// on the wire, which would be the opposite of what clearing looks like).
  Widget _categoryChips(JobFilter filter, JobFilterNotifier notifier) {
    final showingAll = filter.categories.length == kJobCategories.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: AppSpacing.space2,
          runSpacing: AppSpacing.space2,
          children: [
            for (final category in kJobCategories)
              _LocationChip(
                label: kJobCategoryLabels[category] ?? category,
                icon: AppIconName.briefcase,
                selected: filter.categories.contains(category),
                onTap: () => notifier.toggleCategory(category),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.space2),
        Row(
          children: [
            TextButton(
              onPressed: showingAll ? null : () => notifier.selectAllCategories(),
              child: const Text('Select all'),
            ),
            TextButton(
              onPressed: setEquals(filter.categories, kDefaultJobCategories)
                  ? null
                  : () => notifier.setCategories(kDefaultJobCategories),
              child: const Text('Reset to tech'),
            ),
          ],
        ),
      ],
    );
  }

  // ── Location chips ──────────────────────────────────────────────────────────
  Widget _locationChips(JobFilter filter, JobFilterNotifier notifier) {
    return Wrap(
      spacing: AppSpacing.space2,
      runSpacing: AppSpacing.space2,
      children: [
        for (final opt in kFilterLocations)
          _LocationChip(
            label: opt.label,
            icon: opt.isRemote ? AppIconName.home : AppIconName.mapPin,
            selected: filter.locations.contains(opt.label),
            onTap: () => notifier.toggleLocation(opt.label),
          ),
      ],
    );
  }

  // ── Footer ──────────────────────────────────────────────────────────────────
  Widget _footer(int shownCount, bool canClear, JobFilterNotifier notifier) {
    return Container(
      padding: const EdgeInsets.fromLTRB(AppSpacing.space5, AppSpacing.space3, AppSpacing.space5, AppSpacing.space4),
      decoration: BoxDecoration(
        color: context.c.surface,
        border: Border(top: BorderSide(color: context.c.border)),
      ),
      child: Row(
        children: [
          TextButton(
            onPressed: canClear ? () => notifier.clearAll() : null,
            child: const Text('Clear all'),
          ),
          const SizedBox(width: AppSpacing.space3),
          Expanded(
            child: ElevatedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('Show $shownCount job${shownCount == 1 ? '' : 's'}'),
            ),
          ),
        ],
      ),
    );
  }
}

class _SourceCard extends StatelessWidget {
  const _SourceCard({required this.source, required this.count, required this.selected, required this.onTap});
  final String source;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: AppRadius.lgRadius,
      child: Container(
        width: 84,
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.space3, horizontal: AppSpacing.space2),
        decoration: BoxDecoration(
          color: selected ? context.c.accentSoft : context.c.surface,
          border: Border.all(color: selected ? context.c.accent : context.c.border, width: selected ? 1.5 : 1),
          borderRadius: AppRadius.lgRadius,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SourceChip(source: source, size: 28),
            const SizedBox(height: AppSpacing.space2),
            Text(
              source,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.caption.copyWith(
                fontWeight: FontWeight.w600,
                color: selected ? context.c.accent : context.c.ink,
              ),
            ),
            Text('$count', style: AppTypography.caption.copyWith(color: context.c.inkFaint)),
          ],
        ),
      ),
    );
  }
}

class _LocationChip extends StatelessWidget {
  const _LocationChip({required this.label, required this.icon, required this.selected, required this.onTap});
  final String label;
  final AppIconName icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: AppRadius.pillRadius,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.space3, vertical: AppSpacing.space2),
        decoration: BoxDecoration(
          color: selected ? context.c.accentSoft : context.c.surface,
          border: Border.all(color: selected ? context.c.accent : context.c.border, width: selected ? 1.5 : 1),
          borderRadius: AppRadius.pillRadius,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon(icon, size: 15, color: selected ? context.c.accent : context.c.inkSoft),
            const SizedBox(width: 6),
            Text(
              label,
              style: AppTypography.bodySm.copyWith(
                fontWeight: FontWeight.w600,
                color: selected ? context.c.accent : context.c.inkSoft,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// True when the range spans (essentially) the whole domain — treated as "no
/// salary filter" so an untouched or reset slider clears the constraint.
bool _isFullDomain(RangeValues v, double min, double max) {
  const eps = 0.5;
  return v.start <= min + eps && v.end >= max - eps;
}

bool _bucketInRange(int i, double bucketWidth, double domainMin, RangeValues sel) {
  final centre = domainMin + (i + 0.5) * bucketWidth;
  return centre >= sel.start && centre <= sel.end;
}

/// Compact ₹ label for the slider readout — lakh convention above 1L, else K.
/// Deliberately currency-naive (the pool is India-dominant); mirrors
/// [Job.salaryLabel]'s INR branch without importing a whole Job.
String _formatInr(double v) {
  if (v >= 100000) {
    final lakhs = v / 100000;
    final label = lakhs >= 10 ? lakhs.round().toString() : lakhs.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '');
    return '₹${label}L';
  }
  return '₹${(v / 1000).round()}K';
}
