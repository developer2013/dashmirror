//
//  MirrorSender.swift
//  DashMirror – gemeinsam fuer App und Broadcast-Erweiterung
//
//  Client-Seite des Unix-Sockets. Verbindet sich alle 0,5 s neu, solange keine App zuhoert
//  (Uebertragung gestartet, bevor das Auto verbunden ist; App von iOS beendet; App neu gestartet).
//
//  Schreiben laeuft auf einer eigenen seriellen Queue, damit ReplayKit nie warten muss. `backlog` sagt dem
//  Encoder, wie viele Nachrichten noch anstehen – darueber laesst er Bilder VOR dem Kodieren aus.
//  Haengt die App (z. B. von iOS eingefroren), blockiert das Schreiben hoechstens 2 s (SO_SNDTIMEO),
//  dann wird getrennt und neu verbunden.
//

import CoreVideo
import Darwin
import Foundation
import Synchronization

nonisolated final class MirrorSender: @unchecked Sendable {
    /// Steuerbefehle der App (Schluesselbild, Vorgaben). Laeuft auf dem Lese-Thread.
    var onControl: (@Sendable (MirrorHeader, Data) -> Void)?
    var onConnect: (@Sendable () -> Void)?
    var onDisconnect: (@Sendable () -> Void)?

    private final class Connection: @unchecked Sendable {
        let fd: Int32
        /// Nur auf `writeQueue` lesen/schreiben – dort wird der fd auch geschlossen.
        var closed = false
        init(fd: Int32) { self.fd = fd }
    }

    private let path: String
    private let writeQueue = DispatchQueue(label: "mirror.sender.write", qos: .userInteractive)
    private let connectQueue = DispatchQueue(label: "mirror.sender.connect", qos: .utility)
    private let lock = NSLock()
    private var connection: Connection?
    private var timer: DispatchSourceTimer?
    private var sequence: UInt32 = 0          // nur auf writeQueue
    private var failedAttempts = 0            // nur auf connectQueue
    private let pending = Atomic<Int>(0)

    init(path: String) {
        self.path = path
    }

    var isConnected: Bool { lock.withLock { connection != nil } }
    var backlog: Int { pending.load(ordering: .relaxed) }

    func start() {
        lock.withLock {
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: connectQueue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(500))
            timer.setEventHandler { [weak self] in self?.connectIfNeeded() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        let current: Connection? = lock.withLock {
            timer?.cancel()
            timer = nil
            return connection
        }
        // Weckt den Lese-Thread; der raeumt auf und schliesst den fd auf der Schreib-Queue.
        if let current { Darwin.shutdown(current.fd, SHUT_RDWR) }
    }

    func send(_ type: MirrorMessage, flags: UInt8 = 0, orientation: UInt8 = 1, timestamp: UInt64 = 0,
              payload: Data = Data()) {
        guard let connection = lock.withLock({ connection }) else { return }
        pending.add(1, ordering: .relaxed)
        writeQueue.async { [self] in
            defer { pending.subtract(1, ordering: .relaxed) }
            guard !connection.closed else { return }
            sequence &+= 1
            let header = MirrorHeader(type: type, flags: flags, orientation: orientation,
                                      length: UInt32(payload.count), timestamp: timestamp, sequence: sequence)
            var bytes = [UInt8](repeating: 0, count: MirrorHeader.size)
            bytes.withUnsafeMutableBytes { header.write(to: $0) }
            let sent = bytes.withUnsafeBytes { UnixSocket.writeAll(connection.fd, $0) }
                && payload.withUnsafeBytes { UnixSocket.writeAll(connection.fd, $0) }
            if !sent {
                MirrorLog.write("Senden fehlgeschlagen (\(String(cString: strerror(errno)))) – verbinde neu")
                connection.closed = true
                Darwin.shutdown(connection.fd, SHUT_RDWR)
            }
        }
    }

    // MARK: Verbindung

    private func connectIfNeeded() {
        guard lock.withLock({ self.connection == nil && self.timer != nil }) else { return }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        UnixSocket.configure(fd, sendBuffer: 1 << 20, sendTimeout: 2)
        guard UnixSocket.connect(fd, path: path) else {
            close(fd)
            failedAttempts += 1
            if failedAttempts == 1 || failedAttempts % 120 == 0 {
                MirrorLog.write("Warte auf die App (Versuch \(failedAttempts)) – \(path)")
            }
            return
        }
        failedAttempts = 0
        let connection = Connection(fd: fd)
        lock.withLock { self.connection = connection }
        MirrorLog.write("Mit der App verbunden")

        let reader = Thread { [weak self] in self?.readLoop(connection) }
        reader.name = "mirror.sender.read"
        reader.qualityOfService = .userInitiated
        reader.start()
        onConnect?()
    }

    private func readLoop(_ connection: Connection) {
        var head = [UInt8](repeating: 0, count: MirrorHeader.size)
        while true {
            guard head.withUnsafeMutableBytes({ UnixSocket.readExactly(connection.fd, $0) }),
                  let header = head.withUnsafeBytes({ MirrorHeader($0) }),
                  header.length <= 64 * 1024 else { break }
            var payload = Data(count: Int(header.length))
            if header.length > 0 {
                guard payload.withUnsafeMutableBytes({ UnixSocket.readExactly(connection.fd, $0) }) else { break }
            }
            onControl?(header, payload)
        }
        lock.withLock { if self.connection === connection { self.connection = nil } }
        writeQueue.async {
            connection.closed = true
            close(connection.fd)
        }
        MirrorLog.write("Verbindung zur App getrennt")
        onDisconnect?()
    }
}

/// Encoder + Sender + die Verdrahtung dazwischen. Genau so laeuft es in der Erweiterung –
/// und fuers Testbild in der App, damit der Test dieselbe Kette prueft.
nonisolated final class MirrorStreamer: @unchecked Sendable {
    let encoder: MirrorEncoder
    let sender: MirrorSender
    private let lock = NSLock()
    private var lastReport: UInt64 = 0

    init?(settings: MirrorSettings, source: MirrorSource) {
        guard let path = Mirror.socketPath else {
            MirrorLog.write("FEHLER: kein Socket-Pfad – App-Gruppe \(Mirror.appGroup) fehlt in den Entitlements?")
            return nil
        }
        let encoder = MirrorEncoder(settings: settings)
        let sender = MirrorSender(path: path)
        self.encoder = encoder
        self.sender = sender

        encoder.onOutput = { output in
            if let sets = output.parameterSets {
                sender.send(.parameterSets, payload: ParameterSets.encode(sets, nalLength: output.nalLength))
            }
            sender.send(.frame, flags: output.keyframe ? MirrorHeader.keyframeFlag : 0,
                        orientation: output.orientation, timestamp: output.captureTime, payload: output.data)
        }
        sender.onConnect = {
            sender.send(.hello, payload: Data([source.rawValue]))
            encoder.requestKeyframe()
        }
        sender.onControl = { header, payload in
            switch header.type {
            case .requestKeyframe:
                encoder.requestKeyframe()
            case .configure:
                if let settings = payload.withUnsafeBytes({ MirrorSettings(payload: $0) }) { encoder.update(settings) }
            default:
                break
            }
        }
    }

    func start() { sender.start() }

    func stop() {
        sender.stop()
        encoder.invalidate()
    }

    /// Ein Bild vom Bildschirm (bzw. vom Testbild). Ohne zuhoerende App wird gar nicht erst kodiert –
    /// das spart Akku, wenn die Uebertragung laeuft, aber kein Auto verbunden ist.
    func push(_ pixelBuffer: CVPixelBuffer, orientation: UInt8, captureTime: UInt64) {
        guard sender.isConnected else { return }
        encoder.encode(pixelBuffer, orientation: orientation, captureTime: captureTime, backlog: sender.backlog)
        reportIfDue()
    }

    private func reportIfDue() {
        let now = Mirror.now()
        let due: Bool = lock.withLock {
            if lastReport == 0 { lastReport = now }
            guard now - lastReport >= 10_000_000_000 else { return false }
            lastReport = now
            return true
        }
        guard due else { return }
        let counters = encoder.takeCounters()
        MirrorLog.write(String(format: "Sender: %.1f B/s kodiert, ausgelassen %d (Bildrate) + %d (Rueckstau), "
                               + "ausgeleitet %d, Speicher %d MB",
                               Double(counters.encoded) / 10, counters.skippedRate, counters.skippedBusy,
                               counters.flushes, MirrorMemory.footprintMB()))
    }
}
