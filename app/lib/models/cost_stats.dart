/// One row from GET /stats/costs's `breakdown` — one task's slice of
/// this month's LLM spend. All the math (cost, %) is done server-side
/// (server/services/cost_stats.py) — this class just carries the numbers.
class CostBreakdownItem {
  final String task;
  final String label;
  final double cost;
  final int calls;
  final double pct;

  CostBreakdownItem({required this.task, required this.label, required this.cost, required this.calls, required this.pct});

  factory CostBreakdownItem.fromJson(Map<String, dynamic> json) {
    return CostBreakdownItem(
      task: json['task'] as String,
      label: json['label'] as String,
      cost: (json['cost'] as num).toDouble(),
      calls: (json['calls'] as num).toInt(),
      pct: (json['pct'] as num).toDouble(),
    );
  }
}

/// GET /stats/costs's response — this calendar month's LLM usage for the
/// signed-in user, what [CostStatsScreen] renders.
class CostStats {
  final double totalCost;
  final int totalCalls;
  final int totalTokens;
  final List<CostBreakdownItem> breakdown;

  CostStats({required this.totalCost, required this.totalCalls, required this.totalTokens, required this.breakdown});

  factory CostStats.fromJson(Map<String, dynamic> json) {
    return CostStats(
      totalCost: (json['total_cost'] as num).toDouble(),
      totalCalls: (json['total_calls'] as num).toInt(),
      totalTokens: (json['total_tokens'] as num).toInt(),
      breakdown: (json['breakdown'] as List).map((b) => CostBreakdownItem.fromJson(b as Map<String, dynamic>)).toList(),
    );
  }
}
