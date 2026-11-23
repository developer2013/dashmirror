# CLAUDE.md

The shared project rules live in `AGENTS.md` and apply to Claude Code as well:

@AGENTS.md

## Additionally for Claude Code

- Derived build data goes to `build/` (git-ignored) or a scratch directory, never into source folders.
- Runtime checks in the simulator work with `xcrun simctl` alone (install, launch, `io screenshot`, container logs);
  don't assume UI automation (idb, System Events) is available.
- The driving-lock rule (`DashMirror/Driving/DrivingPolicy.swift`) is written by the user – don't fill it in or
  loosen it unasked.
