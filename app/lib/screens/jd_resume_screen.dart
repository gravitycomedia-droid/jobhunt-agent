import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../models/job_extraction.dart';
import '../router/route_args.dart';
import '../services/api_client.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_banner.dart';
import '../widgets/app_form_field.dart';
import '../widgets/app_icon.dart';
import '../widgets/page_header.dart';

/// Standalone from the matching pipeline (no live posting required):
/// paste a job description as text, or upload it as a PDF, review the
/// extracted fields, then generate a resume tailored to it — same
/// two-step parse-then-review shape as [AddJobScreen], and the same
/// tailoring/diff/download UI as any matched job ([ResumeDiffScreen]
/// doesn't know or care that this job didn't come from a live posting).
/// Runs on the server's cheaper GEMINI_MODEL_LITE tier end to end (ADR-017) —
/// than the rest of the app, since this is a convenience tool outside the
/// core matching/tailoring quality bar.
class JdResumeScreen extends StatefulWidget {
  const JdResumeScreen({super.key});

  @override
  State<JdResumeScreen> createState() => _JdResumeScreenState();
}

class _JdResumeScreenState extends State<JdResumeScreen> {
  final ApiClient _apiClient = ApiClient();
  final _jdTextController = TextEditingController();
  late final _titleController = TextEditingController();
  late final _companyController = TextEditingController();
  late final _locationController = TextEditingController();
  late final _salaryMinController = TextEditingController();
  late final _salaryMaxController = TextEditingController();

  bool _isParsing = false;
  bool _isSubmitting = false;
  String? _errorMessage;
  String? _pdfFilename;
  List<int>? _pdfBytes;
  JobExtraction? _extraction;

  @override
  void dispose() {
    _jdTextController.dispose();
    _titleController.dispose();
    _companyController.dispose();
    _locationController.dispose();
    _salaryMinController.dispose();
    _salaryMaxController.dispose();
    super.dispose();
  }

  Future<void> _pickPdf() async {
    final result = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['pdf'], withData: true);
    if (result == null) return;
    final bytes = result.files.single.bytes;
    if (bytes == null) {
      setState(() => _errorMessage = 'Could not read the selected file.');
      return;
    }
    setState(() {
      _pdfBytes = bytes;
      _pdfFilename = result.files.single.name;
      _jdTextController.clear();
    });
  }

  Future<void> _parse() async {
    final text = _jdTextController.text.trim();
    if (text.isEmpty && _pdfBytes == null) return;
    setState(() {
      _isParsing = true;
      _errorMessage = null;
    });
    try {
      final extraction = _pdfBytes != null
          ? await _apiClient.parseJd(pdfBytes: _pdfBytes, pdfFilename: _pdfFilename)
          : await _apiClient.parseJd(jdText: text);
      if (!mounted) return;
      setState(() {
        _extraction = extraction;
        _titleController.text = extraction.title;
        _companyController.text = extraction.company ?? '';
        _locationController.text = extraction.location ?? '';
        _salaryMinController.text = extraction.salaryMin?.round().toString() ?? '';
        _salaryMaxController.text = extraction.salaryMax?.round().toString() ?? '';
        _isParsing = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
        _isParsing = false;
      });
    }
  }

  Future<void> _generate() async {
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });
    final edited = JobExtraction(
      title: _titleController.text.trim(),
      company: _companyController.text.trim().isEmpty ? null : _companyController.text.trim(),
      location: _locationController.text.trim().isEmpty ? null : _locationController.text.trim(),
      description: _extraction?.description,
      salaryMin: double.tryParse(_salaryMinController.text.trim()),
      salaryMax: double.tryParse(_salaryMaxController.text.trim()),
    );
    try {
      final job = await _apiClient.createJdResumeJob(edited);
      if (!mounted) return;
      // Same screen that handles tailoring for any matched job — it kicks
      // off POST /tailor/{job_id} itself when no tailored resume exists yet.
      await context.push('/tailor', extra: TailorArgs(jobId: job.jobId, jobTitle: job.jobTitle));
    } catch (e) {
      setState(() => _errorMessage = e.toString());
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const PageHeader(title: 'Customize resume for a JD', showBack: true),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.screenPadX),
        children: [
          Text(
            'Paste a job description, or upload it as a PDF — get a resume tailored to it, ready to download.',
            style: AppTypography.bodySm.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.space4),
          if (_pdfBytes != null)
            Container(
              padding: const EdgeInsets.all(AppSpacing.space3),
              decoration: BoxDecoration(
                color: AppColors.brandSoft,
                border: Border.all(color: AppColors.brand500),
                borderRadius: AppRadius.mdRadius,
              ),
              child: Row(
                children: [
                  const AppIcon(AppIconName.fileText, size: 18, color: AppColors.brand600),
                  const SizedBox(width: AppSpacing.space2),
                  Expanded(child: Text(_pdfFilename ?? 'JD.pdf', style: AppTypography.bodySm)),
                  InkWell(
                    onTap: () => setState(() {
                      _pdfBytes = null;
                      _pdfFilename = null;
                    }),
                    child: const AppIcon(AppIconName.x, size: 16, color: AppColors.textTertiary),
                  ),
                ],
              ),
            )
          else ...[
            AppFormField(
              label: 'Job description',
              controller: _jdTextController,
              placeholder: 'Paste the JD text here…',
              multiline: true,
              rows: 8,
            ),
            const SizedBox(height: AppSpacing.space2),
            OutlinedButton.icon(
              onPressed: _pickPdf,
              icon: const AppIcon(AppIconName.upload, size: 16, color: AppColors.brand),
              label: const Text('Upload PDF instead'),
            ),
          ],
          const SizedBox(height: AppSpacing.space3),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _isParsing ? null : _parse,
              child: Text(_isParsing ? 'Reading…' : (_extraction == null ? 'Parse JD' : 'Re-parse JD')),
            ),
          ),
          if (_errorMessage != null) ...[
            const SizedBox(height: AppSpacing.space3),
            AppBanner(tone: BannerTone.critical, title: 'Something went wrong', message: _errorMessage),
          ],
          if (_extraction != null) ...[
            const SizedBox(height: AppSpacing.space5),
            const AppBanner(
              tone: BannerTone.info,
              title: 'Auto-filled from the JD',
              message: 'Review before generating — nothing has been tailored yet.',
            ),
            const SizedBox(height: AppSpacing.space3),
            AppFormField(label: 'Title', controller: _titleController, required: true),
            const SizedBox(height: AppSpacing.space3),
            AppFormField(label: 'Company', controller: _companyController),
            const SizedBox(height: AppSpacing.space3),
            AppFormField(label: 'Location', controller: _locationController),
            const SizedBox(height: AppSpacing.space3),
            Row(
              children: [
                Expanded(child: AppFormField(label: 'Min salary', controller: _salaryMinController, keyboardType: TextInputType.number)),
                const SizedBox(width: AppSpacing.space3),
                Expanded(child: AppFormField(label: 'Max salary', controller: _salaryMaxController, keyboardType: TextInputType.number)),
              ],
            ),
            const SizedBox(height: AppSpacing.space5),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isSubmitting || _titleController.text.trim().isEmpty ? null : _generate,
                child: Text(_isSubmitting ? 'Starting…' : 'Generate tailored resume'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
