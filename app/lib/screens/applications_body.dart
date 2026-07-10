import 'package:flutter/material.dart';

import '../models/application_item.dart';
import '../services/api_client.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_icon.dart';
import '../widgets/application_card.dart';
import '../widgets/empty_state.dart';
import '../widgets/kanban_column.dart';
import '../widgets/loading_skeleton.dart';
import 'app_detail_screen.dart';

/// The Track tab's content (chrome comes from [MainTabScreen] /
/// [AppShell]). Brick 7: the application pipeline as a
/// horizontally-scrolling Kanban board — one [KanbanColumn] per
/// [kApplicationStates] stage. Frontend rebuild Phase 2: tapping a card
/// now opens [AppDetailScreen] (notes + on-demand follow-ups) instead of
/// the old stage-picker bottom sheet — moving stages still happens there,
/// just alongside the new fields that didn't fit in a sheet.
class ApplicationsBody extends StatefulWidget {
  const ApplicationsBody({super.key});

  @override
  State<ApplicationsBody> createState() => _ApplicationsBodyState();
}

class _ApplicationsBodyState extends State<ApplicationsBody> {
  final ApiClient _apiClient = ApiClient();

  bool _isLoading = true;
  String? _errorMessage;
  List<ApplicationItem> _items = [];

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
      final items = await _apiClient.fetchApplications();
      setState(() {
        _items = items;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _openDetail(ApplicationItem item) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AppDetailScreen(
          application: item,
          onChanged: (updated) => setState(() {
            _items = _items.map((a) => a.id == updated.id ? updated : a).toList();
          }),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        itemCount: kApplicationStates.length,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.space3),
        itemBuilder: (_, _) => const SizedBox(
          width: 264,
          child: LoadingSkeleton(variant: SkeletonVariant.card),
        ),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: EmptyState(
          icon: AppIconName.alertTriangle,
          title: 'Could not load applications',
          message: _errorMessage,
          actionLabel: 'Retry',
          onAction: _load,
        ),
      );
    }

    if (_items.isEmpty) {
      return Center(
        child: EmptyState(
          icon: AppIconName.columns,
          title: 'Nothing tracked yet',
          message: 'Save a job from Matches to start moving it through the pipeline.',
          actionLabel: 'Retry',
          onAction: _load,
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: SingleChildScrollView(
        padding: EdgeInsets.zero,
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final state in kApplicationStates) ...[
              KanbanColumn(
                stage: state,
                count: _items.where((a) => a.state == state).length,
                children: _items
                    .where((a) => a.state == state)
                    .map(
                      (a) => ApplicationCard(
                        title: a.job.title,
                        company: a.job.company ?? 'Unknown company',
                        salary: a.job.salaryLabel,
                        onTap: () => _openDetail(a),
                      ),
                    )
                    .toList(),
              ),
              const SizedBox(width: AppSpacing.space3),
            ],
          ],
        ),
      ),
    );
  }
}
