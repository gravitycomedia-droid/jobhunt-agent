import 'package:url_launcher/url_launcher.dart';

/// Career-ops integration Brick 6 (docs/21-career-ops-integration-plan.md
/// §1.4, DECISIONS.md ADR-060): v1 contact discovery — a deep-linked
/// Google search restricted to LinkedIn profiles, not a real people-lookup
/// (that needs a licensed search API, scoped separately — see the plan's
/// §3 "v2"). Zero LLM cost and zero new backend surface: pure URL
/// templating, same "code handles logic" posture as everything else
/// (Golden Rule 2), just with no server hop needed at all since there's
/// no data to fetch or generate.
///
/// ToS-safe by construction: the user does the actual browsing in their
/// own authenticated LinkedIn session via a normal search engine result —
/// nothing here scrapes or automates LinkedIn itself, unlike the
/// login-based scraping ADR-003 already rejected for job boards.
Uri buildLinkedInSearchUrl({required String company, required String role}) {
  final terms = [
    'site:linkedin.com/in',
    if (company.trim().isNotEmpty) '"${company.trim()}"',
    if (role.trim().isNotEmpty) '"${role.trim()}"',
  ].join(' ');
  return Uri.https('www.google.com', '/search', {'q': terms});
}

/// Opens the search in the external browser — same launch posture as
/// job_card.dart's "view original posting" (an app-link/deep-link
/// destination the user may need their own logged-in session for).
Future<bool> openLinkedInSearch({required String company, required String role}) {
  final uri = buildLinkedInSearchUrl(company: company, role: role);
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}
