import '../models/form_fill.dart';
import '../models/match_item.dart';

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

/// §4.6 Match detail: the tapped match, passed whole so the detail screen
/// renders instantly without a refetch (the list already holds every field).
/// Transient like [TailorArgs] — not restored across a cold start.
class MatchArgs {
  const MatchArgs({required this.match});
  final MatchItem match;
}

/// §4.8 in-app WebView: the prefilled Google Form URL plus the labels the user
/// still has to attach by hand (file-upload questions Google won't let us
/// prefill). [jobId]/[jobTitle] are set when the parse detected a job
/// description inside the form, which is what lets the WebView's overflow menu
/// offer "tailor my résumé for this JD" without a second parse. Transient like
/// the others.
class FormWebViewArgs {
  const FormWebViewArgs({
    this.prefillUrl,
    required this.formTitle,
    this.filledCount = 0,
    this.fileUploadLabels = const [],
    this.jobId,
    this.jobTitle,
    this.signInUrl,
  }) : assert(prefillUrl != null || signInUrl != null, 'need a URL to load');
  final String? prefillUrl;
  final String formTitle;
  final int filledCount;
  final List<String> fileUploadLabels;
  final String? jobId;
  final String? jobTitle;

  /// ADR-053: set instead of [prefillUrl] when the form requires Google
  /// sign-in. The WebView loads this plain URL first; once the user signs in
  /// and the real form page loads, it reads that page once (never injects
  /// into it), parses + fills through the same pipeline the public-form
  /// path uses, and navigates itself to the resulting prefill URL.
  final String? signInUrl;
}

/// ADR-053: handed back (via a typed `context.push` result) once the
/// sign-in flow above finishes autofilling a gated form — lets
/// [FormFillScreen] adopt the same parsed/answers/prefill state the
/// public-form path already has, so "Review & edit answers" keeps working
/// for a form that needed sign-in too.
class FormAutofillHandoff {
  const FormAutofillHandoff({
    required this.parsed,
    required this.answers,
    required this.prefillUrl,
    required this.fillId,
  });
  final ParsedForm parsed;
  final List<FormAnswer> answers;
  final String prefillUrl;
  final String fillId;
}
