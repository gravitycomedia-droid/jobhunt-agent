import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/form_fill.dart';
import '../router/route_args.dart';
import '../services/api_client.dart';
import '../services/haptic_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_metrics.dart';
import '../widgets/app_banner.dart';
import '../widgets/app_form_field.dart';
import '../widgets/app_icon.dart';
import '../widgets/page_header.dart';

/// Phase 6: "Fill an application form".
///
/// Paste a public form URL → tap once → the server parses it (deterministically
/// for Google Forms), the agent maps your profile onto the questions (nulls
/// where it honestly doesn't know), and the app drops you **straight into the
/// in-app WebView** with the answers already pre-typed (Google's own
/// `usp=pp_url` prefill — no DOM injection). One tap from URL to a filled form;
/// the reviewable answer sheet stays on this screen underneath, reachable from
/// the WebView's ⋮ menu ("Review & edit answers") for anything you want to
/// change, and re-opening after an edit rebuilds the prefill URL.
///
/// It also *learns*: PATCH /forms/fills/{id} persists your final, edited
/// answers, and the next form reuses them for recurring questions (phone,
/// notice period, sponsorship) instead of guessing again.
///
/// You sign into Google in the WebView (their account picker — we never touch
/// credentials), attach any files manually, and tap Google's own Submit.
/// Nothing is ever submitted by the app or server.
class FormFillScreen extends StatefulWidget {
  const FormFillScreen({super.key});

  @override
  State<FormFillScreen> createState() => _FormFillScreenState();
}

class _FormFillScreenState extends State<FormFillScreen> {
  final ApiClient _apiClient = ApiClient();
  final _urlController = TextEditingController();

  bool _isParsing = false;
  bool _isFilling = false;
  String? _errorMessage;
  bool _authRequired = false;

  ParsedForm? _parsed;
  List<FormAnswer> _answers = [];
  final Map<String, TextEditingController> _answerControllers = {};
  String? _prefillUrl;
  String? _fillId;

  @override
  void dispose() {
    _urlController.dispose();
    for (final c in _answerControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _parse() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;
    setState(() {
      _isParsing = true;
      _errorMessage = null;
      _authRequired = false;
      _parsed = null;
      _answers = [];
      _prefillUrl = null;
      _fillId = null;
    });
    try {
      final parsed = await _apiClient.parseForm(url);
      if (!mounted) return;
      setState(() {
        _parsed = parsed;
        _isParsing = false;
      });
      await _fill(parsed);
      // One tap, all the way through: the point of this screen is a *filled
      // form*, not a filled form-review sheet. Only Google Forms can be
      // prefilled, so an LLM-extracted page (or a fill that produced nothing)
      // stops here and shows the copy-paste answer list instead.
      if (mounted && _answers.isNotEmpty && !parsed.form.isLlmExtracted) {
        await _openPrefilled();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isParsing = false;
        _authRequired = e.toString().contains('form_auth_required');
        _errorMessage = _authRequired ? null : e.toString();
      });
    }
  }

