/// GET /wallet (frontend rebuild v2, Phase 4 backend, §4.12 / R-B).
///
/// The COSMETIC credits meter. It is telemetry, never a gate — the balance is
/// DERIVED server-side as `grant − spend-this-period` (services/wallet.py), so
/// it moves with real LLM spend and resets to the full ₹200 grant on its own at
/// the subscription-period rollover with no cron and no write. This class just
/// carries the paise numbers; all denomination is ₹ (paise), unlike
/// [CostStats] which is USD.
class Wallet {
  /// Displayable balance in paise: `grant − spend`, clamped to [0, grant].
  final int balancePaise;

  /// The period's grant in paise (the ₹200 that resets on rollover).
  final int grantPaise;

  /// Spend this period in paise (what "used this month" shows).
  final int spendPaise;

  /// Roughly how many more agent actions the balance buys (R-C). Derived from
  /// the period's mean call cost, or a config fallback when no calls exist yet.
  final int actionsRemaining;

  /// R-C: true when [actionsRemaining] used the fallback cost (no real calls
  /// this period to average) — the UI then hedges the number as approximate.
  final bool estimated;

  /// When the current grant resets. Null if the profile has no period set.
  final DateTime? periodEnd;

  /// Phase 5-style verbatim JSON, cached for round-tripping.
  final Map<String, dynamic> raw;

  const Wallet({
    required this.balancePaise,
    required this.grantPaise,
    required this.spendPaise,
    required this.actionsRemaining,
    required this.estimated,
    this.periodEnd,
    this.raw = const {},
  });

  /// ₹ as a double (paise / 100) — for formatting only, never arithmetic that
  /// feeds a gate (there is no gate; this is cosmetic).
  double get balanceRupees => balancePaise / 100;
  double get spendRupees => spendPaise / 100;

  factory Wallet.fromJson(Map<String, dynamic> json) {
    final end = json['period_end'];
    return Wallet(
      raw: json,
      balancePaise: (json['balance_paise'] as num?)?.toInt() ?? 0,
      grantPaise: (json['grant_paise'] as num?)?.toInt() ?? 0,
      spendPaise: (json['spend_paise'] as num?)?.toInt() ?? 0,
      actionsRemaining: (json['actions_remaining'] as num?)?.toInt() ?? 0,
      estimated: json['estimated'] as bool? ?? false,
      periodEnd: end == null ? null : DateTime.tryParse(end as String),
    );
  }
}
