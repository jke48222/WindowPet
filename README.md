# WindowPet

A macOS desktop creature that is genuinely aware of real windows. It sits on
title bars, rides windows as you drag them, and (eventually) falls when you
close one and reacts to specific apps.

**Status: Stage 2 complete** — the pet is a physical, touchable creature in a
world made of window tops, screen floors, and screen-edge walls: it
spawn-drops onto your frontmost window, rides it as you drag, walks along
title bars (sometimes strolling right off the edge), falls with gravity when
its window closes or gets covered, lands with a squash, leaps ballistically to
whatever app you switch to, climbs the screen edges and backflips off, and —
because the overlay is click-through except over actual creature pixels — you
can boop it with a click, or pick it up with the mouse and throw it. 16
procedurally generated animation frames. Still zero permission prompts.

**The character is Rusty**, a mid-century tin toy robot: teal tin body,
silver faceplate, cyan LED eyes (alarm-orange while falling, powered-off
slits when blinking or mid-landing-squash), chest dial, rivets, and an
antenna bobble that sways with the walk gait. Ten candidate designs live in
`Tools/chargen.swift`; the picker sheets came from `Tools/chargen.swift` and
`Tools/doggen.swift`.

Research dossier: `../PASS-2-macos-software-research.md`, PROJECT 9.

## Run it

```bash
swift run -c release WindowPet
```

Quit via the 🐾 status-bar menu (also shows which app the pet is riding), or
`pkill -x WindowPet`. Diagnostics:

```bash
swift run WindowPet -- --diag 6      # verbose target/tracking log for 6s, then exits
swift run WindowPet -- --testrig     # self-driving e2e check (opens+animates its own window), exits 0/1
swift test                           # geometry + cadence unit tests
```

Regenerate the placeholder sprite (or just replace `Sources/WindowPet/Resources/pet.png`
with real art — the app only loads the PNG):

```bash
swift run PetGen Sources/WindowPet/Resources/pet.png
```

## How the creature works (stage 2)

- **Terrain** ([Terrain.swift](Sources/WindowPetCore/Terrain.swift)): every
  on-screen window's top edge, split into exposed segments by z-order
  occlusion, plus screen floors. The window layout is a platformer level.
- **Physics** ([PetPhysics.swift](Sources/WindowPetCore/PetPhysics.swift)):
  gravity 2400 pt/s², trapezoidal integration, ballistic leap solver. Pure
  functions, unit-tested against the same integrator the engine runs.
