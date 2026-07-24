import 'package:flutter/material.dart';

import '../models/cost_stats.dart';
import '../models/wallet.dart';
import '../services/api_client.dart';
import '../services/cache_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_metrics.dart';
import '../widgets/app_icon.dart';
import '../widgets/app_loader.dart';
import '../widgets/empty_state.dart';
import '../widgets/page_header.dart';

/// §4.12 — the agent wallet. This REPLACES the old raw LLM-cost screen
/// (cost_stats_screen.dart, deleted in Phase 10) at `/cost`.
///
/// The wallet is the COSMETIC credits meter (R-B): a ₹200 grant that moves
/// down as the agent spends on LLM calls and resets to full on the
/// subscription-period rollover. It NEVER gates anything — the real
/// entitlement is `subscription_tier` (Profile's plan card). So there is no
/// real top-up / billing flow to wire; the card's buttons explain that credits
/// come with the plan rather than pretending to sell more.
///
/// Two endpoints back it: GET /wallet (the ₹ balance + actions-left, authored
/// as period spend) and GET /stats/costs (the by-provider / by-activity split).
/// The wallet is denominated in ₹, the cost stats in USD — rather than convert
/// USD with a second copy of the server's rate constant (drift risk), the
/// "used this month" bars split the wallet's own `spend_paise` by each slice's
/// real percentage, so every bar sums back to the balance card's number.
class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key});

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  final ApiClient _apiClient = ApiClient();

  bool _isLoading = true;
  String? _errorMessage;
  Wallet? _wallet;
  CostStats? _stats; // best-effort — the breakdown bars; balance card is fine without it

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _errorMessage = null);
    // Paint cached cost stats instantly if we have them (the balance itself is
    // cheap/quick and always fetched live — a stale ₹ number would mislead).
    var paintedStats = _stats != null;
    if (!paintedStats) {
      final entry = await CacheService.instance.read<CostStats>(
        CacheService.keyCostStats,
        (json) => CostStats.fromJson((json as Map).cast<String, dynamic>()),
      );
      if (entry != null && mounted) {
        paintedStats = true;
        setState(() => _stats = entry.data);
      }
    }
    if (_wallet == null && mounted) setState(() => _isLoading = true);
    try {
      final wallet = await _apiClient.fetchWallet();
      if (!mounted) return;
      setState(() {
        _wallet = wallet;
        _isLoading = false;
      });
      // The breakdown is secondary — a failure here just hides the bars.
      try {
        final stats = await _apiClient.fetchCostStats();
        if (mounted) setState(() => _stats = stats);
        await CacheService.instance.write(CacheService.keyCostStats, stats.raw);
      } catch (_) {/* balance card stands on its own */}
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const PageHeader(title: 'Agent wallet', showBack: true),
      body: RefreshIndicator(onRefresh: _load, child: _body()),
    );
  }

  Widget _body() {
    if (_isLoading && _wallet == null) {
      return const Center(child: AppLoader());
    }
    if (_errorMessage != null && _wallet == null) {
      return ListView(
        children: [
          EmptyState(
            icon: AppIconName.alertTriangle,
            title: 'Could not load your wallet',
            message: _errorMessage,
            actionLabel: 'Retry',
            onAction: _load,
          ),
        ],
      );
    }

    final wallet = _wallet!;
    // The by-provider slices in ₹, derived from the wallet's own spend so they
    // sum to the balance card's "used" figure (see class doc).
    final providers = _stats?.byProvider ?? const <CostProviderItem>[];
    final activities = _stats?.breakdown ?? const <CostBreakdownItem>[];

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.screenPadX),
      children: [
        _balanceCard(wallet),
        const SizedBox(height: AppSpacing.space5),
        if (wallet.spendPaise > 0 && providers.isNotEmpty) ...[
          _sectionHeader('Used this period', _rupees(wallet.spendRupees)),
          const SizedBox(height: AppSpacing.space3),
          for (var i = 0; i < providers.length; i++) ...[
            _bar(
              label: providers[i].label,
              amountPaise: (wallet.spendPaise * providers[i].pct / 100).round(),
              pct: providers[i].pct,
              color: _providerColor(providers[i].provider),
              trailing: '${providers[i].calls} call${providers[i].calls == 1 ? '' : 's'}',
            ),
            if (i != providers.length - 1) const SizedBox(height: AppSpacing.space4),
          ],
        ],
        if (activities.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.space5),
          Text('WHERE IT WENT', style: AppTypography.label.copyWith(color: context.c.inkFaint)),
          const SizedBox(height: AppSpacing.space3),
          for (var i = 0; i < activities.length; i++) ...[
            _bar(
              label: activities[i].label,
              amountPaise: (wallet.spendPaise * activities[i].pct / 100).round(),
              pct: activities[i].pct,
              color: _activityColors[i % _activityColors.length],
            ),
            if (i != activities.length - 1) const SizedBox(height: AppSpacing.space4),
          ],
        ],
        if (wallet.spendPaise == 0) ...[
          const SizedBox(height: AppSpacing.space5),
          const EmptyState(
            icon: AppIconName.bot,
            title: 'Nothing spent this period',
            message: 'As the agent matches, tailors, and drafts on your behalf, its credit use shows up here.',
          ),
        ],
      ],
    );
  }

  /// The gradient prepaid-balance card (§4.12 pixel truth). ₹ balance, actions
  /// left, and — because there is no billing backend — two buttons that
  /// honestly explain the credits rather than faking a purchase.
  Widget _balanceCard(Wallet wallet) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.space4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [context.c.accent, context.c.accent],
        ),
        boxShadow: [
          BoxShadow(
            color: context.c.accent.withValues(alpha: 0.35),
            blurRadius: 40,
            offset: const Offset(0, 18),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          // The two soft translucent circles from the prototype.
          Positioned(
            right: -30,
            top: -30,
            child: _softCircle(150, 0.12),
          ),
          Positioned(
            right: 20,
            bottom: -60,
            child: _softCircle(110, 0.08),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'PREPAID BALANCE',
                style: TextStyle(
                  fontFamily: AppTypography.monoData.fontFamily,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 1,
                  color: Colors.white.withValues(alpha: 0.85),
                ),
              ),
              const SizedBox(height: AppSpacing.space3),
              Text(
                _rupees(wallet.balanceRupees),
                style: TextStyle(
                  fontFamily: AppTypography.monoData.fontFamily,
                  fontSize: 40,
                  fontWeight: FontWeight.w700,
                  height: 1,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '≈ ${_formatCount(wallet.actionsRemaining)} agent action${wallet.actionsRemaining == 1 ? '' : 's'} left${wallet.estimated ? ' (est.)' : ''}',
                style: TextStyle(
                  fontFamily: AppTypography.body.fontFamily,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: Colors.white.withValues(alpha: 0.85),
                ),
              ),
              const SizedBox(height: AppSpacing.space4),
              Row(
                children: [
                  Expanded(
                    child: _cardButton(
                      label: 'Top up',
                      filled: true,
                      onTap: () => _explainCredits(topUp: true),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.space2 + 1),
                  Expanded(
                    child: _cardButton(
                      label: 'Manage',
                      filled: false,
                      onTap: () => _explainCredits(topUp: false),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _softCircle(double size, double opacity) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withValues(alpha: opacity),
      ),
    );
  }

  Widget _cardButton({required String label, required bool filled, required VoidCallback onTap}) {
    return Material(
      color: filled ? Colors.white : Colors.white.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          height: 42,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: filled ? null : Border.all(color: Colors.white.withValues(alpha: 0.5)),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: AppTypography.body.fontFamily,
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: filled ? context.c.accent : Colors.white,
            ),
          ),
        ),
      ),
    );
  }

  /// There's no purchase flow — credits are bundled with the plan and reset on
  /// rollover (R-B). Tapping either button says exactly that rather than
  /// opening a fake checkout.
  void _explainCredits({required bool topUp}) {
    final wallet = _wallet;
    final resets = wallet?.periodEnd;
    final when = resets == null
        ? 'at the start of each period'
        : 'on ${_shortDate(resets)}';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            topUp
                ? 'Credits are included with your plan — they refresh to full $when. No top-up needed.'
                : 'Your plan and credits are managed from your subscription; the balance refreshes $when.',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  Widget _sectionHeader(String title, String amount) {
    return Row(
      children: [
        Expanded(child: Text(title, style: AppTypography.body.copyWith(fontWeight: FontWeight.w600))),
        Text(
          amount,
          style: TextStyle(fontFamily: AppTypography.monoData.fontFamily, fontSize: 14, fontWeight: FontWeight.w600, color: context.c.ink),
        ),
      ],
    );
  }

  Widget _bar({
    required String label,
    required int amountPaise,
    required double pct,
    required Color color,
    String? trailing,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(width: 9, height: 9, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: AppSpacing.space2 + 1),
            Expanded(child: Text(label, style: AppTypography.body.copyWith(fontSize: 13, fontWeight: FontWeight.w500))),
            if (trailing != null) ...[
              Text(trailing, style: AppTypography.label.copyWith(color: context.c.inkFaint)),
              const SizedBox(width: AppSpacing.space3),
            ],
            Text(
              _rupees(amountPaise / 100),
              style: TextStyle(fontFamily: AppTypography.monoData.fontFamily, fontSize: 12.5, fontWeight: FontWeight.w600, color: context.c.ink),
            ),
          ],
        ),
        const SizedBox(height: 7),
        ClipRRect(
          borderRadius: AppRadius.pillRadius,
          child: LinearProgressIndicator(
            value: (pct / 100).clamp(0.0, 1.0),
            minHeight: 8,
            backgroundColor: context.c.surface2,
            valueColor: AlwaysStoppedAnimation(color),
          ),
        ),
      ],
    );
  }

  Color _providerColor(String provider) => switch (provider) {
        'gemini' => context.c.warning,
        'deepseek' => context.c.accent,
        _ => context.c.inkFaint,
      };

  // Theme-aware palette for the per-provider usage bars (resolved live so it
  // flips with dark mode); indexed cyclically at the call site.
  List<Color> get _activityColors => [
        context.c.accent,
        context.c.info,
        context.c.success,
        context.c.warning,
        context.c.critical,
        context.c.inkFaint,
      ];
}

/// ₹ with two decimals, or four for sub-paisa amounts so a tiny real spend
/// isn't rounded to ₹0.00 and read as "nothing happened".
String _rupees(double amount) {
  if (amount > 0 && amount < 0.01) return '₹${amount.toStringAsFixed(4)}';
  return '₹${amount.toStringAsFixed(2)}';
}

/// Compact action count: 3,140 → "3,140", 12,400 → "12.4k".
String _formatCount(int n) {
  if (n >= 10000) return '${(n / 1000).toStringAsFixed(1)}k';
  if (n >= 1000) {
    final s = n.toString();
    return '${s.substring(0, s.length - 3)},${s.substring(s.length - 3)}';
  }
  return '$n';
}

String _shortDate(DateTime d) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${d.day} ${months[d.month - 1]}';
}
