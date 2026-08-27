# WindowPet

A macOS desktop creature that is genuinely aware of real windows. It sits on
title bars, rides windows as you drag them, and falls when you close one.

**Status: 1.0**, a window-aware creature and a full desktop assistant. The
pet is a physical, touchable creature in a
world made of window tops, screen floors, and screen-edge walls: it
spawn-drops onto your frontmost window, rides it as you drag, walks along
title bars (sometimes strolling right off the edge), falls with gravity when
its window closes or gets covered, lands with a squash, leaps ballistically to
whatever app you switch to, climbs the screen edges and backflips off, and , 
because the overlay is click-through except over actual creature pixels, you
can boop it with a click, or pick it up with the mouse and throw it. 16
procedurally generated animation frames. Still zero permission prompts.

Stage 3 added the Accessibility tier: with permission granted (opt-in, from
the status-bar menu, the app never prompts on its own), `AXObserver` events
wake the tracker the instant a window moves instead of waiting for the poll.
Without it, everything above still works exactly the same on Tier 1 alone.

**The character is Rusty**, a mid-century tin toy robot: teal tin body,
silver faceplate, cyan LED eyes (alarm-orange while falling, powered-off
slits when blinking or mid-landing-squash), chest dial, rivets, and an
antenna bobble that sways with the walk gait. Ten candidate designs live in
`Tools/chargen.swift`; the picker sheets came from `Tools/chargen.swift` and
`Tools/doggen.swift`.

## Run it

As an app: `Tools/make-app.sh` builds `build/WindowPet.app` (icns, accessory
Info.plist, SPM resources bundled, hardened-runtime Developer ID signing when
an identity is in the keychain, ad-hoc otherwise, see the script header for
the notarytool commands once enrolled in the Apple Developer Program).

Energy: `Tools/energy-bench.sh` runs the deterministic three-phase benchmark
and publishes [ENERGY.md](ENERGY.md), hard budgets asserted, CI-ready.

From source:

```bash
swift run -c release WindowPet
```

Quit via the status-bar menu (also shows which app the pet is riding), or
`pkill -x WindowPet`. Diagnostics:

```bash
swift run WindowPet -- --diag 6      # verbose target/tracking log for 6s, then exits
swift run WindowPet -- --testrig     # self-driving e2e check (opens+animates its own windows), exits 0/1
swift test                           # geometry, physics, terrain + Tier-2 policy unit tests
```

Regenerate the placeholder sprite (or just replace `Sources/WindowPet/Resources/pet.png`
with real art, the app only loads the PNG):

```bash
swift run PetGen Sources/WindowPet/Resources/pet.png
```

## How the creature works

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
  change), this is what brought active-state CPU inside the energy budget.
  Wall climbs rotate the layer ±90°.
- **Touch**: panels are click-through except over creature pixels, a global
  mouse-moved monitor (no TCC permission needed) plus a per-frame 32×32 alpha
  mask open the "hole" only when the cursor is over the pet. Quick click =
  boop (happy squash, never relocates it); drag = pick up (physics pauses,
  event-driven); release = ballistic throw with the cursor's velocity.
- **Clocks**: CADisplayLink only while something moves, 60 fps for
  falls/leaps/drag-riding, 30 fps for walks/climbs, paused entirely when
  settled AND while held by the mouse. A 0.5 s ambient timer breathes/blinks
  while perched. The rig asserts the link is paused after settling.

## The brain (S4, GOBT behavior layer)

Per the dossier: a BT-ish mode skeleton (Sleeping / Active, with physical
Reacting handled by the engine), **utility scoring** within the active mode,
and a small **GOAP planner**, all pure, seeded, unit-tested code in
`WindowPetCore` ([Behavior.swift](Sources/WindowPetCore/Behavior.swift),
[Planner.swift](Sources/WindowPetCore/Planner.swift)); the engine only
executes directives.

