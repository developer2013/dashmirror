//
//  BroadcastButton.swift
//  DashMirror
//
//  Startet/stoppt die Uebertragung ueber den System-Dialog von ReplayKit. Eine App darf das nicht selbst,
//  nur der Nutzer im System-Dialog. Dessen Knopf (RPSystemBroadcastPickerView) ist klein und kaum
//  gestaltbar – deshalb liegt er unsichtbar daneben und wird von unserem grossen Knopf ausgeloest.
//  `preferredExtension` sorgt dafuer, dass im Dialog gleich unsere Erweiterung ausgewaehlt ist.
//

import ReplayKit
import SwiftUI

struct BroadcastButton: View {
    let running: Bool
    @Environment(\.locale) private var locale

    var body: some View {
        let _ = locale
        Button {
            BroadcastPicker.shared.show()
        } label: {
            Label(running ? String(localized: "Stop mirroring", bundle: .ui) : String(localized: "Start mirroring", bundle: .ui),
                  systemImage: running ? "stop.circle.fill" : "record.circle")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(running ? .red : .accentColor)
        .background(alignment: .center) {
            // Muss im Fenster haengen, sonst kann er den System-Dialog nicht zeigen.
            BroadcastPickerHost()
                .frame(width: 1, height: 1)
                .opacity(0.02)
                .accessibilityHidden(true)
        }
    }
}

@MainActor
final class BroadcastPicker {
    static let shared = BroadcastPicker()

    let view: RPSystemBroadcastPickerView = {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.preferredExtension = Mirror.broadcastExtensionID
        picker.showsMicrophoneButton = false
        return picker
    }()

    func show() {
        guard let button = view.subviews.compactMap({ $0 as? UIButton }).first else {
            MirrorLog.write("FEHLER: Knopf im Broadcast-Dialog nicht gefunden")
            return
        }
        MirrorLog.write("Broadcast-Dialog geoeffnet")
        button.sendActions(for: .allTouchEvents)
    }
}

private struct BroadcastPickerHost: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView { BroadcastPicker.shared.view }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

/// Kleine Vorschau des empfangenen Stroms am iPhone – nur fuers Testbild gedacht. Bei echter Spiegelung
/// wuerde sie sich selbst spiegeln (Tunnelblick).
struct MirrorPreview: UIViewRepresentable {
    let orientation: CGImagePropertyOrientation
    let fit: MirrorFit

    func makeUIView(context: Context) -> MirrorVideoView {
        let view = MirrorVideoView()
        MirrorHub.shared.attach(view.renderer)
        return view
    }

    func updateUIView(_ view: MirrorVideoView, context: Context) {
        view.orientation = orientation
        view.fit = fit
    }

    static func dismantleUIView(_ view: MirrorVideoView, coordinator: ()) {
        MirrorHub.shared.detach(view.renderer)
    }
}
