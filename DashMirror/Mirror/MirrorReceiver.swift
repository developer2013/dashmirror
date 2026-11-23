//
//  MirrorReceiver.swift
//  DashMirror
//
//  Server-Seite des Unix-Sockets: nimmt die Verbindung der Broadcast-Erweiterung (oder des Testbilds) an.
//  Die zuletzt verbundene Quelle gewinnt – startet man eine neue Uebertragung, loest sie eine haengende
//  alte ab, statt in der Warteschlange zu stecken.
//

import Darwin
import Foundation

nonisolated final class MirrorReceiver: @unchecked Sendable {
    /// Laeuft auf dem Lese-Thread der jeweiligen Verbindung. Der Puffer gilt nur waehrend des Aufrufs.
    var onMessage: (@Sendable (_ client: Int, _ header: MirrorHeader, _ payload: UnsafeRawBufferPointer) -> Void)?
    /// `connected == false` kommt nur fuer die jeweils aktuelle Quelle.
    var onClient: (@Sendable (_ client: Int, _ connected: Bool) -> Void)?

    private let path: String
    private let writeQueue = DispatchQueue(label: "mirror.receiver.write", qos: .userInitiated)
    private var listenFD: Int32 = -1
    private var clientFD: Int32 = -1     // nur auf writeQueue
    private var clientID = 0             // nur auf writeQueue
    private var nextID = 1               // nur auf dem Annahme-Thread

    init(path: String) {
        self.path = path
    }

    /// - Returns: Fehlertext oder nil bei Erfolg.
    func start() -> String? {
        guard let fd = UnixSocket.listen(path: path) else {
            let reason = "Socket \(path) (\(path.utf8.count) Zeichen): \(String(cString: strerror(errno)))"
            MirrorLog.write("Empfang FEHLER – \(reason)")
            return reason
        }
        listenFD = fd
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "mirror.receiver.accept"
        thread.qualityOfService = .userInitiated
        thread.start()
        MirrorLog.write("Empfang bereit: \(path)")
        return nil
    }

    /// Steuerbefehl an die aktuelle Quelle (Schluesselbild, Vorgaben). Ohne Quelle passiert nichts.
    func send(_ type: MirrorMessage, payload: Data = Data()) {
        writeQueue.async { [self] in
            guard clientFD >= 0 else { return }
            let header = MirrorHeader(type: type, length: UInt32(payload.count))
            var bytes = [UInt8](repeating: 0, count: MirrorHeader.size)
            bytes.withUnsafeMutableBytes { header.write(to: $0) }
            let fd = clientFD
            let sent = bytes.withUnsafeBytes { UnixSocket.writeAll(fd, $0) }
                && payload.withUnsafeBytes { UnixSocket.writeAll(fd, $0) }
            if !sent { MirrorLog.write("Empfang: Steuerbefehl \(type) nicht zugestellt") }
        }
    }

    private func acceptLoop() {
        while true {
            let fd = Darwin.accept(listenFD, nil, nil)
            guard fd >= 0 else {
                if errno == EINTR || errno == ECONNABORTED { continue }
                MirrorLog.write("Empfang FEHLER: accept – \(String(cString: strerror(errno)))")
                Thread.sleep(forTimeInterval: 1)
                continue
            }
            UnixSocket.configure(fd, receiveBuffer: 2 << 20, sendTimeout: 1)
            let id = nextID
            nextID += 1
            let previous: Int32 = writeQueue.sync {
                let old = clientFD
                clientFD = fd
                clientID = id
                return old
            }
            if previous >= 0 {
                MirrorLog.write("Empfang: neue Quelle loest die alte ab")
                Darwin.shutdown(previous, SHUT_RDWR)     // deren Lese-Thread endet und schliesst den fd
            }
            onClient?(id, true)
            let reader = Thread { [weak self] in self?.readLoop(fd: fd, id: id) }
            reader.name = "mirror.receiver.read"
            reader.qualityOfService = .userInteractive
            reader.start()
        }
    }

    private func readLoop(fd: Int32, id: Int) {
        var head = [UInt8](repeating: 0, count: MirrorHeader.size)
        var capacity = 512 * 1024
        var buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        defer { buffer.deallocate() }

        while true {
            guard head.withUnsafeMutableBytes({ UnixSocket.readExactly(fd, $0) }) else { break }
            guard let header = head.withUnsafeBytes({ MirrorHeader($0) }) else {
                MirrorLog.write("Empfang FEHLER: unbekannter Kopf – Verbindung wird getrennt")
                break
            }
            let length = Int(header.length)
            guard length <= 16 << 20 else {
                MirrorLog.write("Empfang FEHLER: Nachricht zu gross (\(length) Bytes)")
                break
            }
            if length > capacity {
                buffer.deallocate()
                capacity = max(length, capacity * 2)
                buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
            }
            let payload = UnsafeMutableRawBufferPointer(start: buffer, count: length)
            guard UnixSocket.readExactly(fd, payload) else { break }
            onMessage?(id, header, UnsafeRawBufferPointer(payload))
        }

        let wasCurrent: Bool = writeQueue.sync {
            guard clientID == id else { return false }
            clientFD = -1
            return true
        }
        close(fd)
        if wasCurrent { onClient?(id, false) }
    }
}
