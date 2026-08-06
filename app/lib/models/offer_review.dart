/// Career-ops integration Brick 5 (docs/21-career-ops-integration-plan.md
/// §1.3, DECISIONS.md ADR-059). One clause the model identified.
/// `grounded` is server/services/offer_review.py's deterministic check —
/// NOT the model's own claim — so a clause that was paraphrased or
/// invented shows up as `grounded: false` here rather than being trusted.
/// There is deliberately no verdict/risk field anywhere in this shape.
class OfferClause {
  final String clauseText;
  final String category;
  final String plainEnglish;
  final bool grounded;

  OfferClause({
    required this.clauseText,
    required this.category,
    required this.plainEnglish,
    required this.grounded,
  });

  factory OfferClause.fromJson(Map<String, dynamic> json) {
    return OfferClause(
      clauseText: json['clause_text'] as String? ?? '',
      category: json['category'] as String? ?? 'other',
      plainEnglish: json['plain_english'] as String? ?? '',
      grounded: json['grounded'] as bool? ?? false,
    );
  }
}

/// Mirrors one `offer_reviews` row — insert-only (a user may paste a
/// revised offer after negotiating), so [OfferReviewScreen] reads back a
/// list, newest first, not a single overwritten row.
class OfferReview {
  final String id;
  final String applicationId;
  final String rawText;
  final List<OfferClause> clauses;
  final List<String> questionsForLawyer;
  final DateTime createdAt;

  OfferReview({
    required this.id,
    required this.applicationId,
    required this.rawText,
    required this.clauses,
    required this.questionsForLawyer,
    required this.createdAt,
  });

  factory OfferReview.fromJson(Map<String, dynamic> json) {
    return OfferReview(
      id: json['id'] as String,
      applicationId: json['application_id'] as String? ?? '',
      rawText: json['raw_text'] as String? ?? '',
      clauses: (json['clauses'] as List? ?? const [])
          .map((c) => OfferClause.fromJson(c as Map<String, dynamic>))
          .toList(),
      questionsForLawyer: (json['questions_for_lawyer'] as List? ?? const []).cast<String>(),
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }
}