  Future<void> _fill(ParsedForm parsed) async {
    setState(() => _isFilling = true);
    try {
      final result = await _apiClient.fillForm(parsed.form);
      if (!mounted) return;
      setState(() {
        _answers = result.answers;
        _prefillUrl = result.prefillUrl;
        _fillId = result.fillId;
        _isFilling = false;
        for (final a in _answers) {
          _answerControllers[a.entryId] = TextEditingController(text: a.answerText);
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isFilling = false;
        _errorMessage = e.toString();
      });
    }
  }

  /// Rebuilds the prefill URL from the (possibly user-edited) answer rows —
  /// pure string assembly, mirroring the server's builder. Only Google
  /// Forms have entry ids to prefill; edits to flagged/checkbox rows are
  /// included as typed (the user's explicit edit outranks the guardrail's
  /// flag on the ORIGINAL answer — they've reviewed it).
  String? get _editedPrefillUrl {
    final parsed = _parsed;
    if (parsed == null || parsed.form.isLlmExtracted || parsed.form.formUrl.isEmpty) return _prefillUrl;
    final types = {for (final q in parsed.form.questions) q.entryId: q.type};
    final params = <String>['usp=pp_url'];
    for (final a in _answers) {
      if (a.entryId.isEmpty || types[a.entryId] == 'file_upload') continue;
      final text = _answerControllers[a.entryId]?.text.trim() ?? '';
      if (text.isEmpty) continue;
      final values = types[a.entryId] == 'checkbox' ? text.split(',').map((v) => v.trim()) : [text];
      for (final v in values) {
        if (v.isNotEmpty) params.add('entry.${a.entryId}=${Uri.encodeQueryComponent(v)}');
      }
    }
    final sep = parsed.form.formUrl.contains('?') ? '&' : '?';
    return '${parsed.form.formUrl}$sep${params.join('&')}';
  }

  /// The same per-row edits as [_editedPrefillUrl], but as [FormAnswer]s
  /// instead of URL params — sent to PATCH /forms/fills/{id} so a future
  /// form's answer-history reuse learns from what the user actually typed,
  /// not the original LLM guess.
  List<FormAnswer> get _editedAnswers {
    final types = {for (final q in _parsed?.form.questions ?? const <FormQuestion>[]) q.entryId: q.type};
    return _answers.map((a) {
      final text = _answerControllers[a.entryId]?.text.trim() ?? '';
      final Object? value = text.isEmpty
          ? null
          : (types[a.entryId] == 'checkbox' ? text.split(',').map((v) => v.trim()).toList() : text);
      return FormAnswer(
        entryId: a.entryId,
        question: a.question,
        answer: value,
        confidence: a.confidence,
        sourceField: a.sourceField,
        guardrailPass: a.guardrailPass,
      );
    }).toList();
  }

  Future<void> _openPrefilled() async {
    final url = _editedPrefillUrl;
    if (url == null) return;
    HapticService.instance.light();
    final fillId = _fillId;
    if (fillId != null) {
      unawaited(_apiClient.updateFormFillAnswers(fillId, _editedAnswers).catchError((_) {}));
    }
    // §4.8: host the PREFILLED form in an in-app WebView (not the external
    // browser) so the review→attach→submit handoff stays inside the app.
    final filled = _editedAnswers.where((a) => a.answer != null && a.answer.toString().trim().isNotEmpty).length;
    context.push(
      '/form-webview',
      extra: FormWebViewArgs(
        prefillUrl: url,
        formTitle: _parsed?.form.title ?? 'Application form',
        filledCount: filled,
        fileUploadLabels: _fileUploadQuestions.map((q) => q.text).toList(),
        // Carries the JD the parse detected (if any) so the WebView's ⋮ menu
        // can offer "tailor my résumé for this JD" without re-parsing.
        jobId: _parsed?.jobId,
        jobTitle: _parsed?.jobTitle,
      ),
    );
  }

  Future<void> _openPlain() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  /// ADR-053: the sign-in-gated form's primary action. Opens the in-app
  /// WebView on the plain URL, waits for the user to sign into their own
  /// Google account and the real page to load, then autofills it the same
  /// way the public-form path does — see FormWebViewScreen's class doc.
  /// Awaits the typed pop result so this screen's own answer sheet ends up
  /// with the same state the public-form path would have given it directly
  /// (keeps "Review & edit answers" from the WebView's ⋮ menu meaningful).
  Future<void> _openSignInFlow() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;
    final handoff = await context.push<FormAutofillHandoff>(
      '/form-webview',
      extra: FormWebViewArgs(signInUrl: url, formTitle: 'Application form'),
    );
    if (handoff == null || !mounted) return;
    setState(() {
      _parsed = handoff.parsed;
      _answers = handoff.answers;
      _prefillUrl = handoff.prefillUrl;
      _fillId = handoff.fillId;
      _authRequired = false;
      for (final a in _answers) {
        _answerControllers[a.entryId] = TextEditingController(text: a.answerText);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const PageHeader(title: 'Fill an application form', showBack: true),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.screenPadX),
          children: [
            AppFormField(
              label: 'Form URL',
              controller: _urlController,
              placeholder: 'https://docs.google.com/forms/…',
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: AppSpacing.space3),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isParsing || _isFilling ? null : _parse,
                child: Text(_isParsing
                    ? 'Reading the form…'
                    : _isFilling
                        ? 'Filling from your profile…'
                        : 'Autofill & open the form'),
              ),
            ),
            if (_authRequired) ...[
              const SizedBox(height: AppSpacing.space3),
              AppBanner(
                tone: BannerTone.warning,
                title: 'This form requires sign-in to view',
                // ADR-053: sign in right here — the app reads the form once
                // you land on it and fills what it can from your profile,
                // same as an ungated form.
                message: 'Sign in with your Google account in-app and we\'ll autofill it for you.',
                actionLabel: 'Sign in & autofill',
                onAction: _openSignInFlow,
              ),
              const SizedBox(height: AppSpacing.space2),
              Center(
                child: TextButton(
                  onPressed: _openPlain,
                  child: const Text('Or open in your browser instead'),
                ),
              ),
            ],
            if (_errorMessage != null) ...[
              const SizedBox(height: AppSpacing.space3),
              AppBanner(
                tone: BannerTone.critical,
                title: 'Could not process that form',
                message: _errorMessage,
                actionLabel: 'Retry',
                onAction: _parse,
              ),
            ],
            if (_parsed != null) ...[
              const SizedBox(height: AppSpacing.space5),
              Text(_parsed!.form.title, style: AppTypography.title),
              if (_parsed!.form.isLlmExtracted) ...[
                const SizedBox(height: AppSpacing.space2),
                const AppBanner(
                  tone: BannerTone.info,
                  title: 'Extracted with AI (not a Google Form)',
                  message: 'Question detection is best-effort here — double-check against the real page. '
                      'Prefilling only works for Google Forms; use these answers as a copy-paste guide.',
                ),
              ],
              if (_parsed!.jobId != null) ...[
                const SizedBox(height: AppSpacing.space3),
                AppBanner(
                  tone: BannerTone.info,
                  title: 'Job description detected',
                  message: 'This form includes a JD — tailor your resume for it before applying.',
                  actionLabel: 'Tailor resume',
                  onAction: () => context.push(
                    '/tailor',
                    extra: TailorArgs(
                      jobId: _parsed!.jobId!,
                      jobTitle: _parsed!.jobTitle ?? _parsed!.form.title,
                    ),
                  ),
                ),
              ],
            ],
            if (_answers.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.space4),
              for (final answer in _answers) ...[
                _answerRow(answer),
                const SizedBox(height: AppSpacing.space3),
              ],
              const SizedBox(height: AppSpacing.space2),
              if (_fileUploadQuestions.isNotEmpty)
                AppBanner(
                  tone: BannerTone.info,
                  title: 'Attach manually',
                  message: 'Google doesn\'t allow prefilled file answers — attach these in the browser: '
                      '${_fileUploadQuestions.map((q) => q.text).join(' · ')}',
                ),
              const SizedBox(height: AppSpacing.space3),
              if (!_parsed!.form.isLlmExtracted)
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _openPrefilled,
                    icon: AppIcon(AppIconName.externalLink, size: 18, color: context.onAccent),
                    // The form already opened once on parse; this re-opens it
                    // with whatever the user changed in the rows above.
                    label: const Text('Reopen form with my edits'),
                  ),
                ),
              const SizedBox(height: AppSpacing.space2),
              Text(
                'Review every answer above, then submit the form yourself in the browser — '
                'the agent never submits anything for you.',
                textAlign: TextAlign.center,
                style: AppTypography.caption.copyWith(color: context.c.inkFaint),
              ),
            ],
          ],
        ),
      ),
    );
  }

  List<FormQuestion> get _fileUploadQuestions =>
      _parsed?.form.questions.where((q) => q.isFileUpload).toList() ?? const [];

  Widget _answerRow(FormAnswer answer) {
    final controller = _answerControllers[answer.entryId];
    final flagged = answer.needsAttention;
    final String? flagText = !answer.guardrailPass
        ? 'Not an exact option on the form — pick one of the listed choices.'
        : answer.answer == null
            ? 'Your profile doesn\'t contain this — fill it in yourself.'
            : answer.confidence < 0.5
                ? 'Low confidence — double-check this one.'
                : null;
    final question = _parsed?.form.questions.where((q) => q.entryId == answer.entryId).toList() ?? const [];
    final options = question.isNotEmpty ? question.first.options : const <String>[];

    return Container(
      padding: const EdgeInsets.all(AppSpacing.space3),
      decoration: BoxDecoration(
        color: context.c.surface,
        border: Border.all(color: flagged ? context.c.warning.withValues(alpha: 0.30) : context.c.border),
        borderRadius: AppRadius.mdRadius,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(answer.question, style: AppTypography.bodySm.copyWith(fontWeight: FontWeight.w700)),
          if (options.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text('Options: ${options.join(' · ')}', style: AppTypography.caption.copyWith(color: context.c.inkFaint)),
          ],
          const SizedBox(height: AppSpacing.space2),
          if (controller != null)
            AppFormField(label: '', controller: controller, placeholder: 'Your answer…'),
          if (answer.sourceField != null && answer.answer != null) ...[
            const SizedBox(height: 2),
            Text('From your profile: ${answer.sourceField}',
                style: AppTypography.caption.copyWith(color: context.c.inkFaint)),
          ],
          if (flagText != null) ...[
            const SizedBox(height: AppSpacing.space2),
            Row(
              children: [
                AppIcon(AppIconName.alertTriangle, size: 13, color: context.c.warning),
                const SizedBox(width: 4),
                Expanded(child: Text(flagText, style: AppTypography.caption.copyWith(color: context.c.warning))),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
