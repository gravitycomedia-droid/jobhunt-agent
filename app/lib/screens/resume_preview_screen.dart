import 'package:flutter/material.dart';

import '../models/resume_profile.dart';
import '../models/tailored_resume.dart';
import '../services/api_client.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_banner.dart';
import '../widgets/app_icon.dart';
import '../widgets/empty_state.dart';
import '../widgets/loading_skeleton.dart';
import '../widgets/page_header.dart';

/// The compiled tailored-resume preview (frontend rebuild Phase 2,
/// prototype `ui.isResumePreview`) — profile header + the final bullet
/// text per the diff screen's accept/reject choices (`accepted ?
/// tailored : original`). "Submit application" is the human approval
/// gate's actual endpoint: it saves the job to the Kanban tracker linked
/// to this tailored resume (Brick 7's existing infra) — nothing was ever
/// auto-submitted anywhere upstream (golden rule).
class ResumePreviewScreen extends StatefulWidget {
  const ResumePreviewScreen({super.key, required this.jobId, required this.jobTitle});

  final String jobId;
  final String jobTitle;

  @override
  State<ResumePreviewScreen> createState() => _ResumePreviewScreenState();
}

class _ResumePreviewScreenState extends State<ResumePreviewScreen> {
  final ApiClient _apiClient = ApiClient();

  bool _isLoading = true;
  bool _isSubmitting = false;
  bool _submitted = false;
  String? _errorMessage;
  ResumeProfile? _profile;
  TailoredResume? _resume;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final results = await Future.wait([_apiClient.fetchCurrentProfile(), _apiClient.fetchTailoredResume(widget.jobId)]);
      final profile = results[0] as ResumeProfile?;
      final resume = results[1] as TailoredResume?;
      if (profile == null || resume == null) {
        setState(() {
          _errorMessage = 'Could not find the tailored resume — go back and try again.';
          _isLoading = false;
        });
        return;
      }
      setState(() {
        _profile = profile;
        _resume = resume;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _submit() async {
    final resume = _resume;
    if (resume == null) return;
    setState(() => _isSubmitting = true);
    try {
      await _apiClient.saveToTracker(widget.jobId, resumeVersionId: resume.id);
      if (!mounted) return;
      setState(() {
        _isSubmitting = false;
        _submitted = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSubmitting = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const PageHeader(title: 'Resume preview', showBack: true),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return ListView.separated(
        padding: const EdgeInsets.all(AppSpacing.screenPadX),
        itemCount: 3,
        separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.space3),
        itemBuilder: (_, _) => const LoadingSkeleton(variant: SkeletonVariant.card),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: EmptyState(icon: AppIconName.alertTriangle, title: 'Could not load preview', message: _errorMessage),
      );
    }

    final profile = _profile!;
    final resume = _resume!;

    return Column(
      children: [
        if (_submitted)
          const Padding(
            padding: EdgeInsets.fromLTRB(AppSpacing.screenPadX, AppSpacing.space3, AppSpacing.screenPadX, 0),
            child: AppBanner(tone: BannerTone.success, title: 'Updated resume ready', message: 'Saved to your application tracker.'),
          ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.screenPadX),
            children: [
              Container(
                padding: const EdgeInsets.all(AppSpacing.space5),
                decoration: BoxDecoration(color: Colors.white, borderRadius: AppRadius.mdRadius, boxShadow: AppElevation.e2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(profile.name, style: AppTypography.title.copyWith(fontSize: 19, fontWeight: FontWeight.w800)),
                    if (profile.headline != null) ...[
                      const SizedBox(height: 2),
                      Text(profile.headline!, style: AppTypography.bodySm.copyWith(color: AppColors.textSecondary)),
                    ],
                    const Divider(height: AppSpacing.space5),
                    Text(
                      'TAILORED FOR ${widget.jobTitle.toUpperCase()}',
                      style: AppTypography.label.copyWith(color: AppColors.textTertiary),
                    ),
                    const SizedBox(height: AppSpacing.space3),
                    ...resume.bullets.map(
                      (b) => Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('•  ', style: TextStyle(fontSize: 13)),
                            Expanded(
                              child: Text(
                                (b.accepted ?? b.guardrailPass) ? b.tailored : b.original,
                                style: const TextStyle(fontSize: 12.5, height: 1.4, color: Color(0xFF2A2A36)),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (profile.skills.isNotEmpty) ...[
                      const Divider(height: AppSpacing.space5),
                      Text('SKILLS', style: AppTypography.label.copyWith(color: AppColors.textTertiary)),
                      const SizedBox(height: AppSpacing.space2),
                      Text(profile.skills.join(' · '), style: const TextStyle(fontSize: 12.5, height: 1.4)),
                    ],
                    if (profile.education.isNotEmpty) ...[
                      const Divider(height: AppSpacing.space5),
                      Text('EDUCATION', style: AppTypography.label.copyWith(color: AppColors.textTertiary)),
                      const SizedBox(height: AppSpacing.space2),
                      for (final ed in profile.education)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(child: Text('${ed.institution} — ${ed.degree}', style: const TextStyle(fontSize: 12.5))),
                              Text(
                                ed.year,
                                style: TextStyle(fontFamily: AppTypography.monoData.fontFamily, fontSize: 12, color: AppColors.textSecondary),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.screenPadX),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _submitted || _isSubmitting ? null : _submit,
                child: Text(_submitted ? 'In tracker' : (_isSubmitting ? 'Saving…' : 'Submit application')),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
