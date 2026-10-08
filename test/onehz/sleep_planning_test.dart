import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

const h = 3600.0;
List<SleepPlanningDay> days(int from, int through,
        {int? shortDay, double nap = 0}) =>
    [
      for (var d = from; d <= through; d++)
        SleepPlanningDay(d,
            sleepSec: d == shortDay ? 4 * h : 8 * h,
            acceptedNapSec: nap,
            complete: true),
    ];
SleepPlanningResult plan(List<SleepPlanningDay> data,
        {double? strain = 0,
        bool validated = true,
        SleepPlanningPolicy policy = const SleepPlanningPolicy()}) =>
    experimentalSleepPlan(data,
        targetDay: 100,
        referenceSec: 8 * h,
        referenceValidated: validated,
        dayStrain: strain,
        policy: policy);

void main() {
  test(
      'ordinary alarm-constrained history is a reference, never validated need',
      () {
    final ref = experimentalSleepReference(days(10, 100), 100);
    expect(ref.value!.seconds, 8 * h);
    expect(ref.value!.toJson()['validated'], false);
    expect(ref.confidence, lessThanOrEqualTo(0.2));
    expect(plan(days(93, 100), validated: false).nextSleepSec, isNull);
  });
  test('restricted recent nights do not lower the anchored reference', () {
    final source = days(10, 100);
    final anchor = experimentalSleepReference(source, 100).value!;
    final restricted = [
      ...days(10, 92),
      for (var d = 93; d <= 110; d++)
        SleepPlanningDay(d, sleepSec: 4 * h, acceptedNapSec: 0, complete: true)
    ];
    final next =
        experimentalSleepReference(restricted, 110, anchor: anchor).value!;
    expect(next.seconds, anchor.seconds);
    expect(next.fromDay, anchor.fromDay);
  });
  test('reference correction replaces observations and thin anchors abstain',
      () {
    final source = days(10, 100);
    final anchor = experimentalSleepReference(source, 100).value!;
    final corrected = [
      for (final d in source)
        SleepPlanningDay(d.day,
            sleepSec: 9 * h, acceptedNapSec: 0, complete: d.day > 30)
    ];
    expect(experimentalSleepReference(corrected, 100, anchor: anchor).present,
        false);
  });
  test('a four-hour night changes accounting despite six normal nights', () {
    final result = plan(days(93, 100, shortDay: 100));
    expect(result.latestShortfallSec, 4 * h);
    expect(result.recentShortfallSec, 4 * h);
    expect(result.nextSleepSec, 9 * h);
    expect(result.nextSleepSec, lessThan(12 * h));
  });
  test('long prior nights cannot erase a later short night', () {
    final data = [
      for (var d = 93; d < 100; d++)
        SleepPlanningDay(d,
            sleepSec: 10 * h, acceptedNapSec: 0, complete: true),
      const SleepPlanningDay(100,
          sleepSec: 4 * h, acceptedNapSec: 0, complete: true)
    ];
    expect(plan(data).recentShortfallSec, 4 * h);
    expect(plan(data).nextSleepSec, 9 * h);
  });
  test('future or malformed retained anchors cannot establish a reference', () {
    for (final anchor in [
      const SleepPlanningReference(8 * h, 101, 128, 28),
      const SleepPlanningReference(double.nan, 1, 28, 28),
      const SleepPlanningReference(8 * h, 1, 28, 2),
      const SleepPlanningReference(8 * h, 28, 1, 28),
    ]) {
      expect(
          experimentalSleepReference(days(93, 100), 100, anchor: anchor)
              .present,
          false);
    }
  });
  test('repeated restriction is bounded and recomputation is identical', () {
    final data = [
      for (var d = 93; d <= 100; d++)
        SleepPlanningDay(d, sleepSec: 4 * h, acceptedNapSec: 0, complete: true)
    ];
    final first = plan(data).toJson();
    expect(first['need_sec'], 9 * h);
    expect(plan(data).toJson(), first);
  });
  test('longer sleep reduces accounting without changing the reference', () {
    final short = days(93, 100, shortDay: 99);
    final catchup = [
      ...short.take(short.length - 1),
      const SleepPlanningDay(100,
          sleepSec: 10 * h, acceptedNapSec: 0, complete: true)
    ];
    expect(plan(catchup).recentShortfallSec,
        lessThan(plan(short).recentShortfallSec!));
    expect(plan(catchup).nextSleepSec, greaterThanOrEqualTo(8 * h));
  });
  test('today nap credits the next sleep once, not completed-night accounting',
      () {
    final data = days(93, 100, shortDay: 100);
    final napped = [
      ...data.take(data.length - 1),
      const SleepPlanningDay(100,
          sleepSec: 4 * h, acceptedNapSec: h, complete: true)
    ];
    expect(plan(napped).recentShortfallSec, plan(data).recentShortfallSec);
    expect(plan(napped).napCreditSec, h);
    expect(plan(napped).nextSleepSec, 8 * h);
  });
  test('prior-day nap credits only the following completed night', () {
    final data = [
      ...days(93, 98),
      const SleepPlanningDay(99,
          sleepSec: 8 * h, acceptedNapSec: h, complete: true),
      const SleepPlanningDay(100,
          sleepSec: 4 * h, acceptedNapSec: 0, complete: true)
    ];
    expect(plan(data).recentShortfallSec, 3 * h);
    expect(plan(data).napCreditSec, 0);
  });
  test(
      'missing calendar date is unknown, never a compressed seven-night window',
      () {
    final result = plan(days(93, 100).where((d) => d.day != 98).toList());
    expect(result.nextSleepSec, isNull);
    expect(result.recentShortfallSec, isNull);
    expect(result.missingDays, 2);
    expect(result.latestShortfallSec, 0);
  });
  test('partial latest night cannot fall back to an older complete one', () {
    final data = [
      ...days(93, 99),
      const SleepPlanningDay(100,
          sleepSec: h, acceptedNapSec: 0, complete: false)
    ];
    expect(plan(data).latestShortfallSec, isNull);
    expect(plan(data).nextSleepSec, isNull);
  });
  test('unknown naps or strain withhold the target', () {
    final data = [
      ...days(93, 99),
      const SleepPlanningDay(100, sleepSec: 8 * h, complete: true)
    ];
    expect(plan(data).nextSleepSec, isNull);
    expect(plan(days(93, 100), strain: null).nextSleepSec, isNull);
  });
  test('duplicate days cannot accumulate extra shortfall', () {
    expect(plan([...days(93, 100), days(100, 100).single]).status,
        'duplicate_day');
  });
  test('policy limits are explicit and reject invalid coefficients', () {
    expect(
        plan(days(93, 100, shortDay: 100),
                policy: const SleepPlanningPolicy(maxAdjustmentSec: 1800))
            .nextSleepSec,
        8.5 * h);
    expect(
        plan(days(93, 100),
                policy: const SleepPlanningPolicy(dailyRetention: -1))
            .nextSleepSec,
        isNull);
  });
  test(
      'retained anchor survives expired source recordings without claiming validation',
      () {
    const anchor = SleepPlanningReference(8 * h, 1, 28, 28);
    final result =
        experimentalSleepReference(days(93, 100), 100, anchor: anchor);
    expect(result.value, anchor);
    expect(result.confidence, 0.1);
  });
  test('absent, nonfinite and thin references never invent a baseline', () {
    expect(experimentalSleepReference(days(90, 100), 100).present, false);
    expect(
        experimentalSleepPlan(days(93, 100),
                targetDay: 100,
                referenceSec: double.nan,
                referenceValidated: true,
                dayStrain: 0)
            .nextSleepSec,
        isNull);
  });
  test(
      'observed planning is available only as an explicit low-confidence estimate',
      () {
    const ref = SleepPlanningReference(8 * h, 1, 28, 28);
    final estimate = observedSleepPlan(days(93, 100, shortDay: 100),
        targetDay: 100, reference: ref, dayStrain: 0);
    expect(estimate.tier, Tier.estimate);
    expect(estimate.confidence, lessThanOrEqualTo(0.2));
    expect(estimate.value!.latestShortfallSec, 4 * h);
    expect(estimate.value!.nextSleepSec, 9 * h);
    expect(ref.toJson()['validated'], false);
    expect(plan(days(93, 100), validated: false).nextSleepSec, isNull);
  });
  test(
      'midnight keeps completed-night accounting but uses only current-day naps',
      () {
    final data = [
      ...days(93, 100, shortDay: 100),
      const SleepPlanningDay(101, acceptedNapSec: h)
    ];
    final result = experimentalSleepPlan(data,
        targetDay: 100,
        currentDay: 101,
        referenceSec: 8 * h,
        referenceValidated: true,
        dayStrain: 0);
    expect(result.latestSleepDay, 100);
    expect(result.recentShortfallSec, 4 * h);
    expect(result.napCreditSec, h);
    expect(result.nextSleepSec, 8 * h);
  });
  test('reported extra is the amount applied after recommendation bounds', () {
    final result = experimentalSleepPlan(days(93, 100, shortDay: 100),
        targetDay: 100,
        referenceSec: 11 * h,
        referenceValidated: true,
        dayStrain: 21);
    expect(result.nextSleepSec, 11 * h);
    expect(result.shortfallAdjustmentSec, 0);
  });
  test('retained reference round trip rejects malformed source and bounds', () {
    const ref = SleepPlanningReference(8 * h, 1, 28, 28);
    expect(SleepPlanningReference.fromJson(ref.toJson())!.seconds, 8 * h);
    expect(SleepPlanningReference.fromJson({...ref.toJson(), 'nights': 1}),
        isNull);
    expect(
        SleepPlanningReference.fromJson(
            {...ref.toJson(), 'source': 'biological_need'}),
        isNull);
  });
}
