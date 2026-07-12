import 'dart:convert';
import 'dart:typed_data' show Uint8List;

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show Supabase;

import '../models/activity_item.dart';
import '../models/application_item.dart';
import '../models/background_task.dart';
import '../models/cost_stats.dart';
import '../models/form_fill.dart';
import '../models/health_status.dart';
import '../models/job.dart';
import '../models/job_extraction.dart';
import '../models/match_item.dart';
import '../models/resume_profile.dart';
import '../models/shortlist_item.dart';
import '../models/skill_growth_item.dart';
import '../models/tailored_resume.dart';

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
  /// JSearch alone routinely takes ~60s to respond; a longer `.timeout()`
  /// than the other calls reflects that, rather than a bug.
  /// Returns the server's `{fetched, inserted}` counts so the completion
  /// toast (Phase 2) can say what actually happened.
  Future<Map<String, dynamic>> refreshJobs() async {
    final uri = Uri.parse('$_baseUrl/jobs/refresh');
    final response = await http
        .post(uri, headers: _authHeaders())
        .timeout(const Duration(seconds: 120));

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['data'] as Map<String, dynamic>?) ?? const {};
  }

  Future<List<Job>> fetchJobs({int limit = 20, int offset = 0}) async {
    final uri = Uri.parse('$_baseUrl/jobs?limit=$limit&offset=$offset');
    final response = await http.get(uri, headers: _authHeaders());

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['data'] as List)
        .map((j) => Job.fromJson(j as Map<String, dynamic>))
        .toList();
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
  Future<List<MatchItem>> fetchMatches({int limit = 50}) async {
    final uri = Uri.parse('$_baseUrl/matches?limit=$limit');
    final response = await http.get(uri, headers: _authHeaders());

    if (response.statusCode != 200) {
      throw Exception(_extractErrorDetail(response.body, response.statusCode));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['data'] as List)
        .map((j) => MatchItem.fromJson(j as Map<String, dynamic>))
        .toList();
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
