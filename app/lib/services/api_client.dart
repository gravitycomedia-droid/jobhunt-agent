import 'dart:convert';
import 'dart:typed_data' show Uint8List;

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show Supabase;

import '../models/activity_item.dart';
import '../models/application_email.dart';
import '../models/application_item.dart';
import '../models/background_task.dart';
import '../models/chat_message.dart';
import '../models/matches_page.dart';
import '../models/referral_stats.dart';
import '../models/cost_stats.dart';
import '../models/cover_letter.dart';
import '../models/form_fill.dart';
import '../models/health_status.dart';
import '../models/interview_prep.dart';
import '../models/interview_story.dart';
import '../models/job.dart';
import '../models/job_extraction.dart';
import '../models/notification_item.dart';
import '../models/offer_review.dart';
import '../models/resume_profile.dart';
import '../models/score_history.dart';
import '../models/shortlist_item.dart';
import '../models/skill_growth_item.dart';
import '../models/subscription.dart';
import '../models/tailored_resume.dart';
import '../models/wallet.dart';

/// Golden Rule 1 (see CLAUDE.md): the phone never talks to Gemini/Supabase/etc
/// directly — it only ever talks to OUR FastAPI server. This class is the one
/// place that knows the server's base URL and how to call it. Every screen
/// goes through here instead of calling `http` directly, which is what made
/// Brick 9's auth headers a one-file change: [_authHeaders] below.
class ApiClient {
  /// Cloud Run migration: moved off Render (free-tier cold starts were
  /// routinely blowing past client timeouts — see api_client.dart's
  /// timeout comments) onto Cloud Run, same Dockerfile, project
  /// jobhunteragent-502002, region asia-south1. Override with
  /// `--dart-define=API_BASE_URL=http://<lan-ip>:8000` for local dev
  /// against a server running on your own machine instead.
  static String get _baseUrl {
    const override = String.fromEnvironment('API_BASE_URL');
    if (override.isNotEmpty) return override;
    return 'https://jobhunt-agent-server-380742808186.asia-south1.run.app';
  }

  /// Brick 9: every authenticated route needs the current Supabase
  /// session's access token as a Bearer header — server/services/auth.py
  /// verifies it against Supabase's own Auth API. `currentSession` is null
  /// pre-login, which every authenticated call will correctly turn into a
  /// 401 from the server rather than a null-header crash here.
  Map<String, String> _authHeaders([Map<String, String>? extra]) {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    return {if (token != null) 'Authorization': 'Bearer $token', ...?extra};
  }

  /// `Future<HealthStatus>` means "a HealthStatus that isn't ready yet, but
  /// will be" — Dart's version of a Promise. `async` marks this function as
  /// one that can `await` other Futures without blocking the UI thread; while
  /// we're waiting on the network, Flutter keeps rendering frames normally.
  /// This is the FlutterFlow "API Call" action node, hand-written.
  Future<HealthStatus> fetchHealth() async {
    final uri = Uri.parse('$_baseUrl/health');

    // `await` pauses THIS function (not the whole app) until the response
    // arrives, then resumes with the result assigned to `response`.
    final response = await http.get(uri);

    if (response.statusCode != 200) {
      throw Exception('Server returned ${response.statusCode}');
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    if (body['error'] != null) {
      throw Exception(body['error'].toString());
    }

    return HealthStatus.fromJson(body['data'] as Map<String, dynamic>);
  }

  /// The caller's own profile, or null if they haven't uploaded a resume
  /// yet — used to discover whether [registerFcmToken] has anything to
  /// attach a token to.
  Future<ResumeProfile?> fetchCurrentProfile() async {
    final uri = Uri.parse('$_baseUrl/resume/profile');
    final response = await http.get(uri, headers: _authHeaders());

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final data = body['data'];
    return data == null
        ? null
        : ResumeProfile.fromJson(data as Map<String, dynamic>);
  }

  /// Brick 8: registers this device's FCM token so the agent loop
  /// (server/jobs/daily_pipeline.py) can push to it.
  Future<void> registerFcmToken(String fcmToken) async {
    final uri = Uri.parse('$_baseUrl/resume/profile/fcm-token');
    final response = await http.patch(
      uri,
      headers: _authHeaders({'Content-Type': 'application/json'}),
      body: jsonEncode({'fcm_token': fcmToken}),
    );

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }
  }

