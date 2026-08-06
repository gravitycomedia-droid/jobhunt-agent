import 'dart:async' show unawaited;
import 'dart:convert' show jsonDecode, jsonEncode;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../models/form_fill.dart';
import '../router/route_args.dart';
import '../services/api_client.dart';
import '../theme/app_colors.dart';
import '../theme/app_metrics.dart';
import '../widgets/app_icon.dart';
import '../widgets/app_loader.dart';
import '../widgets/page_header.dart';

/// §4.8 in-app WebView. Loads Google's OWN prefilled-form URL (the published
/// `usp=pp_url` prefill mechanism) so the fields arrive already filled and the
/// user reviews + submits without leaving the app.
///
/// Smart AI Fill (career-ops integration) generalized this beyond Google
/// Forms and beyond "only right after a Google sign-in redirect": [browseUrl]
/// opens this screen in plain browse mode (the Jobs tab's Apply button — a
/// job link is usually a listing page, not the form itself, so the user
/// navigates/signs in on the real site first) and the overflow menu's
/// "✨ Smart AI Fill" runs the same one-time-HTML-read pipeline ADR-053 built,
/// on demand, from wherever the user has navigated to.
///
/// Three hard constraints, all honoured here:
///  - **No DOM injection to FILL a Google Form.** Google's fields are only
///    ever populated via Google's own prefill URL, never by us writing into
///    the page — that breaks on every Google reskin and is a worse posture
///    than the published mechanism.
///  - **DOM injection elsewhere (Unstop/Internshala/Naukri/Indeed's own apply
///    forms) is scoped and safety-railed, not the "no injection ever" rule
///    reversed wholesale.** Only [FormQuestion.isInjectable] fields (plain
///    text/paragraph, a real `dom_selector` built deterministically
///    server-side — see services/form_parser.extract_dom_fields) ever get
///    written into; complex widgets (dropdowns, skills pickers, anything
///    without a selector) always surface as a tap-to-copy suggestion
///    instead. Password/OTP/file inputs are excluded at the SOURCE (the
///    server-side extractor never emits a selector for them) — this screen
///    has no separate blocklist to keep in sync because it never sees them.
///  - **Honest copy, and no submit anywhere.** Google Forms can't prefill a
///    file-upload question, and file-upload requires the respondent to be
///    signed into Google; no `<input type="file">` can be set from any
///    script on any site, full stop — that's a browser platform rule, not a
///    choice made here. Whatever got filled, the user reviews and taps the
///    site's own Submit — this screen (and the server) never does.
///
/// ADR-053: when [FormWebViewArgs.signInUrl] is set instead of [prefillUrl]
/// (the form needs Google sign-in to even view), this screen loads that
/// plain URL first. The user signs into their own Google account right here
/// — we never see the credentials, same as the external-browser fallback
/// used to guarantee. Once the WebView lands somewhere that isn't Google's
/// own sign-in page, [_runSmartAiFill] fires automatically (silently) using
/// the exact same mechanism the three header icons below trigger by hand.
///
/// Those three — Smart Apply / Tailor Résumé / Cover Letter — used to live
/// inside the "⋮" overflow menu, undiscoverable enough that a first-time
/// user had no reason to know they existed. They're now visible header
/// icons, plus a one-time animated guide ([_maybeShowGuide]) that pulses
/// them and explains what each does the first time this screen ever opens —
/// see [_showGuide]/[_guideAnimController].
/// The remaining, less-common actions stay behind the "⋮" overflow menu.
enum _FormMenuAction { review, resume, reload, openExternally }

