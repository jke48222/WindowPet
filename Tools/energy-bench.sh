#!/bin/bash
# WindowPet energy benchmark: runs the app's self-instrumenting --bench mode
# (getrusage-based CPU per phase), asserts the dossier budgets, and publishes
# ENERGY.md. External validation (needs sudo, run manually):
#   sudo powermetrics --samplers tasks -i 5000 -n 3 | grep WindowPet
set -euo pipefail
cd "$(dirname "$0")/.."
PHASE="${1:-20}"
swift build -c release >/dev/null
pkill -x WindowPet 2>/dev/null && sleep 1 || true
LOG=$(mktemp)
set +e
.build/release/WindowPet --bench "$PHASE" | tee "$LOG"
RC=${PIPESTATUS[0]}
set -e

CHIP=$(sysctl -n machdep.cpu.brand_string)
OSV=$(sw_vers -productVersion)
DATE=$(date +%Y-%m-%d)
row() { grep "BENCH RESULT $1 " "$LOG" | sed -E 's/.*cpu=([0-9.]+) rss=([0-9.]+)/\1 \2/'; }
P=($(row perched)); S=($(row sleep)); A=($(row active))
VERDICT=$(grep "BENCH DONE" "$LOG" | awk '{print $3}')

cat > ENERGY.md <<MD
# WindowPet: Measured Energy

Measured $DATE on $CHIP, macOS $OSV, release build.
Method: self-reported \`getrusage\` CPU over ${PHASE}s deterministic phases
(driven by the same debug hooks as the test rig); RSS via \`task_info\`.
Overall: **$VERDICT**

| Phase | What | CPU | Budget | RSS |
|---|---|---|---|---|
| sleep | pet asleep, nothing moving | **${S[0]:-?}%** | ≤ 0.3% (hard) | ${S[1]:-?} MB |
| perched | awake on a title bar, breathing/blinking | ${P[0]:-?}% | ≤ 1.0% (soft) | ${P[1]:-?} MB |
| active | continuous planned travel between two windows | **${A[0]:-?}%** | ≤ 3.0% (hard) | ${A[1]:-?} MB |

RSS budget: ≤ 80 MB (hard).

Reproduce: \`Tools/energy-bench.sh [secondsPerPhase]\`, which exits nonzero on
any hard-budget violation (CI-ready). External cross-check:
\`sudo powermetrics --samplers tasks -i 5000 -n 3 | grep WindowPet\`.
MD

# The hand-written half lives in Tools/energy-notes.md and is appended after
# the generated block. It used to live in ENERGY.md itself, where every bench
# run destroyed it.
if [ -f Tools/energy-notes.md ]; then
  printf '\n' >> ENERGY.md
  sed '/^<!--/,/-->$/d' Tools/energy-notes.md | sed '/./,$!d' >> ENERGY.md
  echo "---- ENERGY.md written (generated block + Tools/energy-notes.md) ----"
else
  echo "---- ENERGY.md written ----"
fi
exit $RC
