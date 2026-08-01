import 'dart:async' show unawaited;
import 'dart:convert' show jsonDecode;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

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
/// Two hard constraints, both honoured here:
///  - **No DOM injection to FILL a form.** The fields themselves are always
///    populated via Google's own prefill URL, never by us writing into the
///    page — that breaks on every Google reskin and is a worse posture than
///    the published mechanism. ADR-053's sign-in flow (below) is the one
///    exception to "we never run our own JS" and even that only ever READS
///    the page once (`document.documentElement.outerHTML`) — it does not
///    inject values or trigger a submit.
///  - **Honest copy.** Google Forms can't prefill a file-upload question, and
///    file-upload requires the respondent to be signed into Google. The banner
///    says plainly: we filled the text fields, YOU attach the résumé PDF and
///    tap Submit. The agent never submits anything (golden rule).
///
/// ADR-053: when [FormWebViewArgs.signInUrl] is set instead of [prefillUrl]
/// (the form needs Google sign-in to even view), this screen loads that
/// plain URL first. The user signs into their own Google account right here
/// — we never see the credentials, same as the external-browser fallback
/// used to guarantee. Once the WebView lands somewhere that isn't Google's
/// own sign-in page, that's treated as "the real form loaded": the page's
/// HTML is read ONCE, sent to POST /forms/parse-html (the exact same
/// deterministic parser /forms/parse already uses), mapped onto the
/// profile via the existing /forms/fill, and the WebView navigates itself to
/// the resulting prefill URL — arriving at the same "already filled, review
/// and submit" state the public-form path reaches directly.
/// The top-right overflow ("⋮") actions available while the form is open.
enum _FormMenuAction { review, jobDescription, resume, reload, openExternally }

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
  }) : assert(prefillUrl != null || signInUrl != null, 'need a URL to load');

  final String? prefillUrl;
  final String formTitle;
  final int filledCount;
  final List<String> fileUploadLabels;

  /// Set when the form's description was long enough to be a job description
  /// and the server captured it as a job row (POST /forms/parse). Non-null
  /// turns the overflow menu's JD entries into "tailor for THIS job".
  final String? jobId;
  final String? jobTitle;

  /// ADR-053: see the class doc above. Mutually exclusive with [prefillUrl].
  final String? signInUrl;

  @override
  State<FormWebViewScreen> createState() => _FormWebViewScreenState();
}

class _FormWebViewScreenState extends State<FormWebViewScreen> {
  final ApiClient _apiClient = ApiClient();
  late final WebViewController _controller;
  bool _loading = true;
  bool _showBanner = true;

