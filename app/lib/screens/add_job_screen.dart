import 'package:flutter/material.dart';

import '../models/job_extraction.dart';
import '../services/api_client.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_banner.dart';
import '../widgets/app_form_field.dart';
import '../widgets/page_header.dart';

/// "Add application manually" (frontend rebuild Phase 2, prototype
/// `ui.isAddJob`) — paste a posting URL, let Gemini extract fields
/// server-side, review/edit, then add it to the shared job pool. Two
/// explicit steps (parse, then create) rather than one combined action,
/// so nothing lands in the pool without the user seeing what was
/// extracted first.
class AddJobScreen extends StatefulWidget {
  const AddJobScreen({super.key});

  @override
  State<AddJobScreen> createState() => _AddJobScreenState();
}

class _AddJobScreenState extends State<AddJobScreen> {
  final ApiClient _apiClient = ApiClient();
  final _urlController = TextEditingController();
  late final _titleController = TextEditingController();
  late final _companyController = TextEditingController();
  late final _locationController = TextEditingController();
  late final _salaryMinController = TextEditingController();
  late final _salaryMaxController = TextEditingController();

  bool _isParsing = false;
  bool _isSubmitting = false;
  String? _errorMessage;
  JobExtraction? _extraction;

  @override
  void dispose() {
    _urlController.dispose();
    _titleController.dispose();
    _companyController.dispose();
    _locationController.dispose();
    _salaryMinController.dispose();
    _salaryMaxController.dispose();
    super.dispose();
  }

  Future<void> _parse() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;
    setState(() {
      _isParsing = true;
      _errorMessage = null;
    });
    try {
      final extraction = await _apiClient.parseManualJobUrl(url);
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

  Future<void> _submit() async {
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
      await _apiClient.createManualJob(edited, _urlController.text.trim());
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      setState(() => _errorMessage = e.toString());
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const PageHeader(title: 'Add application manually', showBack: true),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.screenPadX),
        children: [
          Text(
            "Paste a job posting link — we'll pull in the details.",
            style: AppTypography.bodySm.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.space4),
          AppFormField(
            label: 'Posting link',
            controller: _urlController,
            placeholder: 'https://…',
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: AppSpacing.space3),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _isParsing ? null : _parse,
              child: Text(_isParsing ? 'Parsing…' : (_extraction == null ? 'Parse link' : 'Re-parse link')),
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
              title: 'Auto-filled from the link',
              message: 'Review before adding — nothing has been saved yet.',
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
                onPressed: _isSubmitting || _titleController.text.trim().isEmpty ? null : _submit,
                child: Text(_isSubmitting ? 'Adding…' : 'Add to Jobs'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
