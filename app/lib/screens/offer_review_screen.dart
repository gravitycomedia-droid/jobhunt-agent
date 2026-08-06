import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../models/offer_review.dart';
import '../services/api_client.dart';
import '../theme/app_colors.dart';
import '../theme/app_metrics.dart';
import '../widgets/app_banner.dart';
import '../widgets/app_form_field.dart';
import '../widgets/app_icon.dart';
import '../widgets/app_loader.dart';
import '../widgets/page_header.dart';

/// Career-ops integration Brick 5 (docs/21-career-ops-integration-plan.md
/// §1.3, DECISIONS.md ADR-059): paste an offer letter/contract, get back a
/// clause-by-clause plain-English read. Deliberately narrow: this screen
/// NEVER renders a verdict, a risk score, or a "safe to sign" — the schema
/// (models/offer_review.dart) has nowhere to put one, and neither does
/// this UI. `grounded: false` on a clause is shown as a caution, not
/// hidden — see services/offer_review.py::verify_clause_grounding.
class OfferReviewScreen extends StatefulWidget {
  const OfferReviewScreen({super.key, required this.applicationId, required this.jobTitle});

  final String applicationId;
  final String jobTitle;

  @override
  State<OfferReviewScreen> createState() => _OfferReviewScreenState();
}

class _OfferReviewScreenState extends State<OfferReviewScreen> {
  final ApiClient _apiClient = ApiClient();
  final _rawTextController = TextEditingController();

  bool _isLoading = true;
  bool _isAnalyzing = false;
  String? _loadError;
  String? _analyzeError;
  List<OfferReview> _reviews = [];
  bool _showPasteForm = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _rawTextController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    try {
      final reviews = await _apiClient.listOfferReviews(widget.applicationId);
      if (!mounted) return;
      setState(() {
        _reviews = reviews;
        _isLoading = false;
        _showPasteForm = reviews.isEmpty;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _analyze() async {
    final text = _rawTextController.text.trim();
    if (text.isEmpty) {
      setState(() => _analyzeError = 'Paste the offer letter or contract text first.');
      return;
    }
    setState(() {
      _isAnalyzing = true;
      _analyzeError = null;
    });
    try {
      final review = await _apiClient.analyzeOffer(widget.applicationId, text);
      if (!mounted) return;
      setState(() {
        _reviews = [review, ..._reviews];
        _showPasteForm = false;
        _rawTextController.clear();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _analyzeError = e.toString());
    } finally {
      if (mounted) setState(() => _isAnalyzing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: PageHeader(title: 'Offer review', showBack: true),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) return const Center(child: AppLoader());

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.screenPadX),
      children: [
        const AppBanner(
          tone: BannerTone.warning,
          title: 'Not legal advice',
          message: 'This reads what the document says in plain English. It never judges whether it\'s a good deal, and never states what your local law requires — those questions go to a lawyer, listed below.',
        ),
        const SizedBox(height: AppSpacing.space3),
        if (_loadError != null) ...[
          Text(_loadError!, style: AppTypography.bodySm.copyWith(color: context.c.critical)),
          const SizedBox(height: AppSpacing.space3),
        ],
        if (_showPasteForm) _pasteForm() else _latestReview(),
        if (_reviews.length > 1) ...[
          const SizedBox(height: AppSpacing.space4),
          _previousReadsSection(),
        ],
      ],
    );
  }

  Widget _pasteForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppFormField(
          label: 'Offer letter / contract text',
          controller: _rawTextController,
          multiline: true,
          rows: 10,
          placeholder: 'Paste the full text of the offer letter or contract here…',
        ),
        if (_analyzeError != null) ...[
          const SizedBox(height: AppSpacing.space2),
          Text(_analyzeError!, style: AppTypography.bodySm.copyWith(color: context.c.critical)),
        ],
        const SizedBox(height: AppSpacing.space3),
        ElevatedButton(
          onPressed: _isAnalyzing ? null : _analyze,
          child: Text(_isAnalyzing ? 'Reading…' : 'Read this offer'),
        ),
      ],
    );
  }

  Widget _latestReview() {
    final review = _reviews.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${review.clauses.length} clause${review.clauses.length == 1 ? '' : 's'} found', style: AppTypography.headingSm),
        const SizedBox(height: AppSpacing.space3),
        for (var i = 0; i < review.clauses.length; i++) ...[
          if (i > 0) const SizedBox(height: AppSpacing.space2),
          _clauseCard(review.clauses[i]),
        ],
        if (review.questionsForLawyer.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.space4),
          Text('QUESTIONS FOR A LAWYER', style: AppTypography.label.copyWith(color: context.c.inkFaint)),
          const SizedBox(height: AppSpacing.space2),
          Container(
            padding: const EdgeInsets.all(AppSpacing.space3),
            decoration: BoxDecoration(
              color: context.c.surface,
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(color: context.c.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final q in review.questionsForLawyer)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text('•  $q', style: AppTypography.bodySm),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.space4),
        Align(
          alignment: Alignment.center,
          child: TextButton(
            onPressed: () => setState(() => _showPasteForm = true),
            child: const Text('Read another version'),
          ),
        ),
      ],
    );
  }

  Widget _clauseCard(OfferClause clause) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.space3),
      decoration: BoxDecoration(
        color: context.c.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: clause.grounded ? context.c.border : context.c.warning.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  clause.category.replaceAll('_', ' ').toUpperCase(),
                  style: AppTypography.caption.copyWith(color: context.c.info, fontWeight: FontWeight.w700),
                ),
              ),
              if (!clause.grounded)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: context.c.warning.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    border: Border.all(color: context.c.warning.withValues(alpha: 0.4)),
                  ),
                  child: Text(
                    'Verify against the document',
                    style: AppTypography.caption.copyWith(color: context.c.warning, fontWeight: FontWeight.w600),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(clause.plainEnglish, style: AppTypography.body),
          const SizedBox(height: 6),
          InkWell(
            onTap: () {
              Clipboard.setData(ClipboardData(text: clause.clauseText));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Clause text copied')));
            },
            child: Text(
              '"${clause.clauseText}"',
              style: AppTypography.caption.copyWith(color: context.c.inkFaint, fontStyle: FontStyle.italic),
            ),
          ),
        ],
      ),
    );
  }

  Widget _previousReadsSection() {
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text('Previous reads (${_reviews.length - 1})', style: AppTypography.bodySm.copyWith(fontWeight: FontWeight.w600)),
      children: [
        for (final review in _reviews.skip(1))
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const AppIcon(AppIconName.assignment, size: 18),
            title: Text('${review.clauses.length} clauses', style: AppTypography.bodySm),
            subtitle: Text(review.createdAt.toLocal().toString().split('.').first, style: AppTypography.caption),
          ),
      ],
    );
  }
}
