<p align="center">
  <img src="DashMirror/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="128" alt="DashMirror icon">
</p>

# DashMirror

Mirror your **whole iPhone screen** – any app, including games played with a Bluetooth controller – into your own
CarPlay window. No jailbreak, no IPA injection, no extra hardware; the mirrored apps stay untouched.
A fail-closed driving lock hides the picture while the car is moving.

> **Use only while parked.** Not affiliated with, endorsed by, or connected to Apple.
> CarPlay is a trademark of Apple Inc. This is a hobby project, not an App Store app – see [Limitations](#limitations).

## Status (November 2026)

| | |
|---|---|
| Works | iPhone 16 Pro, iOS 27.0.1, with Apple's CarPlay Simulator: real screen mirroring shows up in the CarPlay window, touches on the car screen arrive. |
| Not tested yet | A real car. **iOS 27.2 and later** – Apple cracked down on CarPlay video workarounds in 27.2 (App Store removals); whether this approach is affected is unknown. |
| Driving lock | ⚠️ The rule in `DashMirror/Driving/DrivingPolicy.swift` is still a placeholder that **always locks**. Write your rule before use. |
| UI language | German for now. |

## How it works

```
iPhone screen (game in front, controller paired to the iPhone)
   │ ReplayKit broadcast: every frame as CMSampleBuffer (always portrait + EXIF orientation)
   ▼
MirrorBroadcast.appex  (separate process, hard 50 MB limit)
   │ scale to the car display's size → H.264 (VideoToolbox, hardware, low-latency rate control)
   │ Unix domain socket in the App Group container
   ▼
DashMirror.app
   │ SPS/PPS + frames → CMSampleBuffer → AVSampleBufferDisplayLayer (hardware decoder)
   │ rotation via layer transform, driving lock hides the picture
   ▼
CarPlay window (UIWindowScene under the role "UIWindowSceneSessionRoleCarPlay")
```

- **Audio** needs no extra path: iOS already plays the game's sound through CarPlay. The app never activates an audio session, so it doesn't interrupt it.
- **Touch on the car screen does not reach the mirrored app** – no public API can inject touches into other apps. Control the game with a controller on the iPhone. A tap on the car screen only cycles the picture format.
- The CarPlay window is a plain `UIWindowScene` under a scene role UIKit exports but doesn't name in Swift – discovered by [rPlayAI/cafari-lite](https://github.com/rPlayAI/cafari-lite). iOS only creates that scene for an app signed with **both** CarPlay entitlements, video and audio.

## Requirements

- A **paid** Apple Developer account and Xcode 26.3 or later; iPhone with iOS 26.2 or later (tested on 27.0.1).
- For the car screen: Apple must grant **both** *CarPlay Video App* and *CarPlay Audio App* to your App ID
  ([developer.apple.com/contact/carplay](https://developer.apple.com/contact/carplay/)). With "video" alone the app
  never appears in the car, without any error. Without the entitlements everything else still works on the phone:
  the full mirroring pipeline, the test pattern and the phone UI.

## Setup

1. `cp Config/Local.xcconfig.example Config/Local.xcconfig` (git-ignored) and set your team ID, bundle ID and App Group.
2. Open `DashMirror.xcodeproj` and run once on your iPhone – automatic signing registers both App IDs
   (`<bundle id>` and `<bundle id>.MirrorBroadcast`) and the App Group.
3. Only if Apple granted both CarPlay entitlements: enable them for your App ID in the developer portal, set
   `DASHMIRROR_ENTITLEMENTS = Config/DashMirror-CarPlay.entitlements` in `Local.xcconfig`, and build once in Xcode so it
   fetches a fresh provisioning profile (an old one gives *"Entitlements … not found and could not be included in profile"*).

## Usage

1. Pair a Bluetooth controller with the iPhone.
2. Connect to CarPlay and open **DashMirror** on the car screen.
3. On the iPhone: **Spiegelung starten** → *Start Broadcast* (or Control Center → long-press Screen Recording → DashMirror).
4. Switch to your game, put the iPhone down in landscape, play with the controller.
5. Set Auto-Lock to *Never* – the picture freezes when the iPhone locks.

On the car screen: **tap** = picture format (fit → fill → stretch), **pinch** = zoom, **drag** = move the zoomed
image, **long press** = show stats. Whether a head unit delivers multi-touch depends on the car (Apple's CarPlay
Simulator doesn't), so the iPhone has the same zoom as a slider, plus reset.
On the iPhone: frame rate (30/60) and quality (6/12/20 Mbit/s) apply immediately; resolution follows the car display.

Hold the iPhone in landscape: its image is 2.17:1 and fills a wide car display almost completely. Portrait apps stay
a narrow strip; use zoom for those.

**Black borders are cut off automatically.** Many games leave black bars for the Dynamic Island or render 16:9 on the
19.5:9 screen. The extension detects them and crops before encoding, so the actual content gets bigger. Per axis it
only cuts what is black on *both* sides; when content reaches into a border, the crop shrinks at once, it only grows
after 2 s of stable measurements (dark scenes don't zoom). Toggle: *Schwarze Ränder abschneiden*.

## Driving lock

`DrivingLockMonitor` collects every second: GPS speed, the motion coprocessor's *automotive*/*stationary* state with
confidence, seconds since the last movement, and whether location access is available. `DrivingPolicy.shouldLock`
decides. The monitor starts **locked**; missing data must never look like "parked". When locked, the picture is
removed from the car screen (no frozen frame) and the decoder stops.

Location runs in the background as well (blue status pill) because in the car the game is in front on the iPhone.

In Germany, § 23 (1a) StVO allows a driver to use the screen only when the car is stopped **and the engine is off**
(start-stop does not count) – the app cannot detect the engine. Keep that in mind when writing the rule.

## Testing without a car

```bash
# Build (simulator)
xcodebuild -project DashMirror.xcodeproj -scheme DashMirror \
  -destination "generic/platform=iOS Simulator" -derivedDataPath build build
```

- **Test pattern** (Debug, launch argument `-MirrorTestPattern YES`, also a toggle in the app): runs through the exact
  same chain as the extension (encoder, socket, border crop, decoder, rotation). It is drawn portrait with orientation
  `.right` – like ReplayKit with the iPhone in landscape – and as a 16:9 game with black side bars. If "↑ oben" stands
  upright, "links oben" is top-left and the bars disappear after ~2 s, rotation and cropping work.
- **CarPlay Simulator** (Additional Tools for Xcode) with the iPhone on a cable.
- **`-MirrorNoDrivingLock YES`** (Debug builds only, this launch only): disables the lock for desk testing; the car
  screen shows a permanent orange "Fahrsperre AUS – nur Test" badge. Launched normally, the lock is back.

ReplayKit itself doesn't run in the simulator – real mirroring only on a device.

## Measurements

| Setup | Result |
|---|---|
| Simulator, test pattern | 30 fps, 4–7 ms encoder → app. The simulator has no low-latency encoder (`-12908`) and ignores `MaxFrameDelayCount` (`-12900`); its encoder held frames back and deadlocked a "max 2 in flight" back-pressure rule. Fixed: without low-latency, force output after every frame, plus a 0.5 s escape hatch. |
| iPhone 16 Pro, iOS 27.0.1, test pattern | Hardware low-latency encoder, 30 fps, 9 ms encoder → app. |
| Simulator, 16:9 test pattern with black bars | Bars detected and cut ~2 s after start: 136 px per side (bars are 140 px; the 4 px rest is the safety margin), encoder switches 720×1560 → 720×1288, no frames dropped. |
| iPhone + CarPlay Simulator, real broadcast | Car window 425×255 pt @2x (800×480 native), 49 pt safe-area inset → 752×510 px video area; encoder follows (346×752). Extension: 4 MB at start, 9–10 MB while encoding (limit 50 MB). 23 ms from screen to app incl. ReplayKit. |

ReplayKit only delivers frames when the screen changes – a static screen means few frames, not an error.
**Locking the iPhone ends the broadcast** (measured: iOS finished it 7 s after CarPlay connected, when the phone was
locked); after unlocking it has to be started again. The game is suspended while locked anyway. Set Auto-Lock to
*Never* while playing. Touch on the car screen can't drive other apps, so "phone locked, play by car touch" is
not possible with mirroring.

## Logs

Both processes write to the App Group container (`Logs/app.log`, `Logs/broadcast.log`, viewable and shareable in the
app under *Protokoll*) and a copy into their own container, because `devicectl` may not read App Group containers:

```bash
xcrun devicectl device copy from --device <id> --domain-type appDataContainer \
  --domain-identifier <bundle id> --source Documents/Logs/app.log --destination app.log
xcrun devicectl device copy from --device <id> --domain-type appDataContainer \
  --domain-identifier <bundle id>.MirrorBroadcast --source Documents/Logs/broadcast.log --destination broadcast.log
```

## Limitations

- **Not for the App Store.** The window scene role is undocumented, and Apple's CarPlay video category requires apps
  "designed primarily to provide video playback services" with Apple's templates. Apple removed comparable apps in
  October 2026. Build it for yourself.
- **Don't distribute signed builds** to others – CarPlay entitlements are granted to your team under Apple's terms.
- Extra latency from capture, hand-over and the CarPlay video stream (not measured end-to-end yet).
- DRM-protected content (streaming apps) is black in ReplayKit captures.
- Apple can change or remove the window scene role in any iOS release.

## Open tests

- **Pseudo-standby (idea, not tested yet).** iOS ends the broadcast when the iPhone locks, so real standby is out.
  Idea: keep the iPhone unlocked with the game in front, but make its screen practically dark – Accessibility →
  Display & Text Size → *Reduce White Point* 100 % plus minimum brightness, toggled with the Accessibility Shortcut
  (triple-click the side button), Auto-Lock set to *Never*. iOS applies these filters when displaying, and
  screenshots don't contain them, so ReplayKit probably captures the normal, bright image. To verify: does the car
  picture stay bright while the iPhone looks off?
- A real car (BMW, wireless CarPlay), longer sessions with a warm iPhone, switching Maps ↔ DashMirror.
- iOS 27.2 and later.

## Project layout

| Part | Files |
|---|---|
| Wire protocol, socket helpers | `Shared/MirrorProtocol.swift` |
| Encoder (scale + H.264, frame rate, back-pressure, keyframes) | `Shared/MirrorEncoder.swift` |
| Socket client with reconnect; `MirrorStreamer` = encoder + sender | `Shared/MirrorSender.swift` |
| Broadcast extension | `MirrorBroadcast/SampleHandler.swift` |
| Socket server, CMSampleBuffer assembly | `DashMirror/Mirror/MirrorReceiver.swift`, `MirrorPipeline.swift` |
| App state, settings, stats | `DashMirror/Mirror/MirrorHub.swift` |
| Test pattern | `DashMirror/Mirror/TestPattern.swift` |
| Car screen | `DashMirror/CarPlay/*` |
| Driving lock | `DashMirror/Driving/*` |
| Phone UI | `DashMirror/Phone/*` |
| Signing config | `Config/Signing.xcconfig`, `Config/Local.xcconfig.example` |
| App icon | `scripts/make-icon.swift` (`swift scripts/make-icon.swift`) |

Code comments are in German.

## Credits

- [rPlayAI/cafari-lite](https://github.com/rPlayAI/cafari-lite) (MIT) for showing that a plain `UIWindowScene` under
  `UIWindowSceneSessionRoleCarPlay` works with the CarPlay video + audio entitlements. No code was copied.

## License

MIT – see [LICENSE](LICENSE).
