import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../models/application_item.dart';
import '../services/api_client.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_form_field.dart';
import '../widgets/status_pill.dart';

/// The application detail screen (frontend rebuild Phase 2, prototype
/// `ui.isAppDetail`) — replaces the stage-picker bottom sheet
/// [ApplicationsBody] used to show. Adds two things the bottom sheet
/// never had room for: an editable Notes field (the `applications.notes`
/// column has existed since Brick 7 but had no UI until now) and an
/// on-demand "Draft a follow-up" button.
class AppDetailScreen extends StatefulWidget {
  const AppDetailScreen({super.key, required this.application, required this.onChanged});

  final ApplicationItem application;

  /// Called whenever this screen mutates the application (stage move,
  /// notes save, follow-up drafted) so the caller (ApplicationsBody) can
  /// update its list without a full reload.
  final ValueChanged<ApplicationItem> onChanged;

  @override
  State<AppDetailScreen> createState() => _AppDetailScreenState();
}

class _AppDetailScreenState extends State<AppDetailScreen> {
  final ApiClient _apiClient = ApiClient();
  late ApplicationItem _application = widget.application;
  late final _notesController = TextEditingController(text: _application.notes ?? '');
  late final _contactEmailController = TextEditingController(text: _application.contactEmail ?? '');

  bool _isMovingStage = false;
  bool _isSavingNotes = false;
  bool _isDraftingFollowup = false;
  bool _isSavingContactEmail = false;
  bool _isSendingFollowup = false;
  String? _errorMessage;

  @override
  void dispose() {
    _notesController.dispose();
    _contactEmailController.dispose();
    super.dispose();
  }

  void _update(ApplicationItem next) {
    setState(() => _application = next);
    widget.onChanged(next);
  }

  Future<void> _moveStage(String state) async {
    if (state == _application.state) return;
    setState(() => _isMovingStage = true);
    try {
      await _apiClient.updateApplicationState(_application.id, state);
      if (!mounted) return;
      _update(_application.copyWith(state: state));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not move card: $e')));
    } finally {
      if (mounted) setState(() => _isMovingStage = false);
    }
  }