  // ADR-053 sign-in flow state — stays at these defaults for the ordinary
  // already-prefilled path (widget.signInUrl == null).
  bool _autofillAttempted = false;
  late bool _autofilling = widget.signInUrl != null;
  String? _autofillError;
  late int _filledCount = widget.filledCount;
  FormAutofillHandoff? _handoff;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      // Google Forms needs JS to render regardless. The sign-in path additionally
      // uses it for ONE read of the loaded page — see the class doc.
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
      ..loadRequest(Uri.parse(widget.signInUrl ?? widget.prefillUrl!));
  }

  /// ADR-053: fires on every page load while [widget.signInUrl] is set.
  /// No-ops once already attempted, or while the WebView is still somewhere
  /// under Google's own sign-in flow — the same two markers the server side
  /// (`services/form_parser.py`) already checks for a redirect-based gate.
  Future<void> _maybeAutofillAfterSignIn(String url) async {
    if (widget.signInUrl == null || _autofillAttempted) return;
    if (url.contains('accounts.google.com') || url.contains('ServiceLogin')) return; // still signing in
    _autofillAttempted = true;
    try {
      // A ONE-TIME read of the page the user is already looking at — not an
      // injection, not a fill, not a submit. Platform WebViews return this as
      // a JSON-quoted string (Android/iOS both), hence the unwrap below.
      final raw = (await _controller.runJavaScriptReturningResult('document.documentElement.outerHTML')).toString();
      String html = raw;
      if (raw.startsWith('"')) {
        try {
          html = jsonDecode(raw) as String;
        } catch (_) {
          // Fall back to the raw string — still parsable HTML either way.
        }
      }

      // ADR-053 bug fix: use `url` (where the WebView actually ended up —
      // already past any forms.gle short-link redirect) as the form_url, NOT
      // widget.signInUrl. A forms.gle short link's own redirect is a static
      // mapping that DROPS any query string appended to it, so a prefill URL
      // built on top of the short link would lose every entry.* param the
      // instant Google redirects it — landing on the real form completely
      // unfilled despite a successful parse+fill. `url` here is already the
      // resolved docs.google.com/forms/.../viewform address, which does not
      // have that problem.
      final parsed = await _apiClient.parseFormFromHtml(html, url);
      final fill = await _apiClient.fillForm(parsed.form);
      final prefillUrl = fill.prefillUrl;
      if (prefillUrl == null || fill.answers.isEmpty || parsed.form.isLlmExtracted) {
        // Nothing Google can prefill (a non-Google page, or an empty form) —
        // the signed-in WebView still shows the real form either way, just
        // not pre-typed. Not an error worth alarming over.
        if (mounted) setState(() => _autofilling = false);
        return;
      }

      _handoff = FormAutofillHandoff(parsed: parsed, answers: fill.answers, prefillUrl: prefillUrl, fillId: fill.fillId);
      final filled = fill.answers.where((a) => a.answer != null && a.answerText.trim().isNotEmpty).length;
      if (mounted) {
        setState(() {
          _filledCount = filled;
          _autofilling = false;
        });
      }
      await _controller.loadRequest(Uri.parse(prefillUrl));
    } catch (e) {
      // Best-effort: sign-in succeeded, autofill didn't — the user can still
      // fill the (real, signed-in) form by hand right here, same as the old
      // external-browser fallback, just without leaving the app.
      if (mounted) {
        setState(() {
          _autofilling = false;
          _autofillError = e.toString();
        });
      }
    }
  }

  Future<void> _openExternally() async {
    final url = _handoff?.prefillUrl ?? widget.prefillUrl ?? widget.signInUrl!;
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  /// Everything the user might need *while the form is open* lives behind the
  /// top-right overflow menu, so the WebView itself stays full-bleed: go back
  /// to the answer sheet, deal with the job description, grab the résumé PDF
  /// to attach, reload, or escape to the real browser.
  void _onMenuSelected(_FormMenuAction action) {
    final jobId = widget.jobId;
    switch (action) {
      case _FormMenuAction.review:
        // The answer sheet is the route directly beneath this one and still
        // holds the editable rows — popping is the whole "review" action.
        // ADR-053: `_handoff` carries the sign-in flow's parsed/answers back
        // to that screen so it isn't left showing an empty sheet; it's null
        // (a no-op extra pop argument) on the ordinary already-prefilled path.
        Navigator.of(context).maybePop(_handoff);
      case _FormMenuAction.jobDescription:
        if (jobId != null) {
          context.push('/tailor', extra: TailorArgs(jobId: jobId, jobTitle: widget.jobTitle ?? widget.formTitle));
        } else {
          // No JD came with the form — let the user paste/upload one.
          context.push('/jd-resume');
        }
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

  @override
  Widget build(BuildContext context) {
    final hasJd = widget.jobId != null;
    return Scaffold(
      appBar: PageHeader(
        title: 'Apply',
        showBack: true,
        actions: [
          PopupMenuButton<_FormMenuAction>(
            tooltip: 'More',
            icon: const AppIcon(AppIconName.moreVertical, size: 20),
            onSelected: _onMenuSelected,
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: _FormMenuAction.review,
                child: Text('Review & edit answers'),
              ),
              PopupMenuItem(
                value: _FormMenuAction.jobDescription,
                child: Text(hasJd ? 'Tailor résumé for this JD' : 'Add the job description'),
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
                // ADR-053: the page itself has finished loading by the time
                // autofilling starts (that's what triggers it) — a separate
                // flag from `_loading`, which only covers the WebView's own
                // page-load spinner.
                if (_loading || _autofilling) const Center(child: AppLoader()),
              ],
            ),
          ),
        ],
      ),
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
    return _banner(
      background: context.c.accentSoft,
      foreground: context.c.accent,
      title: _filledCount > 0
          ? 'We prefilled $_filledCount field${_filledCount == 1 ? '' : 's'} — check them, then submit yourself.'
          : 'Review the form, then submit yourself.',
      message: 'Google won’t let us attach files or tap Submit. You attach your résumé PDF and submit — '
          'the agent never submits anything for you.$attach',
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
