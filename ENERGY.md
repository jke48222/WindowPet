# WindowPet: Measured Energy

Measured 2026-08-27 on Apple M5 Pro, macOS 27.0, release build.
Method: self-reported `getrusage` CPU over 15s deterministic phases
(driven by the same debug hooks as the test rig); RSS via `task_info`.
Overall: **PASS**

| Phase | What | CPU | Budget | RSS |
|---|---|---|---|---|
| sleep | pet asleep, nothing moving | **0.25%** | ≤ 0.3% (hard) | 44.1 MB |
| perched | awake on a title bar, breathing/blinking | 0.44% | ≤ 1.0% (soft) | 44.0 MB |
| active | continuous planned travel between two windows | **1.04%** | ≤ 3.0% (hard) | 44.9 MB |

RSS budget: ≤ 80 MB (hard).

Measured again on 2026-08-27 after the clipboard history was added, since that
introduced a 1 Hz poll into the idle path. The numbers are unchanged within
noise: sleep 0.24% to 0.25%, perched 0.42% to 0.44%, active 1.04% both times.

One caveat worth writing down, because it cost two false alarms: **a run taken
while the machine is busy is not a measurement.** The same build measured
0.56% sleep and 1.30% perched, a hard-budget failure, while release builds were
compiling alongside it, and 0.25% and 0.44% ninety seconds later with the
machine settled. Quit everything and check `uptime` before believing a
regression here.

Reproduce: `Tools/energy-bench.sh [secondsPerPhase]`, which exits nonzero on
any hard-budget violation (CI-ready). External cross-check:
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
