import 'package:flutter/material.dart';

import '../models/resume_profile.dart';
import '../services/api_client.dart';
import '../services/haptic_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_metrics.dart';
import '../widgets/app_banner.dart';
import '../widgets/app_form_field.dart';
import '../widgets/app_loader.dart';
import '../widgets/empty_state.dart';
import '../widgets/app_icon.dart';
import '../widgets/page_header.dart';

/// Migration 026: the contact block printed at the top of every compiled
/// résumé PDF — phone, email, LinkedIn, GitHub, personal site, and city.
///
/// The résumé parser pre-fills whatever was printed on the uploaded file
/// (services/llm.py PARSE_SYSTEM_PROMPT), so this screen is usually a
/// *confirm-and-correct* step rather than blank data entry. Every field is
/// optional: a blank one is simply left off the PDF, never rendered as an empty
/// label. Clearing a field submits `''` (not null) so the server can tell
/// "remove this" apart from "leave it alone" — see
/// ApiClient.updateContactDetails.
class ContactDetailsScreen extends StatefulWidget {
  const ContactDetailsScreen({super.key});

  @override
  State<ContactDetailsScreen> createState() => _ContactDetailsScreenState();
}

class _ContactDetailsScreenState extends State<ContactDetailsScreen> {
  final ApiClient _apiClient = ApiClient();

  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _locationController = TextEditingController();
  final _linkedinController = TextEditingController();
  final _githubController = TextEditingController();
  final _websiteController = TextEditingController();

  bool _isLoading = true;
  bool _isSaving = false;
  String? _errorMessage;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _emailController.dispose();
    _phoneController.dispose();
    _locationController.dispose();
    _linkedinController.dispose();
    _githubController.dispose();
    _websiteController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    try {
      final profile = await _apiClient.fetchCurrentProfile();
      if (!mounted) return;
      setState(() {
        _fill(profile);
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e.toString();
        _isLoading = false;
      });
    }
  }

  void _fill(ResumeProfile? profile) {
    _emailController.text = profile?.email ?? '';
    _phoneController.text = profile?.phone ?? '';
    _locationController.text = profile?.location ?? '';
    _linkedinController.text = profile?.linkedinUrl ?? '';
    _githubController.text = profile?.githubUrl ?? '';
    _websiteController.text = profile?.websiteUrl ?? '';
  }

  Future<void> _save() async {
    HapticService.instance.light();
    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });
    try {
      await _apiClient.updateContactDetails(
        email: _emailController.text,
        phone: _phoneController.text,
        location: _locationController.text,
        linkedinUrl: _linkedinController.text,
        githubUrl: _githubController.text,
        websiteUrl: _websiteController.text,
      );
      if (!mounted) return;
      setState(() => _isSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Contact details saved — they’ll appear on your next résumé.')),
      );
      Navigator.of(context).maybePop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _errorMessage = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const PageHeader(title: 'Contact details', showBack: true),
      body: SafeArea(top: false, child: _body()),
    );
  }

  Widget _body() {
    if (_isLoading) return const Center(child: AppLoader());

    if (_loadError != null) {
      return ListView(
        children: [
          EmptyState(
            icon: AppIconName.alertTriangle,
            title: 'Could not load your details',
            message: _loadError,
            actionLabel: 'Retry',
            onAction: _load,
          ),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.screenPadX),
      children: [
        Text(
          'These go at the top of every résumé the agent builds for you, so a '
          'recruiter can reach you from the first line. Leave anything you don’t '
          'have blank — it’s left off the page rather than shown empty.',
          style: AppTypography.bodySm.copyWith(color: context.c.inkSoft),
        ),
        const SizedBox(height: AppSpacing.space5),
        AppFormField(
          label: 'Email',
          controller: _emailController,
          placeholder: 'you@gmail.com',
          keyboardType: TextInputType.emailAddress,
        ),
        const SizedBox(height: AppSpacing.space3),
        AppFormField(
          label: 'Phone',
          controller: _phoneController,
          placeholder: '+91 98765 43210',
          keyboardType: TextInputType.phone,
        ),
        const SizedBox(height: AppSpacing.space3),
        AppFormField(
          label: 'Location',
          controller: _locationController,
          placeholder: 'Bengaluru, India',
        ),
        const SizedBox(height: AppSpacing.space5),
        Text('LINKS', style: AppTypography.label.copyWith(color: context.c.inkFaint)),
        const SizedBox(height: AppSpacing.space2),
        AppFormField(
          label: 'LinkedIn',
          controller: _linkedinController,
          placeholder: 'linkedin.com/in/your-handle',
          keyboardType: TextInputType.url,
        ),
        const SizedBox(height: AppSpacing.space3),
        AppFormField(
          label: 'GitHub',
          controller: _githubController,
          placeholder: 'github.com/your-handle',
          keyboardType: TextInputType.url,
        ),
        const SizedBox(height: AppSpacing.space3),
        AppFormField(
          label: 'Personal website',
          controller: _websiteController,
          placeholder: 'your-site.dev',
          keyboardType: TextInputType.url,
        ),
        if (_errorMessage != null) ...[
          const SizedBox(height: AppSpacing.space3),
          AppBanner(
            tone: BannerTone.critical,
            title: 'Could not save',
            message: _errorMessage,
            actionLabel: 'Retry',
            onAction: _save,
          ),
        ],
        const SizedBox(height: AppSpacing.space5),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _isSaving ? null : _save,
            child: Text(_isSaving ? 'Saving…' : 'Save contact details'),
          ),
        ),
      ],
    );
  }
}