  /// Onboarding (frontend rebuild Phase 1): the roles/min-salary the agent
  /// matches against. Not yet wired into the server's job-fetch step (see
  /// DECISIONS.md) — this just persists the preference for now.
  Future<void> updateTargetRoles(
    List<String> targetRoles,
    double? minSalary,
  ) async {
    final uri = Uri.parse('$_baseUrl/resume/profile/target-roles');
    final response = await http.patch(
      uri,
      headers: _authHeaders({'Content-Type': 'application/json'}),
      body: jsonEncode({'target_roles': targetRoles, 'min_salary': minSalary}),
    );

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }
  }

  /// Suggestion chips for [TargetRolesScreen]: `dbRoles` are roles the job
  /// pool actually has postings for right now (busiest first), `otherRoles`
  /// is a curated fallback list for roles the pool doesn't specifically
  /// label. See routers/jobs.py's GET /jobs/role-suggestions.
  Future<({List<String> dbRoles, List<String> otherRoles})> getRoleSuggestions() async {
    final uri = Uri.parse('$_baseUrl/jobs/role-suggestions');
    final response = await http.get(uri, headers: _authHeaders());

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final data = body['data'] as Map<String, dynamic>;
    return (
      dbRoles: (data['db_roles'] as List).cast<String>(),
      otherRoles: (data['other_roles'] as List).cast<String>(),
    );
  }

  /// Onboarding step between review and roles: student vs. experienced,
  /// plus USN/college name for students (only sent when the resume parse
  /// didn't already find them — see [ResumeProfile.employmentType]/[usn]).
  Future<ResumeProfile> updateStudentInfo({
    required String employmentType,
    String? usn,
    String? collegeName,
  }) async {
    final uri = Uri.parse('$_baseUrl/resume/profile/student-info');
    final response = await http.patch(
      uri,
      headers: _authHeaders({'Content-Type': 'application/json'}),
      body: jsonEncode({
        'employment_type': employmentType,
        'usn': usn,
        'college_name': collegeName,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return ResumeProfile.fromJson(body['data'] as Map<String, dynamic>);
  }

  /// Phase 6 (§4.1) student branch of the onboarding fork: academic facts the
  /// résumé parse doesn't reliably capture. All optional — an all-null body is
  /// a valid skip that still advances the step server-side.
  Future<ResumeProfile> updateAcademics({
    String? branch,
    int? gradYear,
    double? cgpa,
    String? usn,
    String? collegeName,
  }) async {
    return _patchProfile('/resume/profile/academics', {
      'branch': branch,
      'grad_year': gradYear,
      'cgpa': cgpa,
      'usn': usn,
      'college_name': collegeName,
    });
  }

  /// Phase 6 (§4.1) professional branch of the fork: employer/years/notice.
  Future<ResumeProfile> updateExperience({
    String? company,
    double? experienceYears,
    int? noticePeriodDays,
  }) async {
    return _patchProfile('/resume/profile/experience', {
      'company': company,
      'experience_years': experienceYears,
      'notice_period_days': noticePeriodDays,
    });
  }

  /// Phase 6 (§4.1) preferred cities. Advances onboarding to 'roles'.
  Future<ResumeProfile> updateTargetLocations(List<String> locations) async {
    return _patchProfile('/resume/profile/target-locations', {'target_locations': locations});
  }

  /// Migration 026: the contact block that heads every compiled résumé PDF.
  /// Goes through the ordinary PATCH /resume/profile (these are résumé content,
  /// not onboarding state), sending only the six contact keys so the rest of
  /// the profile is untouched. Pass `''` to clear a field — a blank renders as
  /// absent in the PDF, whereas a `null` would be indistinguishable from
  /// "don't change this".
  Future<ResumeProfile> updateContactDetails({
    required String email,
    required String phone,
    required String location,
    required String linkedinUrl,
    required String githubUrl,
    required String websiteUrl,
  }) async {
    return _patchProfile('/resume/profile', {
      'email': email.trim(),
      'phone': phone.trim(),
      'location': location.trim(),
      'linkedin_url': linkedinUrl.trim(),
      'github_url': githubUrl.trim(),
      'website_url': websiteUrl.trim(),
    });
  }

  /// Shared PATCH-and-parse for the onboarding detail endpoints — all return
  /// the updated profile row in the `{data, error}` envelope.
  Future<ResumeProfile> _patchProfile(String path, Map<String, dynamic> payload) async {
    final response = await http.patch(
      Uri.parse('$_baseUrl$path'),
      headers: _authHeaders({'Content-Type': 'application/json'}),
      body: jsonEncode(payload),
    );
    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return ResumeProfile.fromJson(body['data'] as Map<String, dynamic>);
  }

  /// Uploads a resume PDF for parsing. `MultipartRequest` is Dart's way of
  /// building a multipart/form-data POST — the same wire format a browser
  /// uses for a file-upload `<form>`, just constructed in code instead of
  /// dragged onto a FlutterFlow upload widget.
  Future<ResumeProfile> parseResume(List<int> pdfBytes, String filename) async {
    final uri = Uri.parse('$_baseUrl/resume/parse');
    final request = http.MultipartRequest('POST', uri)
      ..headers.addAll(_authHeaders())
      ..files.add(
        http.MultipartFile.fromBytes(
          'file',
          pdfBytes,
          filename: filename,
          contentType: MediaType('application', 'pdf'),
        ),
      );

    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return ResumeProfile.fromJson(body['data'] as Map<String, dynamic>);
  }

  /// PATCHes the (possibly hand-edited) profile back to the server.
  Future<ResumeProfile> updateProfile(ResumeProfile profile) async {
    final uri = Uri.parse('$_baseUrl/resume/profile');
    final response = await http.patch(
      uri,
      headers: _authHeaders({'Content-Type': 'application/json'}),
      body: jsonEncode(profile.toJson()),
    );

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return ResumeProfile.fromJson(body['data'] as Map<String, dynamic>);
  }

  /// Triggers a fetch+dedup+insert cycle on the server across four sources
  /// (Adzuna, JSearch, Greenhouse, Lever — job source expansion, ADR-018).
  /// ADR-011-shaped, same as [tailorResume]/[rerankShortlist]: JSearch alone
  /// routinely takes ~60s, which used to hold the connection open long
  /// enough for Android's network stack to abort it (`ClientException:
  /// Software caused connection abort`). The server now answers 202 with a
  /// task id immediately — poll [getTaskStatus] for the `{fetched,
  /// inserted}` result.
  Future<String> refreshJobs() async {
    final uri = Uri.parse('$_baseUrl/jobs/refresh');
    final response = await http
        .post(uri, headers: _authHeaders())
        .timeout(const Duration(seconds: 60));

    if (response.statusCode != 202) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['data'] as Map<String, dynamic>)['task_id'] as String;
  }

  /// [categories] filters SERVER-side (migration 027). Unlike the work-type,
  /// source and location filters — which narrow an already-loaded list in memory
  /// — category has to be applied before pagination: with the broad pool ~75% of
  /// rows are non-engineering, so filtering client-side would page through
  /// thousands of sales postings to find the engineering ones. Empty = all.
  Future<List<Job>> fetchJobs({int limit = 20, int offset = 0, Set<String> categories = const {}}) async {
    final query = {
      'limit': '$limit',
      'offset': '$offset',
      if (categories.isNotEmpty) 'category': categories.join(','),
    };
    final uri = Uri.parse('$_baseUrl/jobs').replace(queryParameters: query);
    final response = await http.get(uri, headers: _authHeaders());

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['data'] as List)
        .map((j) => Job.fromJson(j as Map<String, dynamic>))
        .toList();
  }

  /// Every job in the pool matching [categories], not just the first page.
  ///
  /// The Jobs tab shows the whole pool — but `GET /jobs` caps `limit` at 100, so
  /// one call could only ever show the newest 100. This walks the pages until
  /// one comes back short.
  ///
  /// `maxPages` used to be a safety stop that never fired: the ingestion
  /// relevance gate kept the pool to fresher/intern roles in two cities, so it
  /// sat in the tens. ADR-003 v3 changed that — the broad pool runs to 1,400+
  /// rows, past this 1,000 ceiling, and the cap would SILENTLY TRUNCATE rather
  /// than stop something runaway. That's why [categories] exists and why the
  /// Jobs tab always passes one: the server-side narrowing is what keeps this
  /// walk short, not the page cap.
  Future<List<Job>> fetchAllJobs({int pageSize = 100, int maxPages = 10, Set<String> categories = const {}}) async {
    final all = <Job>[];
    for (var page = 0; page < maxPages; page++) {
      final batch = await fetchJobs(limit: pageSize, offset: page * pageSize, categories: categories);
      all.addAll(batch);
      // A short page means we've reached the end.
      if (batch.length < pageSize) break;
    }
    return all;
  }

  /// Add Job step 1 (frontend rebuild Phase 2): fetches the pasted URL
  /// server-side and asks Gemini to extract job fields — nothing is
  /// created yet, this is just for the user to review/edit.
  Future<JobExtraction> parseManualJobUrl(String url) async {
    final uri = Uri.parse('$_baseUrl/jobs/manual/parse');
    final response = await http
        .post(
          uri,
          headers: _authHeaders({'Content-Type': 'application/json'}),
          body: jsonEncode({'url': url}),
        )
        .timeout(const Duration(seconds: 45));

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return JobExtraction.fromJson(body['data'] as Map<String, dynamic>);
  }

  /// Add Job step 2: creates (or returns the existing duplicate of) a job
  /// from the reviewed extraction.
  Future<Job> createManualJob(JobExtraction extraction, String url) async {
    final uri = Uri.parse('$_baseUrl/jobs/manual');
    final response = await http.post(
      uri,
      headers: _authHeaders({'Content-Type': 'application/json'}),
      body: jsonEncode({...extraction.toJson(), 'url': url}),
    );

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return Job.fromJson(body['data'] as Map<String, dynamic>);
  }

  /// JD-paste resume builder step 1: paste JD text, or upload it as a PDF
  /// (exactly one of [jdText]/[pdfBytes]) — returns structured fields to
  /// review before [createJdResumeJob] creates anything. Multipart even
  /// for the text-only case since the server route accepts both shapes.
  Future<JobExtraction> parseJd({
    String? jdText,
    List<int>? pdfBytes,
    String? pdfFilename,
  }) async {
    final uri = Uri.parse('$_baseUrl/jobs/from-jd/parse');
    final request = http.MultipartRequest('POST', uri)
      ..headers.addAll(_authHeaders());
    if (pdfBytes != null) {
      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          pdfBytes,
          filename: pdfFilename ?? 'jd.pdf',
          contentType: MediaType('application', 'pdf'),
        ),
      );
    } else {
      request.fields['jd_text'] = jdText ?? '';
    }

    final streamedResponse = await request.send().timeout(
      const Duration(seconds: 45),
    );
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return JobExtraction.fromJson(body['data'] as Map<String, dynamic>);
  }

  /// JD-paste resume builder step 2: creates the job + application row
  /// from the reviewed extraction. The caller then pushes ResumeDiffScreen
  /// with the returned id/title — same tailoring flow as any matched job.
  Future<JdResumeJob> createJdResumeJob(JobExtraction extraction) async {
    final uri = Uri.parse('$_baseUrl/jobs/from-jd');
    final response = await http.post(
      uri,
      headers: _authHeaders({'Content-Type': 'application/json'}),
      body: jsonEncode(extraction.toJson()),
    );

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return JdResumeJob.fromJson(body['data'] as Map<String, dynamic>);
  }

  /// Stage-1 RAG shortlist (Brick 4, ADR-001): the top-N jobs by cosine
  /// similarity to the stored profile. No LLM re-rank yet — that's Brick 5.
  Future<List<ShortlistItem>> fetchShortlist({int limit = 50}) async {
    final uri = Uri.parse('$_baseUrl/matches/shortlist?limit=$limit');
    final response = await http.get(uri, headers: _authHeaders());

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['data'] as List)
        .map((j) => ShortlistItem.fromJson(j as Map<String, dynamic>))
        .toList();
  }

  /// Stage 2 of the two-stage RAG match (Brick 5, ADR-001): triggers the LLM
  /// re-rank for the top [limit] shortlisted jobs and caches results
  /// server-side. ADR-011: the server now answers 202 with a task id
  /// immediately instead of holding the socket open for minutes of
  /// sequential Gemini calls (which Android's network stack aborted) —
  /// poll [getTaskStatus] until the task finishes, then [fetchMatches].
  Future<String> rerankShortlist({int limit = 20}) async {
    final uri = Uri.parse('$_baseUrl/matches/rerank?limit=$limit');
    // 60s not 30s: Render free tier (ADR-010) cold-starts after ~15min idle,
    // which alone can eat 30-60s before this fast POST even gets a response.
    final response = await http
        .post(uri, headers: _authHeaders())
        .timeout(const Duration(seconds: 60));

    if (response.statusCode != 202) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['data'] as Map<String, dynamic>)['task_id'] as String;
  }

  /// Polls one background task row (ADR-011). TaskCenter owns the polling
  /// loop; screens subscribe to it rather than calling this directly.
  Future<BackgroundTask> getTaskStatus(String taskId) async {
    final uri = Uri.parse('$_baseUrl/tasks/$taskId');
    final response = await http
        .get(uri, headers: _authHeaders())
        .timeout(const Duration(seconds: 60));

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return BackgroundTask.fromJson(body['data'] as Map<String, dynamic>);
  }

  /// Cached stage-2 results, best fit first — what [ShortlistScreen] renders
  /// as [MatchCard]s.
  ///
  /// Plan 21: returns a [MatchesPage] rather than a bare list, because `data`
  /// now carries the `locked` teasers and the profile's effective limit
  /// alongside the matches themselves.
  Future<MatchesPage> fetchMatches({int limit = 50}) async {
    final uri = Uri.parse('$_baseUrl/matches?limit=$limit');
    final response = await http.get(uri, headers: _authHeaders());

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    // fromAny, not fromJson: tolerates the pre-Plan-21 bare-array `data` so a
    // new app build against a not-yet-deployed server still renders matches.
    return MatchesPage.fromAny(body['data']);
  }

  /// Plan 21: this profile's referral code, how many people have used it, and
  /// the quota that has bought them. Backs [ReferralScreen].
  Future<ReferralStats> fetchReferralStats() async {
    final uri = Uri.parse('$_baseUrl/referrals/me');
    final response = await http.get(uri, headers: _authHeaders());

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return ReferralStats.fromJson((body['data'] as Map).cast<String, dynamic>());
  }

  /// Plan 21: applies someone else's invite code to this profile, granting both
  /// sides bonus matches. The server answers 400 with a human-readable reason
  /// for an invalid, self-owned, or already-redeemed code — [_extractErrorDetail]
  /// pulls that message out so onboarding can show it inline rather than
  /// failing silently.
  Future<ReferralStats> redeemReferralCode(String code) async {
    final uri = Uri.parse('$_baseUrl/referrals/redeem');
    final response = await http.post(
      uri,
      headers: _authHeaders({'Content-Type': 'application/json'}),
      body: jsonEncode({'code': code}),
    );

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return ReferralStats.fromJson((body['data'] as Map).cast<String, dynamic>());
  }

  /// Brick 6: tailors the stored resume toward one job and runs the
  /// anti-fabrication guardrail (ADR-004) over the result. ADR-011: one
  /// Gemini call takes 20-60s, so the server answers 202 + a task id —
  /// poll [getTaskStatus], then read the row via [fetchTailoredResume].
  Future<String> tailorResume(String jobId) async {
    final uri = Uri.parse('$_baseUrl/tailor/$jobId');
    final response = await http
        .post(uri, headers: _authHeaders())
        .timeout(const Duration(seconds: 60));

    if (response.statusCode != 202) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['data'] as Map<String, dynamic>)['task_id'] as String;
  }

  /// Reads back the most recent tailored resume for a job, if one exists —
  /// lets [ResumeDiffScreen] skip re-tailoring on revisit.
  Future<TailoredResume?> fetchTailoredResume(String jobId) async {
    final uri = Uri.parse('$_baseUrl/tailor/$jobId');
    final response = await http.get(uri, headers: _authHeaders());

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final data = body['data'];
    return data == null
        ? null
        : TailoredResume.fromJson(data as Map<String, dynamic>);
  }

  /// The human approval gate (Golden Rule: no auto-submitting anywhere) —
  /// marks a tailored resume reviewed and ready to use. [accepted] is the
  /// per-bullet keep-original/use-tailored decision, one bool per bullet
  /// in the same order as [TailoredResume.bullets] (frontend rebuild
  /// Phase 2); omit it to keep the original Brick 6 behavior of a single
  /// global approve.
  Future<TailoredResume> approveTailoredResume(
    String tailoredResumeId, {
    List<bool>? accepted,
  }) async {
    final uri = Uri.parse('$_baseUrl/tailor/$tailoredResumeId/approve');
    final response = await http.patch(
      uri,
      headers: _authHeaders({'Content-Type': 'application/json'}),
      body: jsonEncode({'accepted': ?accepted}),
    );

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return TailoredResume.fromJson(body['data'] as Map<String, dynamic>);
  }

  /// Career-ops integration Brick 2 (ADR-056): drafts a cover letter for one
  /// job and runs the same anti-fabrication guardrail tailoring uses over
  /// every paragraph. Same 202-plus-poll shape as [tailorResume] — poll
  /// [getTaskStatus], then read the row via [fetchCoverLetter].
  Future<String> generateCoverLetter(String jobId) async {
    final uri = Uri.parse('$_baseUrl/cover-letters/$jobId');
    final response = await http
        .post(uri, headers: _authHeaders())
        .timeout(const Duration(seconds: 60));

    if (response.statusCode != 202) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['data'] as Map<String, dynamic>)['task_id'] as String;
  }

  /// Reads back the most recent cover letter for a job, if one exists —
  /// lets [CoverLetterScreen] skip re-drafting on revisit.
  Future<CoverLetter?> fetchCoverLetter(String jobId) async {
    final uri = Uri.parse('$_baseUrl/cover-letters/$jobId');
    final response = await http.get(uri, headers: _authHeaders());

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final data = body['data'];
    return data == null ? null : CoverLetter.fromJson(data as Map<String, dynamic>);
  }

  /// The human approval gate — marks a cover letter reviewed. [accepted] is
  /// the per-paragraph keep/flag decision, one bool per paragraph in the
  /// same order as [CoverLetter.paragraphs]; omit it to accept every
  /// paragraph that passed the guardrail.
  Future<CoverLetter> approveCoverLetter(String coverLetterId, {List<bool>? accepted}) async {
    final uri = Uri.parse('$_baseUrl/cover-letters/$coverLetterId/approve');
    final response = await http.patch(
      uri,
      headers: _authHeaders({'Content-Type': 'application/json'}),
      body: jsonEncode({'accepted': ?accepted}),
    );

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return CoverLetter.fromJson(body['data'] as Map<String, dynamic>);
  }

  /// Downloads the compiled PDF for an approved cover letter — same
  /// binary-body exception as [downloadResumePdf].
  Future<Uint8List> downloadCoverLetterPdf(String coverLetterId) async {
    final uri = Uri.parse('$_baseUrl/cover-letters/$coverLetterId/pdf');
    final response = await http
        .get(uri, headers: _authHeaders())
        .timeout(const Duration(seconds: 60));

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }
    return response.bodyBytes;
  }

  /// Brick 7: adds a job to the Kanban tracker at the 'saved' stage.
  /// Idempotent server-side — safe to call again for a job already tracked.
  /// The create response is the bare application row (no job join, unlike
  /// [fetchApplications]), so this returns nothing — callers that need to
  /// show the tracker re-fetch the list.
  Future<void> saveToTracker(String jobId, {String? resumeVersionId}) async {
    final uri = Uri.parse('$_baseUrl/applications');
    final response = await http.post(
      uri,
      headers: _authHeaders({'Content-Type': 'application/json'}),
      body: jsonEncode({
        'job_id': jobId,
        'resume_version_id': ?resumeVersionId,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }
  }

  /// All tracked applications, job details joined in — what
  /// [ApplicationsScreen]'s Kanban board renders.
  Future<List<ApplicationItem>> fetchApplications() async {
    final uri = Uri.parse('$_baseUrl/applications');
    final response = await http.get(uri, headers: _authHeaders());

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['data'] as List)
        .map((a) => ApplicationItem.fromJson(a as Map<String, dynamic>))
        .toList();
  }

  /// The Kanban drag action: moves an application to a new pipeline stage.
  /// Returns nothing (the PATCH response is the bare row, no job join) —
  /// [ApplicationsScreen] updates its local copy via [ApplicationItem.copyWith]
  /// on success instead of re-parsing a job-less row.
  Future<void> updateApplicationState(
    String applicationId,
    String state,
  ) async {
    final uri = Uri.parse('$_baseUrl/applications/$applicationId');
    final response = await http.patch(
      uri,
      headers: _authHeaders({'Content-Type': 'application/json'}),
      body: jsonEncode({'state': state}),
    );

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }
  }

  /// AppDetailScreen's notes field (frontend rebuild Phase 2) — the
  /// `applications.notes` column existed since Brick 7 but had no editable
  /// UI until now.
  Future<void> updateApplicationNotes(
    String applicationId,
    String notes,
  ) async {
    final uri = Uri.parse('$_baseUrl/applications/$applicationId');
    final response = await http.patch(
      uri,
      headers: _authHeaders({'Content-Type': 'application/json'}),
      body: jsonEncode({'notes': notes}),
    );

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }
  }

  /// AppDetailScreen's "Draft a follow-up" button (frontend rebuild Phase
  /// 2): on-demand version of the daily agent loop's stale-application
  /// sweep, for one application the user explicitly asked about. Returns
  /// the (subject, body) pair so the caller can update local state without
  /// a full reload.
  Future<(String, String)> draftFollowup(String applicationId) async {
    final uri = Uri.parse('$_baseUrl/applications/$applicationId/followup');
    final response = await http
        .post(uri, headers: _authHeaders())
        .timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final data = body['data'] as Map<String, dynamic>;
    return (
      data['followup_subject'] as String,
      data['followup_body'] as String,
    );
  }

  /// AppDetailScreen's contact-email field (Phase 4) — the recruiter
  /// address "Approve & send" delivers a drafted follow-up to.
  Future<void> updateApplicationContactEmail(
    String applicationId,
    String contactEmail,
  ) async {
    final uri = Uri.parse('$_baseUrl/applications/$applicationId');
    final response = await http.patch(
      uri,
      headers: _authHeaders({'Content-Type': 'application/json'}),
      body: jsonEncode({'contact_email': contactEmail}),
    );

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }
  }

  /// AppDetailScreen's "Approve & send" button (Phase 4) — the one place
  /// in this app that sends anything external. Requires a draft and a
  /// contact email to already be set; the tap itself is the human
  /// approval gate (Golden Rule: no auto-submitting anywhere).
  Future<void> sendFollowup(String applicationId) async {
    final uri = Uri.parse(
      '$_baseUrl/applications/$applicationId/followup/send',
    );
    final response = await http
        .post(uri, headers: _authHeaders())
        .timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }
  }

  /// Career-ops integration Brick 3 (ADR-057): drafts a first-contact
  /// application/referral/cold email. Synchronous, not 202-plus-poll — same
  /// single-short-call shape as [draftFollowup], not [generateCoverLetter]'s
  /// background task. Every call inserts a NEW row (see
  /// [ApplicationEmailDraft]'s docstring), so the caller should refresh via
  /// [listApplicationEmails] afterward rather than trying to patch state in
  /// place.
  Future<ApplicationEmailDraft> draftApplicationEmail(String applicationId, String kind) async {
    final uri = Uri.parse('$_baseUrl/application-emails/$applicationId');
    final response = await http
        .post(
          uri,
          headers: _authHeaders({'Content-Type': 'application/json'}),
          body: jsonEncode({'kind': kind}),
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return ApplicationEmailDraft.fromJson(body['data'] as Map<String, dynamic>);
  }

  /// Every drafted variant for this application, newest first, plus the
  /// résumé/cover-letter attachment checklist (Golden Rule 2 — computed
  /// server-side, not asked of the LLM).
  Future<ApplicationEmailList> listApplicationEmails(String applicationId) async {
    final uri = Uri.parse('$_baseUrl/application-emails/$applicationId');
    final response = await http.get(uri, headers: _authHeaders());

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return ApplicationEmailList.fromJson(body['data'] as Map<String, dynamic>);
  }

  /// The "Approve & send" action for one drafted email — same posture as
  /// [sendFollowup]: requires a contact email already set on the
  /// application, and the tap itself is the human approval gate (Golden
  /// Rule: no auto-submitting anywhere).
  Future<ApplicationEmailDraft> sendApplicationEmail(String applicationId, String emailId) async {
    final uri = Uri.parse('$_baseUrl/application-emails/$applicationId/$emailId/send');
    final response = await http
        .post(uri, headers: _authHeaders())
        .timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return ApplicationEmailDraft.fromJson(body['data'] as Map<String, dynamic>);
  }

  /// Career-ops integration Brick 4 (ADR-058): generates a fresh interview
  /// pack for one application. Synchronous, not 202-plus-poll — same
  /// shape as [draftApplicationEmail]. Every call regenerates; nothing is
  /// cached server-side (see [InterviewPack]'s docstring), so the caller
  /// should hold the result in local state, not re-fetch it.
  Future<InterviewPack> generateInterviewPack(String applicationId) async {
    final uri = Uri.parse('$_baseUrl/interview-prep/$applicationId');
    final response = await http
        .post(uri, headers: _authHeaders())
        .timeout(const Duration(seconds: 45));

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return InterviewPack.fromJson(body['data'] as Map<String, dynamic>);
  }

  /// The persistent story bank (migration 034) — every saved story,
  /// newest first, independent of any one application.
  Future<List<InterviewStory>> listInterviewStories() async {
    final uri = Uri.parse('$_baseUrl/interview-stories');
    final response = await http.get(uri, headers: _authHeaders());

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['data'] as List).map((s) => InterviewStory.fromJson(s as Map<String, dynamic>)).toList();
  }

  /// Saves one story — either a generated pack's STAR answer the user
  /// chose to keep, or one written from scratch. [sourceJobId] is the job
  /// that prompted it, if any.
  Future<InterviewStory> createInterviewStory({
    required String situation,
    required String task,
    required String action,
    required String result,
    String? reflection,
    String? sourceJobId,
  }) async {
    final uri = Uri.parse('$_baseUrl/interview-stories');
    final response = await http.post(
      uri,
      headers: _authHeaders({'Content-Type': 'application/json'}),
      body: jsonEncode({
        'situation': situation,
        'task': task,
        'action': action,
        'result': result,
        if (reflection != null) 'reflection': reflection,
        if (sourceJobId != null) 'source_job_id': sourceJobId,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return InterviewStory.fromJson(body['data'] as Map<String, dynamic>);
  }

  /// Edits an existing story — every field optional, only sent fields
  /// change (server-side PATCH semantics via `exclude_unset`).
  Future<InterviewStory> updateInterviewStory(
    String storyId, {
    String? situation,
    String? task,
    String? action,
    String? result,
    String? reflection,
  }) async {
    final uri = Uri.parse('$_baseUrl/interview-stories/$storyId');
    final response = await http.patch(
      uri,
      headers: _authHeaders({'Content-Type': 'application/json'}),
      body: jsonEncode({
        if (situation != null) 'situation': situation,
        if (task != null) 'task': task,
        if (action != null) 'action': action,
        if (result != null) 'result': result,
        if (reflection != null) 'reflection': reflection,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return InterviewStory.fromJson(body['data'] as Map<String, dynamic>);
  }

  Future<void> deleteInterviewStory(String storyId) async {
    final uri = Uri.parse('$_baseUrl/interview-stories/$storyId');
    final response = await http.delete(uri, headers: _authHeaders());

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }
  }

  /// Career-ops integration Brick 5 (ADR-059): pastes one offer letter or
  /// contract's text and gets back a clause-by-clause plain-English read.
  /// Insert-only server-side — a re-paste after negotiating creates a new
  /// entry rather than overwriting the first read.
  Future<OfferReview> analyzeOffer(String applicationId, String rawText) async {
    final uri = Uri.parse('$_baseUrl/offer-reviews/$applicationId');
    final response = await http
        .post(
          uri,
          headers: _authHeaders({'Content-Type': 'application/json'}),
          body: jsonEncode({'raw_text': rawText}),
        )
        .timeout(const Duration(seconds: 60));

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return OfferReview.fromJson(body['data'] as Map<String, dynamic>);
  }

  /// Every offer read for this application, newest first.
  Future<List<OfferReview>> listOfferReviews(String applicationId) async {
    final uri = Uri.parse('$_baseUrl/offer-reviews/$applicationId');
    final response = await http.get(uri, headers: _authHeaders());

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['data'] as List).map((r) => OfferReview.fromJson(r as Map<String, dynamic>)).toList();
  }

  /// Career-ops integration Brick 1 (ADR-055): one-off catch-up for jobs
  /// ingested before `jobs.legitimacy_tier` existed —
  /// `score_posting()` only ever runs at ingestion time, so it never
  /// retroactively scores the existing pool on its own. Ops-triggered
  /// (debug gallery only, `kDebugMode`-gated — see routers/jobs.py's own
  /// docstring: "not something the app surfaces to end users"), safe to
  /// call repeatedly. Returns how many rows this ONE call scored (capped
  /// at 500 server-side) — the caller loops until it comes back 0.
  Future<int> backfillJobLegitimacy() async {
    final uri = Uri.parse('$_baseUrl/jobs/backfill-legitimacy');
    final response = await http
        .post(uri, headers: _authHeaders())
        .timeout(const Duration(seconds: 60));

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['data'] as Map<String, dynamic>)['backfilled'] as int;
  }

  /// Brick 9: manually triggers the agent loop for the caller's own
  /// profile only (POST /pipeline/run-mine) — distinct from the Render
  /// cron's POST /pipeline/run, which processes every beta user and is
  /// guarded by a shared secret instead of a user session. ADR-011: same
  /// 202 + poll pattern as [rerankShortlist]; returns the task id.
  Future<String> runPipeline() async {
    final uri = Uri.parse('$_baseUrl/pipeline/run-mine');
    final response = await http
        .post(uri, headers: _authHeaders())
        .timeout(const Duration(seconds: 60));

    if (response.statusCode != 202) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['data'] as Map<String, dynamic>)['task_id'] as String;
  }

  /// Phase 8 (§4.10): sends one turn to the grounded career assistant. Like
  /// [rerankShortlist]/[tailorResume] this is an ADR-011 async job — the server
  /// answers 202 with a task id (poll [getTaskStatus]; the finished task's
  /// `result.message` is the assistant reply) and the thread the turn landed in.
  /// Omit [threadId] to start a new conversation; pass an owned one to continue.
  /// Pro-gated server-side (402 on the free tier) and rate-limited.
  Future<ChatSendResult> sendChatMessage(String message, {String? threadId}) async {
    final uri = Uri.parse('$_baseUrl/chat');
    final response = await http
        .post(
          uri,
          headers: _authHeaders({'Content-Type': 'application/json'}),
          body: jsonEncode({'message': message, 'thread_id': ?threadId}),
        )
        .timeout(const Duration(seconds: 60));

    if (response.statusCode != 202) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return ChatSendResult.fromJson(body['data'] as Map<String, dynamic>);
  }

  /// Phase 8: the caller's conversations, most-recently-active first. The chat
  /// screen reads only the newest thread's id to reload history on open — so a
  /// conversation survives an app restart (§4.10 acceptance).
  Future<List<ChatThread>> listChatThreads() async {
    final uri = Uri.parse('$_baseUrl/chat/threads');
    final response = await http.get(uri, headers: _authHeaders());

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['data'] as List)
        .map((t) => ChatThread.fromJson(t as Map<String, dynamic>))
        .toList();
  }

  /// Phase 8: one thread's messages, oldest-first. 404 if it isn't the caller's.
  Future<List<ChatMessage>> fetchChatThread(String threadId) async {
    final uri = Uri.parse('$_baseUrl/chat/threads/$threadId');
    final response = await http.get(uri, headers: _authHeaders());

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final data = body['data'] as Map<String, dynamic>;
    return ((data['messages'] as List?) ?? const [])
        .map((m) => ChatMessage.fromJson(m as Map<String, dynamic>))
        .toList();
  }

  /// Phase 3: this calendar month's LLM cost/usage for the caller,
  /// broken down by task — what [CostStatsScreen] renders.
  Future<CostStats> fetchCostStats() async {
    final uri = Uri.parse('$_baseUrl/stats/costs');
    final response = await http.get(uri, headers: _authHeaders());

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return CostStats.fromJson(body['data'] as Map<String, dynamic>);
  }

  /// Phase 3: "what the agent did on your behalf" — application stage
  /// changes, follow-up drafts, and resume tailoring, newest first. Used
  /// by both [ActivityLogScreen] (full feed) and Home's "Recent
  /// activity" section (first couple of entries).
  Future<List<ActivityItem>> fetchActivity({int limit = 30}) async {
    final uri = Uri.parse('$_baseUrl/stats/activity?limit=$limit');
    final response = await http.get(uri, headers: _authHeaders());

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['data'] as List)
        .map((a) => ActivityItem.fromJson(a as Map<String, dynamic>))
        .toList();
  }

  /// Phase 4: skills-to-learn aggregated from the caller's real match
  /// gaps, with a real "N of M matches" frequency and LLM-suggested
  /// courses/projects — what [SkillGrowthScreen] renders. One Gemini call,
  /// but its input scales with match count (up to 50 matches' worth of gap
  /// text in a single prompt) — observed ~50s for 20 real matches, so this
  /// gets the same generous-timeout treatment as the other known-slow
  /// single-call tasks below rather than the default (no timeout at all).
  Future<List<SkillGrowthItem>> fetchSkillGrowth() async {
    final uri = Uri.parse('$_baseUrl/stats/skill-growth');
    final response = await http
        .get(uri, headers: _authHeaders())
        .timeout(const Duration(minutes: 3));

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['data'] as List)
        .map((s) => SkillGrowthItem.fromJson(s as Map<String, dynamic>))
        .toList();
  }

  /// Phase 5 (frontend rebuild v2): the fit-score history behind Home's
  /// gauge delta chip (R-D). `delta` comes back null until two snapshots
  /// ≥24h apart exist — the caller then hides the chip rather than showing
  /// a fabricated `+0` (§4.2). See server/services/score_history.py.
  Future<ScoreHistory> fetchScoreHistory() async {
    final uri = Uri.parse('$_baseUrl/stats/score-history');
    final response = await http.get(uri, headers: _authHeaders());

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return ScoreHistory.fromJson(body['data'] as Map<String, dynamic>);
  }

  /// Phase 5: the caller's plan state for Profile's plan card (§4.11).
  /// `tier` is the only field that gates anything server-side.
  Future<Subscription> fetchSubscription() async {
    final uri = Uri.parse('$_baseUrl/subscription');
    final response = await http.get(uri, headers: _authHeaders());

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return Subscription.fromJson(body['data'] as Map<String, dynamic>);
  }

  /// Phase 5: the notification feed + unread count (§4.13). Home reads only
  /// [NotificationFeed.unreadCount] for the bell badge; the full feed screen
  /// arrives in Phase 9. The unread count lives INSIDE data (server keeps the
  /// standard envelope), so it round-trips through [NotificationFeed.fromJson].
  Future<NotificationFeed> fetchNotifications({int limit = 50}) async {
    final uri = Uri.parse('$_baseUrl/notifications?limit=$limit');
    final response = await http.get(uri, headers: _authHeaders());

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return NotificationFeed.fromJson(body['data'] as Map<String, dynamic>);
  }

  /// Phase 9: mark one notification read (§4.13). Server returns the updated
  /// row; the screen only needs the success, so this returns nothing.
  Future<void> markNotificationRead(String id) async {
    final uri = Uri.parse('$_baseUrl/notifications/$id/read');
    final response = await http.patch(uri, headers: _authHeaders());
    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }
  }

  /// Phase 9: clear the whole unread badge in one call (§4.13, "Mark all
  /// read"). Idempotent server-side — only touches still-unread rows.
  Future<void> markAllNotificationsRead() async {
    final uri = Uri.parse('$_baseUrl/notifications/read-all');
    final response = await http.post(uri, headers: _authHeaders());
    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }
  }

  /// Phase 9: the cosmetic credits meter (§4.12 / R-B). Denominated in paise
  /// (₹), derived server-side from real spend — never gates. See [Wallet].
  Future<Wallet> fetchWallet() async {
    final uri = Uri.parse('$_baseUrl/wallet');
    final response = await http.get(uri, headers: _authHeaders());
    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return Wallet.fromJson(body['data'] as Map<String, dynamic>);
  }

  /// Phase 9: irreversibly delete the caller's account (§4.15). The UI gates
  /// this behind a [HoldButton], never a plain tap — this method assumes that
  /// confirmation already happened. Server cascades every profile-scoped row
  /// and removes the auth user; a 502 means data was deleted but the sign-in
  /// removal failed (surface its message so the user knows to contact support).
  Future<void> deleteAccount() async {
    final uri = Uri.parse('$_baseUrl/account');
    final response = await http.delete(uri, headers: _authHeaders());
    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }
  }

  /// Phase 6: parse a pasted application-form URL. Google Forms parse
  /// deterministically server-side; other pages go through an LLM
  /// extraction (flagged `llm_extracted`). A 403 with `form_auth_required`
  /// means the form needs Google sign-in to even view — the screen shows
  /// the open-in-browser fallback for that.
  Future<ParsedForm> parseForm(String url) async {
    final uri = Uri.parse('$_baseUrl/forms/parse');
    final response = await http
        .post(
          uri,
          headers: _authHeaders({'Content-Type': 'application/json'}),
          body: jsonEncode({'url': url}),
        )
        .timeout(const Duration(seconds: 60));

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return ParsedForm.fromJson(body['data'] as Map<String, dynamic>);
  }

  /// ADR-053: the sign-in-gated counterpart to [parseForm]. The server can't
  /// fetch a sign-in-gated form itself (no Google session), so the client
  /// fetches the page from inside an authenticated in-app WebView (the user
  /// signs in with their own account; we never see the credentials) and
  /// hands the resulting HTML here for the exact same deterministic parse.
  Future<ParsedForm> parseFormFromHtml(String html, String formUrl) async {
    final uri = Uri.parse('$_baseUrl/forms/parse-html');
    final response = await http
        .post(
          uri,
          headers: _authHeaders({'Content-Type': 'application/json'}),
          body: jsonEncode({'html': html, 'form_url': formUrl}),
        )
        .timeout(const Duration(seconds: 60));

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return ParsedForm.fromJson(body['data'] as Map<String, dynamic>);
  }

  /// Phase 6: map the stored profile onto a parsed form. One Gemini call
  /// (nulls where the profile has no answer — never invented) plus the
  /// deterministic choice-membership guardrail, then the prefill URL.
  Future<FormFillResult> fillForm(FormSchemaModel form) async {
    final uri = Uri.parse('$_baseUrl/forms/fill');
    final response = await http
        .post(
          uri,
          headers: _authHeaders({'Content-Type': 'application/json'}),
          body: jsonEncode({'form': form.toJson()}),
        )
        .timeout(const Duration(seconds: 90));

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return FormFillResult.fromJson(body['data'] as Map<String, dynamic>);
  }

  /// Persists the user's final (possibly edited) answers for a fill —
  /// called right before opening the prefilled form, so the next form's
  /// /forms/fill can silently reuse recurring answers (server's
  /// _build_answer_history) from what was actually confirmed, not the raw
  /// LLM guess. Fire-and-forget from the caller's side: errors here should
  /// never block or fail the "open the form" action itself.
  Future<void> updateFormFillAnswers(
    String fillId,
    List<FormAnswer> answers,
  ) async {
    final uri = Uri.parse('$_baseUrl/forms/fills/$fillId');
    final response = await http.patch(
      uri,
      headers: _authHeaders({'Content-Type': 'application/json'}),
      body: jsonEncode({'answers': answers.map((a) => a.toJson()).toList()}),
    );

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }
  }

  /// Phase 4B: downloads the compiled ATS-friendly PDF for an approved
  /// tailored resume. The one endpoint that skips the JSON envelope —
  /// binary body (documented exception in server/routers/tailor.py).
  Future<Uint8List> downloadResumePdf(String tailoredResumeId) async {
    final uri = Uri.parse('$_baseUrl/tailor/$tailoredResumeId/pdf');
    final response = await http
        .get(uri, headers: _authHeaders())
        .timeout(const Duration(seconds: 60));

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }
    return response.bodyBytes;
  }

  /// Phase 3B: explicit onboarding-step advance for skip buttons
  /// (ProfileReview skip → 'roles', TargetRoles skip → 'done'). The server
  /// state machine is forward-only, so this can never regress a user.
  Future<void> updateOnboardingStep(String step) async {
    final uri = Uri.parse('$_baseUrl/resume/profile/onboarding-step');
    final response = await http.patch(
      uri,
      headers: _authHeaders({'Content-Type': 'application/json'}),
      body: jsonEncode({'step': step}),
    );

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }
  }

  /// Phase 4 Settings screen: gates the two calls
  /// jobs/daily_pipeline.py::_process_profile already makes unconditionally
  /// (push alerts, stale follow-up drafting) — not new pipeline behavior,
  /// just an on/off switch. Deliberately separate from PATCH /resume/profile,
  /// same reason as fcm-token/target-roles.
  Future<void> updateNotificationPrefs({
    required bool alerts,
    required bool followupNudge,
  }) async {
    final uri = Uri.parse('$_baseUrl/resume/profile/notification-prefs');
    final response = await http.patch(
      uri,
      headers: _authHeaders({'Content-Type': 'application/json'}),
      body: jsonEncode({'alerts': alerts, 'followup_nudge': followupNudge}),
    );

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }
  }

  /// Turns a non-2xx response body into a human-readable message. The server
  /// always sends its reason in `detail` (FastAPI's HTTPException shape), so
  /// that's preferred; the status-code fallbacks are for the rare case where
  /// the body isn't the JSON we expect.
  ///
  /// 429 (rate limited, server ADR-027) gets an explicit friendly branch:
  /// TaskCenter surfaces a thrown message straight into a toast, and "You're
  /// doing that too fast — please wait a few minutes" is what the user should
  /// see there, never a raw "Server returned 429" or a generic error screen.
  String _extractErrorDetail(String responseBody, int statusCode) {
    String? detail;
    try {
      final decoded = jsonDecode(responseBody) as Map<String, dynamic>;
      detail = decoded['detail']?.toString();
    } catch (_) {
      detail = null;
    }
    if (statusCode == 429) {
      return detail?.isNotEmpty == true
          ? detail!
          : 'You\'re doing that too fast — please wait a few minutes and try again.';
    }
    return detail ?? 'Server returned $statusCode';
  }
}
