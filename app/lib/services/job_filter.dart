import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/job.dart';

/// A location choice on the filter sheet (§4.4). [aliases] are lower-case
/// substrings any of which, found in `job.location`, counts as a match — city
/// names travel under several spellings (Bengaluru/Bangalore/BLR), so a single
/// literal would silently drop postings. `Remote` is special-cased: it also
/// matches `work_type == 'remote'`, since a remote posting often names no city.
class JobLocationOption {
  const JobLocationOption(this.label, this.aliases, {this.isRemote = false});
  final String label;
  final List<String> aliases;
  final bool isRemote;

  bool matches(Job job) {
    if (isRemote && job.workType == 'remote') return true;
    final loc = job.location?.toLowerCase();
    if (loc == null) return false;
    return aliases.any(loc.contains);
  }
}

/// The five landmark cities + Remote drawn in §4.4, in the order the sheet
/// renders them. Kept here (not in the widget) so [JobFilter.matches] and the
/// chips agree on exactly one definition of "in Bengaluru".
const List<JobLocationOption> kFilterLocations = [
  JobLocationOption('Remote', ['remote', 'anywhere', 'work from home'], isRemote: true),
  JobLocationOption('Hyderabad', ['hyderabad', 'hyd']),
  JobLocationOption('Bengaluru', ['bengaluru', 'bangalore', 'blr']),
  JobLocationOption('Delhi', ['delhi', 'new delhi', 'ncr']),
  JobLocationOption('Mumbai', ['mumbai', 'bombay']),
  JobLocationOption('Pune', ['pune']),
];

/// Every category the server can return (mirrors server/services/job_category.py
/// ::CATEGORIES and migration 027's CHECK). Order is the order the sheet renders
/// chips in — engineering-adjacent first, since that's what this app is for.
const List<String> kJobCategories = [
  'engineering',
  'data',
  'design',
  'product',
  'marketing',
  'sales',
  'finance',
  'operations',
  'hr',
  'content',
  'legal',
  'other',
];

/// The categories the Jobs tab starts on. NOT "all": ADR-003 v3 widened
/// ingestion to Unstop's entire catalogue, so ~75% of the pool is sales,
/// marketing, finance and operations. Defaulting to everything would bury the
/// engineering roles this app exists to surface — and would make the app page
/// through 1,400 rows to show them. The other categories are one tap away in the
/// filter sheet; they're de-emphasised, not hidden.
const Set<String> kDefaultJobCategories = {'engineering', 'data', 'design', 'product'};

/// Human labels for the chips. Kept beside the vocabulary so a new category
/// can't ship with a raw slug like "hr" showing in the UI.
const Map<String, String> kJobCategoryLabels = {
  'engineering': 'Engineering',
  'data': 'Data & AI',
  'design': 'Design',
  'product': 'Product',
  'marketing': 'Marketing',
  'sales': 'Sales',
  'finance': 'Finance',
  'operations': 'Operations',
  'hr': 'HR',
  'content': 'Content',
  'legal': 'Legal',
  'other': 'Other',
};

/// Immutable filter criteria shared by the sheet, the Jobs list, and the
/// header badge (§4.4). Every field's "unset" value means "don't narrow on
/// this axis", so the default instance matches the whole pool.
///
/// One axis is different: [categories] is applied SERVER-side and everything
/// else client-side. See that field — it's the one toggle that refetches.
@immutable
class JobFilter {
  const JobFilter({
    this.sources = const {},
    this.workType,
    this.salary,
    this.locations = const {},
    this.categories = kDefaultJobCategories,
  });

  /// The discipline allow-list, sent to `GET /jobs?category=`. Empty = all.
  ///
  /// The odd one out: every other axis here narrows an already-loaded list in
  /// memory (master-plan rule 8), and changing this one REFETCHES. It has to.
  /// With the broad pool the app would otherwise download 1,400+ postings —
  /// past `fetchAllJobs`'s page ceiling, so the tail would be silently missing —
  /// to display the ~200 the user actually wants. Narrowing before pagination is
  /// what keeps the Jobs tab loading a couple of hundred rows instead.
  final Set<String> categories;

  /// Empty = all sources. A non-empty set is an allow-list.
  final Set<String> sources;

  /// null = Any; else 'remote' | 'hybrid' | 'onsite'.
  final String? workType;

  /// null = no salary constraint. Values are absolute amounts in the pool's
  /// dominant currency (INR for this app); the sheet supplies the domain and
  /// clamps. Jobs with no salary at all are never hidden by this — unknown pay
  /// is not "₹0", and hiding most of the pool over missing data would mislead.
  final SalaryRange? salary;

  /// Empty = all locations. A non-empty set is an allow-list of labels from
  /// [kFilterLocations].
  final Set<String> locations;

