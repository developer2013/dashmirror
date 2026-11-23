//
//  LogView.swift
//  DashMirror
//
//  Zeigt die letzten Zeilen beider Protokolle (App und Broadcast-Erweiterung) aus dem gemeinsamen
//  Container und kann sie teilen – fuer die Auswertung nach einer Testfahrt ohne Mac.
//

import SwiftUI

struct LogView: View {
    @State private var text = ""

    private var files: [URL] {
        [MirrorLog.appLogName, MirrorLog.broadcastLogName].compactMap { MirrorLog.url($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? String(localized: "No entries yet.") : text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Reload", systemImage: "arrow.clockwise") { load() }
            }
            if !files.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(items: files)
                }
            }
        }
        .task { load() }
    }

    private func load() {
        text = [(String(localized: "App"), MirrorLog.appLogName), (String(localized: "Extension"), MirrorLog.broadcastLogName)]
            .map { title, name in
                let content = MirrorLog.url(name).flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
                let lines = content.split(separator: "\n", omittingEmptySubsequences: true).suffix(150)
                return "── \(title) ──\n" + (lines.isEmpty ? String(localized: "(empty)") : lines.joined(separator: "\n"))
            }
            .joined(separator: "\n\n")
    }
}
