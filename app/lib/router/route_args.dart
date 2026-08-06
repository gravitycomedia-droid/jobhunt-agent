import '../models/form_fill.dart';
import '../models/job.dart';
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

/// Career-ops integration Brick 2 (ADR-056): same shape/reasoning as
/// [TailorArgs] — transient, not restorable across a cold start.
class CoverLetterArgs {
  const CoverLetterArgs({required this.jobId, required this.jobTitle});
  final String jobId;
  final String jobTitle;
}

/// Career-ops integration Bricks 4/5 (ADR-058/059): interview prep and
/// offer review are both keyed on an APPLICATION, not a job — unlike
/// [CoverLetterArgs]/[TailorArgs], which run before an application exists.
/// Same transient posture as the others.
class ApplicationScopedArgs {
  const ApplicationScopedArgs({required this.applicationId, required this.jobTitle});
  final String applicationId;
  final String jobTitle;
}

/// §4.6 Match detail: the tapped match, passed whole so the detail screen
/// renders instantly without a refetch (the list already holds every field).
/// Transient like [TailorArgs] — not restored across a cold start.
class MatchArgs {
  const MatchArgs({required this.match});
  final MatchItem match;
}

/// Job detail (Smart AI Fill, career-ops integration): the tapped raw job
/// from the Jobs tab, passed whole like [MatchArgs] — the list already
/// holds every field, so no refetch on open. Transient, same posture as
/// the others.
class JobArgs {
  const JobArgs({required this.job});
  final Job job;
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
    this.browseUrl,
  }) : assert(
          prefillUrl != null || signInUrl != null || browseUrl != null,
          'need a URL to load',
        );
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

  /// Smart AI Fill "Apply" entry point (Jobs tab → Job detail → Apply): the
  /// job's own posting URL, loaded plain with NO autofill attempt on load —
  /// a job link is usually a listing/JD page, not the application form
  /// itself, so the user browses/signs in/clicks through on the real site
  /// first. Autofill only ever runs when they explicitly tap "Smart AI
  /// Fill" from the overflow menu, reusing the exact same one-time-HTML-read
  /// pipeline ADR-053 built for the post-Google-sign-in case — just
  /// triggered manually, from wherever the user has navigated to, instead of
  /// automatically right after a Google sign-in redirect.
  final String? browseUrl;
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
