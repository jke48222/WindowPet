# Changelog

## 1.2.0 (2026-08-27)

Rusty stopped being a creature that walks on your windows and became one that
can see them.

### He can see and arrange your windows

- `windows` reports what is open: which apps, how many, what size, where. It
  reuses the zero-permission window poll he already walks on, and keeps the
  invariant: app names come from the process id, never `kCGWindowOwnerName`,
  and no window title is read anywhere in it.
- "Put Safari left and Terminal bottom right" arranges them, on whichever
  display each window is already on.
- Arrangements are saved and recalled by name, and "put it back" restores each
  window to the exact frame it had, at the size it actually was.

### He can keep watch

- "Tell me when the build finishes." He goes and stands on that window and
  lights a small lamp at his shoulder, so the promise is visible rather than
  taken on faith. The signal is the Accessibility event stream he already
  counts for reactions: frequency only, still no titles.
- "Every weekday at 9, tell me what is on my calendar" runs the full assistant
  when it comes due. A missed slot is never replayed, so a laptop waking at 3pm
  does not get every morning it slept through.
- Everything he says unprompted now passes a quiet check first. Focus on, your
  microphone in use, or the screen locked, and it waits, then arrives with a
  word about why. Full screen or mid-sentence, and it appears without being
  spoken. Older than two hours and it is dropped, because it is not news.

### He can do more, and cost less

- **Dictation.** Hold Option-D and speak, and the words go from the on-device
  recognizer straight into whatever app is in front. No request, no token,
  nothing leaves the machine.
- **A daily spending limit**, five dollars by default, checked before every
  model call and before every iteration of the agent loop, so a runaway plan
  stops at the ceiling rather than past it.
- **He remembers what you copy**, in memory only and never on disk, skipping
  anything a password manager marked concealed or that looks like a key.
- **Drop a file on him** and he reads it. Text and PDFs.
- **Teach him a trick**: record what he does, name it, ask for it later.
- **Memory can belong to one app.** "In Xcode: keep the left half" only comes
  back while Xcode is in front.
- **He speaks MCP.** Servers in `mcp.json` join the same tool schema and the
  same confirmation gate as everything built in.

### Under it

- Swift 6 language mode across every target, zero warnings on a clean build.
  The UI classes are actor-isolated rather than main-thread by convention, so
  two agent turns cannot interleave and corrupt a conversation.
- Multi-display behavior is decided by one policy instead of assuming the main
  display, so snapping a window keeps it on the screen it is already on.
- Universal binary, arm64 and x86_64, both at the macOS 14 minimum.
- Hardened runtime on every signing branch, with the entitlements the
  microphone and Apple events need on top of their permission grants.
- 360 unit tests, up from 131. End to end rig 138 checks, up from 93.

### Still open

- Not notarized. That needs a Developer ID Application certificate, which
  needs Apple Developer Program enrollment. Everything downstream of it is
  wired: `Tools/make-dist.sh --notarize` signs, submits, staples and verifies.
- Dictation's speech path and the Focus reader have not been exercised against
  real permissions and a real Focus mode. See the README's known gaps.

## 1.1.0 (2026-08-27)

Universal binary, hardened runtime with entitlements, signed DMG path, and the
first release tag.

## 1.0.0 (2026-08-20)

First working build: the creature, the two-tier window model, the assistant,
voice, skins, and the app bundle.
