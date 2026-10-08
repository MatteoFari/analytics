// EXPERIMENTAL planning policy, not a measurement of biological sleep need.
// Kitamura et al. (2016), doi:10.1038/srep35812, estimated need using repeated
// controlled sleep extension. Ordinary wearable durations do not establish
// that opportunity, including weekends or nights without an app alarm.
// Banks et al. (2010), doi:10.1093/sleep/33.8.1013, found incomplete recovery
// after one recovery night. Neither study supplies the policy coefficients
// below. They are explicit engineering assumptions for sensitivity testing.
// Observed-history planning is a low-confidence estimate, never biological need.
// The separate validated-reference entry point remains gated.
import 'dart:math' as math;

import '../types.dart';
import '../util.dart' show percentile;

class SleepPlanningDay {
  // Civil calendar ordinal, NOT elapsed seconds / 86400. Supplied by Edge.
  final int day;
  final double? sleepSec, acceptedNapSec;
  final bool complete;
  const SleepPlanningDay(this.day,
      {this.sleepSec, this.acceptedNapSec, this.complete = false});

  bool get usable =>
      complete &&
      sleepSec != null &&
      sleepSec!.isFinite &&
      sleepSec! > 0 &&
      sleepSec! <= 24 * 3600;
  bool get knownNaps =>
      acceptedNapSec != null &&
      acceptedNapSec!.isFinite &&
      acceptedNapSec! >= 0 &&
      acceptedNapSec! <= 24 * 3600;
}

class SleepPlanningReference {
  final double seconds;
  final int fromDay, throughDay, nights;
  const SleepPlanningReference(
      this.seconds, this.fromDay, this.throughDay, this.nights);
  static SleepPlanningReference? fromJson(Object? value) {
    if (value is! Map || value['source'] != 'observed_longer_sleep')
      return null;
    final seconds = value['reference_sec'], from = value['from_day'];
    final through = value['through_day'], nights = value['nights'];
    if (seconds is! num ||
        !seconds.isFinite ||
        seconds <= 0 ||
        seconds > 24 * 3600 ||
        from is! int ||
        through is! int ||
        through - from != 27 ||
        nights is! int ||
        nights < 21 ||
        nights > 28) {
      return null;
    }
    return SleepPlanningReference(seconds.toDouble(), from, through, nights);
  }

  Map<String, dynamic> toJson() => {
        'reference_sec': seconds,
        'from_day': fromDay,
        'through_day': throughDay,
        'nights': nights,
        'source': 'observed_longer_sleep',
        'validated': false
      };
}

/// A descriptive, frozen longer-sleep reference, NOT an identified sleep need.
/// No alarm/free-day classification. The 21-of-28 minimum and upper quartile
/// are prototype eligibility/summary choices, not published need coefficients.
/// Recent seven days are excluded so a short night cannot lower its own target.
/// A retained anchor is recomputed after corrections; if its records expired,
/// the caller may keep the saved reference, but must first validate revisions.
Metric<SleepPlanningReference> experimentalSleepReference(
    List<SleepPlanningDay> history, int targetDay,
    {SleepPlanningReference? anchor}) {
  const absent = Metric<SleepPlanningReference>.absent(
      tier: Tier.estimate,
      inputs_used: ['complete_sleep_history'],
      note: 'need_baseline:have=0,need=21');
  if (anchor != null &&
      (!anchor.seconds.isFinite ||
          anchor.seconds <= 0 ||
          anchor.seconds > 24 * 3600 ||
          anchor.throughDay - anchor.fromDay != 27 ||
          anchor.throughDay >= targetDay - 6 ||
          anchor.nights < 21 ||
          anchor.nights > 28)) {
    return absent;
  }
  final byDay = <int, SleepPlanningDay>{};
  for (final d in history) {
    if (byDay.containsKey(d.day)) return absent; // never count a day twice
    byDay[d.day] = d;
  }
  final eligible = byDay.values
      .where(
          (d) => d.usable && d.day < targetDay - 6 && d.day >= targetDay - 90)
      .toList()
    ..sort((a, b) => a.day.compareTo(b.day));
  int? from = anchor?.fromDay;
  int? through = anchor?.throughDay;
  if (anchor != null && !byDay.keys.any((d) => d >= from! && d <= through!)) {
    return Metric(
        value: anchor,
        confidence: 0.1,
        tier: Tier.estimate,
        inputs_used: const ['retained_sleep_reference'],
        note:
            'Retained observed reference; not validated biological sleep need');
  }
  if (from == null || through == null) {
    for (final d in eligible) {
      final count =
          eligible.where((v) => v.day >= d.day && v.day < d.day + 28).length;
      if (count >= 21) {
        from = d.day;
        through = d.day + 27;
        break;
      }
    }
  }
  if (from == null || through == null) return absent;
  final values = <double>[
    for (final d in byDay.values)
      if (d.usable && d.day >= from && d.day <= through) d.sleepSec!
  ];
  if (values.length < 21 || through >= targetDay - 6) return absent;
  return Metric(
      value: SleepPlanningReference(
          percentile(values, 75)!, from, through, values.length),
      confidence: 0.2 * (values.length / 28).clamp(0, 1),
      tier: Tier.estimate,
      inputs_used: const ['complete_sleep_history'],
      note:
          'Observed upper-quartile duration, not validated biological sleep need');
}

