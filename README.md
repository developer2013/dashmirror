# DashMirror

Mirror your whole iPhone screen into your own CarPlay window: any app, including games you play with a Bluetooth
controller. No jailbreak, no IPA injection, no extra hardware ([details](#no-hacks-no-extra-hardware)). A fail-closed
driving lock hides the picture while the car is moving.

> **Use only while parked.** Not affiliated with, endorsed by, or connected to Apple. CarPlay is a trademark of
> Apple Inc. This is a hobby project, not an App Store app. See [Limitations](#limitations) and
> [Use at your own risk](#use-at-your-own-risk).

## Status (November 2026)

| Area | State |
|---|---|
| Works | iPhone 16 Pro, iOS 27.0.1, in Apple's CarPlay Simulator and in a real BMW over a cable (23 Nov 2026): mirroring, rotation, picture formats, touches on the car screen. |
| Not tested yet | Wireless CarPlay. Instant replay, blurred background, night mode and heat protection in a real car; so far they have only run in the simulator. iOS 27.2 and later: Apple cracked down on CarPlay video workarounds in 27.2 (App Store removals), and whether this approach is affected is unknown. |
| Driving lock | ⚠️ The rule in `DashMirror/Driving/DrivingPolicy.swift` is still a placeholder that **always locks**. Write your rule before use. |
| UI language | English and German. Follows the iPhone language, or pick one under **Language** in the app. The switch is immediate, on the car screen too. |

## What it does

- Mirrors whatever is in front on the iPhone into a CarPlay window, at the car display's resolution and 30 or 60 fps.
- [Seven picture formats](#picture-formats) and pinch zoom.
- [Cuts off black borders](#black-borders-and-blurred-background) that games leave themselves, and fills any remaining
  bars with a blurred copy of the picture.
- [Instant replay](#instant-replay): a long press on the car screen saves the last 30 seconds to Photos.
- [Night mode](#night-mode) and [heat protection](#heat-protection).
- Switches between English and German without a restart.

## No hacks, no extra hardware

DashMirror only uses what iOS offers every developer:

- No jailbreak. It runs on a normal iPhone with a current iOS.
- No modified apps. Nothing is injected into the apps you mirror; they run unchanged.
- No extra devices. No CarPlay dongle, no Android box, no HDMI adapter, no Raspberry Pi. Just the iPhone and the
  car's normal CarPlay connection.
- No private APIs. The screen capture is a regular ReplayKit broadcast that you start yourself, like a screen
  recording. Encoding, transport and display use VideoToolbox, a Unix socket and AVFoundation.
- No DRM tricks. Protected video stays black.

One part is not standard: the car screen is a plain UIKit window under CarPlay's window scene role, which Apple
doesn't document. iOS only creates that window for apps with both CarPlay entitlements, and you request those from
Apple yourself (see [Requirements](#requirements) and [Limitations](#limitations)).

## How it works

```text
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

The game's sound needs no extra path: iOS already plays it through CarPlay. The app never activates an audio
session, so it doesn't interrupt that.

Touch on the car screen does not reach the mirrored app. No public API lets one app inject touches into another, so
you control the game with a controller on the iPhone. Taps on the car screen go to DashMirror itself (see
[Usage](#usage)).

The CarPlay window is a plain `UIWindowScene` under a scene role that UIKit exports but doesn't name in Swift.
[rPlayAI/cafari-lite](https://github.com/rPlayAI/cafari-lite) found it. iOS only creates that scene for an app signed
with both CarPlay entitlements, video and audio.

## Requirements

- A paid Apple Developer account, Xcode 26.3 or later, and an iPhone with iOS 26.2 or later (tested on 27.0.1).
- For the car screen, Apple must grant both **CarPlay Video App** and **CarPlay Audio App** to your App ID
  ([developer.apple.com/contact/carplay](https://developer.apple.com/contact/carplay/)). With video alone the app
  never appears in the car, and you get no error. Without the entitlements everything else still works on the phone:
  the mirroring pipeline, the test pattern and the phone UI.

## Setup

```bash
git clone https://github.com/developer2013/dashmirror.git
cd dashmirror
cp Config/Local.xcconfig.example Config/Local.xcconfig
```

1. In `Config/Local.xcconfig` (git-ignored), set your team ID, bundle ID and App Group.
2. Open `DashMirror.xcodeproj` and run once on your iPhone. Automatic signing registers both App IDs (`BUNDLE_ID` and
   `BUNDLE_ID.MirrorBroadcast`) and the App Group.
3. Only if Apple granted both CarPlay entitlements: enable them for your App ID in the developer portal, set
   `DASHMIRROR_ENTITLEMENTS = Config/DashMirror-CarPlay.entitlements` in `Local.xcconfig`, and build once in Xcode so
   it fetches a fresh provisioning profile. An old profile fails with *"Entitlements … not found and could not be
   included in profile"*.

## Usage

1. Pair a Bluetooth controller with the iPhone.
2. Connect to CarPlay and open DashMirror on the car screen.
3. On the iPhone, tap **Start mirroring**, then **Start Broadcast**. Or open Control Center, long-press
   **Screen Recording** and choose **DashMirror**.
4. Switch to your game, put the iPhone down in landscape and play with the controller.
5. Set **Auto-Lock** to **Never**. Locking the iPhone ends the broadcast.

On the car screen:

| Gesture | Action |
|---|---|
| Tap | Control bar: picture format, save clip, stats, reset zoom. Hides after 4 s. |
| Long press | Save a clip of the last 30 s. |
| Pinch | Zoom. |
| Drag | Move the zoomed picture. |

Whether a head unit delivers multi-touch depends on the car (Apple's CarPlay Simulator doesn't), so the iPhone has the
same zoom as a slider, plus a reset button. Frame rate (30/60) and quality (6/12/20 Mbit/s) are set on the iPhone and
apply immediately. The resolution follows the car display.

Hold the iPhone in landscape. Its picture is 2.17:1 and fills a wide car display almost completely. Portrait apps stay
a narrow strip with the blurred background behind it; zoom helps there.

## Features

### Picture formats

The format button in the control bar cycles through them. The iPhone shows each one with a short explanation.

| Format | What it does |
|-|-|
| Automatic (default) | Fills when the shapes differ by less than 15 %, otherwise fits. Never distorts. |
| Fit | Whole picture, black bars. |
| Slight zoom | Zooms in until at most 12 % is cut off. |
| Smart fill | Up to 10 % stretch plus up to 10 % zoom. |
| Slight stretch | Stretches by at most 12 %, the rest stays black bars. |
| Fill (zoom) | Fills completely, edges are cut off. |
| Stretch | Fills completely, distorted. |

In the BMW (2.45:1 display, iPhone landscape 2.17:1) the gap is 13 %, so Automatic, Slight zoom and Smart fill all
come out borderless or nearly so. Which one looks best is still to be tested in the car.

### Black borders and blurred background

Many games leave black bars for the Dynamic Island or render 16:9 on the 19.5:9 screen. The extension detects them and
crops before encoding, so the actual content gets bigger. Per axis it only cuts what is black on both sides. When
content reaches into a border, the crop shrinks at once; it only grows after 2 s of stable measurements, so dark scenes
don't zoom. Toggle: **Cut off black borders**.

Where bars remain (portrait apps, the Fit format), the same picture fills the space behind them, enlarged and blurred,
like portrait videos on TV. This is a second display layer with its own hardware decoder, attached only while bars are
visible. Toggle: **Blurred background instead of black bars**.

### Instant replay

The app keeps the last 30 s of the stream it already receives: encoded H.264, in groups that each start with a
keyframe (the encoder sets one at least every 2 s), capped at 64 MB. Saving only wraps those frames into an MP4 with
`AVAssetWriter` passthrough, without re-encoding. In the simulator, 12 s of video took 0.04 s. The rotation goes into
the track transform.

Clips go to Photos with "add only" access. iOS can only ask for that access while the DashMirror window is in front on
the iPhone. Until then, clips wait in the Files app (**On My iPhone › DashMirror › Clips**) and move to Photos the next
time you open the app. Clips are video only, because the extension sends no audio. A new picture format (car display
change, border crop) or orientation starts the buffer over.

### Night mode

Dims the car picture with a black layer, 15 to 70 %. **Automatic** follows the car's day/night signal: CarPlay switches
the window's appearance (`userInterfaceStyle`) by headlights or light sensor, the same signal navigation apps use for
their maps. Some cars report night all the time, so the iPhone shows what the car reports.

### Heat protection

The app checks the iPhone's thermal state every 0.5 s. At *serious* it lowers the resolution to 75 % and the data rate
to 8 Mbit/s, at *critical* to 67 %, 6 Mbit/s and 30 fps. That happens before iOS throttles the game on its own, and the
car screen shows a short note. The rule is one small function in `DashMirror/Mirror/ThermalPolicy.swift`. It keeps
60 fps as long as possible, because smoothness usually matters more in games than sharpness on a small car display.

## Driving lock

Every second, `DrivingLockMonitor` collects the GPS speed, the motion coprocessor's automotive/stationary state with
its confidence, the seconds since the last movement, and whether location access is available.
`DrivingPolicy.shouldLock` decides. The monitor starts locked, and missing data never counts as parked. When locked,
the picture is removed from the car screen (no frozen frame) and the decoder stops.

Location also runs in the background (blue status pill), because in the car the game is in front on the iPhone.

In Germany, § 23 (1a) StVO allows a driver to use the screen only when the car is stopped and the engine is off.
Start-stop does not count, and the app cannot detect the engine. Keep that in mind when you write the rule.

## Testing without a car

```bash
xcodebuild -project DashMirror.xcodeproj -scheme DashMirror \
  -destination "generic/platform=iOS Simulator" -derivedDataPath build build
```

ReplayKit doesn't run in the simulator, so real mirroring needs a device. The rest of the chain can be tested with
these launch arguments (Debug builds only):

| Launch argument | What it does |
|---|---|
| `-MirrorTestPattern YES` | Sends a test pattern through the same chain as the extension: encoder, socket, border crop, decoder, rotation. Also a toggle in the app. |
| `-MirrorNoDrivingLock YES` | Disables the driving lock for this launch only. The car screen shows a permanent orange badge. |
| `-MirrorCarPreview YES` | Shows the car screen in the iPhone window, so the control bar, blurred background and night mode can be checked without a CarPlay display. |
| `-MirrorShowControls YES` | Keeps the control bar visible. |
| `-MirrorReplayTest 12` | Saves a clip after 12 s (file only, no Photos). |
| `-MirrorThermalTest serious` | Fakes the thermal state. The simulator always reports *nominal*. |

The test pattern is drawn portrait with orientation `.right`, like ReplayKit with the iPhone in landscape, and shows a
16:9 game with black side bars. If "↑ top" stands upright, "top left" is in the top left corner and the bars disappear
after about 2 s, rotation and cropping work.

With the iPhone on a cable, Apple's CarPlay Simulator (Additional Tools for Xcode) shows the car screen on the Mac.

## Measurements

| Setup | Result |
|---|---|
| BMW, real car, iPhone 16 Pro over a cable (23 Nov 2026) | CarPlay window 642×240 pt @3x (1440×540 native), 49 pt sidebar → 1770×723 px video area (2.45:1). 30–57 fps, 12–21 ms from screen to app. |
| iPhone + CarPlay Simulator, real broadcast | Car window 425×255 pt @2x (800×480 native), 49 pt safe-area inset → 752×510 px video area; the encoder follows (346×752). Extension: 4 MB at start, 9–10 MB while encoding (limit 50 MB). 23 ms from screen to app including ReplayKit. |
| iPhone 16 Pro, iOS 27.0.1, test pattern | Hardware low-latency encoder, 30 fps, 9 ms encoder → app. |
| Simulator, test pattern | 30 fps, 4–7 ms encoder → app. The simulator has no low-latency encoder (`-12908`) and ignores `MaxFrameDelayCount` (`-12900`). Its encoder held frames back and deadlocked a "max 2 in flight" back-pressure rule. Fixed: without low-latency, force output after every frame, plus a 0.5 s escape hatch. |
| Simulator, 16:9 test pattern with black bars | Bars detected and cut about 2 s after start: 136 px per side (the bars are 140 px; the 4 px rest is the safety margin). The encoder switches from 720×1560 to 720×1288, no frames dropped. |
| Simulator, instant replay | `-MirrorReplayTest 14`: a clip of 11.7 s (the buffer restarted when the border crop changed the format), 353 frames, 0.6 MB, written in 0.04 s. It plays upright as 1288×720 with the rotation in the track transform. |
| Simulator, heat protection | `-MirrorThermalTest serious`: encoder settings go from 1920×1080 at 12 Mbit/s to 1440×810 at 8 Mbit/s, 60 fps kept. |
| Simulator, blurred background | Second display layer next to the main one, no decoder errors. 0.2 frames/s were dropped for a moment while it waited for its first keyframe. |

ReplayKit's orientation `.right` (6) needs a 90° counter-clockwise rotation, the opposite of the EXIF reading. The
first version showed YouTube upside down in the BMW. Netflix stays black: ReplayKit doesn't capture DRM content, by
design.

ReplayKit only delivers frames when the screen changes, so a static screen means few frames, not an error.

Locking the iPhone ends the broadcast. In the measurement iOS finished it 7 s after CarPlay connected, when the phone
was locked, and after unlocking it has to be started again. The game is suspended while locked anyway. Touch on the
car screen can't drive other apps, so "phone locked, play by car touch" is not possible with mirroring.

## Logs

Both processes write to the App Group container (`Logs/app.log`, `Logs/broadcast.log`, viewable and shareable in the
app under **Log**) and a copy into their own container, because `devicectl` may not read App Group containers. The
app's copy is also in the Files app (**On My iPhone › DashMirror › Logs**).

```bash
xcrun devicectl device copy from --device DEVICE_ID --domain-type appDataContainer \
  --domain-identifier BUNDLE_ID --source Documents/Logs/app.log --destination app.log
xcrun devicectl device copy from --device DEVICE_ID --domain-type appDataContainer \
  --domain-identifier BUNDLE_ID.MirrorBroadcast --source Documents/Logs/broadcast.log --destination broadcast.log
```

## Limitations

- Not for the App Store. The window scene role is undocumented, and Apple's CarPlay video category requires apps
  "designed primarily to provide video playback services" built with Apple's templates. Apple removed comparable apps
  in October 2026. Build it for yourself.
- Don't distribute signed builds to others. Apple grants CarPlay entitlements to your team under its terms.
- Capture, hand-over and the CarPlay video stream add latency. End-to-end latency hasn't been measured yet.
- DRM-protected content (streaming apps) is black in ReplayKit captures.
- Apple can change or remove the window scene role in any iOS release.

## Use at your own risk

DashMirror is a hobby project. The code is free and comes as is, without warranty (see [LICENSE](LICENSE)).

If you build it, what you do with it is your responsibility. That includes requesting CarPlay entitlements from
Apple, adding them to your own App ID, writing the driving-lock rule and changing the code. Whether that fits Apple's
developer agreements is between you and Apple. The CarPlay window is meant for a parked car, so don't watch or play
while driving.

To the extent permitted by law, I'm not liable for damage, lost data, fines, trouble with your developer account or
anything else that comes from building, changing or using DashMirror.

## Open tests

- Pseudo-standby, an untested idea. iOS ends the broadcast when the iPhone locks, so real standby is out. Instead, keep
  the iPhone unlocked with the game in front but make its screen practically dark: **Reduce White Point** at 100 %
  (Accessibility › Display & Text Size) plus minimum brightness, toggled with the Accessibility Shortcut (triple-click
  the side button), and Auto-Lock set to **Never**. iOS applies these filters when displaying, and screenshots don't
  contain them, so ReplayKit probably captures the normal, bright picture. To check: does the car picture stay bright
  while the iPhone looks off?
- Wireless CarPlay, longer sessions with a warm iPhone, switching between Maps and DashMirror.
- The new features in a real car: does the blur render on the head unit, does the BMW send a day/night signal (the log
  line is `Autodisplay: Auto meldet …`), does heat protection kick in on a warm day, how big is the control bar on the
  240 pt high screen.
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
| Instant replay (ring buffer, MP4 passthrough, Photos) | `DashMirror/Mirror/ReplayBuffer.swift`, `ClipWriter.swift`, `ReplayRecorder.swift` |
| Heat protection rule | `DashMirror/Mirror/ThermalPolicy.swift` |
| Test pattern | `DashMirror/Mirror/TestPattern.swift` |
| Car screen | `DashMirror/CarPlay/*` |
| Driving lock | `DashMirror/Driving/*` |
| Phone UI | `DashMirror/Phone/*` |
| Signing config | `Config/Signing.xcconfig`, `Config/Local.xcconfig.example` |
| App icon | `Design/AppIcon/mobile-casting.svg` (Nucleo, not MIT) → `scripts/make-icon.sh` (needs `brew install librsvg`) |

Code comments are in German.

## Questions and reports

If something doesn't work or you want to know how a part works, open an
[issue](https://github.com/developer2013/dashmirror/issues). I'm happy to help. I can't give out IPAs or builds signed
with my entitlements.

Every car behaves a little differently (display size, multi-touch, day/night signal). If you try DashMirror, a
[car report](https://github.com/developer2013/dashmirror/issues/new?template=car-report.yml) helps, whether it works
or not. The logs contain speed, but no location.

## Credits

- [rPlayAI/cafari-lite](https://github.com/rPlayAI/cafari-lite) (MIT) showed that a plain `UIWindowScene` under
  `UIWindowSceneSessionRoleCarPlay` works with the CarPlay video and audio entitlements. No code was copied.
- App icon: *mobile-casting* by [Nucleo](https://nucleoapp.com/).

## Author

Made by Carsten Sachse ([carstensachse.de](https://www.carstensachse.de/)).

## License

Code: MIT, see [LICENSE](LICENSE).

The app icon is the *mobile-casting* icon from [Nucleo](https://nucleoapp.com/) and is not covered by the MIT license.
It is included under Nucleo's open-source allowance with their copyright notice (see
`Design/AppIcon/mobile-casting.svg`). Redistribution of the icon on its own is prohibited, so forks should replace it.
