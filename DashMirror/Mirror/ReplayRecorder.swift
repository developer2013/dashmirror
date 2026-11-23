//
//  ReplayRecorder.swift
//  DashMirror
//
//  Sofort-Wiederholung: speichert auf Knopfdruck (Auto oder iPhone) die letzten 30 s als Clip.
//  Ablauf: Snapshot aus dem ReplayBuffer -> MP4 in Documents/Clips (ClipWriter) -> nach Fotos, Datei weg.
//
//  Fotos-Zugriff ("nur hinzufuegen") fragt iOS nur am iPhone ab, und nur wenn unser iPhone-Fenster vorn ist.
//  Im Auto laeuft vorne aber das Spiel – deshalb bleibt ein Clip ohne Zugriff erst in der Dateien-App
//  (Auf meinem iPhone > DashMirror > Clips) und wandert nach Fotos, sobald der Zugriff erlaubt ist.
//

import Foundation
import Observation
import Photos
import UIKit

@Observable
final class ReplayRecorder {
    enum Outcome {
        case photos(seconds: Int)
        case files(seconds: Int)
        case empty
        case failed

        /// Bei jedem Lesen neu uebersetzt – so folgt auch eine alte Meldung dem Sprachwechsel.
        var message: String {
            switch self {
            case .photos(let seconds):
                String(format: String(localized: "Clip saved to Photos (%d s)", bundle: .ui), locale: .ui, seconds)
            case .files(let seconds):
                String(format: String(localized: "Clip saved (%d s) – allow Photos access on the iPhone to move it there", bundle: .ui),
                       locale: .ui, seconds)
            case .empty:
                String(localized: "Nothing to save yet – the clip starts with the mirroring", bundle: .ui)
            case .failed:
                String(localized: "The clip could not be saved", bundle: .ui)
            }
        }
    }

    var enabled = UserDefaults.standard.object(forKey: "replayEnabled") as? Bool ?? true {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: "replayEnabled")
            buffer.setEnabled(enabled)
            MirrorLog.write("Sofort-Wiederholung \(enabled ? "an" : "aus")")
        }
    }
    private(set) var isSaving = false
    private(set) var lastOutcome: Outcome?
    /// Clips in Documents/Clips, die noch auf den Fotos-Zugriff warten.
    private(set) var pendingClips = 0
    private(set) var photosAccess = PHPhotoLibrary.authorizationStatus(for: .addOnly)

    @ObservationIgnored let buffer: ReplayBuffer

    init(buffer: ReplayBuffer) {
        self.buffer = buffer
        buffer.setEnabled(enabled)
        pendingClips = Self.pendingFiles().count
    }

    var hasPhotosAccess: Bool { photosAccess == .authorized || photosAccess == .limited }

    // MARK: Speichern

    func save() async -> Outcome {
        guard !isSaving else { return lastOutcome ?? .empty }
        isSaving = true
        defer { isSaving = false }
        let outcome = await makeClip()
        lastOutcome = outcome
        return outcome
    }

    private func makeClip() async -> Outcome {
        guard enabled, let snapshot = buffer.snapshot() else {
            MirrorLog.write("Clip: nichts im Puffer")
            return .empty
        }
        guard let directory = Self.directory else { return .failed }
        let url = directory.appendingPathComponent(Self.fileName())
        let seconds: Int
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let started = Date()
            // Eigener Thread: unter Approachable Concurrency liefe eine nonisolated-async-Funktion sonst
            // auf dem Hauptthread des Aufrufers.
            let length = try await Task.detached(priority: .userInitiated) {
                try await ClipWriter.write(snapshot, to: url)
            }.value
            seconds = Int(length.rounded())
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            MirrorLog.write(String(format: "Clip geschrieben: %.1f s, %d Bilder, %.1f MB, Ausrichtung %d, in %.2f s",
                                   length, snapshot.frames.count, Double(size) / 1_000_000,
                                   Int(snapshot.orientation), Date().timeIntervalSince(started)))
        } catch {
            MirrorLog.write("Clip FEHLER: \(error)")
            try? FileManager.default.removeItem(at: url)
            return .failed
        }
        #if DEBUG
        // Test-Hilfe (siehe MirrorHub.start): Datei behalten, Fotos nicht anfassen.
        if UserDefaults.standard.object(forKey: "MirrorReplayTest") != nil {
            refreshPending()
            return .files(seconds: seconds)
        }
        #endif
        if await ensurePhotosAccess(), await importToPhotos(url) {
            return .photos(seconds: seconds)
        }
        refreshPending()
        return .files(seconds: seconds)
    }

    // MARK: Fotos

    /// Vom iPhone-Knopf: Zugriff erfragen und wartende Clips uebernehmen.
    func requestPhotosAccess() async {
        photosAccess = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        MirrorLog.write("Fotos-Zugriff: \(photosAccess.rawValue)")
        await importPending()
    }

    /// Wartende Clips nach Fotos (beim Oeffnen der App am iPhone und nach Erteilen des Zugriffs).
    func importPending() async {
        photosAccess = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard hasPhotosAccess else { return }
        for url in Self.pendingFiles() {
            _ = await importToPhotos(url)
        }
        refreshPending()
    }

    private func ensurePhotosAccess() async -> Bool {
        photosAccess = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if photosAccess == .notDetermined, Self.phoneWindowActive {
            photosAccess = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        return hasPhotosAccess
    }

    private func importToPhotos(_ url: URL) async -> Bool {
        do {
            try await PHPhotoLibrary.shared().performChanges {
                _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
            try? FileManager.default.removeItem(at: url)
            MirrorLog.write("Clip in Fotos: \(url.lastPathComponent)")
            return true
        } catch {
            MirrorLog.write("Clip nicht in Fotos (\(url.lastPathComponent)): \(error.localizedDescription)")
            return false
        }
    }

    // MARK: Dateien

    private func refreshPending() {
        pendingClips = Self.pendingFiles().count
    }

    /// Documents/Clips – dank UIFileSharingEnabled in der Dateien-App sichtbar.
    private static var directory: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Clips", isDirectory: true)
    }

    private static func pendingFiles() -> [URL] {
        guard let directory else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "mp4" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func fileName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "DashMirror \(formatter.string(from: Date())).mp4"
    }

    /// Nur wenn das iPhone-Fenster vorn ist, kann iOS den Zugriffsdialog zeigen. Das CarPlay-Fenster zaehlt
    /// nicht – `applicationState` waere auch dann `.active`, wenn am iPhone das Spiel laeuft.
    private static var phoneWindowActive: Bool {
        UIApplication.shared.connectedScenes.contains {
            $0.session.role == .windowApplication && $0.activationState == .foregroundActive
        }
    }
}
