//
//  ReplayBuffer.swift
//  DashMirror
//
//  Ringpuffer fuer die Sofort-Wiederholung: haelt die letzten 30 s des empfangenen H.264-Stroms, so wie er
//  ankommt (fertig kodiert). Speichern heisst dann nur noch verpacken (ClipWriter), kein Neukodieren – und
//  die Erweiterung mit ihrer 50-MB-Grenze merkt davon nichts.
//
//  Gespeichert wird in Gruppen ab je einem Schluesselbild (der Encoder setzt hoechstens alle 2 s eins),
//  denn ein Clip muss mit einem Schluesselbild beginnen. Weggeworfen wird immer eine ganze Gruppe.
//  Neues Bildformat oder neue Ausrichtung: Puffer leeren – ein Clip hat genau ein Format.
//
//  Laeuft auf dem Lese-Thread des Empfangs (Aufrufe aus MirrorPipeline), gelesen wird vom Hauptthread.
//

import CoreMedia
import Foundation

nonisolated final class ReplayBuffer: @unchecked Sendable {
    struct Frame: Sendable {
        let data: Data
        /// Aufnahmezeit in ns (Host-Uhr, wie im MirrorHeader).
        let time: UInt64
        let keyframe: Bool
    }

    /// Alles, was ClipWriter fuer eine Datei braucht. CMFormatDescription ist unveraenderlich.
    struct Snapshot: @unchecked Sendable {
        let format: CMVideoFormatDescription
        let orientation: UInt8
        let frames: [Frame]

        var seconds: Double {
            guard let first = frames.first, let last = frames.last, last.time > first.time else { return 0 }
            return Double(last.time - first.time) / 1_000_000_000
        }
    }

    static let window: UInt64 = 30 * 1_000_000_000
    /// Obergrenze fuer den Speicher der App (laeuft im Hintergrund neben dem Spiel). Bei 12 Mbit/s reichen
    /// 30 s fuer ~45 MB; bei 20 Mbit/s wird der Clip entsprechend kuerzer.
    static let maxBytes = 64 << 20

    private struct Group {
        var frames: [Frame]
        var bytes: Int
        var start: UInt64 { frames[0].time }
    }

    private let lock = NSLock()
    private var enabled = false
    private var format: CMVideoFormatDescription?
    private var orientation: UInt8 = 1
    private var groups: [Group] = []
    private var bytes = 0

    func setEnabled(_ on: Bool) {
        lock.withLock {
            enabled = on
            if !on { removeAll() }
        }
    }

    func clear() {
        lock.withLock { removeAll() }
    }

    /// Neues Bildformat (SPS/PPS) – alte Bilder passen nicht mehr dazu.
    func setFormat(_ description: CMVideoFormatDescription) {
        lock.withLock {
            if let format, CMFormatDescriptionEqual(format, otherFormatDescription: description) { return }
            format = description
            removeAll()
        }
    }

    func append(_ payload: UnsafeRawBufferPointer, time: UInt64, keyframe: Bool, orientation: UInt8) {
        lock.lock()
        defer { lock.unlock() }
        guard enabled, format != nil, let base = payload.baseAddress, payload.count > 0 else { return }
        if orientation != self.orientation {
            self.orientation = orientation
            removeAll()
        }
        // Zeit laeuft rueckwaerts = andere Quelle oder Uhrsprung: neu anfangen.
        if let last = groups.last?.frames.last, time < last.time { removeAll() }

        let frame = Frame(data: Data(bytes: base, count: payload.count), time: time, keyframe: keyframe)
        if keyframe {
            groups.append(Group(frames: [frame], bytes: payload.count))
        } else if !groups.isEmpty {
            groups[groups.count - 1].frames.append(frame)
            groups[groups.count - 1].bytes += payload.count
        } else {
            return      // vor dem ersten Schluesselbild ist nichts brauchbar
        }
        bytes += payload.count

        // Vorderste Gruppe weg, solange die naechste schon alleine das Zeitfenster abdeckt (oder zu viel Speicher).
        while groups.count > 1, groups[1].start + Self.window <= time || bytes > Self.maxBytes {
            bytes -= groups.removeFirst().bytes
        }
    }

    /// Kopie fuers Speichern (Data ist copy-on-write, das kostet praktisch nichts). nil = nichts da.
    func snapshot() -> Snapshot? {
        lock.withLock {
            guard let format, !groups.isEmpty else { return nil }
            return Snapshot(format: format, orientation: orientation, frames: groups.flatMap(\.frames))
        }
    }

    /// Erwartet gehaltenes `lock`.
    private func removeAll() {
        groups.removeAll()
        bytes = 0
    }
}
