import 'package:flutter/material.dart';

import '../models/interview_story.dart';
import '../services/api_client.dart';
import '../theme/app_colors.dart';
import '../theme/app_metrics.dart';
import '../widgets/app_form_field.dart';
import '../widgets/app_icon.dart';
import '../widgets/app_loader.dart';
import '../widgets/empty_state.dart';
import '../widgets/page_header.dart';

/// Career-ops integration Brick 4 (docs/21-career-ops-integration-plan.md
/// §1.2, DECISIONS.md ADR-058): the persistent story bank — reachable from
/// [InterviewPrepScreen]'s app bar action and from Profile, independent of
/// any one job. Every story here was either saved from a generated pack
/// or written from scratch; unlike a pack, these survive.
class StoryBankScreen extends StatefulWidget {
  const StoryBankScreen({super.key});

  @override
  State<StoryBankScreen> createState() => _StoryBankScreenState();
}

class _StoryBankScreenState extends State<StoryBankScreen> {
  final ApiClient _apiClient = ApiClient();
  bool _isLoading = true;
  String? _errorMessage;
  List<InterviewStory> _stories = [];

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
      final stories = await _apiClient.listInterviewStories();
      if (!mounted) return;
      setState(() {
        _stories = stories;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _openEditor({InterviewStory? existing}) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _StoryEditorSheet(apiClient: _apiClient, existing: existing),
    );
    if (saved == true) _load();
  }

  Future<void> _delete(InterviewStory story) async {
    try {
      await _apiClient.deleteInterviewStory(story.id);
      if (!mounted) return;
      setState(() => _stories.removeWhere((s) => s.id == story.id));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not delete: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: PageHeader(
        title: 'Story bank',
        showBack: true,
        actions: [
          HeaderActionButton(icon: AppIconName.plus, tooltip: 'Add a story', onPressed: () => _openEditor()),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) return const Center(child: AppLoader());

    if (_errorMessage != null) {
      return Center(
        child: EmptyState(
          icon: AppIconName.alertTriangle,
          title: 'Could not load your stories',
          message: _errorMessage,
          actionLabel: 'Retry',
          onAction: _load,
        ),
      );
    }

    if (_stories.isEmpty) {
      return Center(
        child: EmptyState(
          icon: AppIconName.book,
          title: 'No stories yet',
          message: 'Save STAR answers from an interview pack, or write one from scratch — real answers you can reuse across interviews.',
          actionLabel: 'Add a story',
          onAction: () => _openEditor(),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.screenPadX),
      children: [
        for (var i = 0; i < _stories.length; i++) ...[
          if (i > 0) const SizedBox(height: AppSpacing.space3),
          _storyCard(_stories[i]),
        ],
      ],
    );
  }

  Widget _storyCard(InterviewStory story) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.space3),
      decoration: BoxDecoration(
        color: context.c.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: context.c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _field('Situation', story.situation),
          _field('Task', story.task),
          _field('Action', story.action),
          _field('Result', story.result),
          if ((story.reflection ?? '').isNotEmpty) _field('Reflection', story.reflection!),
          const SizedBox(height: AppSpacing.space2),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: () => _openEditor(existing: story), child: const Text('Edit')),
              TextButton(
                onPressed: () => _delete(story),
                style: TextButton.styleFrom(foregroundColor: context.c.critical),
                child: const Text('Delete'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _field(String label, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: RichText(
        text: TextSpan(
          style: AppTypography.bodySm.copyWith(color: context.c.ink),
          children: [
            TextSpan(text: '$label: ', style: TextStyle(fontWeight: FontWeight.w700, color: context.c.inkFaint)),
            TextSpan(text: text),
          ],
        ),
      ),
    );
  }
}

/// Add/edit sheet — a manual write shares the same four required STAR
/// fields plus an optional reflection a saved-from-pack story has.
class _StoryEditorSheet extends StatefulWidget {
  const _StoryEditorSheet({required this.apiClient, this.existing});

  final ApiClient apiClient;
  final InterviewStory? existing;

  @override
  State<_StoryEditorSheet> createState() => _StoryEditorSheetState();
}

class _StoryEditorSheetState extends State<_StoryEditorSheet> {
  late final _situation = TextEditingController(text: widget.existing?.situation ?? '');
  late final _task = TextEditingController(text: widget.existing?.task ?? '');
  late final _action = TextEditingController(text: widget.existing?.action ?? '');
  late final _result = TextEditingController(text: widget.existing?.result ?? '');
  late final _reflection = TextEditingController(text: widget.existing?.reflection ?? '');
  bool _isSaving = false;
  String? _error;

  @override
  void dispose() {
    _situation.dispose();
    _task.dispose();
    _action.dispose();
    _result.dispose();
    _reflection.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_situation.text.trim().isEmpty || _task.text.trim().isEmpty || _action.text.trim().isEmpty || _result.text.trim().isEmpty) {
      setState(() => _error = 'Situation, task, action, and result are all required.');
      return;
    }
    setState(() {
      _isSaving = true;
      _error = null;
    });
    try {
      final existing = widget.existing;
      if (existing == null) {
        await widget.apiClient.createInterviewStory(
          situation: _situation.text.trim(),
          task: _task.text.trim(),
          action: _action.text.trim(),
          result: _result.text.trim(),
          reflection: _reflection.text.trim().isEmpty ? null : _reflection.text.trim(),
        );
      } else {
        await widget.apiClient.updateInterviewStory(
          existing.id,
          situation: _situation.text.trim(),
          task: _task.text.trim(),
          action: _action.text.trim(),
          result: _result.text.trim(),
          reflection: _reflection.text.trim(),
        );
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.screenPadX),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.existing == null ? 'Add a story' : 'Edit story',
                  style: AppTypography.headingSm,
                ),
                const SizedBox(height: AppSpacing.space4),
                AppFormField(label: 'Situation', controller: _situation, multiline: true, rows: 2, required: true),
                const SizedBox(height: AppSpacing.space3),
                AppFormField(label: 'Task', controller: _task, multiline: true, rows: 2, required: true),
                const SizedBox(height: AppSpacing.space3),
                AppFormField(label: 'Action', controller: _action, multiline: true, rows: 3, required: true),
                const SizedBox(height: AppSpacing.space3),
                AppFormField(label: 'Result', controller: _result, multiline: true, rows: 2, required: true),
                const SizedBox(height: AppSpacing.space3),
                AppFormField(
                  label: 'Reflection (optional)',
                  controller: _reflection,
                  multiline: true,
                  rows: 2,
                  hint: 'What worked, or what you\'d change next time — added after a real interview.',
                ),
                if (_error != null) ...[
                  const SizedBox(height: AppSpacing.space2),
                  Text(_error!, style: AppTypography.bodySm.copyWith(color: context.c.critical)),
                ],
                const SizedBox(height: AppSpacing.space4),
                ElevatedButton(
                  onPressed: _isSaving ? null : _save,
                  child: Text(_isSaving ? 'Saving…' : 'Save'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