- **Needs vector** (energy / curiosity / attention / boredom) drifts with
  activity and is modified by events: boops and grabs satisfy attention,
  arriving somewhere new satisfies curiosity, idling builds boredom,
  everything spends energy.
- **Utility scoring** picks among sit / stroll / step-off-the-edge / travel /
  climb via softmax with a repeat penalty, so idling never loops one
  behavior, and a curious ignored pet visibly gravitates to your active
  window.
- **Travel is planned, not teleported**: leaps have a planning range (560 pt),
  so far targets route as real itineraries, walk under it, hop the
  mid-height window, leap again. If no ranged route exists, a single direct
  cartoon leap keeps reachability identical to stage 2.
- **Sleep**: exhaustion forces a recharge nap (drooped antenna, green
  charging dial, drifting Zs); boops, grabs, and falls wake it; recharged, it
  wakes on its own. Clocks stay paused while it sleeps, naps are free.

## Assistant (A1–A5)

Summon **Rusty's chat panel** with **Option-Space** (rebindable: menu bar,
Shortcut, then press any combo) or by double-clicking him. One glass panel shared by every input method: typing, push-to-talk,
and the wake word all land in the same rolling transcript. Drag the header
to move it, Esc hides it. Standard editing keys work inside it (Command-C, V, X, A, Z, and
Shift-Z), and Command-C with nothing selected copies Rusty's last answer.
The transcript keeps the full conversation and scrolls; minimizing shrinks
the panel to a small square chip with his face that you click to reopen,
and the close control hides it until you summon it again. The panel, the
speech bubble, and Rusty himself are all dressed by the
active **skin** (menu: Skin): Tinplate (hand-painted cream windup, the
default), Seafoam (the brushed sea-glass look), Midnight, and Sakura. Each
skin recolors the sprite, panel, and bubble together; Shimeji packs still
import for full third-party art. Exact commands run
instantly: `open/launch <app>`, `switch to/focus <app>`, `hide <app>`,
`quit <app>` (asks for a confirming Return), `move window left/right`,
`maximize`, `center window`, `volume up/down`, `mute/unmute`,
`play/next/previous`, `search <query>`, `shortcut <name>`. A grammar match
only wins when its target exists, "open big brother on paramount plus"
isn't an app, so it falls through to the smarter tiers, which route it as
`open_url` to the right website (https-only, validated). The brains also
carry the recent conversation (follow-ups like "now hide it" resolve), can
type into the focused app (`type_text`) and fill the clipboard
(`copy_text`). Window moves glide with an eased slide and report honestly
when Accessibility isn't granted.

**The agentic loop.** With a Claude key set, Rusty doesn't guess a plan up
front: he runs a real tool-use loop, and answers **stream in word by word**
as he writes them. Claude calls a tool, *sees the actual
result*, and decides the next step, up to eight iterations, until the job
is done. That is what makes him adapt instead of pretending: ask for an app
that doesn't exist and he finds that out from the tool result, then offers
the website or says plainly that it isn't installed. He can call `look`
mid-loop to check his own work on screen. Each step narrates in the panel
as it happens ("Opening Safari", "Searching for tin toys"). Every tool call
lands on the same gated action a typed command would, so `quit`, dangerous
AppleScript, and `run_admin` still stop the loop and wait for your Return
(Esc declines that step and lets him adapt rather than killing the run).
The system prompt and tool definitions are identical every iteration, so
they are sent with a cache breakpoint and read from cache after the first
call.

**Screen sight.** Rusty can see your screen when you ask: "what's this
error?", "read this to me", "what's on my screen?" route to `look`, which
captures the screen, downsizes it, and sends it to Claude's vision so he
answers from what is actually there. It is read-only and needs Screen
Recording permission (macOS prompts on first use); the capture never leaves
the vision request.