class SleepPlanningPolicy {
  final double dailyRetention, adjustmentFraction, maxAdjustmentSec;
  // Explicit prototype assumptions, not inferred physiological repayment.
  const SleepPlanningPolicy(
      {this.dailyRetention = 0.85,
      this.adjustmentFraction = 0.25,
      this.maxAdjustmentSec = 3600});
  bool get valid =>
      dailyRetention.isFinite &&
      dailyRetention > 0 &&
      dailyRetention <= 1 &&
      adjustmentFraction.isFinite &&
      adjustmentFraction >= 0 &&
      adjustmentFraction <= 1 &&
      maxAdjustmentSec.isFinite &&
      maxAdjustmentSec >= 0;
}

class SleepPlanningResult {
  final int? latestSleepDay;
  final double? latestShortfallSec, recentShortfallSec, nextSleepSec;
  final double? shortfallAdjustmentSec, napCreditSec, strainBonusSec;
  final int missingDays;
  final String status;
  const SleepPlanningResult(
      {this.latestSleepDay,
      this.latestShortfallSec,
      this.recentShortfallSec,
      this.nextSleepSec,
      this.shortfallAdjustmentSec,
      this.napCreditSec,
      this.strainBonusSec,
      this.missingDays = 0,
      required this.status});
  Map<String, dynamic> toJson() => {
        'status': status,
        'latest_sleep_day': latestSleepDay,
        'latest_shortfall_sec': latestShortfallSec,
        'recent_shortfall_sec': recentShortfallSec,
        'need_sec': nextSleepSec,
        'shortfall_adjustment_sec': shortfallAdjustmentSec,
        'nap_credit_sec': napCreditSec,
        'strain_bonus_sec': strainBonusSec,
        'missing_days': missingDays,
        'model': 'observed_sleep_plan_v1'
      };
}

/// Planning relative to a measured longer-sleep reference. This deliberately
/// does NOT establish individual biological need or claim WHOOP's coefficients.
/// Partial repayment has no validated universal dose: Banks et al. (2010),
/// doi:10.1093/sleep/33.8.1013. The policy is disclosed alongside every result.
/// A shortfall is a comparison to this reference, not a clinical debt measure.
Metric<SleepPlanningResult> observedSleepPlan(
  List<SleepPlanningDay> history, {
  required int targetDay,
  int? currentDay,
  required SleepPlanningReference? reference,
  double? dayStrain,
  SleepPlanningPolicy policy = const SleepPlanningPolicy(),
}) {
  final validReference = reference == null
      ? null
      : SleepPlanningReference.fromJson(reference.toJson());
  final result = _buildSleepPlan(history,
      targetDay: targetDay,
      currentDay: currentDay,
      referenceSec: validReference?.seconds,
      dayStrain: dayStrain,
      policy: policy);
  return Metric(
      value: result,
      confidence: validReference == null ? 0 : 0.2,
      tier: Tier.estimate,
      inputs_used: const [
        'observed_longer_sleep',
        'complete_sleep_history',
        'accepted_naps',
        'day_strain'
      ],
      note:
          'Observed-reference planning estimate; not measured biological need. '
          'Retention, scaling and cap are engineering assumptions.');
}