  /// Drives the header's "filters are on" dot. Categories count as active only
  /// when they DIFFER from the default — the default is the app's normal
  /// resting state, and showing a permanent dot would train the user to ignore
  /// it.
  bool get isActive =>
      sources.isNotEmpty ||
      workType != null ||
      salary != null ||
      locations.isNotEmpty ||
      !setEquals(categories, kDefaultJobCategories);

  /// One shared definition of "this job survives the current filter". Every
  /// axis is AND-ed; within the location and source axes the members are OR-ed.
  ///
  /// [categories] is deliberately NOT re-checked here — the server already
  /// applied it, and re-applying would drop legitimately-returned rows whose
  /// category is null (ingested before migration 027's backfill).
  bool matches(Job job) {
    if (sources.isNotEmpty && !sources.contains(job.source)) return false;
    if (workType != null && job.workType != workType) return false;
    if (salary != null) {
      final v = jobSalaryValue(job);
      // Unknown salary passes (see [salary] doc); a known value must overlap.
      if (v != null && (v < salary!.min || v > salary!.max)) return false;
    }
    if (locations.isNotEmpty) {
      final opts = kFilterLocations.where((o) => locations.contains(o.label));
      if (!opts.any((o) => o.matches(job))) return false;
    }
    return true;
  }

  JobFilter copyWith({
    Set<String>? sources,
    Set<String>? locations,
    Set<String>? categories,
    SalaryRange? salary,
    bool clearSalary = false,
    String? workType,
    bool clearWorkType = false,
  }) =>
      JobFilter(
        sources: sources ?? this.sources,
        locations: locations ?? this.locations,
        categories: categories ?? this.categories,
        salary: clearSalary ? null : (salary ?? this.salary),
        workType: clearWorkType ? null : (workType ?? this.workType),
      );
}

/// A closed salary interval. A tiny value type (not Flutter's `RangeValues`)
/// so the provider layer stays free of a `material` import and it round-trips
/// as plain numbers.
@immutable
class SalaryRange {
  const SalaryRange(this.min, this.max);
  final double min;
  final double max;

  @override
  bool operator ==(Object other) => other is SalaryRange && other.min == min && other.max == max;

  @override
  int get hashCode => Object.hash(min, max);
}

/// The single scalar a job contributes to the salary histogram / range filter:
/// its stated midpoint, or whichever bound exists. null when the posting names
/// no pay at all.
double? jobSalaryValue(Job job) {
  final lo = job.salaryMin;
  final hi = job.salaryMax;
  if (lo != null && hi != null) return (lo + hi) / 2;
  return lo ?? hi;
}

/// The one shared filter-state holder (§4.4: "one Riverpod provider shared by
/// the sheet, the list, and the count badge"). Every surface reads THIS, so the
/// active-dot on the header, the "Show N" in the sheet, and the visible list
/// can never disagree about what's filtered.
final jobFilterProvider = NotifierProvider<JobFilterNotifier, JobFilter>(JobFilterNotifier.new);

class JobFilterNotifier extends Notifier<JobFilter> {
  @override
  JobFilter build() => const JobFilter();

  void toggleSource(String source) {
    final next = {...state.sources};
    next.contains(source) ? next.remove(source) : next.add(source);
    state = state.copyWith(sources: next);
  }

  void toggleLocation(String label) {
    final next = {...state.locations};
    next.contains(label) ? next.remove(label) : next.add(label);
    state = state.copyWith(locations: next);
  }

  /// Unlike the other toggles this one costs a network fetch, so the Jobs tab
  /// watches `categories` specifically and refetches when it changes.
  ///
  /// Untoggling the last category snaps back to the default rather than leaving
  /// an empty set: empty means "all categories" on the wire, so a user clearing
  /// every chip would get the OPPOSITE of what they asked for — 1,400 rows of
  /// mostly sales postings instead of none.
  void toggleCategory(String category) {
    final next = {...state.categories};
    next.contains(category) ? next.remove(category) : next.add(category);
    state = state.copyWith(categories: next.isEmpty ? kDefaultJobCategories : next);
  }

  void setCategories(Set<String> categories) =>
      state = state.copyWith(categories: categories.isEmpty ? kDefaultJobCategories : categories);

  /// Every category at once — the explicit "show me everything" escape hatch,
  /// distinct from the empty set (which would snap back to the default).
  void selectAllCategories() => state = state.copyWith(categories: kJobCategories.toSet());

  /// null clears the work-type constraint (the "Any" segment).
  void setWorkType(String? workType) =>
      state = workType == null ? state.copyWith(clearWorkType: true) : state.copyWith(workType: workType);

  /// Pass null (or the full pool domain) to clear the salary constraint.
  void setSalary(SalaryRange? range) =>
      state = range == null ? state.copyWith(clearSalary: true) : state.copyWith(salary: range);

  void clearAll() => state = const JobFilter();
}
