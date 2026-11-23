# AGENTS.md – rules for AI agents in this project

Applies to all agents (Claude Code, Codex, …). Overview and usage: `README.md`.

## What this is

An iOS app that mirrors the iPhone screen into a CarPlay window: a ReplayKit broadcast extension encodes the screen
as H.264 and sends it over a Unix domain socket in the App Group container to the app, which shows it in a
`UIWindowScene` under the role `UIWindowSceneSessionRoleCarPlay`. Target: an iPhone with a Bluetooth controller in a
(parked) car. Hobby/open-source project, not for the App Store.

- Targets: `DashMirror` (app) and `MirrorBroadcast` (extension, bundle ID `<app bundle ID>.MirrorBroadcast`).
- Team, bundle ID, App Group and entitlements file come from `Config/Signing.xcconfig`, overridden by the
  git-ignored `Config/Local.xcconfig`. **Never** hard-code a team ID, bundle ID or App Group in code or the pbxproj;
  code reads the App Group from the Info.plist key `DashMirrorAppGroup`.
- Folders are *synchronized groups* (Xcode 16+): just add files, don't edit the pbxproj for them.
  `Shared/` belongs to **both** targets, `DashMirror/` only to the app, `MirrorBroadcast/` only to the extension.
- `Config/` (Info.plists, entitlements, xcconfigs) deliberately lives outside the synchronized folders.
- Xcode 26.3, iOS SDK 26.2, deployment target 26.2, Swift 5 language mode with Approachable Concurrency.

## Build and verify

```bash
xcodebuild -project DashMirror.xcodeproj -scheme DashMirror \
  -destination "generic/platform=iOS Simulator" -derivedDataPath build build
xcodebuild -project DashMirror.xcodeproj -scheme DashMirror \
  -destination "generic/platform=iOS" -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

- Goal: both builds **without warnings**.
- Runtime check in the simulator: launch with `-MirrorTestPattern YES`, then read `Logs/app.log` in the App Group
  container (`xcrun simctl get_app_container <udid> <bundle id> <app group>`). Expected after ~10 s:
  `Empfang (10 s): 30.0 B/s … Latenz <10 ms, verworfen 0.0/s`.
- Real mirroring (ReplayKit) and CarPlay only on a device – the user measures there. Never call something
  "tested in the car" that only ran in the simulator.
- Don't register anything in the developer portal yourself (`-allowProvisioningUpdates` etc.) – the user does that.

## Fixed rules (don't change without asking)

1. **The driving lock is fail-closed.** `DrivingLockMonitor` starts locked; missing data must never look like
   "parked". The rule itself lives alone in `Driving/DrivingPolicy.swift` and is the user's decision.
   Only exception: launch argument `-MirrorNoDrivingLock YES`, Debug builds only, this launch only, with a permanent
   orange badge on the car screen. No other bypasses. When locked, the display is detached **and** cleared
   (`flush(removingDisplayedImage: true)`) – no frozen frame.
2. **The extension stays below 50 MB.** No SwiftUI/UIKit UI, no image copies, no JPEG. ReplayKit's buffer goes
   straight (or scaled via `VTPixelTransferSession`) into the hardware encoder. Rotation happens in the app via the
   layer transform, never in the extension. The `Sender:` log line shows the memory footprint.
3. **Never drop encoded frames.** Back-pressure is resolved **before** encoding (skip the frame). A missing P-frame
   breaks everything up to the next keyframe. After a reconnect or a new display: request a keyframe.
4. **The encoder must not deadlock.** Without the low-latency encoder, encoders hold frames back; hence
   `completeEachFrame` plus the escape hatch (see README "Measurements"). Verify back-pressure changes in the
   simulator with the test pattern.
5. **The app plays no sound** and activates no `AVAudioSession` – it would interrupt the game's audio.
6. **Both CarPlay entitlements** (`carplay-video` + `carplay-audio`) or none. Switch only via
   `DASHMIRROR_ENTITLEMENTS`. Simulator builds always use the CarPlay file.
7. **Code in `Shared/` is explicitly `nonisolated`** (app: MainActor by default, extension: not) and runs on
   background threads. Callbacks there are `@Sendable`; back into the app via `Task { @MainActor in … }`.
   No `UIApplication` in `Shared/` (the extension builds with `APPLICATION_EXTENSION_API_ONLY`).
8. **Wire format** (`MirrorProtocol.swift`): change both sides together; bump the `MRR1` magic on incompatible changes.
   Every source sends `hello` with its `MirrorSource` first; the screen source ends a running test pattern.

## Style

- UI strings in German **with** umlauts ("Übertragung"). Code comments and log lines in German with ae/oe/ue.
- Public docs (README, this file) in English.
- Comments explain *why* and record measurements with a date (e.g. "gemessen am 23.11.2026").
- New test findings go into the README ("Measurements") and the log (`MirrorLog.write`), so test drives stay
  analysable without a Mac.