/// Rebuild from unique accepted records, never append to a debt balance.
/// Prior-day naps credit the following completed night; target-day naps credit
/// only the NEXT sleep. Thus a nap cannot appear on both sides of this plan.
/// Missing dates/naps stay unknown. A recent missing day withholds the total
/// and recommendation, but not a genuinely observed latest-night shortfall.
SleepPlanningResult experimentalSleepPlan(
  List<SleepPlanningDay> history, {
  required int targetDay,
  int? currentDay,
  required double? referenceSec,
  bool referenceValidated = false,
  double? dayStrain,
  SleepPlanningPolicy policy = const SleepPlanningPolicy(),
}) {
  if (!referenceValidated) {
    return const SleepPlanningResult(status: 'baseline_unvalidated');
  }
  return _buildSleepPlan(history,
      targetDay: targetDay,
      currentDay: currentDay,
      referenceSec: referenceSec,
      dayStrain: dayStrain,
      policy: policy);
}

SleepPlanningResult _buildSleepPlan(
  List<SleepPlanningDay> history, {
  required int targetDay,
  int? currentDay,
  required double? referenceSec,
  double? dayStrain,
  required SleepPlanningPolicy policy,
}) {
  if (referenceSec == null ||
      !referenceSec.isFinite ||
      referenceSec <= 0 ||
      referenceSec > 24 * 3600 ||
      !policy.valid) {
    return const SleepPlanningResult(status: 'baseline_unavailable');
  }
  final days = <int, SleepPlanningDay>{};
  for (final d in history) {
    if (days.containsKey(d.day))
      return const SleepPlanningResult(status: 'duplicate_day');
    days[d.day] = d;
  }
  final latest = days[targetDay];
  final latestShortfall = latest != null && latest.usable
      ? math.max(0.0, referenceSec - latest.sleepSec!)
      : null;
  var missing = 0;
  var shortfall = 0.0;
  for (var day = targetDay - 6; day <= targetDay; day++) {
    final night = days[day];
    final previous = days[day - 1];
    if (night == null ||
        !night.usable ||
        previous == null ||
        !previous.knownNaps) {
      missing++;
      continue;
    }
    // Surplus may reduce an existing balance, never bank sleep against a
    // later short night. Rebuilt from calendar records, not a mutable ledger.
    shortfall = math.max(
        0.0,
        shortfall * policy.dailyRetention +
            referenceSec -
            night.sleepSec! -
            previous.acceptedNapSec!);
  }
  final today = days[currentDay ?? targetDay];
  final naps = today != null && today.knownNaps ? today.acceptedNapSec : null;
  final strain = dayStrain != null &&
          dayStrain.isFinite &&
          dayStrain >= 0 &&
          dayStrain <= 21
      ? dayStrain / 21 * 45 * 60
      : null; // existing Edge planning policy
  if (missing > 0 || naps == null || strain == null) {
    return SleepPlanningResult(
        latestSleepDay: latest?.day,
        latestShortfallSec: latestShortfall,
        missingDays: missing,
        status: 'insufficient_recent_data');
  }
  final adjustment =
      math.min(policy.maxAdjustmentSec, shortfall * policy.adjustmentFraction);
  // Same 6–11 h planning bounds as the existing coaching policy, disclosed.
  final noNap =
      (referenceSec + adjustment + strain).clamp(6 * 3600.0, 11 * 3600.0);
  final next = (referenceSec + adjustment + strain - naps)
      .clamp(6 * 3600.0, 11 * 3600.0);
  return SleepPlanningResult(
      latestSleepDay: latest?.day,
      latestShortfallSec: latestShortfall,
      recentShortfallSec: shortfall,
      nextSleepSec: next,
      shortfallAdjustmentSec:
          next - (referenceSec + strain - naps).clamp(6 * 3600.0, 11 * 3600.0),
      napCreditSec: noNap - next,
      strainBonusSec: next -
          (referenceSec + adjustment - naps).clamp(6 * 3600.0, 11 * 3600.0),
      status: 'estimate');
}
