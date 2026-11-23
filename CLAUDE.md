# CLAUDE.md

The shared project rules live in `AGENTS.md` and apply to Claude Code as well:

@AGENTS.md

## Additionally for Claude Code

- Derived build data goes to `build/` (git-ignored) or a scratch directory, never into source folders.
- Runtime checks in the simulator work with `xcrun simctl` alone (install, launch, `io screenshot`, container logs);
  don't assume UI automation (idb, System Events) is available.
- The driving-lock rule (`DashMirror/Driving/DrivingPolicy.swift`) is the user's decision (set on 23 Nov 2026 at their
  request: 7 km/h, 5 s, fail-closed without accurate GPS) – don't change or loosen it unasked.
