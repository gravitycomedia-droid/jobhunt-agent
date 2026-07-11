import 'package:flutter/material.dart';

import '../models/cost_stats.dart';
import '../services/api_client.dart';
import '../services/cache_service.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_icon.dart';
import '../widgets/empty_state.dart';
import '../widgets/loading_skeleton.dart';
import '../widgets/page_header.dart';

const List<Color> _breakdownColors = [
  AppColors.brand600,
  AppColors.infoFill,
  AppColors.successFill,
  AppColors.warningFill,
  AppColors.criticalFill,
  AppColors.neutral400,
];

/// Frontend rebuild Phase 3 (prototype `ui.isCostStats`): this calendar
/// month's LLM cost/usage, broken down by task. The prototype shows a
/// "$X of $Y budget" bar — there's no budget concept anywhere in this
/// app (no config, no column), so rather than invent one, this shows the
/// real total plus per-task bars sized by their real share of it. See
/// server/services/cost_stats.py for the (approximate) pricing this is
/// built on.
class CostStatsScreen extends StatefulWidget {
  const CostStatsScreen({super.key});

  @override
  State<CostStatsScreen> createState() => _CostStatsScreenState();
}

class _CostStatsScreenState extends State<CostStatsScreen> {
  final ApiClient _apiClient = ApiClient();

  bool _isLoading = true;
  String? _errorMessage;
  CostStats? _stats;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _errorMessage = null);
    // Phase 5: paint cached stats instantly, revalidate underneath.
    var painted = _stats != null;
    if (!painted) {
      final entry = await CacheService.instance.read<CostStats>(
        CacheService.keyCostStats,
        (json) => CostStats.fromJson((json as Map).cast<String, dynamic>()),
      );
      if (entry != null && mounted) {
        painted = true;
        setState(() {
          _stats = entry.data;
          _isLoading = false;
        });
      }
    }
    if (!painted && mounted) setState(() => _isLoading = true);
    try {
      final stats = await _apiClient.fetchCostStats();
      if (!mounted) return;
      setState(() {
        _stats = stats;
        _isLoading = false;
      });
      await CacheService.instance.write(CacheService.keyCostStats, stats.raw);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = painted ? null : e.toString();
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const PageHeader(title: 'LLM usage', showBack: true),
      body: RefreshIndicator(onRefresh: _load, child: _body()),
    );
  }

  Widget _body() {
    if (_isLoading) {
      return ListView(
        padding: const EdgeInsets.all(AppSpacing.screenPadX),
        children: const [LoadingSkeleton(variant: SkeletonVariant.card)],
      );
    }

    if (_errorMessage != null) {
      return ListView(
        children: [
          EmptyState(
            icon: AppIconName.alertTriangle,
            title: 'Could not load usage stats',
            message: _errorMessage,
            actionLabel: 'Retry',
            onAction: _load,
          ),
        ],
      );
    }

    final stats = _stats!;
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.screenPadX),
      children: [
        _totalCard(stats),
        const SizedBox(height: AppSpacing.space3),
        Row(
          children: [
            Expanded(child: _metricTile('${stats.totalCalls}', 'API calls')),
            const SizedBox(width: AppSpacing.space2),
            Expanded(child: _metricTile(_formatTokens(stats.totalTokens), 'Tokens used')),
          ],
        ),
        const SizedBox(height: AppSpacing.space5),
        if (stats.breakdown.isEmpty)
          const EmptyState(
            icon: AppIconName.dollarSign,
            title: 'No usage yet this month',
            message: 'Once the agent matches, tailors, or drafts something, its cost shows up here.',
          )
        else ...[
          Text('BY ACTIVITY', style: AppTypography.label.copyWith(color: AppColors.textTertiary)),
          const SizedBox(height: AppSpacing.space3),
          for (var i = 0; i < stats.breakdown.length; i++) ...[
            _breakdownRow(stats.breakdown[i], _breakdownColors[i % _breakdownColors.length]),
            if (i != stats.breakdown.length - 1) const SizedBox(height: AppSpacing.space4),
          ],
        ],
      ],
    );
  }

  Widget _totalCard(CostStats stats) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.space4),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: AppRadius.lgRadius,
        boxShadow: AppElevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('This month', style: AppTypography.caption.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(
            '\$${stats.totalCost.toStringAsFixed(2)}',
            style: TextStyle(
              fontFamily: AppTypography.monoData.fontFamily,
              fontSize: 34,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.4,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _metricTile(String value, String label) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.space3),
      decoration: BoxDecoration(color: AppColors.surface, border: Border.all(color: AppColors.border), borderRadius: AppRadius.mdRadius),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: TextStyle(fontFamily: AppTypography.monoData.fontFamily, fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
          ),
          const SizedBox(height: 2),
          Text(label, style: AppTypography.label.copyWith(color: AppColors.textTertiary)),
        ],
      ),
    );
  }

  Widget _breakdownRow(CostBreakdownItem item, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(item.label, style: AppTypography.body.copyWith(fontWeight: FontWeight.w600))),
            Text(
              '\$${item.cost.toStringAsFixed(item.cost < 0.01 && item.cost > 0 ? 4 : 2)}',
              style: TextStyle(fontFamily: AppTypography.monoData.fontFamily, fontSize: 14, color: AppColors.textPrimary),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: AppRadius.pillRadius,
          child: LinearProgressIndicator(
            value: (item.pct / 100).clamp(0.0, 1.0),
            minHeight: 8,
            backgroundColor: AppColors.neutral200,
            valueColor: AlwaysStoppedAnimation(color),
          ),
        ),
      ],
    );
  }
}

String _formatTokens(int tokens) {
  if (tokens >= 1000000) return '${(tokens / 1000000).toStringAsFixed(1)}M';
  if (tokens >= 1000) return '${(tokens / 1000).toStringAsFixed(1)}K';
  return '$tokens';
}
