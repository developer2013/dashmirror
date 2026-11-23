//
//  MirrorLog.swift
//  DashMirror – gemeinsam fuer App und Broadcast-Erweiterung
//
//  Protokoll fuer Tests im Auto, wo kein Mac mitliest. Beide Prozesse schreiben in den gemeinsamen
//  Container (Logs/app.log bzw. Logs/broadcast.log), damit die App beide anzeigen und teilen kann, und
//  zusaetzlich in ihren eigenen Container (Documents/Logs/...) fuer devicectl.
//  Ausserdem geht jede Zeile ins System-Log (Subsystem "DashMirror").
//

import Foundation
import os

nonisolated enum MirrorLog {
    static let appLogName = "app.log"
    static let broadcastLogName = "broadcast.log"

    private static let isExtension = Bundle.main.bundleURL.pathExtension == "appex"
    private static let fileName = isExtension ? broadcastLogName : appLogName
    private static let logger = Logger(subsystem: "DashMirror", category: isExtension ? "broadcast" : "app")
    private static let queue = DispatchQueue(label: "mirror.log", qos: .utility)
    private static let maxSize = 1_000_000

    /// Ortszeit, damit die Zeilen zur Uhr im Auto passen.
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static var directory: URL? { Mirror.containerURL?.appendingPathComponent("Logs", isDirectory: true) }

    static func url(_ name: String) -> URL? { directory?.appendingPathComponent(name) }

    static func write(_ message: String) {
        logger.log("\(message, privacy: .public)")
        let line = "\(stamp.string(from: Date())) \(message)\n"
        queue.async { append(line) }
    }

    /// Zweites Ziel im EIGENEN Container des Prozesses: Nur den kann `devicectl device copy from` per Kabel lesen.
    /// Der gemeinsame Container ist dafuer gesperrt (gemessen am 23.11.2026: "outside the directories the
    /// container access policy allows").
    private static let ownDirectory = URL.documentsDirectory.appendingPathComponent("Logs", isDirectory: true)

    private static func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        if let directory { append(data, to: directory) }
        append(data, to: ownDirectory)
    }

    private static func append(_ data: Data, to directory: URL) {
        let file = directory.appendingPathComponent(fileName)
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        // Einfache Rotation: ab 1 MB wird die alte Datei zu *.old.log
        if let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int, size > maxSize {
            let old = directory.appendingPathComponent(fileName.replacingOccurrences(of: ".log", with: ".old.log"))
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: file, to: old)
        }
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: file)
        }
    }
}
