// Personal-fork experiment: port of stable_methods.py, frozen 2026-10-05.
// SHA256 a25bfbc74c1a15bcc7e6e5052ce6e0bb2c7a1ca27ef6a25f3e094593d396557a.
// Original spectral/tracking adaptation inspired by Pirhonen/Vehkaoja 2020,
// doi:10.1016/j.bspc.2020.101887. Not their published algorithm; no inherited
// accuracy claim. Confidence is uncalibrated. Never use as a readiness input.
import 'dart:math' as math;

import '../util.dart' show lombScargle, median;

const _bins = 341;
const _windowSec = 300.0;
const _stepSec = 150.0;
const _minExplained = 0.15;
const _maxCompetitor = 0.8;

class ExperimentalRespWindow {
  final double startSec, endSec;
  double? brpm, freshPeak, strength, competitorRatio, contextPeak, modeMass;
  String status = 'thin';
  List<double>? _evidence;
  ExperimentalRespWindow(this.startSec, this.endSec);

  Map<String, dynamic> toJson() => {
    'start_sec': startSec,
    'end_sec': endSec,
    'brpm': brpm,
    'status': status,
    'fresh_peak': freshPeak,
    'strength': strength,
    'competitor_ratio': competitorRatio,
    'context_peak': contextPeak,
    'mode_mass': modeMass,
  };
}

class ExperimentalRespResult {
  final double? brpm;
  final String status;
  final double coverage, coveredSeconds;
  final int quarters;
  final List<ExperimentalRespWindow> windows;
  const ExperimentalRespResult({
    this.brpm,
    required this.status,
    this.coverage = 0,
    this.coveredSeconds = 0,
    this.quarters = 0,
    this.windows = const [],
  });

  Map<String, dynamic> toJson() => {
    'brpm': brpm,
    'status': status,
    'coverage': coverage,
    'covered_seconds': coveredSeconds,
    'quarters': quarters,
    'windows': windows.map((w) => w.toJson()).toList(),
    'experimental': true,
    'confidence_is_not_calibrated': true,
    'timing': 'reported_record_anchors',
    'window_grid': 'epoch_150_seconds',
  };
}

/// Cleaned NN intervals at their ORIGINAL reported/held epoch timestamps (ms).
/// Do not supply a cumulative RR clock: the prototype was validated against
/// record anchors. Only fully contained five-minute sleep windows are used.
/// No previous night, population breathing baseline, gap filling, or WHOOP
/// value enters this estimator. Missing/weak/competing evidence stays absent.
ExperimentalRespResult experimentalRsaRespRate(
  List<double> nn,
  List<double> epochTimesMs, {
  required double sleepStartMs,
  required double sleepEndMs,
}) {
  const invalid = ExperimentalRespResult(status: 'missing_or_invalid');
  if (nn.length < 30 ||
      nn.length != epochTimesMs.length ||
      !sleepStartMs.isFinite ||
      !sleepEndMs.isFinite ||
      sleepEndMs <= sleepStartMs)
    return invalid;
  for (var i = 0; i < nn.length; i++) {
    if (!nn[i].isFinite ||
        nn[i] <= 0 ||
        !epochTimesMs[i].isFinite ||
        (i > 0 && epochTimesMs[i] < epochTimesMs[i - 1]))
      return invalid;
  }
  if (epochTimesMs.last <= epochTimesMs.first) return invalid;
  final startSec = sleepStartMs / 1000, endSec = sleepEndMs / 1000;
  final first = (startSec / _stepSec).ceil() * _stepSec;
  final count = math.max(
    0,
    ((endSec - _windowSec - first) / _stepSec).floor() + 1,
  );
  final rows = <ExperimentalRespWindow>[];
  // Use the existing native-time LS implementation, rescaled to SciPy's
  // precenter=True, normalize=True power (fraction of centered sum of squares).
  final grid = List<double>.generate(_bins, (i) => (6 + i * 0.1) / 60);
  var lo = 0, hi = 0;
  for (var k = 0; k < count; k++) {
    final a = first + k * _stepSec, b = a + _windowSec;
    final row = ExperimentalRespWindow(a, b);
    rows.add(row);
    while (lo < nn.length && epochTimesMs[lo] / 1000 < a) {
      lo++;
    }
    hi = math.max(lo, hi);
    while (hi < nn.length && epochTimesMs[hi] / 1000 < b) {
      hi++;
    }
    if (hi - lo < 30) continue;
    final t = [for (var i = lo; i < hi; i++) epochTimesMs[i] / 1000 - a];
    final x = nn.sublist(lo, hi);
    final span = t.last - t.first;
    if (span < _windowSec * 0.8) continue;
    final steps = [for (var i = 1; i < t.length; i++) t[i] - t[i - 1]];
    final positive = steps.where((v) => v > 0).toList();
    if (positive.length < 20) continue;
    final cap = 2 * median(positive)!;
    final observed = steps.fold<double>(0, (s, v) => s + math.min(v, cap));
    final elapsedWeight = (observed / _windowSec).clamp(0.0, 1.0);
    if (elapsedWeight < 0.5) {
      row.status = 'low_elapsed_coverage';
      continue;
    }
    final mean = x.reduce((a, b) => a + b) / x.length;
    final ss = x.fold<double>(0, (s, v) => s + (v - mean) * (v - mean));
    if (math.sqrt(ss / x.length) <= 1e-8) {
      row.status = 'flat';
      continue;
    }
    final ls = lombScargle(t, x, grid);
    if (ls == null) continue;
    final densityScale = 2 * span / (x.length - 1);
    final power = [
      for (final p in ls.spectrum)
        (2 * p.psd / (densityScale * ss)).clamp(0.0, 1.0),
    ];
    final best = _argmax(power);
    var competitor = 0.0;
    for (var i = 0; i < _bins; i++) {
      if ((i - best).abs() > 10) competitor = math.max(competitor, power[i]);
    }
    row.freshPeak = 6 + best * 0.1;
    row.strength = power[best];
    row.competitorRatio = competitor / math.max(power[best], 1e-12);
    if (best == 0 || best == _bins - 1 || power[best] < 0.02) {
      row.status = 'weak_or_edge';
      continue;
    }
    final weight =
        elapsedWeight * (power[best] / _minExplained).clamp(0.0, 1.0);
    row._evidence = _normalized([
      for (final p in power) math.exp(30 * weight * (p - power[best])),
    ]);
    row.status = 'evidence';
  }
  // A rejected/missing spectrum ends a run. Context never bridges that gap.
  var i = 0;
  while (i < rows.length) {
    if (rows[i]._evidence == null) {
      i++;
      continue;
    }
    final begin = i;
    while (i < rows.length && rows[i]._evidence != null) {
      i++;
    }
    _track(rows.sublist(begin, i));
  }
  final accepted = rows.where((w) => w.brpm != null).toList();
  var covered = 0.0, previousEnd = double.negativeInfinity;
  final quarters = <int>{};
  for (final w in accepted) {
    covered += math.max(0, w.endSec - math.max(w.startSec, previousEnd));
    previousEnd = math.max(previousEnd, w.endSec);
    quarters.add(
      math.min(
        3,
        (4 * ((w.startSec + w.endSec) / 2 - startSec) / (endSec - startSec))
            .floor(),
      ),
    );
  }
  for (final w in rows) {
    w._evidence = null;
  }
  final enough = covered >= 1800 && quarters.length >= 3;
  return ExperimentalRespResult(
    brpm: enough ? median([for (final w in accepted) w.brpm!]) : null,
    status: enough ? 'research_estimate' : 'insufficient_representative_signal',
    coverage: covered / (endSec - startSec),
    coveredSeconds: covered,
    quarters: quarters.length,
    windows: rows,
  );
}

