//
//  ContentView.swift
//  DashMirror
//
//  iPhone-Oberflaeche: Spiegelung starten, Zustand von Empfang/Auto/Fahrsperre, Einstellungen, Testbild.
//  Im Auto selbst sieht man davon nichts – dort laeuft das gespiegelte Spiel.
//
//  Texte: Englisch ist die Ausgangssprache, Deutsch steht in Shared/Localizable.xcstrings. Literale in Text,
//  Section, Button usw. werden automatisch uebersetzt; berechnete Texte laufen ueber String(localized:).
//

import CoreLocation
import Photos
import SwiftUI

struct ContentView: View {
    @Environment(MirrorHub.self) private var hub
    @Environment(\.scenePhase) private var scenePhase
    @State private var holdsDrivingMonitor = false
    @Environment(LanguageStore.self) private var language
    /// Abhaengigkeit: Bei Sprachwechsel werden die berechneten Texte (Quelle, CarPlay …) neu erzeugt.
    @Environment(\.locale) private var locale

    var body: some View {
        @Bindable var hub = hub
        @Bindable var language = language
        let _ = locale
        NavigationStack {
            Form {
                Section {
                    StatusHeader()
                    if hub.testPatternRunning {
                        // Vorschau nur fuers Testbild – bei echter Spiegelung wuerde sie sich selbst spiegeln.
                        MirrorPreview(orientation: hub.orientation, fit: .fit)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    }
                    BroadcastButton(running: hub.source == .screen)
                } footer: {
                    Text("Then switch to your game. You control it with a Bluetooth controller on the iPhone; sound plays through the car as usual.")
                }

                Section("Receiving") {
                    LabeledContent("Source", value: sourceText)
                    LabeledContent("Frame rate", value: String(format: String(localized: "%.0f fps", bundle: .ui), locale: .ui, hub.framesPerSecond))
                    LabeledContent("Data rate", value: String(format: "%.1f Mbit/s", locale: .ui, hub.megabitsPerSecond))
                    LabeledContent("Latency to the app", value: hub.latencyMs.map { String(format: "%.0f ms", locale: .ui, $0) } ?? "–")
                    LabeledContent("Resolution", value: hub.frameSize == .zero ? "–"
                                   : "\(Int(hub.frameSize.width)) × \(Int(hub.frameSize.height))")
                    if hub.droppedPerSecond > 0 {
                        LabeledContent("Dropped", value: String(format: "%.1f/s", locale: .ui, hub.droppedPerSecond))
                    }
                    if let error = hub.receiverError {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }

                Section {
                    LabeledContent("CarPlay", value: carText)
                    Picker("Picture format", selection: $hub.fit) {
                        ForEach(MirrorFit.allCases) { Text(verbatim: $0.title).tag($0) }
                    }
                    Text(verbatim: hub.fit.detail).font(.caption).foregroundStyle(.secondary)
                    Toggle("Blurred background instead of black bars", isOn: $hub.ambientBackground)
                    Toggle("Cut off black borders", isOn: $hub.autoCrop)
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent("Zoom", value: String(format: "%.1f×", locale: .ui, hub.zoom))
                        Slider(value: $hub.zoom, in: 1...3, step: 0.05)
                    }
                    if hub.zoom > 1.001 || hub.panFraction != .zero {
                        Button("Reset zoom and position") { hub.resetZoom() }
                    }
                } header: {
                    Text("Car")
                } footer: {
                    Text("Holding the iPhone in landscape fills wide car displays best. Cutting off borders removes black bars that games leave themselves (e.g. for the Dynamic Island). In the car: tap = controls (picture format, clip, info), press and hold = save clip, two fingers = zoom (if the car display supports it), drag = move.")
                }

                Section {
                    Picker("Night mode", selection: $hub.nightMode) {
                        ForEach(NightMode.allCases) { Text(verbatim: $0.title).tag($0) }
                    }
                    if hub.nightMode != .off {
                        VStack(alignment: .leading, spacing: 4) {
                            LabeledContent("Dimming", value: String(format: "%.0f %%", locale: .ui, hub.nightStrength * 100))
                            Slider(value: $hub.nightStrength, in: NightMode.strengthRange)
                        }
                    }
                    LabeledContent("Car reports", value: carAppearanceText)
                } header: {
                    Text("Night mode")
                } footer: {
                    Text("Dims the picture in the car at night so bright games don’t dazzle. “Automatic” follows the car’s day/night switch (headlights or light sensor). If the car always reports night, choose “Always” or “Off”.")
                }

                ReplaySection(replay: hub.replay, sourceConnected: hub.sourceConnected)

                DrivingSection(monitor: hub.driving)

                Section {
                    Picker("Frame rate", selection: $hub.frameRate) {
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    }
                    .pickerStyle(.segmented)
                    Picker("Quality", selection: $hub.bitrateMbps) {
                        Text("Economy (6 Mbit/s)").tag(6)
                        Text("Normal (12 Mbit/s)").tag(12)
                        Text("High (20 Mbit/s)").tag(20)
                    }
                    Toggle("Heat protection", isOn: $hub.heatProtection)
                    LabeledContent("iPhone temperature", value: hub.thermalState.title)
                    if hub.heatReducing {
                        Text(verbatim: reducedText).font(.caption).foregroundStyle(.orange)
                    }
                } header: {
                    Text("Quality")
                } footer: {
                    Text("Applies immediately, even during a running broadcast. The resolution follows the car display automatically. Heat protection lowers resolution and data rate when the iPhone gets hot, the frame rate only at the hottest level – before iOS throttles the game.")
                }

                Section {
                    Toggle("Send test pattern", isOn: Binding(get: { hub.testPatternRunning },
                                                              set: { hub.setTestPattern($0) }))
                } header: {
                    Text("Test")
                } footer: {
                    Text("Sends a test pattern through the same chain as the mirroring (encoder, socket, display). If “↑ top” stands upright and readable, rotation is correct too.")
                }

                Section("How it works") {
                    Step(1, "Pair a Bluetooth controller with the iPhone.")
                    Step(2, "Connect the iPhone to CarPlay and open “DashMirror” in the car.")
                    Step(3, "Tap “Start mirroring” here › “Start Broadcast”.")
                    Step(4, "Switch to your game, put the iPhone down in landscape and play with the controller.")
                    Step(5, "Set Auto-Lock to “Never” – locking the iPhone ends the broadcast.")
                }

                Section {
                    Picker("App language", selection: $language.selection) {
                        ForEach(AppLanguage.allCases) { Text(verbatim: $0.title).tag($0) }
                    }
                } header: {
                    Text("Language")
                } footer: {
                    Text("Follows the iPhone language unless you pick one here. Changes apply immediately, in the car as well.")
                }

                Section {
                    NavigationLink("Log") { LogView() }
                }

                Section {
                    LabeledContent("Developer") {
                        Link(destination: Self.website) { Text(verbatim: "carstensachse.de") }
                    }
                    LabeledContent("Version", value: Self.version)
                } header: {
                    Text("About")
                } footer: {
                    Text("DashMirror is open source (MIT license).")
                }
            }
            .navigationTitle("DashMirror")
        }
        // Die Fahrsperre-Anzeige am iPhone nur live halten, solange die App vorn ist (GPS kostet Akku).
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                // Clips, die im Auto ohne Fotos-Zugriff gespeichert wurden, jetzt nachholen.
                Task { await hub.replay.importPending() }
            }
            if phase == .active, !holdsDrivingMonitor {
                hub.driving.acquire()
                holdsDrivingMonitor = true
            } else if phase != .active, holdsDrivingMonitor {
                hub.driving.release()
                holdsDrivingMonitor = false
            }
        }
    }

    private var sourceText: String {
        guard hub.sourceConnected else { return String(localized: "none", bundle: .ui) }
        switch hub.source {
        case .screen: return String(localized: "iPhone screen", bundle: .ui)
        case .testPattern: return String(localized: "Test pattern", bundle: .ui)
        case nil: return String(localized: "connected", bundle: .ui)
        }
    }

    private static let website = URL(string: "https://www.carstensachse.de/")!

    private static var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    private var carAppearanceText: String {
        guard let dark = hub.carIsDark else { return "–" }
        return dark ? String(localized: "night", bundle: .ui) : String(localized: "day", bundle: .ui)
    }

    private var reducedText: String {
        let settings = hub.effectiveSettings
        return String(format: String(localized: "Lowered to max. %1$d × %2$d, %3$d fps, %4$d Mbit/s", bundle: .ui),
                      locale: .ui, settings.maxLongSide, settings.maxShortSide, settings.frameRate,
                      settings.bitrate / 1_000_000)
    }

    private var carText: String {
        guard hub.carConnected else { return String(localized: "not connected", bundle: .ui) }
        let size = hub.carPixelSize == .zero ? "" : " · \(Int(hub.carPixelSize.width)) × \(Int(hub.carPixelSize.height)) px"
        return (hub.carForeground ? String(localized: "connected", bundle: .ui) : String(localized: "in background", bundle: .ui)) + size
    }
}

