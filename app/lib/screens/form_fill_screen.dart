import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/form_fill.dart';
import '../router/route_args.dart';
import '../services/api_client.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_banner.dart';
import '../widgets/app_form_field.dart';
import '../widgets/app_icon.dart';
import '../widgets/page_header.dart';

/// Phase 6: "Fill an application form".
///
/// Paste a public form URL → the server parses it (deterministically for
/// Google Forms) → the agent maps your profile onto the questions (nulls
/// where it honestly doesn't know) → you review and edit every answer →
/// "Open prefilled form" launches the form in YOUR browser with answers
/// pre-typed. You sign into Google there (their account picker — we never
/// touch credentials), attach any files manually, and tap Google's own
/// Submit. Nothing is ever submitted by the app or server.
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
    final fillId = _fillId;
    if (fillId != null) {
      unawaited(_apiClient.updateFormFillAnswers(fillId, _editedAnswers).catchError((_) {}));
    }
    final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open the form')));
    }
  }

  Future<void> _openPlain() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
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
                        : 'Parse & fill from my profile'),
              ),
            ),
            if (_authRequired) ...[
              const SizedBox(height: AppSpacing.space3),
              AppBanner(
                tone: BannerTone.warning,
                title: 'This form requires sign-in to view',
                message: 'Open it in your browser, sign in with your Google account, and fill it there.',
                actionLabel: 'Open in browser',
                onAction: _openPlain,
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
                    icon: const AppIcon(AppIconName.externalLink, size: 18, color: AppColors.textOnBrand),
                    label: const Text('Open prefilled form'),
                  ),
                ),
              const SizedBox(height: AppSpacing.space2),
              Text(
                'Review every answer above, then submit the form yourself in the browser — '
                'the agent never submits anything for you.',
                textAlign: TextAlign.center,
                style: AppTypography.caption.copyWith(color: AppColors.textTertiary),
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
        color: AppColors.surface,
        border: Border.all(color: flagged ? AppColors.warningBorder : AppColors.border),
        borderRadius: AppRadius.mdRadius,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(answer.question, style: AppTypography.bodySm.copyWith(fontWeight: FontWeight.w700)),
          if (options.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text('Options: ${options.join(' · ')}', style: AppTypography.caption.copyWith(color: AppColors.textTertiary)),
          ],
          const SizedBox(height: AppSpacing.space2),
          if (controller != null)
            AppFormField(label: '', controller: controller, placeholder: 'Your answer…'),
          if (answer.sourceField != null && answer.answer != null) ...[
            const SizedBox(height: 2),
            Text('From your profile: ${answer.sourceField}',
                style: AppTypography.caption.copyWith(color: AppColors.textTertiary)),
          ],
          if (flagText != null) ...[
            const SizedBox(height: AppSpacing.space2),
            Row(
              children: [
                const AppIcon(AppIconName.alertTriangle, size: 13, color: AppColors.warningText),
                const SizedBox(width: 4),
                Expanded(child: Text(flagText, style: AppTypography.caption.copyWith(color: AppColors.warningText))),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
