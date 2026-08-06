import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:go_router/go_router.dart';

import '../models/application_email.dart';
import '../models/application_item.dart';
import '../router/route_args.dart';
import '../services/api_client.dart';
import '../services/contact_discovery.dart';
import '../theme/app_colors.dart';
import '../theme/app_metrics.dart';
import '../widgets/app_form_field.dart';
import '../widgets/app_icon.dart';
import '../widgets/page_header.dart';
import '../widgets/status_pill.dart';

/// Career-ops integration Brick 3 (ADR-057) — the three tones
/// generate_application_email supports. Kept next to the screen that's the
/// only place they're picked from.
const List<(String, String)> _kEmailKinds = [
  ('application', 'Application'),
  ('referral', 'Referral ask'),
  ('cold', 'Cold outreach'),
];

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

  // Career-ops integration Brick 3 (ADR-057).
  String _selectedEmailKind = 'application';
  bool _isLoadingEmails = true;
  bool _isDraftingEmail = false;
  String? _sendingEmailId;
  String? _emailErrorMessage;
  ApplicationEmailList? _emailList;

  @override
  void initState() {
    super.initState();
    _loadApplicationEmails();
  }

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

  Future<void> _loadApplicationEmails() async {
    setState(() => _isLoadingEmails = true);
    try {
      final list = await _apiClient.listApplicationEmails(_application.id);
      if (!mounted) return;
      setState(() {
        _emailList = list;
        _isLoadingEmails = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _emailErrorMessage = e.toString();
        _isLoadingEmails = false;
      });
    }
  }

  Future<void> _draftApplicationEmail() async {
    setState(() {
      _isDraftingEmail = true;
      _emailErrorMessage = null;
    });
    try {
      await _apiClient.draftApplicationEmail(_application.id, _selectedEmailKind);
      if (!mounted) return;
      await _loadApplicationEmails();
    } catch (e) {
      if (!mounted) return;
      setState(() => _emailErrorMessage = e.toString());
    } finally {
      if (mounted) setState(() => _isDraftingEmail = false);
    }
  }

  Future<void> _sendApplicationEmail(String emailId) async {
    setState(() {
      _sendingEmailId = emailId;
      _emailErrorMessage = null;
    });
    try {
      await _apiClient.sendApplicationEmail(_application.id, emailId);
      if (!mounted) return;
      await _loadApplicationEmails();
    } catch (e) {
      if (!mounted) return;
      setState(() => _emailErrorMessage = e.toString());
    } finally {
      if (mounted) setState(() => _sendingEmailId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final job = _application.job;
    return Scaffold(
      appBar: const PageHeader(title: 'Application', showBack: true),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.screenPadX),
        children: [
          Text(job.title, style: AppTypography.title),
          Text(job.company ?? 'Unknown company', style: AppTypography.bodySm.copyWith(color: context.c.inkSoft)),
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
          Text('MOVE TO STAGE', style: AppTypography.label.copyWith(color: context.c.inkFaint)),
          const SizedBox(height: AppSpacing.space2),
          Wrap(
            spacing: AppSpacing.space2,
            runSpacing: AppSpacing.space2,
            children: [
              for (final state in kApplicationStates)
                OutlinedButton(
                  onPressed: _isMovingStage ? null : () => _moveStage(state),
                  style: OutlinedButton.styleFrom(
                    backgroundColor: state == _application.state ? context.c.accentSoft : null,
                    side: BorderSide(color: state == _application.state ? context.c.accent : context.c.border),
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
            Text(_errorMessage!, style: AppTypography.bodySm.copyWith(color: context.c.critical)),
          ],
          const SizedBox(height: AppSpacing.space5),
          _applicationEmailsSection(),
          const SizedBox(height: AppSpacing.space5),
          _prepareSection(),
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
        color: context.c.info.withValues(alpha: 0.12),
        border: Border.all(color: context.c.info.withValues(alpha: 0.30)),
        borderRadius: AppRadius.mdRadius,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Follow-up draft', style: AppTypography.caption.copyWith(color: context.c.info, fontWeight: FontWeight.w700)),
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
          Icon(Icons.check_circle, color: context.c.success, size: 16),
          const SizedBox(width: AppSpacing.space1),
          Text('Sent', style: AppTypography.bodySm.copyWith(color: context.c.success, fontWeight: FontWeight.w600)),
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

  /// Career-ops integration Brick 3 (ADR-057). Distinct from the follow-up
  /// card above: a follow-up is one overwrite-in-place nudge for silence
  /// after applying, this is a first-contact email (application ask,
  /// referral ask, or cold outreach) — and every draft here is kept as its
  /// own row, so this renders a list, not a single card.
  Widget _applicationEmailsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('APPLICATION EMAILS', style: AppTypography.label.copyWith(color: context.c.inkFaint)),
        const SizedBox(height: AppSpacing.space2),
        Wrap(
          spacing: AppSpacing.space2,
          runSpacing: AppSpacing.space2,
          children: [
            for (final (kind, label) in _kEmailKinds)
              OutlinedButton(
                onPressed: _isDraftingEmail ? null : () => setState(() => _selectedEmailKind = kind),
                style: OutlinedButton.styleFrom(
                  backgroundColor: kind == _selectedEmailKind ? context.c.accentSoft : null,
                  side: BorderSide(color: kind == _selectedEmailKind ? context.c.accent : context.c.border),
                ),
                child: Text(label),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.space2),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: _isDraftingEmail ? null : _draftApplicationEmail,
            child: Text(_isDraftingEmail ? 'Drafting…' : 'Draft an email'),
          ),
        ),
        if (_emailErrorMessage != null) ...[
          const SizedBox(height: AppSpacing.space2),
          Text(_emailErrorMessage!, style: AppTypography.bodySm.copyWith(color: context.c.critical)),
        ],
        const SizedBox(height: AppSpacing.space3),
        if (_isLoadingEmails)
          const Center(child: Padding(padding: EdgeInsets.all(AppSpacing.space3), child: CircularProgressIndicator()))
        else if (_emailList != null) ...[
          _attachmentsHint(_emailList!),
          if (_emailList!.drafts.isNotEmpty) const SizedBox(height: AppSpacing.space2),
          for (var i = 0; i < _emailList!.drafts.length; i++) ...[
            if (i > 0) const SizedBox(height: AppSpacing.space2),
            _emailDraftCard(_emailList!.drafts[i]),
          ],
        ],
      ],
    );
  }

  Widget _attachmentsHint(ApplicationEmailList list) {
    if (list.drafts.isEmpty) return const SizedBox.shrink();
    final parts = <String>[
      if (list.hasResume) 'tailored résumé' else 'no tailored résumé yet',
      if (list.hasCoverLetter) 'cover letter' else 'no cover letter yet',
    ];
    return Text(
      'Remember to attach: ${parts.join(', ')}.',
      style: AppTypography.caption.copyWith(color: context.c.inkFaint),
    );
  }

  Widget _emailDraftCard(ApplicationEmailDraft draft) {
    final isSending = _sendingEmailId == draft.id;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.space3),
      decoration: BoxDecoration(
        color: context.c.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: draft.guardrailPass ? context.c.border : context.c.critical.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _kEmailKinds.firstWhere((k) => k.$1 == draft.kind, orElse: () => (draft.kind, draft.kind)).$2,
                  style: AppTypography.caption.copyWith(color: context.c.info, fontWeight: FontWeight.w700),
                ),
              ),
              StatusPill(
                context: PillContext.guardrail,
                value: draft.guardrailPass ? 'pass' : 'fail',
                size: PillSize.sm,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(draft.subject, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(draft.body, style: AppTypography.bodySm),
          if (draft.flaggedAtoms.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.space2),
            Wrap(
              spacing: AppSpacing.space2,
              runSpacing: AppSpacing.space2,
              children: [
                for (final a in draft.flaggedAtoms)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: context.c.critical.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                      border: Border.all(color: context.c.critical),
                    ),
                    child: Text(
                      'Not in your resume: ${a.text}',
                      style: AppTypography.caption.copyWith(color: context.c.critical),
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: AppSpacing.space2),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: '${draft.subject}\n\n${draft.body}'));
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied to clipboard')));
                },
                child: const Text('Copy'),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.space1),
          _emailSendRow(draft, isSending),
        ],
      ),
    );
  }

  Widget _emailSendRow(ApplicationEmailDraft draft, bool isSending) {
    if (draft.isSent) {
      return Row(
        children: [
          Icon(Icons.check_circle, color: context.c.success, size: 16),
          const SizedBox(width: AppSpacing.space1),
          Text('Sent', style: AppTypography.bodySm.copyWith(color: context.c.success, fontWeight: FontWeight.w600)),
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
            onPressed: (!hasContactEmail || isSending) ? null : () => _sendApplicationEmail(draft.id),
            child: Text(isSending ? 'Sending…' : 'Approve & send'),
          ),
        ),
        if (!hasContactEmail) ...[
          const SizedBox(height: AppSpacing.space1),
          Text('Add a contact email above to send.', style: AppTypography.caption),
        ],
      ],
    );
  }

  Future<void> _findPeople() async {
    final job = _application.job;
    final ok = await openLinkedInSearch(company: job.company ?? '', role: job.title);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the search — try again from a browser.')),
      );
    }
  }

  /// Career-ops integration Bricks 4-6 (ADR-058/059/060): three independent
  /// "get ready" tools, grouped together since they're all things a
  /// candidate reaches for once an application is actually moving, not at
  /// the moment they save a job. Each is its own screen (or, for contact
  /// discovery, an external browser tab) rather than inline content here —
  /// interview packs and offer reads are both too long to embed the way
  /// the follow-up/application-email cards above are.
  Widget _prepareSection() {
    final job = _application.job;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('PREPARE', style: AppTypography.label.copyWith(color: context.c.inkFaint)),
        const SizedBox(height: AppSpacing.space2),
        OutlinedButton.icon(
          onPressed: () => context.push(
            '/interview-prep',
            extra: ApplicationScopedArgs(applicationId: _application.id, jobTitle: job.title),
          ),
          icon: const AppIcon(AppIconName.helpCircle, size: 18),
          label: const Text('Prepare for the interview'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(double.infinity, 44), alignment: Alignment.centerLeft),
        ),
        const SizedBox(height: AppSpacing.space2),
        OutlinedButton.icon(
          onPressed: () => context.push(
            '/offer-review',
            extra: ApplicationScopedArgs(applicationId: _application.id, jobTitle: job.title),
          ),
          icon: const AppIcon(AppIconName.assignment, size: 18),
          label: const Text('Read an offer or contract'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(double.infinity, 44), alignment: Alignment.centerLeft),
        ),
        const SizedBox(height: AppSpacing.space2),
        OutlinedButton.icon(
          onPressed: _findPeople,
          icon: const AppIcon(AppIconName.people, size: 18),
          label: Text('Find people at ${job.company ?? 'this company'}'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(double.infinity, 44), alignment: Alignment.centerLeft),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            'Opens a LinkedIn people search in your browser — you browse in your own session.',
            style: AppTypography.caption.copyWith(color: context.c.inkFaint),
          ),
        ),
      ],
    );
  }
}