int _argmax(List<double> p) {
  var best = 0;
  for (var i = 1; i < p.length; i++) {
    if (p[i] > p[best]) best = i;
  }
  return best;
}

List<double> _normalized(List<double> p) {
  final sum = p.reduce((a, b) => a + b);
  return [for (final v in p) v / sum];
}

// scipy.ndimage.gaussian_filter1d(sigma=10, truncate=4, mode='nearest'),
// then the frozen 95% local / 5% uniform transition mixture.
final _kernel = _normalized([
  for (var i = -40; i <= 40; i++) math.exp(-0.5 * i * i / 100),
]);
List<double> _transition(List<double> p) {
  final local = List<double>.filled(_bins, 0);
  for (var i = 0; i < _bins; i++) {
    for (var j = -40; j <= 40; j++) {
      local[i] += _kernel[j + 40] * p[(i + j).clamp(0, _bins - 1)];
    }
  }
  return [for (final v in _normalized(local)) 0.95 * v + 0.05 / _bins];
}

void _track(List<ExperimentalRespWindow> run) {
  final forwards = <List<double>>[], backwards = <List<double>>[];
  var p = List<double>.filled(_bins, 1 / _bins);
  for (final row in run) {
    p = _transition(p);
    p = _normalized([for (var i = 0; i < _bins; i++) p[i] * row._evidence![i]]);
    forwards.add(p);
  }
  p = List<double>.filled(_bins, 1 / _bins);
  for (final row in run.reversed) {
    backwards.add(p);
    p = _normalized([for (var i = 0; i < _bins; i++) p[i] * row._evidence![i]]);
    p = _transition(p);
  }
  for (var r = 0; r < run.length; r++) {
    final row = run[r],
        forward = forwards[r],
        backward = backwards[run.length - 1 - r];
    final posterior = _normalized([
      for (var i = 0; i < _bins; i++) forward[i] * backward[i],
    ]);
    final best = _argmax(posterior);
    var mass = 0.0;
    for (var i = 0; i < _bins; i++) {
      if ((i - best).abs() <= 10) mass += posterior[i];
    }
    row.contextPeak = 6 + best * 0.1;
    row.modeMass = mass;
    if (row.strength! < _minExplained) {
      row.status = 'weak_context_only';
    } else if (row.competitorRatio! >= _maxCompetitor) {
      row.status = 'ambiguous_fresh_signal';
    } else if (mass < 0.8) {
      row.status = 'ambiguous_tracked_modes';
    } else if ((row.contextPeak! - row.freshPeak!).abs() > 1) {
      row.status = 'tracked_disagrees_with_fresh_signal';
    } else {
      row.brpm = row.contextPeak;
      row.status = 'accepted_research';
    }
  }
}
