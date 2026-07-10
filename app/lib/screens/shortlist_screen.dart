import 'package:flutter/material.dart';

import '../models/application_item.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_icon.dart';
import '../widgets/empty_state.dart';
import '../widgets/job_card.dart';

/// Reached from the Jobs tab's "Shortlist · N" pill (frontend rebuild
/// Phase 1, prototype `ui.isShortlist`). Zero new backend: just the
/// caller's already-fetched [ApplicationItem] list filtered to the
/// 'saved' stage — Brick 7's Kanban 'saved' state IS the shortlist, this
/// screen just names and surfaces it separately.
class ShortlistScreen extends StatelessWidget {
  const ShortlistScreen({super.key, required this.applications});

  final List<ApplicationItem> applications;

  @override
  Widget build(BuildContext context) {
    final shortlist = applications.where((a) => a.state == 'saved').toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Shortlist')),
      body: Padding(
        padding: const EdgeInsets.all(AppSpacing.screenPadX),
        child: shortlist.isEmpty
            ? Center(
                child: EmptyState(
                  icon: AppIconName.bookmark,
                  title: 'No saved jobs yet',
                  message: 'Tap the bookmark on any job to add it to your shortlist.',
                  actionLabel: 'Browse jobs',
                  onAction: () => Navigator.of(context).pop(),
                ),
              )
            : ListView.separated(
                padding: EdgeInsets.zero,
                itemCount: shortlist.length,
                separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.space3),
                itemBuilder: (context, index) {
                  final job = shortlist[index].job;
                  return JobCard(
                    title: job.title,
                    company: job.company ?? 'Unknown company',
                    location: job.location,
                    source: job.source,
                    salary: job.salaryLabel,
                    postedAt: job.postedAtLabel,
                    bookmarked: true,
                  );
                },
              ),
      ),
    );
  }
}