private struct StatusHeader: View {
    @Environment(MirrorHub.self) private var hub
    @Environment(\.locale) private var locale

    var body: some View {
        let _ = locale
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private var running: Bool { hub.sourceConnected }
    private var symbol: String { running ? "dot.radiowaves.left.and.right" : "rectangle.on.rectangle" }
    private var color: Color { running ? .green : .secondary }
    private var title: String {
        guard running else { return String(localized: "Ready", bundle: .ui) }
        return hub.testPatternRunning ? String(localized: "Test pattern running", bundle: .ui) : String(localized: "Mirroring", bundle: .ui)
    }
    private var subtitle: String {
        let car = hub.carConnected ? String(localized: "Car connected", bundle: .ui) : String(localized: "No car connected", bundle: .ui)
        if hub.carConnected, hub.driving.isLocked { return car + " · " + String(localized: "Driving lock active", bundle: .ui) }
        return car
    }
}

/// Sofort-Wiederholung: an/aus, Clip vom iPhone aus speichern, Fotos-Zugriff und wartende Clips.
private struct ReplaySection: View {
    @Bindable var replay: ReplayRecorder
    let sourceConnected: Bool
    @Environment(\.locale) private var locale

    var body: some View {
        let _ = locale
        Section {
            Toggle("Keep the last 30 seconds", isOn: $replay.enabled)
            Button {
                Task { _ = await replay.save() }
            } label: {
                Label(replay.isSaving ? String(localized: "Saving…", bundle: .ui)
                                      : String(localized: "Save last 30 seconds", bundle: .ui),
                      systemImage: "record.circle")
            }
            .disabled(!replay.enabled || replay.isSaving || !sourceConnected)
            if let outcome = replay.lastOutcome {
                Text(verbatim: outcome.message).font(.caption).foregroundStyle(.secondary)
            }
            if replay.pendingClips > 0 {
                LabeledContent("Waiting for Photos", value: "\(replay.pendingClips)")
            }
            if replay.photosAccess == .notDetermined {
                Button("Allow Photos access") { Task { await replay.requestPhotosAccess() } }
            } else if !replay.hasPhotosAccess {
                Button("Allow in Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
        } header: {
            Text("Instant replay")
        } footer: {
            Text("Saves what just happened as a video, without sound. In the car: tap › “Save clip”, or press and hold. Clips go to Photos; until access is allowed they wait in the Files app (On My iPhone › DashMirror › Clips).")
        }
    }
}

private struct DrivingSection: View {
    let monitor: DrivingLockMonitor
    @Environment(\.locale) private var locale

    var body: some View {
        let _ = locale
        Section {
            LabeledContent("Picture in the car") {
                if monitor.isLocked {
                    Text("locked").foregroundStyle(.orange)
                } else {
                    Text("unlocked").foregroundStyle(.green)
                }
            }
            LabeledContent("Speed",
                           value: monitor.signals.speedKmh.map { String(format: "%.0f km/h", locale: .ui, $0) } ?? String(localized: "unknown", bundle: .ui))
            LabeledContent("Motion", value: motionText)
            LabeledContent("Stationary for",
                           value: monitor.signals.secondsSinceMoving.map { String(format: "%.0f s", locale: .ui, $0) } ?? "–")
            LabeledContent("Location", value: DrivingLockMonitor.describe(monitor.authorization))
            if monitor.authorization == .notDetermined {
                Button("Allow location") { monitor.requestPermission() }
            } else if monitor.authorization == .denied || monitor.authorization == .restricted {
                Button("Allow in Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
        } header: {
            Text("Driving lock")
        } footer: {
            Text("When the car moves, the picture in the car disappears immediately. Without location access it stays off.")
        }
    }

    private var motionText: String {
        guard monitor.motionAvailable else { return String(localized: "not available", bundle: .ui) }
        let s = monitor.signals
        if s.automotive { return s.stationary ? String(localized: "in car, standing", bundle: .ui) : String(localized: "in car, moving", bundle: .ui) }
        return s.stationary ? String(localized: "standing", bundle: .ui) : "–"
    }
}

private struct Step: View {
    let number: Int
    let text: LocalizedStringKey

    init(_ number: Int, _ text: LocalizedStringKey) {
        self.number = number
        self.text = text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: "\(number)").font(.subheadline.bold()).foregroundStyle(.tint).frame(width: 18)
            Text(text).font(.subheadline)
        }
    }
}

#Preview {
    ContentView().environment(MirrorHub.shared).preferredColorScheme(.dark)
}
