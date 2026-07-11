import 'package:flutter_test/flutter_test.dart';
import 'package:jobhunt_agent/models/job.dart';

Job _job({double? min, double? max, String? currency, DateTime? postedAt}) {
  return Job(
    id: 'j1',
    source: 'adzuna',
    title: 'Flutter Developer',
    salaryMin: min,
    salaryMax: max,
    salaryCurrency: currency,
    postedAt: postedAt,
  );
}

void main() {
  group('salaryLabel (Phase 1D currency fix)', () {
    test('INR renders in lakh convention, never \$', () {
      final label = _job(min: 2000000, max: 4000000, currency: 'INR').salaryLabel;
      expect(label, '₹20L–₹40L');
    });

    test('INR below one lakh renders thousands', () {
      expect(_job(min: 80000, currency: 'INR').salaryLabel, '₹80K');
    });

    test('USD renders with dollar symbol', () {
      expect(_job(min: 145000, max: 180000, currency: 'USD').salaryLabel, '\$145K–\$180K');
    });

    test('unknown currency shows the code, not a wrong symbol', () {
      expect(_job(min: 50000, currency: 'PLN').salaryLabel, 'PLN 50K');
    });

    test('missing currency shows bare amount, not an assumed \$', () {
      expect(_job(min: 50000).salaryLabel, '50K');
    });

    test('no salary at all is null', () {
      expect(_job().salaryLabel, isNull);
    });
  });

  group('postedAtLabel (Phase 1D freshness fix)', () {
    test('recent date renders relative', () {
      final label = _job(postedAt: DateTime.now().subtract(const Duration(days: 3))).postedAtLabel;
      expect(label, '3d ago');
    });

    test('implausible age (2591d) renders date unknown, never Nd ago', () {
      final label = _job(postedAt: DateTime.now().subtract(const Duration(days: 2591))).postedAtLabel;
      expect(label, 'date unknown');
    });

    test('missing date renders date unknown', () {
      expect(_job().postedAtLabel, 'date unknown');
    });
  });
}