class FormWebViewScreen extends StatefulWidget {
  const FormWebViewScreen({
    super.key,
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

  /// Set when the form's description was long enough to be a job description
  /// and the server captured it as a job row (POST /forms/parse). Non-null
  /// turns the overflow menu's JD entries into "tailor for THIS job".
  final String? jobId;
  final String? jobTitle;

  /// ADR-053: see the class doc above. Mutually exclusive with [prefillUrl]/[browseUrl].
  final String? signInUrl;

  /// Smart AI Fill's "Apply" entry point — see the class doc above.
  /// Mutually exclusive with [prefillUrl]/[signInUrl].
  final String? browseUrl;

  @override
  State<FormWebViewScreen> createState() => _FormWebViewScreenState();
}

class _FormWebViewScreenState extends State<FormWebViewScreen> with SingleTickerProviderStateMixin {
  final ApiClient _apiClient = ApiClient();
  late final WebViewController _controller;
  bool _loading = true;
  bool _showBanner = true;

  /// First-ever-visit guide (persisted so it only shows once, ever — not
  /// once per screen visit, which would just be repetitive). Drives both the
  /// pulsing scale on the three header icons and the explainer card in
  /// [_guideOverlay].
  static const _guideSeenKey = 'smart_apply_guide_seen_v1';
  bool _showGuide = false;
  late final AnimationController _guideAnimController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  );

  // ADR-053 sign-in flow state — stays at these defaults for the ordinary
  // already-prefilled path (widget.signInUrl == null). Smart AI Fill's
  // manual trigger (widget.browseUrl != null) reuses every field below
  // through the same [_runSmartAiFill] method the sign-in flow calls.
  bool _autofillAttempted = false;
  late bool _autofilling = widget.signInUrl != null;
  String? _autofillError;
  late int _filledCount = widget.filledCount;
  FormAutofillHandoff? _handoff;

  /// Smart AI Fill: fields the last run found an answer for but could NOT
  /// safely inject (a dropdown/skills-picker/anything without a real DOM
  /// selector, or any field on a page that only got as far as the
  /// stripped-text LLM extraction) — shown as a tap-to-copy sheet instead of
  /// being written into the page blind.
  List<(FormQuestion, FormAnswer)> _suggestions = [];
  bool _hasRunSmartFill = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      // Google Forms needs JS to render regardless. Smart AI Fill additionally
      // uses it for reading the current page once and (non-Google pages only,
      // text-like fields only) writing plain values into it — see class doc.
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (mounted) setState(() => _loading = true);
          },
          onPageFinished: (url) {
            if (mounted) setState(() => _loading = false);
            unawaited(_maybeAutofillAfterSignIn(url));
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.browseUrl ?? widget.signInUrl ?? widget.prefillUrl!));
    unawaited(_maybeShowGuide());
  }

  @override
  void dispose() {
    _guideAnimController.dispose();
    super.dispose();
  }

  /// Shows the pulsing header-icon guide exactly once, ever — checked
  /// against a persisted flag so returning to this screen on a later
  /// application doesn't repeat something the user already learned.
  /// Auto-dismisses after a few seconds so it never sits blocking anything
  /// if the user just starts using the page without tapping "Got it".
  Future<void> _maybeShowGuide() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_guideSeenKey) == true) return;
    if (!mounted) return;
    setState(() => _showGuide = true);
    unawaited(_guideAnimController.repeat(reverse: true));
    Future.delayed(const Duration(seconds: 6), () {
      if (mounted && _showGuide) unawaited(_dismissGuide());
    });
  }

  Future<void> _dismissGuide() async {
    if (!_showGuide) return;
    if (mounted) setState(() => _showGuide = false);
    _guideAnimController
      ..stop()
      ..reset();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_guideSeenKey, true);
  }

  /// ADR-053: fires on every page load while [widget.signInUrl] is set.
  /// No-ops once already attempted, or while the WebView is still somewhere
  /// under Google's own sign-in flow — the same two markers the server side
  /// (`services/form_parser.py`) already checks for a redirect-based gate.
  /// [widget.browseUrl] never auto-triggers — Smart AI Fill only ever runs
  /// there when the user explicitly taps the overflow menu action, since a
  /// job's own posting link is rarely the application form itself.
  Future<void> _maybeAutofillAfterSignIn(String url) async {
    if (widget.signInUrl == null || _autofillAttempted) return;
    if (url.contains('accounts.google.com') || url.contains('ServiceLogin')) return; // still signing in
    _autofillAttempted = true;
    await _runSmartAiFill(silent: true);
  }

  /// The one shared Smart AI Fill pipeline — reads the CURRENT page's HTML
  /// once (never an injection, never a submit), parses + maps it through the
  /// existing server pipeline, and either:
  ///  - a Google Form: builds the prefill URL and navigates there (fields
  ///    arrive already typed, exactly like the public-form path);
  ///  - a dom_extracted page (Unstop/Internshala/Naukri/Indeed's own apply
  ///    forms): injects [FormQuestion.isInjectable] fields directly, surfaces
  ///    anything else as a tap-to-copy suggestion;
  ///  - an llm_extracted page (DOM extraction found nothing fillable — most
  ///    often a JS-rendered SPA whose inputs mounted after this read):
  ///    tap-to-copy suggestions only, same as [dom_extracted]'s non-injectable
  ///    remainder.
  /// [silent] suppresses the "nothing to fill here" snackbar for the
  /// automatic post-Google-sign-in trigger — a toast firing the instant a
  /// sign-in redirect settles reads as noise, not feedback, there.
  Future<void> _runSmartAiFill({bool silent = false}) async {
    setState(() => _autofilling = true);
    try {
      // A READ of the page the user is already looking at — not an
      // injection, not a submit. Platform WebViews return this as a
      // JSON-quoted string (Android/iOS both), hence the unwrap below.
      final raw = (await _controller.runJavaScriptReturningResult('document.documentElement.outerHTML')).toString();
      String html = raw;
      if (raw.startsWith('"')) {
        try {
          html = jsonDecode(raw) as String;
        } catch (_) {
          // Fall back to the raw string — still parsable HTML either way.
        }
      }

      // The WebView's OWN current url (already past any redirect) — not
      // widget.signInUrl/widget.browseUrl, which a short-link or the site's
      // own login redirect can leave stale. Same reasoning as ADR-053's
      // forms.gle bug fix.
      final currentUrl = await _controller.currentUrl() ?? widget.signInUrl ?? widget.browseUrl ?? widget.prefillUrl!;
      final parsed = await _apiClient.parseFormFromHtml(html, currentUrl);
      final fill = await _apiClient.fillForm(parsed.form);

      if (parsed.form.source == 'google_form') {
        await _applyGoogleFormFill(parsed, fill);
      } else {
        await _applySmartAiFill(parsed, fill, silent: silent);
      }
    } catch (e) {
      // Best-effort: the read/parse/fill succeeded far enough to try, or it
      // didn't — either way the user can still fill the real page by hand.
      if (mounted) {
        setState(() {
          _autofilling = false;
          _autofillError = e.toString();
        });
      }
    }
  }

  Future<void> _applyGoogleFormFill(ParsedForm parsed, FormFillResult fill) async {
    final prefillUrl = fill.prefillUrl;
    if (prefillUrl == null || fill.answers.isEmpty) {
      // Nothing Google can prefill (an empty form) — the WebView still shows
      // the real form either way, just not pre-typed. Not an error.
      if (mounted) setState(() { _autofilling = false; _hasRunSmartFill = true; });
      return;
    }
    _handoff = FormAutofillHandoff(parsed: parsed, answers: fill.answers, prefillUrl: prefillUrl, fillId: fill.fillId);
    final filled = fill.answers.where((a) => a.answer != null && a.answerText.trim().isNotEmpty).length;
    if (mounted) {
      setState(() {
        _filledCount = filled;
        _autofilling = false;
        _hasRunSmartFill = true;
        _suggestions = [];
      });
    }
    await _controller.loadRequest(Uri.parse(prefillUrl));
  }

  Future<void> _applySmartAiFill(ParsedForm parsed, FormFillResult fill, {required bool silent}) async {
    final questionsByEntry = {for (final q in parsed.form.questions) q.entryId: q};
    final injectable = <FormAnswer>[];
    final suggestions = <(FormQuestion, FormAnswer)>[];
    for (final answer in fill.answers) {
      if (answer.answer == null || answer.answerText.trim().isEmpty || !answer.guardrailPass) continue;
      final question = questionsByEntry[answer.entryId];
      if (question == null) continue;
      if (parsed.form.isDomExtracted && question.isInjectable) {
        injectable.add(answer);
      } else {
        suggestions.add((question, answer));
      }
    }

    if (injectable.isNotEmpty) {
      await _controller.runJavaScript(_buildInjectionJs(questionsByEntry, injectable));
    }

    // Fire-and-forget, same posture as the Google-Form path's PATCH before
    // opening the prefilled form — teaches future fills, never blocks this one.
    unawaited(_apiClient.updateFormFillAnswers(fill.fillId, fill.answers).catchError((_) {}));

    if (!mounted) return;
    setState(() {
      _filledCount = injectable.length;
      _autofilling = false;
      _hasRunSmartFill = true;
      _suggestions = suggestions;
    });
    if (injectable.isNotEmpty || suggestions.isNotEmpty) {
      _showSuggestionsSheet();
    } else if (!silent) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't find anything fillable on this page")),
      );
    }
  }

  /// Builds one self-contained JS injection for every [injectable] answer.
  /// `setNativeValue` uses the prototype's own value setter (not a plain
  /// `el.value =`) so React-controlled inputs — common on these ATS pages —
  /// actually register the change; each field is wrapped in its own
  /// try/catch so one renamed/missing selector can't abort the rest (a
  /// reskin degrades to "filled fewer fields", never a crash or a value
  /// landing in the wrong place). Never touches a submit/button element —
  /// only ever calls into the exact selector server/services/form_parser.py
  /// built for each field.
  String _buildInjectionJs(Map<String, FormQuestion> questionsByEntry, List<FormAnswer> injectable) {
    final buffer = StringBuffer()
      ..writeln('(function() {')
      ..writeln('function setNativeValue(el, value) {')
      ..writeln('  if (!el) return;')
      ..writeln('  var proto = Object.getPrototypeOf(el);')
      ..writeln('  var desc = Object.getOwnPropertyDescriptor(proto, "value");')
      ..writeln('  var setter = desc && desc.set;')
      ..writeln('  if (setter) { setter.call(el, value); } else { el.value = value; }')
      ..writeln('  el.dispatchEvent(new Event("input", { bubbles: true }));')
      ..writeln('  el.dispatchEvent(new Event("change", { bubbles: true }));')
      ..writeln('}');
    for (final answer in injectable) {
      final question = questionsByEntry[answer.entryId];
      if (question == null || question.domSelector.isEmpty) continue;
      final selectorJs = jsonEncode(question.domSelector);
      final valueJs = jsonEncode(answer.answerText);
      buffer.writeln('try { setNativeValue(document.querySelector($selectorJs), $valueJs); } catch (e) {}');
    }
    buffer.writeln('})();');
    return buffer.toString();
  }

  void _showSuggestionsSheet() {
    // Same shape as job_filter_sheet.dart's showJobFilterSheet — an explicit
    // backgroundColor is required here: without one, showModalBottomSheet
    // defaults to a transparent backdrop, which is why this used to render
    // as barely-legible text floating over the WebView page behind it.
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.c.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
      ),
      builder: (sheetContext) => _SuggestionsSheet(filledCount: _filledCount, suggestions: _suggestions),
    );
  }

  Future<void> _openExternally() async {
    final url = _handoff?.prefillUrl ?? widget.prefillUrl ?? widget.browseUrl ?? widget.signInUrl!;
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  /// The rarer actions stay behind the top-right overflow menu, so the
  /// WebView itself stays full-bleed: go back to the answer sheet, grab the
  /// résumé PDF to attach, reload, or escape to the real browser. The three
  /// common ones (Smart Apply, Tailor Résumé, Cover Letter) are the visible
  /// header icons below instead — see [_onSmartApplyTap] etc.
  void _onMenuSelected(_FormMenuAction action) {
    final jobId = widget.jobId;
    switch (action) {
      case _FormMenuAction.review:
        // The answer sheet is the route directly beneath this one and still
        // holds the editable rows — popping is the whole "review" action.
        // ADR-053: `_handoff` carries the sign-in flow's parsed/answers back
        // to that screen so it isn't left showing an empty sheet; it's null
        // (a no-op extra pop argument) on the ordinary already-prefilled path
        // and on the Smart AI Fill browse-mode path (no caller awaiting it).
        Navigator.of(context).maybePop(_handoff);
      case _FormMenuAction.resume:
        if (jobId != null) {
          context.push('/tailor/preview', extra: TailorArgs(jobId: jobId, jobTitle: widget.jobTitle ?? widget.formTitle));
        } else {
          context.push('/jd-resume');
        }
      case _FormMenuAction.reload:
        _controller.reload();
      case _FormMenuAction.openExternally:
        _openExternally();
    }
  }

  /// The three header-icon actions the first-visit guide points at. Each
  /// counts as "the user found it" — dismissing the guide (and persisting
  /// that) the same as tapping "Got it" would, so the pulse/card don't keep
  /// pestering someone who's already using the icons on their own.
  void _onSmartApplyTap() {
    unawaited(_dismissGuide());
    _runSmartAiFill();
  }

  void _onTailorResumeTap() {
    unawaited(_dismissGuide());
    final jobId = widget.jobId;
    if (jobId != null) {
      context.push('/tailor', extra: TailorArgs(jobId: jobId, jobTitle: widget.jobTitle ?? widget.formTitle));
    } else {
      // No JD came with the form yet — let the user paste/upload one first.
      context.push('/jd-resume');
    }
  }

  void _onCoverLetterTap() {
    unawaited(_dismissGuide());
    final jobId = widget.jobId;
    if (jobId != null) {
      context.push('/cover-letter', extra: CoverLetterArgs(jobId: jobId, jobTitle: widget.jobTitle ?? widget.formTitle));
    } else {
      // CoverLetterArgs needs a real jobId — nothing to draft against yet.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add the job description first — tap the résumé icon')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasJd = widget.jobId != null;
    return Scaffold(
      appBar: PageHeader(
        title: 'Apply',
        showBack: true,
        // A solid accent header, distinct from the rest of the app's neutral
        // ones — this screen hosts a real website below it, and a plain
        // surface-coloured bar used to blend right into "just part of the
        // page". context.onAccent (not a hardcoded white) keeps text/icon
        // contrast correct in both themes.
        backgroundColor: context.c.accent,
        foregroundColor: context.onAccent,
        actions: [
          _pulsingGuideIcon(
            HeaderActionButton(
              icon: AppIconName.autoAwesome,
              tooltip: 'Smart Apply — fill this page from your profile',
              onPressed: _onSmartApplyTap,
            ),
          ),
          _pulsingGuideIcon(
            HeaderActionButton(
              icon: AppIconName.fileText,
              tooltip: hasJd ? 'Tailor résumé for this JD' : 'Add the job description to tailor a résumé',
              onPressed: _onTailorResumeTap,
            ),
          ),
          _pulsingGuideIcon(
            HeaderActionButton(
              icon: AppIconName.mail,
              tooltip: hasJd ? 'Draft a cover letter for this JD' : 'Add the job description first',
              onPressed: _onCoverLetterTap,
            ),
          ),
          PopupMenuButton<_FormMenuAction>(
            tooltip: 'More',
            // Unlike HeaderActionButton, this icon paints no opaque badge of
            // its own — needs an explicit onAccent colour or it'd inherit
            // the ambient (dark) default and disappear against the blue bar.
            icon: AppIcon(AppIconName.moreVertical, size: 20, color: context.onAccent),
            onSelected: _onMenuSelected,
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: _FormMenuAction.review,
                child: Text('Review & edit answers'),
              ),
              PopupMenuItem(
                value: _FormMenuAction.resume,
                child: Text(hasJd ? 'Get my résumé PDF' : 'Build a résumé to attach'),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(value: _FormMenuAction.reload, child: Text('Reload form')),
              // An escape hatch — some sign-in flows behave better in the real
              // browser. Never a workaround for the honest constraints above.
              const PopupMenuItem(value: _FormMenuAction.openExternally, child: Text('Open in browser')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (_showBanner) _handoffBanner(),
          Expanded(
            child: Stack(
              children: [
                WebViewWidget(controller: _controller),
                // The page itself has finished loading by the time
                // autofilling starts (that's what triggers it) — a separate
                // flag from `_loading`, which only covers the WebView's own
                // page-load spinner.
                if (_loading || _autofilling) const Center(child: AppLoader()),
                if (_showGuide) _guideOverlay(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Scales the icon up/down while the first-visit guide is active — a
  /// no-op wrapper (returns [child] unchanged) once it's been dismissed, so
  /// there's no lingering animation cost on every later visit.
  Widget _pulsingGuideIcon(Widget child) {
    if (!_showGuide) return child;
    return ScaleTransition(
      scale: Tween<double>(begin: 1.0, end: 1.22).animate(CurvedAnimation(parent: _guideAnimController, curve: Curves.easeInOut)),
      child: child,
    );
  }

  /// The one-time explainer card, positioned under the header icons it's
  /// pointing at. A `CustomPaint` triangle stands in for a speech-bubble
  /// tail rather than pulling in a whole coach-mark package for one shape.
  Widget _guideOverlay() {
    return Positioned(
      top: 0,
      right: AppSpacing.space3,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
        builder: (context, t, child) => Opacity(
          opacity: t,
          child: Transform.translate(offset: Offset(0, (1 - t) * -12), child: child),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            CustomPaint(size: const Size(16, 8), painter: _UpTrianglePainter(context.c.ink)),
            Container(
              width: 240,
              padding: const EdgeInsets.all(AppSpacing.space3),
              decoration: BoxDecoration(
                color: context.c.ink,
                borderRadius: AppRadius.mdRadius,
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.2), blurRadius: 12, offset: const Offset(0, 4))],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _guideRow(AppIconName.autoAwesome, 'Smart Apply', 'fills this page from your profile'),
                  const SizedBox(height: 6),
                  _guideRow(AppIconName.fileText, 'Tailor Résumé', 'rewrites your résumé for this job'),
                  const SizedBox(height: 6),
                  _guideRow(AppIconName.mail, 'Cover Letter', 'drafts one for this job'),
                  const SizedBox(height: AppSpacing.space2),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => unawaited(_dismissGuide()),
                      style: TextButton.styleFrom(foregroundColor: context.c.paper, padding: EdgeInsets.zero),
                      child: const Text('Got it'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _guideRow(AppIconName icon, String title, String detail) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppIcon(icon, size: 15, color: context.c.paper),
        const SizedBox(width: 6),
        Expanded(
          child: RichText(
            text: TextSpan(
              style: AppTypography.caption.copyWith(color: context.c.paper),
              children: [
                TextSpan(text: '$title  ', style: const TextStyle(fontWeight: FontWeight.w700)),
                TextSpan(text: detail),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _handoffBanner() {
    // ADR-053: while the sign-in page is still up (or being followed
    // through Google's flow), lead with what's actually happening instead of
    // the "we prefilled" copy below, which isn't true yet.
    if (widget.signInUrl != null && !_autofillAttempted) {
      return _banner(
        background: context.c.accentSoft,
        foreground: context.c.accent,
        title: 'Sign in with your own Google account below',
        message: 'Once you land on the form, we\'ll read it and fill in what we can from your profile.',
      );
    }
    // Smart AI Fill browse mode, before the user has run it yet — the
    // instructive banner tells them what the ✨ header icon is for, since
    // there's nothing to review or report on until they tap it.
    if (widget.browseUrl != null && !_hasRunSmartFill) {
      return _banner(
        background: context.c.accentSoft,
        foreground: context.c.accent,
        title: 'Browse to the application form, then tap ✨ Smart Apply',
        message: 'Sign in and navigate to the real application page on this site — the ✨ icon above '
            'reads whatever page you\'re on and fills what it can from your profile.',
      );
    }
    if (_autofillError != null) {
      return _banner(
        background: context.c.warning.withValues(alpha: 0.12),
        foreground: context.c.warning,
        title: 'Couldn\'t auto-fill this one',
        message: 'You\'re signed in — go ahead and fill it in yourself right here.',
      );
    }

    final attach = widget.fileUploadLabels.isNotEmpty
        ? ' Attach manually: ${widget.fileUploadLabels.join(' · ')}.'
        : '';
    final suggestionsNote = _suggestions.isNotEmpty
        ? ' ${_suggestions.length} more field${_suggestions.length == 1 ? '' : 's'} need${_suggestions.length == 1 ? 's' : ''} your review — tap Smart AI Fill again to see them.'
        : '';
    return _banner(
      background: context.c.accentSoft,
      foreground: context.c.accent,
      title: _filledCount > 0
          ? 'We filled $_filledCount field${_filledCount == 1 ? '' : 's'} — check them, then submit yourself.'
          : 'Review the form, then submit yourself.',
      message: 'The agent fills, you review and tap the site\'s own Submit — nothing is ever submitted for you.'
          '$attach$suggestionsNote',
    );
  }

  Widget _banner({required Color background, required Color foreground, required String title, required String message}) {
    return Container(
      color: background,
      padding: const EdgeInsets.fromLTRB(AppSpacing.screenPadX, AppSpacing.space3, AppSpacing.space2, AppSpacing.space3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppTypography.bodySm.copyWith(fontWeight: FontWeight.w700, color: foreground)),
                const SizedBox(height: 2),
                Text(message, style: AppTypography.caption.copyWith(color: foreground)),
              ],
            ),
          ),
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: () => setState(() => _showBanner = false),
            icon: AppIcon(AppIconName.x, size: 16, color: foreground),
          ),
        ],
      ),
    );
  }
}

/// Smart AI Fill: fields that were answered from the profile but couldn't be
/// safely written into the page (a dropdown/skills-picker/anything without a
/// real DOM selector, or an llm_extracted page with none at all) — tap a row
/// to copy its answer, then paste it into the real field yourself.
class _SuggestionsSheet extends StatelessWidget {
  const _SuggestionsSheet({required this.filledCount, required this.suggestions});

  final int filledCount;
  final List<(FormQuestion, FormAnswer)> suggestions;

  @override
  Widget build(BuildContext context) {
    // Bounded so a long suggestion list scrolls WITHIN the sheet instead of
    // pushing past the top of the screen — isScrollControlled alone gives an
    // unbounded height budget, not a sane one.
    final maxHeight = MediaQuery.sizeOf(context).height * 0.85;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.space4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: AppSpacing.space3),
                  decoration: BoxDecoration(color: context.c.border, borderRadius: BorderRadius.circular(2)),
                ),
              ),
              Text(
                filledCount > 0 ? 'Filled $filledCount field${filledCount == 1 ? '' : 's'} directly' : 'Nothing filled directly',
                style: AppTypography.title.copyWith(fontSize: 16, color: context.c.ink),
              ),
              if (suggestions.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.space2),
                Text(
                  'These need your review — tap to copy, then paste into the field on the page.',
                  style: AppTypography.bodySm.copyWith(color: context.c.inkSoft),
                ),
                const SizedBox(height: AppSpacing.space3),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: suggestions.length,
                    separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.space2),
                    itemBuilder: (context, index) {
                      final (question, answer) = suggestions[index];
                      return _suggestionRow(context, question, answer);
                    },
                  ),
                ),
              ] else if (filledCount == 0) ...[
                const SizedBox(height: AppSpacing.space2),
                Text(
                  "Couldn't find anything fillable on this page.",
                  style: AppTypography.bodySm.copyWith(color: context.c.inkSoft),
                ),
              ],
              const SizedBox(height: AppSpacing.space2),
            ],
          ),
        ),
      ),
    );
  }

  Widget _suggestionRow(BuildContext context, FormQuestion question, FormAnswer answer) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.space3),
      decoration: BoxDecoration(
        color: context.c.surface2,
        border: Border.all(color: context.c.border),
        borderRadius: AppRadius.mdRadius,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  question.text,
                  style: AppTypography.bodySm.copyWith(fontWeight: FontWeight.w700, color: context.c.ink),
                ),
                const SizedBox(height: 2),
                Text(answer.answerText, style: AppTypography.bodySm.copyWith(color: context.c.inkSoft)),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Copy',
            icon: AppIcon(AppIconName.fileText, size: 18, color: context.c.accent),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: answer.answerText));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
            },
          ),
        ],
      ),
    );
  }
}

/// The first-visit guide card's speech-bubble tail — a plain filled
/// triangle pointing up at the header icons, not worth a whole package.
class _UpTrianglePainter extends CustomPainter {
  const _UpTrianglePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(size.width * 0.5, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_UpTrianglePainter old) => old.color != color;
}
