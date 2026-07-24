import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../theme/app_colors.dart';
import '../theme/app_metrics.dart';
import '../widgets/app_icon.dart';
import '../widgets/page_header.dart';

/// §4.8 in-app WebView. Loads Google's OWN prefilled-form URL (the published
/// `usp=pp_url` prefill mechanism) so the fields arrive already filled and the
/// user reviews + submits without leaving the app.
///
/// Two hard constraints, both honoured here:
///  - **No DOM injection.** We only ever load the prefill URL. We never inject
///    JavaScript to fill or submit — that breaks on every Google reskin and is
///    a worse posture than the published mechanism.
///  - **Honest copy.** Google Forms can't prefill a file-upload question, and
///    file-upload requires the respondent to be signed into Google. The banner
///    says plainly: we filled the text fields, YOU attach the résumé PDF and
///    tap Submit. The agent never submits anything (golden rule).
class FormWebViewScreen extends StatefulWidget {
  const FormWebViewScreen({
    super.key,
    required this.prefillUrl,
    required this.formTitle,
    this.filledCount = 0,
    this.fileUploadLabels = const [],
  });

  final String prefillUrl;
  final String formTitle;
  final int filledCount;
  final List<String> fileUploadLabels;

  @override
  State<FormWebViewScreen> createState() => _FormWebViewScreenState();
}

class _FormWebViewScreenState extends State<FormWebViewScreen> {
  late final WebViewController _controller;
  bool _loading = true;
  bool _showBanner = true;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted) // Google Forms needs JS to render — but we never RUN our own.
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (mounted) setState(() => _loading = true);
          },
          onPageFinished: (_) {
            if (mounted) setState(() => _loading = false);
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.prefillUrl));
  }

  Future<void> _openExternally() async {
    await launchUrl(Uri.parse(widget.prefillUrl), mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: PageHeader(
        title: 'Apply',
        showBack: true,
        // An escape hatch — some sign-in flows behave better in the real
        // browser. Never a workaround for the honest constraints above.
        actions: [
          IconButton(
            tooltip: 'Open in browser',
            onPressed: _openExternally,
            icon: const AppIcon(AppIconName.externalLink, size: 20),
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
                if (_loading) const Center(child: CircularProgressIndicator()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _handoffBanner() {
    final attach = widget.fileUploadLabels.isNotEmpty
        ? ' Attach manually: ${widget.fileUploadLabels.join(' · ')}.'
        : '';
    return Container(
      color: context.c.accentSoft,
      padding: const EdgeInsets.fromLTRB(AppSpacing.screenPadX, AppSpacing.space3, AppSpacing.space2, AppSpacing.space3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.filledCount > 0
                      ? 'We prefilled ${widget.filledCount} field${widget.filledCount == 1 ? '' : 's'} — check them, then submit yourself.'
                      : 'Review the form, then submit yourself.',
                  style: AppTypography.bodySm.copyWith(fontWeight: FontWeight.w700, color: context.c.accent),
                ),
                const SizedBox(height: 2),
                Text(
                  'Google won’t let us attach files or tap Submit. You attach your résumé PDF and submit — '
                  'the agent never submits anything for you.$attach',
                  style: AppTypography.caption.copyWith(color: context.c.accent),
                ),
              ],
            ),
          ),
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: () => setState(() => _showBanner = false),
            icon: AppIcon(AppIconName.x, size: 16, color: context.c.accent),
          ),
        ],
      ),
    );
  }
}
