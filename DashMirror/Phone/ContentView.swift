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
import SwiftUI

struct ContentView: View {
    @Environment(MirrorHub.self) private var hub
    @Environment(\.scenePhase) private var scenePhase
    @State private var holdsDrivingMonitor = false

    var body: some View {
        @Bindable var hub = hub
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
                    LabeledContent("Frame rate", value: String(format: String(localized: "%.0f fps"), locale: .current, hub.framesPerSecond))
                    LabeledContent("Data rate", value: String(format: "%.1f Mbit/s", locale: .current, hub.megabitsPerSecond))
                    LabeledContent("Latency to the app", value: hub.latencyMs.map { String(format: "%.0f ms", locale: .current, $0) } ?? "–")
                    LabeledContent("Resolution", value: hub.frameSize == .zero ? "–"
                                   : "\(Int(hub.frameSize.width)) × \(Int(hub.frameSize.height))")
                    if hub.droppedPerSecond > 0 {
                        LabeledContent("Dropped", value: String(format: "%.1f/s", locale: .current, hub.droppedPerSecond))
                    }
                    if let error = hub.receiverError {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }

                Section {
                    LabeledContent("CarPlay", value: carText)
                    Picker("Picture format", selection: $hub.fit) {
                        ForEach(MirrorFit.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Toggle("Cut off black borders", isOn: $hub.autoCrop)
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent("Zoom", value: String(format: "%.1f×", locale: .current, hub.zoom))
                        Slider(value: $hub.zoom, in: 1...3, step: 0.05)
                    }
                    if hub.zoom > 1.001 || hub.panFraction != .zero {
                        Button("Reset zoom and position") { hub.resetZoom() }
                    }
                } header: {
                    Text("Car")
                } footer: {
                    Text("Holding the iPhone in landscape fills wide car displays best. Cutting off borders removes black bars that games leave themselves (e.g. for the Dynamic Island). In the car: tap = picture format, two fingers = zoom (if the car display supports it), drag = move.")
                }

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
                } header: {
                    Text("Quality")
                } footer: {
                    Text("Applies immediately, even during a running broadcast. The resolution follows the car display automatically.")
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
                    NavigationLink("Log") { LogView() }
                }
            }
            .navigationTitle("DashMirror")
        }
        // Die Fahrsperre-Anzeige am iPhone nur live halten, solange die App vorn ist (GPS kostet Akku).
        .onChange(of: scenePhase, initial: true) { _, phase in
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
        guard hub.sourceConnected else { return String(localized: "none") }
        switch hub.source {
        case .screen: return String(localized: "iPhone screen")
        case .testPattern: return String(localized: "Test pattern")
        case nil: return String(localized: "connected")
        }
    }

    private var carText: String {
        guard hub.carConnected else { return String(localized: "not connected") }
        let size = hub.carPixelSize == .zero ? "" : " · \(Int(hub.carPixelSize.width)) × \(Int(hub.carPixelSize.height)) px"
        return (hub.carForeground ? String(localized: "connected") : String(localized: "in background")) + size
    }
}

private struct StatusHeader: View {
    @Environment(MirrorHub.self) private var hub

    var body: some View {
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
        guard running else { return String(localized: "Ready") }
        return hub.testPatternRunning ? String(localized: "Test pattern running") : String(localized: "Mirroring")
    }
    private var subtitle: String {
        let car = hub.carConnected ? String(localized: "Car connected") : String(localized: "No car connected")
        if hub.carConnected, hub.driving.isLocked { return car + " · " + String(localized: "Driving lock active") }
        return car
    }
}

private struct DrivingSection: View {
    let monitor: DrivingLockMonitor

    var body: some View {
        Section {
            LabeledContent("Picture in the car") {
                if monitor.isLocked {
                    Text("locked").foregroundStyle(.orange)
                } else {
                    Text("unlocked").foregroundStyle(.green)
                }
            }
            LabeledContent("Speed",
                           value: monitor.signals.speedKmh.map { String(format: "%.0f km/h", locale: .current, $0) } ?? String(localized: "unknown"))
            LabeledContent("Motion", value: motionText)
            LabeledContent("Stationary for",
                           value: monitor.signals.secondsSinceMoving.map { String(format: "%.0f s", locale: .current, $0) } ?? "–")
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
        guard monitor.motionAvailable else { return String(localized: "not available") }
        let s = monitor.signals
        if s.automotive { return s.stationary ? String(localized: "in car, standing") : String(localized: "in car, moving") }
        return s.stationary ? String(localized: "standing") : "–"
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
