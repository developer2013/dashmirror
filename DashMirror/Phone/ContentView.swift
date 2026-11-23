//
//  ContentView.swift
//  DashMirror
//
//  iPhone-Oberflaeche: Spiegelung starten, Zustand von Empfang/Auto/Fahrsperre, Einstellungen, Testbild.
//  Im Auto selbst sieht man davon nichts – dort laeuft das gespiegelte Spiel.
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
                    Text("Danach zum Spiel wechseln. Gesteuert wird per Bluetooth-Controller am iPhone, der Ton läuft wie gewohnt über das Auto.")
                }

                Section("Empfang") {
                    LabeledContent("Quelle", value: sourceText)
                    LabeledContent("Bildrate", value: String(format: "%.0f B/s", hub.framesPerSecond))
                    LabeledContent("Datenrate", value: String(format: "%.1f Mbit/s", hub.megabitsPerSecond))
                    LabeledContent("Latenz bis zur App", value: hub.latencyMs.map { String(format: "%.0f ms", $0) } ?? "–")
                    LabeledContent("Auflösung", value: hub.frameSize == .zero ? "–"
                                   : "\(Int(hub.frameSize.width)) × \(Int(hub.frameSize.height))")
                    if hub.droppedPerSecond > 0 {
                        LabeledContent("Verworfen", value: String(format: "%.1f/s", hub.droppedPerSecond))
                    }
                    if let error = hub.receiverError {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }

                Section {
                    LabeledContent("CarPlay", value: carText)
                    Picker("Bildformat", selection: $hub.fit) {
                        ForEach(MirrorFit.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Toggle("Schwarze Ränder abschneiden", isOn: $hub.autoCrop)
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent("Zoom", value: String(format: "%.1f×", hub.zoom))
                        Slider(value: $hub.zoom, in: 1...3, step: 0.05)
                    }
                    if hub.zoom > 1.001 || hub.panFraction != .zero {
                        Button("Zoom und Ausschnitt zurücksetzen") { hub.resetZoom() }
                    }
                } header: {
                    Text("Auto")
                } footer: {
                    Text("iPhone quer halten füllt breite Autodisplays am besten. Ränder abschneiden entfernt schwarze Streifen, die Spiele selbst lassen (z. B. wegen der Dynamic Island). Im Auto: tippen = Bildformat, zwei Finger = zoomen, ziehen = Ausschnitt, doppelt tippen = zurücksetzen.")
                }

                DrivingSection(monitor: hub.driving)

                Section {
                    Picker("Bildrate", selection: $hub.frameRate) {
                        Text("30 B/s").tag(30)
                        Text("60 B/s").tag(60)
                    }
                    .pickerStyle(.segmented)
                    Picker("Qualität", selection: $hub.bitrateMbps) {
                        Text("Sparsam (6 Mbit/s)").tag(6)
                        Text("Normal (12 Mbit/s)").tag(12)
                        Text("Hoch (20 Mbit/s)").tag(20)
                    }
                } header: {
                    Text("Qualität")
                } footer: {
                    Text("Gilt sofort, auch während einer laufenden Übertragung. Die Auflösung richtet sich automatisch nach dem Autodisplay.")
                }

                Section {
                    Toggle("Testbild senden", isOn: Binding(get: { hub.testPatternRunning },
                                                            set: { hub.setTestPattern($0) }))
                } header: {
                    Text("Test")
                } footer: {
                    Text("Schickt ein Testbild durch dieselbe Kette wie die Spiegelung (Encoder, Socket, Anzeige). Steht „↑ oben“ aufrecht und lesbar, stimmt auch die Drehung.")
                }

                Section("So geht’s") {
                    Step(1, "Bluetooth-Controller mit dem iPhone koppeln.")
                    Step(2, "iPhone mit CarPlay verbinden und im Auto „DashMirror“ öffnen.")
                    Step(3, "Hier „Spiegelung starten“ › „Übertragung starten“.")
                    Step(4, "Zum Spiel wechseln, iPhone quer ablegen und mit dem Controller spielen.")
                    Step(5, "Automatische Sperre auf „Nie“ stellen – sonst steht das Bild, sobald sich das iPhone sperrt.")
                }

                Section {
                    NavigationLink("Protokoll") { LogView() }
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
        guard hub.sourceConnected else { return "keine" }
        switch hub.source {
        case .screen: return "iPhone-Bildschirm"
        case .testPattern: return "Testbild"
        case nil: return "verbunden"
        }
    }

    private var carText: String {
        guard hub.carConnected else { return "nicht verbunden" }
        let size = hub.carPixelSize == .zero ? "" : " · \(Int(hub.carPixelSize.width)) × \(Int(hub.carPixelSize.height)) px"
        return (hub.carForeground ? "verbunden" : "im Hintergrund") + size
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
        guard running else { return "Bereit" }
        return hub.testPatternRunning ? "Testbild läuft" : "Spiegelung läuft"
    }
    private var subtitle: String {
        let car = hub.carConnected ? "Auto verbunden" : "Kein Auto verbunden"
        if hub.carConnected, hub.driving.isLocked { return car + " · Fahrsperre aktiv" }
        return car
    }
}

private struct DrivingSection: View {
    let monitor: DrivingLockMonitor

    var body: some View {
        Section {
            LabeledContent("Bild im Auto") {
                Text(monitor.isLocked ? "gesperrt" : "frei")
                    .foregroundStyle(monitor.isLocked ? .orange : .green)
            }
            LabeledContent("Geschwindigkeit",
                           value: monitor.signals.speedKmh.map { String(format: "%.0f km/h", $0) } ?? "unbekannt")
            LabeledContent("Bewegung", value: motionText)
            LabeledContent("Stillstand seit",
                           value: monitor.signals.secondsSinceMoving.map { String(format: "%.0f s", $0) } ?? "–")
            LabeledContent("Standort", value: DrivingLockMonitor.describe(monitor.authorization))
            if monitor.authorization == .notDetermined {
                Button("Standort erlauben") { monitor.requestPermission() }
            } else if monitor.authorization == .denied || monitor.authorization == .restricted {
                Button("In den Einstellungen erlauben") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
        } header: {
            Text("Fahrsperre")
        } footer: {
            Text("Fährt das Auto, wird das Bild im Auto sofort ausgeblendet. Ohne Standort bleibt es aus.")
        }
    }

    private var motionText: String {
        guard monitor.motionAvailable else { return "nicht verfügbar" }
        let s = monitor.signals
        if s.automotive { return s.stationary ? "im Auto, steht" : "im Auto, fährt" }
        return s.stationary ? "steht" : "–"
    }
}

private struct Step: View {
    let number: Int
    let text: String

    init(_ number: Int, _ text: String) {
        self.number = number
        self.text = text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)").font(.subheadline.bold()).foregroundStyle(.tint).frame(width: 18)
            Text(text).font(.subheadline)
        }
    }
}

#Preview {
    ContentView().environment(MirrorHub.shared).preferredColorScheme(.dark)
}
