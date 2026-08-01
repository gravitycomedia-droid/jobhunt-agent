import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/skill_growth_item.dart';
import '../services/api_client.dart';
import '../services/cache_service.dart';
import '../services/haptic_service.dart';
import '../services/refresh_throttle.dart';
import '../services/skill_progress.dart';
import '../theme/app_colors.dart';
import '../theme/app_metrics.dart';
import '../theme/app_theme.dart';
import '../widgets/app_icon.dart';
import '../widgets/empty_state.dart';
import '../widgets/mascot_loader.dart';
import '../widgets/page_header.dart';

/// Phase 4 — skills to learn, derived from the caller's REAL match gaps
/// (server/services/skill_growth.py), presented as a progress dashboard: a
/// score ring, a level, and three tabs (Skills · Courses · Projects) whose
/// cards you tick off as you complete them.
///
/// **Every number here is computed, not invented** (Golden Rule 2). The
/// prototype this is modelled on shows an arbitrary "560 / 1000 skill score";
/// that would be a fabrication. What ships instead is *gap coverage*: each
/// recommendation is worth XP in proportion to how many of your ranked matches
/// its gap actually blocks ([SkillGrowthItem.frequency], counted in Python from
/// real match rows), and the score is the XP earned over the XP on the table.
/// So "410 of 780" means "the gaps you've closed account for 410 of the 780
/// match-blocking points in front of you" — checkable, and it moves only when
/// you tick something off or the agent re-ranks.
///
/// The ticks themselves live on the device ([SkillProgressStore]) — a personal
/// checklist over the agent's advice, not agent state.
class SkillGrowthScreen extends StatefulWidget {
  const SkillGrowthScreen({super.key});

  @override
  State<SkillGrowthScreen> createState() => _SkillGrowthScreenState();
}

/// Which list the segmented control is showing.
enum _Tab { skills, courses, projects }

/// One tickable recommendation, flattened out of the per-skill server payload
/// so all three tabs share a single card, a single XP rule and a single
/// completion set.
class _Item {
  const _Item({
    required this.id,
    required this.tab,
    required this.title,
    required this.subtitle,
    required this.skill,
    required this.xp,
  });

  final String id;
  final _Tab tab;
  final String title;
  final String subtitle;
  final String skill;
  final int xp;
}

class _SkillGrowthScreenState extends State<SkillGrowthScreen> with SingleTickerProviderStateMixin {
  final ApiClient _apiClient = ApiClient();

  final RefreshThrottle _throttle = RefreshThrottle();

  bool _isLoading = true;
  bool _isRefreshing = false;
  String? _errorMessage;
  List<SkillGrowthItem> _items = [];
  List<_Item> _flat = [];
  Set<String> _done = {};
  _Tab _tab = _Tab.skills;

  /// When the painted recommendations were generated (cache write time). Shown
  /// as "Updated 3h ago" so the 12-hour passive window has an on-screen answer.
  DateTime? _lastUpdated;