  Future<void> _saveNotes() async {
    setState(() => _isSavingNotes = true);
    try {
      await _apiClient.updateApplicationNotes(_application.id, _notesController.text.trim());
      if (!mounted) return;
      _update(_application.copyWith(notes: _notesController.text.trim()));
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Notes saved')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save notes: $e')));
    } finally {
      if (mounted) setState(() => _isSavingNotes = false);
    }
  }

  Future<void> _draftFollowup() async {
    setState(() {
      _isDraftingFollowup = true;
      _errorMessage = null;
    });
    try {
      final (subject, body) = await _apiClient.draftFollowup(_application.id);
      if (!mounted) return;
      _update(_application.copyWith(followupSubject: subject, followupBody: body));
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.toString());
    } finally {
      if (mounted) setState(() => _isDraftingFollowup = false);
    }
  }

  Future<void> _saveContactEmail() async {
    setState(() => _isSavingContactEmail = true);
    try {
      await _apiClient.updateApplicationContactEmail(_application.id, _contactEmailController.text.trim());
      if (!mounted) return;
      _update(_application.copyWith(contactEmail: _contactEmailController.text.trim()));
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Contact email saved')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save contact email: $e')));
    } finally {
      if (mounted) setState(() => _isSavingContactEmail = false);
    }
  }

  Future<void> _sendFollowup() async {
    setState(() {
      _isSendingFollowup = true;
      _errorMessage = null;
    });
    try {
      await _apiClient.sendFollowup(_application.id);
      if (!mounted) return;
      _update(_application.copyWith(followupSentAt: DateTime.now()));
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.toString());
    } finally {
      if (mounted) setState(() => _isSendingFollowup = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final job = _application.job;
    return Scaffold(
      appBar: AppBar(title: const Text('Application')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.screenPadX),
        children: [
          Text(job.title, style: AppTypography.title),
          Text(job.company ?? 'Unknown company', style: AppTypography.bodySm.copyWith(color: AppColors.textSecondary)),
          const SizedBox(height: AppSpacing.space4),
          Row(
            children: [
              Text('Current stage', style: AppTypography.caption.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(width: AppSpacing.space2),
              StatusPill(context: PillContext.stage, value: _application.state, size: PillSize.sm),
              if (_isMovingStage) ...[
                const SizedBox(width: AppSpacing.space2),
                const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            ],
          ),
          const SizedBox(height: AppSpacing.space4),
          Text('MOVE TO STAGE', style: AppTypography.label.copyWith(color: AppColors.textTertiary)),
          const SizedBox(height: AppSpacing.space2),
          Wrap(
            spacing: AppSpacing.space2,
            runSpacing: AppSpacing.space2,
            children: [
              for (final state in kApplicationStates)
                OutlinedButton(
                  onPressed: _isMovingStage ? null : () => _moveStage(state),
                  style: OutlinedButton.styleFrom(
                    backgroundColor: state == _application.state ? AppColors.brandSoft : null,
                    side: BorderSide(color: state == _application.state ? AppColors.brand500 : AppColors.border),
                  ),
                  child: StatusPill(context: PillContext.stage, value: state, size: PillSize.sm),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.space5),
          AppFormField(label: 'Notes', controller: _notesController, multiline: true, rows: 4),
          const SizedBox(height: AppSpacing.space2),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _isSavingNotes ? null : _saveNotes,
              child: Text(_isSavingNotes ? 'Saving…' : 'Save notes'),
            ),
          ),
          const SizedBox(height: AppSpacing.space3),
          AppFormField(
            label: 'Contact email',
            controller: _contactEmailController,
            placeholder: 'recruiter@company.com',
            hint: 'Where "Approve & send" delivers a drafted follow-up.',
            keyboardType: TextInputType.emailAddress,
          ),
          const SizedBox(height: AppSpacing.space2),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _isSavingContactEmail ? null : _saveContactEmail,
              child: Text(_isSavingContactEmail ? 'Saving…' : 'Save contact email'),
            ),
          ),
          const SizedBox(height: AppSpacing.space3),
          if (_application.followupBody != null) _followupCard() else _draftFollowupButton(),
          if (_errorMessage != null) ...[
            const SizedBox(height: AppSpacing.space3),
            Text(_errorMessage!, style: AppTypography.bodySm.copyWith(color: AppColors.criticalText)),
          ],
        ],
      ),
    );
  }

  Widget _draftFollowupButton() {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        onPressed: _isDraftingFollowup ? null : _draftFollowup,
        child: Text(_isDraftingFollowup ? 'Drafting…' : 'Draft a follow-up'),
      ),
    );
  }

  Widget _followupCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.space3),
      decoration: BoxDecoration(
        color: AppColors.infoSoft,
        border: Border.all(color: AppColors.infoBorder),
        borderRadius: AppRadius.mdRadius,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Follow-up draft', style: AppTypography.caption.copyWith(color: AppColors.infoText, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(_application.followupSubject ?? '', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(_application.followupBody ?? '', style: AppTypography.bodySm),
          const SizedBox(height: AppSpacing.space2),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _isDraftingFollowup ? null : _draftFollowup,
                child: Text(_isDraftingFollowup ? 'Redrafting…' : 'Redraft'),
              ),
              TextButton(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: '${_application.followupSubject}\n\n${_application.followupBody}'));
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied to clipboard')));
                },
                child: const Text('Copy'),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.space2),
          _sendRow(),
        ],
      ),
    );
  }

  Widget _sendRow() {
    if (_application.followupSentAt != null) {
      return Row(
        children: [
          const Icon(Icons.check_circle, color: AppColors.successFill, size: 16),
          const SizedBox(width: AppSpacing.space1),
          Text('Sent', style: AppTypography.bodySm.copyWith(color: AppColors.successText, fontWeight: FontWeight.w600)),
        ],
      );
    }

    final hasContactEmail = (_application.contactEmail ?? '').isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: (!hasContactEmail || _isSendingFollowup) ? null : _sendFollowup,
            child: Text(_isSendingFollowup ? 'Sending…' : 'Approve & send'),
          ),
        ),
        if (!hasContactEmail) ...[
          const SizedBox(height: AppSpacing.space1),
          Text('Add a contact email above to send.', style: AppTypography.caption),
        ],
      ],
    );
  }
}
