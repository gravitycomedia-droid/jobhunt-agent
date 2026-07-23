/// Phase 2b: typed payloads passed to go_router routes via `state.extra`.
/// Kept in their own file (not app_router.dart) so screens that are themselves
/// route targets can import the arg type without a circular import back into the
/// router. `extra` is not restorable across a cold start — fine for transient
/// flows like tailoring.
class TailorArgs {
  const TailorArgs({required this.jobId, required this.jobTitle});
  final String jobId;
  final String jobTitle;
}
