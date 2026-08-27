# WindowPet — Measured Energy

Measured 2026-08-19 on Apple M5 Pro, macOS 27.0, release build.
Method: self-reported `getrusage` CPU over 15s deterministic phases
(driven by the same debug hooks as the test rig); RSS via `task_info`.
Overall: **PASS**

| Phase | What | CPU | Budget | RSS |
|---|---|---|---|---|
| sleep | pet asleep, nothing moving | **0.24%** | ≤ 0.3% (hard) | 47.7 MB |
| perched | awake on a title bar, breathing/blinking | 0.42% | ≤ 1.0% (soft) | 47.6 MB |
| active | continuous planned travel between two windows | **1.04%** | ≤ 3.0% (hard) | 48.5 MB |

RSS budget: ≤ 80 MB (hard).

Reproduce: `Tools/energy-bench.sh [secondsPerPhase]` — exits nonzero on any
hard-budget violation (CI-ready). External cross-check:
`sudo powermetrics --samplers tasks -i 5000 -n 3 | grep WindowPet`.

## Wake word: still unmeasured (2026-08-20)

The published numbers above are the wake-word-off configuration.

An attempt to measure wake-word-on was **inconclusive and is not published**.
Sampling the installed app with the setting on and off gave overlapping CPU
(0.7% to 2.1% either way, noise dominating at this sample size) and about
2 to 3 MB more resident memory with it on.

The reason the CPU delta is meaningless: running the installed, signed binary
with `--diag` reports `voice permissions = speech not asked yet, mic not asked
yet`. Speech recognition never actually started, so nothing was measured. A
real number needs Microphone and Speech Recognition granted to
`/Applications/WindowPet.app` first (the prompts fire the first time the wake
word tries to listen).

Note when re-measuring: run the **installed** binary, not `swift run`. TCC
permissions and preferences are keyed to the signing identity and bundle, so
the development binary reports its own (empty) permissions and its own
defaults domain, which also hides the configured API key.
