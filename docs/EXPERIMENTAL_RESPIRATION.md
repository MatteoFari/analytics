# Experimental respiratory rate

Personal-fork port of the frozen `stable_methods.py` prototype from 5 October
2026 (SHA256 `a25bfbc74c1a15bcc7e6e5052ce6e0bb2c7a1ca27ef6a25f3e094593d396557a`).
It is an original research adaptation inspired by Pirhonen / Vehkaoja 2020,
DOI `10.1016/j.bspc.2020.101887`, rather than their published algorithm.

`experimentalRsaRespRate` takes artifact-corrected NN intervals, the original
reported/held epoch timestamps for retained beats, and the sleep bounds. Use
`correctRr(...).nnSourceIndices` to retain those timestamps; do not substitute
the cumulative clock from `nnTimesMs`. Existing correction outputs are unchanged.

The frozen settings are a 6–40 br/min grid in 0.1 increments, fully contained
300-second windows on an absolute 150-second grid, normalized native-time
Lomb–Scargle spectra, and bidirectional tracking with a 95% Gaussian local / 5%
uniform transition. Fresh signal strength, competing peaks, tracked mode mass
and fresh/tracked agreement all gate each displayed window. Missing spectra
split runs. A nightly median needs at least 1,800 seconds of accepted-window
union coverage across at least three sleep quarters. No gaps are filled.

Confidence is uncalibrated. The personal comparison covers nine recorded nights,
eight with WHOOP comparators; it does not establish independent accuracy. One
WHOOP rise was missed. Uniform low-heart-rate aliases remain withheld. Never
use this experiment as a recovery input or export it as a standard measurement.

Edge opts in with `--dart-define=EXPERIMENTAL_RESPIRATION=true` and stores
`resp_rate_experimental` separately. A new analytics commit must be pinned by its
full SHA with the matching Edge algorithm-version bump. The local work is not
published upstream; development builds use an ignored, exact-commit Git override
until the same commit is published to a fork.

Validation: `dart test test/onehz/experimental_resp_rate_test.dart
test/onehz/respiration_test.dart`. Private replay inputs remain outside Git.