- **FSM** ([PetEngine.swift](Sources/WindowPet/PetEngine.swift)):
  falling → landing → standing → walking, with leaps on app activation
  (debounced 400 ms so cmd-tab spam doesn't yank the pet). Eviction rules:
  window closed/minimized → fall; stand-point occluded (1 Hz audit) → fall.
- **Presentation** ([OverlayStage.swift](Sources/WindowPet/OverlayStage.swift)):
  one screen-sized overlay panel per display; the sprite is a CALayer moved
  GPU-side (a Core Animation transaction, not a window-server geometry
  change) — this is what brought active-state CPU inside the energy budget.
  Wall climbs rotate the layer ±90°.
- **Touch**: panels are click-through except over creature pixels — a global
  mouse-moved monitor (no TCC permission needed) plus a per-frame 32×32 alpha
  mask open the "hole" only when the cursor is over the pet. Quick click =
  boop (happy squash, never relocates it); drag = pick up (physics pauses,
  event-driven); release = ballistic throw with the cursor's velocity.
- **Clocks**: CADisplayLink only while something moves — 60 fps for
  falls/leaps/drag-riding, 30 fps for walks/climbs, paused entirely when
  settled AND while held by the mouse. A 0.5 s ambient timer breathes/blinks
  while perched. The rig asserts the link is paused after settling.

## Architecture (two-tier window model)

- **Tier 1 (built): `CGWindowListCopyWindowInfo`** — bounds + z-order for every
  window, zero permissions. Physics/geometry floor. Polled adaptively:
  60 Hz only while the target frame is actually changing, 10 Hz settled,
  4 Hz after 20 s of stillness, 2 Hz with no target. Single-window queries
  (`.optionIncludingWindow`) in the hot loop; full-list queries only on
  retarget and a 1 Hz topmost audit. Retargets are event-driven
  (`NSWorkspace` activation / Space-change notifications), and everything
  suspends on sleep/screen-lock.
- **Tier 2 (next): `AXUIElement`/`AXObserver`** — event-driven frame-accurate
  updates plus semantics, per-app, with the full hardening matrix (messaging
  timeouts, Electron `AXManualAccessibility`, crash guards). Personality layer.
  If AX fails for an app, Tier 1 still places the pet correctly.

**Permission invariant:** we never read `kCGWindowName` / `kCGWindowOwnerName`
(they trip the Screen Recording prompt on macOS 15+). Bounds, layer, PID, and
window number are free. `grep -rn "kCGWindowOwnerName" Sources/` must only ever
hit the comment in `Tier1.swift`. App identity for the status item comes from
`NSRunningApplication` (local, unrestricted).

The overlay is a borderless, non-activating `NSPanel` (`.floating`,
`canJoinAllSpaces + fullScreenAuxiliary + stationary`, click-through) — it can
never steal focus or eat a click.

Layout: `WindowPetCore` (pure geometry/cadence math, headless-testable) ·
`WindowPet` (app) · `PetGen` (sprite generator). The CG↔AppKit coordinate flip
(top-left vs bottom-left origin, anchored to `NSScreen.screens[0]`) lives in
`Geometry.swift` with unit tests — it is the classic bug in this domain.

## Measured energy (2026-08-19, M5 Pro, release build, stage 2 final)

| State | CPU | Notes |
|---|---|---|
| Perched, still (incl. breathing) | 0.0–0.5% | budget <0.3% — met at rest; breathing ticks show ≤0.5 in 2 s samples; tune in S7 |
| Walk bursts (1.5–3.5 s, every 4–9 s) | **0.9–2.8%** | budget <3% ✓ — was ~4–5% when the sprite was its own moving window; GPU layer moves fixed it |
| Held by the mouse | ~0% | display link paused, purely event-driven |
| Memory | ~48 MB RSS | budget <80 MB ✓ |

Re-measure: `top -pid $(pgrep -x WindowPet) -l 6 -s 2 -stats cpu,mem,command`
or (needs sudo) `sudo powermetrics --samplers tasks -i 5000 -n 3 | grep WindowPet`.

## Verification

- `swift test` — 16 tests: coordinate math, terrain occlusion/segmentation,
  landing selection, gravity integration, leap-solver accuracy (integrated
  numerically to ≤1.5 pt), rate-policy bands.
- `--testrig` — 50/50, two parts. Window terrain: spawn-fall onto a window,
  close-→-fall-→-land on the window below, walking staying on the edge,
  ballistic leap onto a higher window, occlusion eviction, riding a moving
  window (Δx exact). Floor terrain: sprite-feet/anchor coherence, the alpha
  hole (opens on body pixels, stays shut between the feet and in empty air),
  wall climb with ±90° rotation and leap-off, grab → drag → throw physics,
  and clock quiescence. Rig windows are borderless and the rig runs as an
  accessory app — both deliberate: environments that suppress background
  titled/regular-app windows (fullscreen video, Focus) still map these, so
  the rig runs everywhere. Terrain is restricted to the rig's own PID so the
  live desktop can't perturb it.

## Next (per dossier roadmap)

- S3 — AX Tier 2: `AXObserver` event-driven tracking with the full hardening
  matrix (messaging timeouts, Electron `AXManualAccessibility`, crash
  guards), AX-permission onboarding.
- Then: GOBT behavior engine (S4), Shimeji XML import (S5), app reactions
  (S6), energy CI + `powermetrics` publishing (S7), notarized DMG (S8).
