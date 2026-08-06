/// Plan 21: GET /referrals/me — everything [ReferralScreen] renders, plus what
/// POST /referrals/redeem echoes back so a successful redemption updates the
/// quota display without a second round-trip.
class ReferralStats {
  /// This profile's own shareable code. Nullable only defensively: migration
  /// 036 makes the column NOT NULL, so in practice it's always present.
  final String? referralCode;

  /// How many people have redeemed this profile's code.
  final int referredCount;

  /// Bonus full-analysis matches earned from referrals.
  final int bonusMatchQuota;

  /// Total full-analysis matches this profile gets. Computed server-side on
  /// purpose — the tier-vs-quota rules live in one place (services/referrals.py)
  /// rather than being duplicated in Dart where they could drift.
  final int effectiveMatchLimit;

  const ReferralStats({
    required this.referralCode,
    required this.referredCount,
    required this.bonusMatchQuota,
    required this.effectiveMatchLimit,
  });

  factory ReferralStats.fromJson(Map<String, dynamic> json) => ReferralStats(
        referralCode: json['referral_code'] as String?,
        referredCount: (json['referred_count'] as num?)?.toInt() ?? 0,
        bonusMatchQuota: (json['bonus_match_quota'] as num?)?.toInt() ?? 0,
        effectiveMatchLimit: (json['effective_match_limit'] as num?)?.toInt() ?? 0,
      );
}