  // The ring/score count-up. Mirrors FitGauge's one-shot reveal, but this one
  // re-runs on every tick so the score visibly climbs when you complete
  // something — the whole point of the dashboard.
  late final AnimationController _ac =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 650));
  late Animation<double> _scoreAnim = const AlwaysStoppedAnimation(0);
  double _shownScore = 0;

  // ── XP weights ────────────────────────────────────────────────────────────
  // All three are multiples of the SAME real quantity: how many of your ranked
  // matches list this gap. The relative sizes encode effort, not evidence —
  // shipping a project is worth more than finishing a course, which is worth
  // more than ticking "I know this now".
  static const _xpPerMatchSkill = 10;
  static const _xpPerMatchCourse = 6;
  static const _xpPerMatchProject = 8;

  @override
  void initState() {
    super.initState();
    _ac.addListener(() => setState(() => _shownScore = _scoreAnim.value));
    _load();
  }

  @override
  void dispose() {
    _ac.dispose();
    super.dispose();
  }

  /// Cache-first (ADR-028), because this endpoint is a single ~50s Gemini call:
  /// paint the last generated set instantly, and on a PASSIVE load (opening the
  /// screen) skip the network entirely while that cache is inside
  /// [CacheService.skillGrowthFreshFor]. [force] — pull-to-refresh, Retry —
  /// always regenerates, debounced against a burst of pulls.
  Future<void> _load({bool force = false}) async {
    if (force && !_throttle.shouldRun()) return;
    setState(() => _errorMessage = null);

    final painted = await _paintFromCache();
    if (!force && painted && await CacheService.instance.isFresh(
          CacheService.keySkillGrowth,
          within: CacheService.skillGrowthFreshFor,
        )) {
      return;
    }

    setState(() {
      _isLoading = !painted;
      _isRefreshing = painted;
    });
    try {
      final results = await Future.wait([
        _apiClient.fetchSkillGrowth(),
        SkillProgressStore.instance.read(),
      ]);
      if (!mounted) return;
      final items = results[0] as List<SkillGrowthItem>;
      setState(() {
        _items = items;
        _flat = _flatten(items);
        _done = results[1] as Set<String>;
        _isLoading = false;
        _isRefreshing = false;
        _lastUpdated = DateTime.now();
      });
      _animateScoreTo(_earnedXp.toDouble(), from: 0);
      await CacheService.instance.write(CacheService.keySkillGrowth, [for (final i in items) i.raw]);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        // A failed refresh over painted cache is not an error screen — the
        // "Updated …" line already says the data is from before.
        _errorMessage = painted ? null : e.toString();
        _isLoading = false;
        _isRefreshing = false;
      });
    }
  }

  /// Paints the cached recommendations (plus the local tick set). Returns true
  /// if anything was painted.
  Future<bool> _paintFromCache() async {
    if (_items.isNotEmpty) return true;
    final entry = await CacheService.instance.read<List<SkillGrowthItem>>(
      CacheService.keySkillGrowth,
      (json) => (json as List)
          .map((s) => SkillGrowthItem.fromJson((s as Map).cast<String, dynamic>()))
          .toList(),
    );
    if (entry == null || entry.data.isEmpty || !mounted) return false;
    final done = await SkillProgressStore.instance.read();
    if (!mounted) return false;
    setState(() {
      _items = entry.data;
      _flat = _flatten(entry.data);
      _done = done;
      _lastUpdated = entry.cachedAt;
      _isLoading = false;
    });
    _animateScoreTo(_earnedXp.toDouble(), from: 0);
    return true;
  }

  /// Content-derived id: stable while the recommendation's text is, and
  /// naturally orphaned when the agent replaces it (see [SkillProgressStore]).
  static String _id(_Tab tab, String skill, String title) => '${tab.name}:$skill:$title';

  List<_Item> _flatten(List<SkillGrowthItem> items) {
    final out = <_Item>[];
    for (final item in items) {
      final n = math.max(1, item.frequency);
      out.add(_Item(
        id: _id(_Tab.skills, item.skill, item.skill),
        tab: _Tab.skills,
        title: item.skill,
        subtitle: item.reason,
        skill: item.skill,
        xp: n * _xpPerMatchSkill,
      ));
      for (final c in item.courses) {
        out.add(_Item(
          id: _id(_Tab.courses, item.skill, c.title),
          tab: _Tab.courses,
          title: c.title,
          subtitle: '${c.provider} · ${c.duration}',
          skill: item.skill,
          xp: n * _xpPerMatchCourse,
        ));
      }
      for (final p in item.projects) {
        out.add(_Item(
          id: _id(_Tab.projects, item.skill, p.title),
          tab: _Tab.projects,
          title: p.title,
          subtitle: p.impact,
          skill: item.skill,
          xp: n * _xpPerMatchProject,
        ));
      }
    }
    return out;
  }

  // ── derived, deterministic numbers ────────────────────────────────────────
  int get _totalXp => _flat.fold(0, (sum, i) => sum + i.xp);
  int get _earnedXp => _flat.where((i) => _done.contains(i.id)).fold(0, (sum, i) => sum + i.xp);
  double get _fraction => _totalXp == 0 ? 0 : _earnedXp / _totalXp;
  int _doneCount(_Tab tab) => _flat.where((i) => i.tab == tab && _done.contains(i.id)).length;
  int _tabCount(_Tab tab) => _flat.where((i) => i.tab == tab).length;

  /// Five bands over gap coverage. The label describes the *coverage*, not the
  /// person — the agent has no basis for calling anyone "in-demand", but it can
  /// say truthfully how much of the gap between them and their matches is left.
  static const _levels = <(double, int, String)>[
    (0.0, 1, 'Getting started'),
    (0.2, 2, 'Building up'),
    (0.45, 3, 'Closing gaps'),
    (0.7, 4, 'Nearly there'),
    (0.9, 5, 'Gaps closed'),
  ];

  (double, int, String) get _level {
    var current = _levels.first;
    for (final band in _levels) {
      if (_fraction >= band.$1) current = band;
    }
    return current;
  }

  (double, int, String)? get _nextLevel {
    final index = _levels.indexOf(_level);
    return index + 1 < _levels.length ? _levels[index + 1] : null;
  }

  void _animateScoreTo(double target, {double? from}) {
    _scoreAnim = Tween<double>(begin: from ?? _shownScore, end: target)
        .animate(CurvedAnimation(parent: _ac, curve: Curves.easeOutCubic));
    _ac
      ..reset()
      ..forward();
  }

  Future<void> _toggle(_Item item) async {
    HapticService.instance.light();
    final done = {..._done};
    if (done.contains(item.id)) {
      done.remove(item.id);
    } else {
      done.add(item.id);
    }
    setState(() => _done = done);
    _animateScoreTo(_earnedXp.toDouble());
    await SkillProgressStore.instance.write(done);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const PageHeader(title: 'Skill growth', showBack: true),
      body: RefreshIndicator(onRefresh: () => _load(force: true), child: _body()),
    );
  }

  Widget _body() {
    if (_isLoading) {
      return const MascotLoader(caption: 'Reading your match gaps…');
    }

    if (_errorMessage != null) {
      return ListView(
        children: [
          EmptyState(
            icon: AppIconName.alertTriangle,
            title: 'Could not load skill growth',
            message: _errorMessage,
            actionLabel: 'Retry',
            onAction: () => _load(force: true),
          ),
        ],
      );
    }

    if (_items.isEmpty) {
      return ListView(
        children: const [
          EmptyState(
            icon: AppIconName.trendingUp,
            title: 'Nothing to learn from yet',
            message: 'Once the agent has scored some matches, skill gaps show up here.',
          ),
        ],
      );
    }

    final visible = _flat.where((i) => i.tab == _tab).toList();
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.screenPadX),
      children: [
        _updatedRow(),
        _scoreCard(),
        const SizedBox(height: AppSpacing.space4),
        _segmentedTabs(),
        const SizedBox(height: AppSpacing.space4),
        Text(_tabBlurb, style: AppTypography.bodySm.copyWith(color: context.c.inkSoft)),
        const SizedBox(height: AppSpacing.space3),
        for (final item in visible) ...[
          _itemCard(item),
          const SizedBox(height: AppSpacing.space2),
        ],
        if (visible.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.space5),
            child: Text(
              'Nothing here yet — the agent adds these as it finds gaps in your matches.',
              textAlign: TextAlign.center,
              style: AppTypography.bodySm.copyWith(color: context.c.inkFaint),
            ),
          ),
      ],
    );
  }

  String get _tabBlurb => switch (_tab) {
        _Tab.skills => 'Skills the agent found missing from your top matches. Each is worth XP in '
            'proportion to how many of those matches it blocks.',
        _Tab.courses => 'Courses that close your biggest gaps. Mark one complete to bank its XP.',
        _Tab.projects => 'Portfolio-ready builds that prove the skills these postings ask for.',
      };

  /// "Updated 3h ago" + a live "Refreshing…" state, so the long passive window
  /// (and a pull-to-refresh in flight) are both visible. Nothing to say before
  /// the first successful load.
  Widget _updatedRow() {
    final label = lastUpdatedLabel(_lastUpdated);
    if (label == null && !_isRefreshing) return const SizedBox.shrink();
    final c = context.c;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.space3),
      child: Row(
        children: [
          if (_isRefreshing) ...[
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 1.6, color: c.inkFaint),
            ),
            const SizedBox(width: 8),
            Text(
              'Regenerating from your latest matches…',
              style: AppTypography.caption.copyWith(color: c.inkFaint),
            ),
          ] else
            Text(
              '$label · pull to regenerate',
              style: AppTypography.caption.copyWith(color: c.inkFaint),
            ),
        ],
      ),
    );
  }

  // ── 1. the score card: ring + level + progress + tallies ──────────────────
  Widget _scoreCard() {
    final c = context.c;
    final (_, levelNum, levelTitle) = _level;
    final next = _nextLevel;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.space4, AppSpacing.space5, AppSpacing.space4, AppSpacing.space4),
      decoration: BoxDecoration(
        color: c.accentSoft,
        border: Border.all(color: Color.alphaBlend(c.accent.withValues(alpha: 0.24), c.border)),
        borderRadius: AppRadius.lgRadius,
      ),
      child: Column(
        children: [
          SizedBox(
            width: 150,
            height: 150,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CustomPaint(
                  size: const Size(150, 150),
                  painter: _RingPainter(
                    fraction: _totalXp == 0 ? 0 : (_shownScore / _totalXp).clamp(0.0, 1.0),
                    track: c.accent.withValues(alpha: 0.16),
                    fill: c.accent,
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('${_shownScore.round()}', style: mono(38, w: FontWeight.w700, color: c.ink)),
                    const SizedBox(height: 2),
                    Text('of $_totalXp XP', style: AppTypography.caption.copyWith(color: c.inkSoft)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.space3),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(color: c.surface, borderRadius: AppRadius.pillRadius),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppIcon(AppIconName.trendingUp, size: 14, color: c.accent),
                const SizedBox(width: 6),
                Text(
                  'Level $levelNum · $levelTitle',
                  style: AppTypography.bodySm.copyWith(color: c.accent, fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.space4),
          Row(
            children: [
              Expanded(
                child: Text(
                  next == null
                      ? 'Every gap the agent found is covered.'
                      : '${(next.$1 * _totalXp).ceil() - _earnedXp} XP to level ${next.$2}',
                  style: AppTypography.caption.copyWith(color: c.inkSoft),
                ),
              ),
              Text('${(_fraction * 100).round()}%', style: mono(12, w: FontWeight.w600, color: c.inkSoft)),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: LinearProgressIndicator(
              value: _fraction,
              minHeight: 9,
              backgroundColor: c.surface,
              valueColor: AlwaysStoppedAnimation(c.accent),
            ),
          ),
          const SizedBox(height: AppSpacing.space4),
          Row(
            children: [
              Expanded(child: _tally(_Tab.skills, 'skills')),
              const SizedBox(width: AppSpacing.space2),
              Expanded(child: _tally(_Tab.courses, 'courses')),
              const SizedBox(width: AppSpacing.space2),
              Expanded(child: _tally(_Tab.projects, 'projects')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _tally(_Tab tab, String label) {
    final c = context.c;
    final done = _doneCount(tab);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 11),
      decoration: BoxDecoration(color: c.surface, borderRadius: AppRadius.mdRadius),
      child: Column(
        children: [
          Text(
            '$done/${_tabCount(tab)}',
            style: mono(18, w: FontWeight.w700, color: done > 0 ? c.success : c.ink),
          ),
          const SizedBox(height: 2),
          Text(label, style: AppTypography.caption.copyWith(color: c.inkSoft)),
        ],
      ),
    );
  }

  // ── 2. segmented control ──────────────────────────────────────────────────
  Widget _segmentedTabs() {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: c.surface2,
        border: Border.all(color: c.border),
        borderRadius: AppRadius.mdRadius,
      ),
      child: Row(
        children: [
          for (final tab in _Tab.values)
            Expanded(
              child: GestureDetector(
                onTap: () {
                  HapticService.instance.selection();
                  setState(() => _tab = tab);
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _tab == tab ? c.surface : Colors.transparent,
                    borderRadius: BorderRadius.circular(9),
                    boxShadow: _tab == tab ? AppElevation.e1 : null,
                  ),
                  child: Text(
                    switch (tab) {
                      _Tab.skills => 'Skills',
                      _Tab.courses => 'Courses',
                      _Tab.projects => 'Projects',
                    },
                    style: AppTypography.bodySm.copyWith(
                      fontWeight: FontWeight.w600,
                      color: _tab == tab ? c.ink : c.inkSoft,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ── 3. one tickable recommendation ────────────────────────────────────────
  Widget _itemCard(_Item item) {
    final c = context.c;
    final done = _done.contains(item.id);
    return Container(
      padding: const EdgeInsets.all(AppSpacing.space3),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: done ? c.success.withValues(alpha: 0.35) : c.border),
        borderRadius: AppRadius.mdRadius,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: c.accentSoft, borderRadius: AppRadius.mdRadius),
            child: AppIcon(
              switch (item.tab) {
                _Tab.skills => AppIconName.autoAwesome,
                _Tab.courses => AppIconName.fileText,
                _Tab.projects => AppIconName.briefcase,
              },
              size: 18,
              color: c.accent,
            ),
          ),
          const SizedBox(width: AppSpacing.space3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(item.title, style: AppTypography.body.copyWith(fontWeight: FontWeight.w700)),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(color: c.accentSoft, borderRadius: BorderRadius.circular(6)),
                      child: Text('+${item.xp}', style: mono(10, w: FontWeight.w600, color: c.accent)),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(item.subtitle, style: AppTypography.caption.copyWith(color: c.inkSoft)),
                // On the course/project tabs, name the gap this closes —
                // otherwise a bare course title has no visible link to why the
                // agent surfaced it.
                if (item.tab != _Tab.skills) ...[
                  const SizedBox(height: 3),
                  Text('For ${item.skill}', style: AppTypography.caption.copyWith(color: c.inkFaint)),
                ],
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.space2),
          _toggleButton(item, done),
        ],
      ),
    );
  }

  Widget _toggleButton(_Item item, bool done) {
    final c = context.c;
    final label = switch (item.tab) {
      _Tab.skills => done ? 'Learned' : 'Learn',
      _Tab.courses => done ? 'Done' : 'Enrol',
      _Tab.projects => done ? 'Shipped' : 'Build',
    };
    return Semantics(
      button: true,
      selected: done,
      label: '$label — ${item.title}',
      child: GestureDetector(
        onTap: () => _toggle(item),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: done ? c.success : c.accentSoft,
            border: Border.all(color: done ? c.success : c.accent),
            borderRadius: AppRadius.mdRadius,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIcon(
                done ? AppIconName.check : AppIconName.plus,
                size: 13,
                color: done ? Colors.white : c.accent,
              ),
              const SizedBox(width: 4),
              Text(
                label,
                style: AppTypography.caption.copyWith(
                  fontWeight: FontWeight.w700,
                  color: done ? Colors.white : c.accent,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The 150px progress ring behind the score. A plain full circle (not the 270°
/// gauge of `FitGauge`) — this is a completion fraction, not a 0–100 reading on
/// a scale.
class _RingPainter extends CustomPainter {
  const _RingPainter({required this.fraction, required this.track, required this.fill});

  final double fraction;
  final Color track;
  final Color fill;

  @override
  void paint(Canvas canvas, Size size) {
    const thickness = 13.0;
    final rect = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: (size.shortestSide - thickness) / 2,
    );
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = thickness
      ..color = track;
    canvas.drawArc(rect, 0, 2 * math.pi, false, base);

    final progress = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = thickness
      ..strokeCap = StrokeCap.round
      ..color = fill;
    canvas.drawArc(rect, -math.pi / 2, 2 * math.pi * fraction, false, progress);
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.fraction != fraction || old.fill != fill || old.track != track;
}
