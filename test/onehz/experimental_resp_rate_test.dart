import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:openstrap_analytics/onehz.dart';

({List<double> rr, List<double> ts}) signal({
  double start = 0,
  double seconds = 7200,
  double rate = 12.5,
  bool uniform = false,
  int? noiseSeed,
}) {
  final rr = <double>[], ts = <double>[];
  final random = math.Random(noiseSeed ?? 7);
  var t = 0.0;
  while (t < seconds) {
    // A variable sample cadence helps distinguish the true line from an alias
    // at low heart rate; an exactly regular cadence must remain ambiguous.
    ts.add((start + t) * 1000);
    rr.add(
      noiseSeed != null
          ? 1300 + 50 * (random.nextDouble() - 0.5)
          : 1360 + 50 * math.cos(2 * math.pi * rate * t / 60),
    );
    t += uniform ? 60 / 44 : 60 / (44 + 4 * math.sin(2 * math.pi * t / 90));
  }
  return (rr: rr, ts: ts);
}

void main() {
  ExperimentalRespResult estimate(
    ({List<double> rr, List<double> ts}) s, {
    double start = 0,
    double end = 7200,
  }) =>
      experimentalRsaRespRate(
        s.rr,
        s.ts,
        sleepStartMs: start * 1000,
        sleepEndMs: end * 1000,
      );

  test('low-heart-rate signal resolves without the blanket 48 bpm cutoff', () {
    final r = estimate(signal());
    expect(r.brpm, closeTo(12.5, 0.1));
    expect(r.coveredSeconds, greaterThanOrEqualTo(1800));
    expect(r.quarters, greaterThanOrEqualTo(3));
    expect(r.toJson()['confidence_is_not_calibrated'], true);
  });
  test('uniform sample-time aliases remain absent', () {
    final r = estimate(signal(uniform: true));
    expect(r.brpm, isNull);
    expect(r.windows.any((w) => w.status == 'ambiguous_fresh_signal'), true);
  });
  test('fresh evidence supports an abrupt breathing increase', () {
    final s = signal();
    final rr = [
      for (var i = 0; i < s.ts.length; i++)
        1360 +
            50 *
                math.cos(2 *
                    math.pi *
                    (s.ts[i] < 3600000 ? 12.5 : 20) *
                    s.ts[i] /
                    60000)
    ];
    final r = estimate((rr: rr, ts: s.ts));
    final before = r.windows.where((w) => w.endSec <= 3600 && w.brpm != null);
    final after = r.windows.where((w) => w.startSec >= 3600 && w.brpm != null);
    expect(before, isNotEmpty);
    expect(after, isNotEmpty);
    expect(before.every((w) => (w.brpm! - 12.5).abs() <= 0.1), true);
    expect(after.every((w) => (w.brpm! - 20).abs() <= 0.1), true);
  });
  test('noise, empty, invalid, flat and short sleep remain absent', () {
    expect(estimate(signal(noiseSeed: 42)).brpm, isNull);
    expect(estimate((rr: [], ts: [])).brpm, isNull);
    final s = signal(seconds: 1200);
    expect(estimate(s, end: 1200).brpm, isNull);
    expect(
      estimate((rr: List.filled(s.rr.length, 1300), ts: s.ts)).brpm,
      isNull,
    );
    expect(
      estimate((rr: [double.nan, ...s.rr.skip(1)], ts: s.ts)).brpm,
      isNull,
    );
    expect(estimate((rr: s.rr, ts: s.ts.reversed.toList())).brpm, isNull);
  });
  test(
    'absolute grid includes exact final window and survives epoch translation',
    () {
      final s = signal();
      final a = estimate(s);
      const epoch = 1791244800.0; // exactly on the 150-second grid
      final b = estimate(
        (rr: s.rr, ts: [for (final t in s.ts) t + epoch * 1000]),
        start: epoch,
        end: epoch + 7200,
      );
      expect(a.windows.last.endSec, 7200);
      expect(b.windows.last.endSec, epoch + 7200);
      expect(b.brpm, a.brpm);
      expect(b.windows.length, a.windows.length);
      expect(estimate(s, start: 60, end: 7140).brpm, a.brpm);
    },
  );
  test('a recording confined to one part of the night cannot represent it', () {
    final r = estimate(signal(seconds: 2400), end: 14400);
    expect(r.coveredSeconds, greaterThanOrEqualTo(1800));
    expect(r.brpm, isNull);
  });
  test('missing windows stay empty and split temporal runs', () {
    final s = signal();
    final keep = [
      for (var i = 0; i < s.ts.length; i++)
        if (s.ts[i] < 2400000 || s.ts[i] >= 4800000) i,
    ];
    final r = estimate((
      rr: [for (final i in keep) s.rr[i]],
      ts: [for (final i in keep) s.ts[i]],
    ));
    final missing = r.windows.where(
      (w) => w.startSec >= 2400 && w.endSec <= 4800,
    );
    expect(missing, isNotEmpty);
    expect(missing.every((w) => w.brpm == null && w.contextPeak == null), true);
  });
  test(
    'correction retains input indices without changing its existing clock',
    () {
      final rr = <double>[1000.0, 1000, 200, 1000, 1000, 1000];
      final ts = <double>[
        1000000.0,
        1001000,
        1002000,
        1003000,
        1004000,
        1005000
      ];
      final r = correctRr(rr, rrTsMs: ts);
      expect(r.nnSourceIndices.length, r.nn.length);
      expect(r.nnSourceIndices, orderedEquals([0, 1, 2, 3, 4, 5]));
      expect(r.nnTimesMs, orderedEquals([1000, 2000, 2200, 3200, 4200, 5200]));
    },
  );
}