Beyond the dedicated verbs, Claude has universal tools that cover nearly
everything else: `run_applescript` (drive any scriptable app, System
Events, Notes, Reminders, Calendar, timers, dark mode, and more),
`press_keys` (any keyboard shortcut in the focused app), `screenshot`, and
`run_admin` for the rare task that needs root. Scripts that delete things,
touch the shell, or press keys pause in the panel with the exact script
shown and a one-Return safety check; `run_admin` always pauses and then
hands off to the macOS password dialog, so a privileged command needs two
human checkpoints (your Return, then your password) and there is no stored
credential or standing helper the agent could spend on its own.
**Full Disk Access** (menu bar, Grant Full Disk Access) is optional and
user-granted: with it on, those tools can reach protected files (Mail,
Messages, Safari, other apps' containers) when you ask. "Test Claude
Brain" in the menu fires a live round trip and reports whether the key,
network, and wire format all work. Answers are not truncated: a real
question gets a full reply (the panel scrolls, the voice reads it all),
while a spoken quip riding a command stays short.

Anything else goes to **on-device Apple Foundation Models** (macOS 26+,
Apple Intelligence enabled, private, free, no network): "can you pull up
safari for me little buddy" → routes to `open Safari` and Rusty answers in a
the chat panel ("Beep boop, browser loaded!"). The model only ever PROPOSES a
(verb, argument, reply); execution flows through the same gated pipeline and
confirmation rules as typed commands, grounded in what Rusty can actually
see (frontmost app, what he's standing on, open apps). Falls back gracefully
when Apple Intelligence is off. Window moves use the same Accessibility
capability as Voice Control, guarded and timed out like all AX here.

**Claude brain (A5, optional, the smart tier):** paste an Anthropic API key
(menu bar, "Anthropic API Key…", stored locally; or the ANTHROPIC_API_KEY env
var) and everything the grammar can't parse goes to **claude-opus-5** before
the on-device model. That upgrade is about answers, not just routing:
"hey rusty, what's a monad" gets a real, accurate explanation in the bubble
(Claude-tier replies get ~220 chars vs the on-device 90, spoken aloud).
Wire format is the Anthropic Messages API with structured outputs, a JSON
schema pins the `{verb, argument, reply}` shape so parsing can't drift, at
effort "low" to keep voice latency conversational. Claude still only
PROPOSES; the same gated verb pipeline executes, and `quit` keeps the typed
double-⏎. Refusals and network failures fall through to the on-device tier
automatically; a rejected key says so in the bubble. The menu bar shows which
brain is live ("Brain: Claude (claude-opus-5)" / "On-Device (Apple)" /
"Grammar Only"). Privacy: only your command text and a one-line context
summary (frontmost app, open apps, where Rusty stands) are sent to
Anthropic. Model overridable via the `anthropicModel` default.
**"Hey Rusty" (A4)**: an always-on, on-device wake word (menu bar toggle).
Say "hey rusty, mute the sound" in one breath and it routes directly; a bare
"hey rusty" chimes and opens hands-free capture that ends on silence, the
chat panel pops up with the live transcript (dimmed until final) and the
reply, same as typing. And the conversation keeps going: after Rusty
finishes speaking, the mic reopens for a follow-up with no new "hey rusty";
staying quiet for a few seconds ends the chat gracefully. UI sounds are
soft synthesized kalimba taps (struck-bar partials, nothing beepy), and
they have a menu toggle (Chime Sounds).

**Memory.** Rusty remembers between launches. Tell him a preference and he
saves it himself (there are `remember` and `forget` tools he decides to
call); it lands in a plain JSON file under Application Support that you can
read, and the menu's "What Rusty Remembers" lists every fact with buttons to
reveal the file or erase the lot. He is told never to save secrets. Recent
exchanges carry over too, so a follow-up still resolves after a restart.

**Cost.** The menu shows "Usage today", tokens and dollars, counted from the
real usage numbers in the response stream and reset daily. Cached input is
counted at its own cheaper rate, which is why the loop's cache breakpoint
matters.

**Custom skins.** Beyond the four built-ins, drop a JSON file in the skins
folder (Skin menu, Open Skins Folder) to define your own: pick which robot
finish to wear and set every panel and bubble color as hex. The folder is
created with a working example and a README. Bad files are skipped and the
reason is reported rather than silently vanishing. Costs
are deliberate and visible: the mic stays open (persistent indicator) and
continuous recognition uses some CPU while enabled, the published energy
budgets apply to the wake-word-off configuration. It pauses during capture
and on sleep/lock, and restarts its recognizer on a rolling basis.

**Push-to-talk (A3): hold ⌥Space and speak**, the chat panel shows the
live transcript while you talk; release to route it through the same brain.
Recognition is on-device where the locale supports it, and the microphone
runs only while the key is held: no always-on listening, no permanent mic
indicator, zero idle cost. Replies are spoken aloud. Default provider is **free Microsoft
neural TTS** (community edge-tts tool, keyless, unofficial-but-stable;
voice `en-US-AnaNeural`, changeable via the `edgeVoice` default; requires a
python3 with `pip install edge-tts`). Switch providers under menu bar, Voice:
Free / ElevenLabs / System. **ElevenLabs** is kept on the back burner, one
click re-enables Jessica when a key is set (menu bar, "ElevenLabs API Key…", stored locally; or the
ELEVENLABS_API_KEY env var; voice/model overridable via the
`elevenLabsVoice`/`elevenLabsModel` defaults), with the best installed
system voice as the automatic fallback for no-key, network, or quota
failures (the picker prefers premium > enhanced > compact voices, download
a nicer one under System Settings → Accessibility → Spoken Content → System
Voice → Manage Voices and Rusty will use it automatically). A dev `.env`
(gitignored) with `elevenlabs=<key>` can be imported via
`defaults write com.funproject.windowpet elevenLabsKey ...`. Only Rusty's short
replies are sent to ElevenLabs, your speech is recognized on-device. Toggle
"Spoken Replies" in the menu bar to silence him. Destructive verbs from voice
park in the panel with a safety check, press Return there to confirm. First use prompts
for Microphone and Speech Recognition permissions.

## Never out of bounds

The visible body touches screen edges exactly (clamps use the drawn body's
edge, not the sprite canvas); airborne arcs bonk on the menu-bar/notch line
instead of exiting the top; falling stays over the floor span; edges too
high for the body flip him into a ceiling hang; and a visibility watchdog
relocates a resting pet if it's ever mostly offscreen for a few seconds.

## Shimeji packs (S5, the ecosystem unlock)

Any shimeji-ee character pack (`conf/actions.xml` + `img/*.png`) can be the
pet, **their art, our brain**:

```bash
swift run -c release WindowPet -- --character /path/to/SomeShimejiPack
```

The choice persists (`--character builtin` returns to Rusty; the menu bar
shows the active character). The importer parses the pack's actions.xml
(English shimeji-ee schema), maps Stand/Walk/Falling/Bouncing/Sit/Pinched onto
WindowPet's animation kinds with fallback chains, converts tick durations
(~40 ms each), honors the faces-left art convention, and builds alpha masks , 
imported characters are immediately boopable, grabbable, and throwable. The
pack's behaviors.xml is deliberately ignored: the GOBT engine drives every
character. Characters hot-swap at runtime without interrupting whatever the
pet is doing. (Japanese-schema packs and per-pose anchors: future work.)

## Reactions (S6, app awareness as personality)

Every reaction derives from real, observable system state, never randomness:

- **Immersion nap**: the frontmost window covering ≥98.5% of the screen
  (fullscreen video, deliberately above "maximized") sends the pet to the
  floor, a shuffle toward the edge, and a quiet nap until it ends. Being
  net-positive during focused work is the category's survival rule.
- **Build agitation**: window-title-change *frequency* (a compiling Terminal,
  progress titles) sensed via Tier-2 `kAXTitleChanged` events, rate only,
  the title text is never read. The pet paces on the busy window, watching.
- **Distraction closed**: quitting Slack/Discord/Teams earns celebratory hops.
- **Welcome back**: mouse activity after 90+ seconds away gets a greeting hop
  and satisfies the attention need.

Thresholds live in [ReactionPolicy.swift](Sources/WindowPetCore/ReactionPolicy.swift)
(pure, unit-tested, incl. the decaying-rate math). Reaction statuses hold
briefly so routine transitions can't stomp them; activation-chasing yields to
sleep, immersion, and in-flight errands.

## Architecture (two-tier window model)

- **Tier 1 (built): `CGWindowListCopyWindowInfo`**, bounds + z-order for every
  window, zero permissions. Physics/geometry floor. Polled adaptively:
  60 Hz only while the target frame is actually changing, 10 Hz settled,
  4 Hz after 20 s of stillness, 2 Hz with no target. Single-window queries
  (`.optionIncludingWindow`) in the hot loop; full-list queries only on
  retarget and a 1 Hz topmost audit. Retargets are event-driven
  (`NSWorkspace` activation / Space-change notifications), and everything
  suspends on sleep/screen-lock.
- **Tier 2 (built, S3): `AXObserver` as a read-free event stream**, window
  moved/resized/created/focused/miniaturized notifications per observed app.
  Events are never trusted for geometry; they mean "consult Tier 1 now":
  instant motion wake for the ridden window (vs ≤100 ms watch latency),
  audit nudges for structural changes (rate-limited, busy Electron renderers
  spam these). Hardening: 100 ms messaging timeouts on every element, exactly
  one guarded AX read per app (attach-time window probe), evidence-based
  Electron handling (silent-through-probation while Tier 1 sees motion →
  force `AXManualAccessibility` → still silent → mark degraded, judged by
  `Tier2Policy` in Core under unit test), per-app capability matrix in the
  status menu and `--diag`, LRU cap of 6 observers, detach on app quit.
  If AX fails for an app, the pet still stands on it correctly, it just has
  no event-driven opinions about it.
- **Accessibility onboarding**: zero-prompt by default. Tier 2 enables
  silently if the process is already trusted; otherwise the menu bar offers
  "Enable window senses…", which fires the system prompt and polls for the
  grant (there is no notification) so it lights up without a restart.

**Permission invariant:** we never read `kCGWindowName` / `kCGWindowOwnerName`
(they trip the Screen Recording prompt on macOS 15+). Bounds, layer, PID, and
window number are free. `grep -rn "kCGWindowOwnerName" Sources/` must only ever
hit the comment in `Tier1.swift`. App identity for the status item comes from
`NSRunningApplication` (local, unrestricted).

The overlay is a borderless, non-activating `NSPanel` (`.floating`,
`canJoinAllSpaces + fullScreenAuxiliary + stationary`, click-through), it can
never steal focus or eat a click.

Layout: `WindowPetCore` (pure geometry/cadence math, headless-testable) ·
`WindowPet` (app) · `PetGen` (sprite generator). The CG↔AppKit coordinate flip
(top-left vs bottom-left origin, anchored to `NSScreen.screens[0]`) lives in
`Geometry.swift` with unit tests, it is the classic bug in this domain.

## Measured energy (2026-08-19, M5 Pro, release build, stage 2 final)

| State | CPU | Notes |
|---|---|---|
| Perched, still (incl. breathing) | 0.0–0.5% | budget <0.3%, met at rest; breathing ticks show ≤0.5 in 2 s samples; tune in S7 |
| Walk bursts (1.5–3.5 s, every 4–9 s) | **0.9–2.8%** | budget <3% ✓, was ~4–5% when the sprite was its own moving window; GPU layer moves fixed it |
| Held by the mouse | ~0% | display link paused, purely event-driven |
| Memory | ~48 MB RSS | budget <80 MB ✓ |

Re-measure: `top -pid $(pgrep -x WindowPet) -l 6 -s 2 -stats cpu,mem,command`
or (needs sudo) `sudo powermetrics --samplers tasks -i 5000 -n 3 | grep WindowPet`.

## Verification

- `swift test`, 131 tests: coordinate math, terrain occlusion/segmentation,
  landing selection, gravity integration, leap-solver accuracy (integrated
  numerically to ≤1.5 pt), rate-policy bands.
- `--testrig`, 93/93, eight parts (ceiling hang, speech bubbles). Shimeji part: writes a schema-exact
  synthetic pack to disk, imports it, asserts the action mapping (walk ×3,
  Bouncing→land ×2, Pinched→jump, sleep falls back to idle, 6 ticks → 0.24 s,
  faces-left), hot-swaps it onto the live pet mid-run, verifies the
  click-through hole against the imported alpha, and swaps back. Others, rebuilt as a sequential step runner:
  every step acts and then polls a condition until it holds or times out, so
  load spikes on a live machine become waits instead of flakes. Reactions
  part: real fullscreen-window immersion → retreat + nap → wake on close;
  celebration and greeting through the same code paths the real signals use;
  cross-process title-spam sensed at rate ≥0.8/τ; agitated pacing on the hot
  window; full quiescence after decay. Earlier parts: Behavior: a seeded brain with forced
  needs travels to a high window via a genuine 2-step planned route (leap
  the mid shelf, leap the target), sleeps on exhaustion with the display
  link verified paused, and wakes on recharge. Earlier parts: Tier 2: attaches an observer to a helper
  process (`--helper-window`) that wiggles a titled window, asserts real
  cross-process AX events arrive and drive the engine's wake pipeline; the
  riding phase also exercises the organic path (standing on a window
  auto-attaches, and the drag's first AX event wakes tracking instantly).
  Skips loudly without Accessibility. Earlier parts: Window terrain: spawn-fall onto a window,
  close-→-fall-→-land on the window below, walking staying on the edge,
  ballistic leap onto a higher window, occlusion eviction, riding a moving
  window (Δx exact). Floor terrain: sprite-feet/anchor coherence, the alpha
  hole (opens on body pixels, stays shut between the feet and in empty air),
  wall climb with ±90° rotation and leap-off, grab → drag → throw physics,
  and clock quiescence. Rig windows are borderless and the rig runs as an
  accessory app, both deliberate: environments that suppress background
  titled/regular-app windows (fullscreen video, Focus) still map these, so
  the rig runs everywhere. Terrain is restricted to the rig's own PID so the
  live desktop can't perturb it. Tier 2: a second `--helper-window` process
  opens a titled window and wiggles it, so the observer sees real
  cross-process AX notifications, the rig asserts attach, non-degraded
  health, ≥3 `kAXWindowMoved` events in 1.6 s, and that the engine's wake
  pipeline fired. Those phases skip cleanly, and say so, when Accessibility
  isn't granted, so the rig still passes on a clean machine.

## Shipping

`bash Tools/make-app.sh` builds and signs WindowPet.app (Developer ID if
present, else the Apple Development identity, so permission grants persist
across rebuilds). `bash Tools/make-dist.sh` wraps it in a
drag-to-Applications DMG. First launch shows a short welcome that explains
the permissions. The menu has Start at Login and About. For public
distribution, enroll in the Apple Developer Program, add a Developer ID
Application certificate, and notarize the DMG (commands in the script
headers); everything else is already in place.

## Next

- Grant Accessibility, Microphone, and Speech once to the installed app;
  the Apple Development signature keeps them sticky. Then measure
  wake-word-on CPU for ENERGY.md.
- Notarization once enrolled in the Apple Developer Program.
- Later: learned associations (S6b), Japanese-schema Shimeji packs +
  per-pose anchors (S5b), ElevenLabs credit monitor, custom skin editor.

## License

MIT, see [LICENSE](LICENSE).
