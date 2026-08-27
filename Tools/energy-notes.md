<!-- Hand-written notes appended below the generated block by
     Tools/energy-bench.sh. Edit this file, not ENERGY.md: ENERGY.md is
     regenerated on every bench run and anything written there directly is
     destroyed by the next one. -->

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

## Measure on a quiet machine (2026-08-27)

A run taken while builds are compiling is not a measurement. The same build
reported 0.56% sleep and 1.30% perched, both budget failures, with release
builds running alongside it, and 0.25% and 0.44% ninety seconds later with the
machine settled. Check `uptime` first; the test rig's window-choreography
phases fail the same way and for the same reason.
