/// GET /subscription (frontend rebuild v2, Phase 4 backend). Backs the
/// Profile "plan card" (§4.11). [tier] is the only field that actually
/// gates anything server-side (services/entitlements.py); [status] and
/// [periodEnd] are lifecycle display fields for the billing card.
class Subscription {
  final String tier; // 'free' | 'pro'
  final String status; // 'active' | ...
  final DateTime? periodEnd;

  const Subscription({required this.tier, required this.status, this.periodEnd});

  factory Subscription.fromJson(Map<String, dynamic> json) {
    final end = json['period_end'];
    return Subscription(
      tier: (json['tier'] as String?) ?? 'free',
      status: (json['status'] as String?) ?? 'active',
      periodEnd: end == null ? null : DateTime.tryParse(end as String),
    );
  }

  bool get isPro => tier == 'pro';
}
