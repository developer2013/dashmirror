//
//  MirrorProtocol.swift
//  DashMirror – gemeinsam fuer App und Broadcast-Erweiterung (Ordner Shared/, in beiden Targets)
//
//  Draht-Format zwischen Erweiterung (Client: liefert H.264) und App (Server: zeigt es im Auto).
//  Jede Nachricht = 24 Byte Kopf + Nutzdaten, alles little endian:
//
//     0  UInt32  Kennung "MRR1"
//     4  UInt8   Typ (MirrorMessage)
//     5  UInt8   Flags (Bit 0 = Schluesselbild)
//     6  UInt8   Ausrichtung des Bildes (CGImagePropertyOrientation, 1 = aufrecht)
//     7  UInt8   reserviert
//     8  UInt32  Laenge der Nutzdaten
//    12  UInt64  Erfassungszeit in ns (CLOCK_UPTIME_RAW – App und Erweiterung teilen diese Uhr)
//    20  UInt32  laufende Nummer
//
//  Alles hier ist ausdruecklich `nonisolated`: Die App kompiliert mit MainActor als Standard,
//  die Erweiterung ohne – und dieser Code laeuft in beiden auf Hintergrund-Threads.
//

import Darwin
import Foundation

nonisolated enum Mirror {
    /// Aus dem Info.plist (DashMirrorAppGroup <- DASHMIRROR_APP_GROUP in Config/Signing.xcconfig / Local.xcconfig),
    /// damit jeder Fork seine eigene App-Gruppe nutzen kann, ohne Code zu aendern.
    static let appGroup = Bundle.main.object(forInfoDictionaryKey: "DashMirrorAppGroup") as? String
        ?? "group.com.example.dashmirror"
    /// Nur in der App sinnvoll (dort ist Bundle.main die App): Kennung der Erweiterung = App-ID + ".MirrorBroadcast".
    static var broadcastExtensionID: String { (Bundle.main.bundleIdentifier ?? "") + ".MirrorBroadcast" }

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    /// Unix-Socket zwischen Erweiterung und App. `sun_path` fasst nur 104 Bytes: Auf dem iPhone ist der
    /// Gruppen-Container kurz genug (rund 95 Zeichen), im Simulator liegt er tief im Mac-Benutzerordner –
    /// dort weicht der Socket nach /tmp aus. (Die Erweiterung laeuft im Simulator nicht, nur das Testbild.)
    static var socketPath: String? {
        #if targetEnvironment(simulator)
        return "/tmp/dashmirror.sock"
        #else
        return containerURL?.appendingPathComponent("mirror.sock").path
        #endif
    }

    static var sharedDefaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    /// Monotone Uhr in Nanosekunden, in allen Prozessen dieselbe (= mach_absolute_time in ns).
    static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
}

/// Wer sendet. Laufen Testbild und Bildschirm-Uebertragung gleichzeitig, wuerden sich beide alle 0,5 s
/// gegenseitig abloesen – deshalb meldet sich jede Quelle an, und der Bildschirm beendet das Testbild.
nonisolated enum MirrorSource: UInt8 {
    case screen = 1
    case testPattern = 2
}

nonisolated enum MirrorMessage: UInt8 {
    case parameterSets = 1     // Erweiterung -> App: SPS/PPS, kommt vor jedem Schluesselbild
    case frame = 2             // Erweiterung -> App: ein H.264-Bild (AVCC: NAL-Einheiten mit Laengenpraefix)
    case hello = 3             // Erweiterung -> App: erste Nachricht, 1 Byte MirrorSource
    case requestKeyframe = 10  // App -> Erweiterung: bitte sofort ein Schluesselbild
    case configure = 11        // App -> Erweiterung: Zielgroesse, Bildrate, Bitrate (MirrorSettings)
}

nonisolated struct MirrorHeader {
    static let size = 24
    static let magic: UInt32 = 0x3152_524D    // Bytes "MRR1"
    static let keyframeFlag: UInt8 = 1

    var type: MirrorMessage
    var flags: UInt8 = 0
    var orientation: UInt8 = 1
    var length: UInt32 = 0
    var timestamp: UInt64 = 0
    var sequence: UInt32 = 0

    var isKeyframe: Bool { flags & Self.keyframeFlag != 0 }

    func write(to buffer: UnsafeMutableRawBufferPointer) {
        buffer.storeBytes(of: Self.magic.littleEndian, toByteOffset: 0, as: UInt32.self)
        buffer.storeBytes(of: type.rawValue, toByteOffset: 4, as: UInt8.self)
        buffer.storeBytes(of: flags, toByteOffset: 5, as: UInt8.self)
        buffer.storeBytes(of: orientation, toByteOffset: 6, as: UInt8.self)
        buffer.storeBytes(of: UInt8(0), toByteOffset: 7, as: UInt8.self)
        buffer.storeBytes(of: length.littleEndian, toByteOffset: 8, as: UInt32.self)
        buffer.storeBytes(of: timestamp.littleEndian, toByteOffset: 12, as: UInt64.self)
        buffer.storeBytes(of: sequence.littleEndian, toByteOffset: 20, as: UInt32.self)
    }
}

extension MirrorHeader {
    /// nil bei falscher Kennung oder unbekanntem Typ – dann ist der Datenstrom kaputt und die Verbindung
    /// wird getrennt (beide Seiten werden immer zusammen gebaut, es gibt keine alten Gegenstellen).
    nonisolated init?(_ buffer: UnsafeRawBufferPointer) {
        guard buffer.count >= Self.size,
              UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: 0, as: UInt32.self)) == Self.magic,
              let type = MirrorMessage(rawValue: buffer[4]) else { return nil }
        self.init(type: type,
                  flags: buffer[5],
                  orientation: buffer[6],
                  length: UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: 8, as: UInt32.self)),
                  timestamp: UInt64(littleEndian: buffer.loadUnaligned(fromByteOffset: 12, as: UInt64.self)),
                  sequence: UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: 20, as: UInt32.self)))
    }
}

/// Vorgaben fuer den Encoder. Bildrate und Bitrate stellt man am iPhone ein (gemeinsame Einstellungen),
/// die Hoechstgroesse schickt die App, sobald sie die Pixelgroesse des Autodisplays kennt.
nonisolated struct MirrorSettings: Equatable, CustomStringConvertible {
    var maxLongSide: Int
    var maxShortSide: Int
    var frameRate: Int
    var bitrate: Int

    static let standard = MirrorSettings(maxLongSide: 1920, maxShortSide: 1080, frameRate: 60, bitrate: 12_000_000)

    var description: String {
        "max \(maxLongSide)x\(maxShortSide), \(frameRate) B/s, \(bitrate / 1_000_000) Mbit/s"
    }

    var payload: Data {
        var data = Data(capacity: 16)
        for value in [maxLongSide, maxShortSide, frameRate, bitrate] {
            withUnsafeBytes(of: UInt32(clamping: value).littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func load() -> MirrorSettings {
        var settings = standard
        let defaults = Mirror.sharedDefaults
        if let rate = defaults?.object(forKey: "frameRate") as? Int, rate > 0 { settings.frameRate = rate }
        if let bitrate = defaults?.object(forKey: "bitrate") as? Int, bitrate > 0 { settings.bitrate = bitrate }
        return settings
    }

    func save() {
        Mirror.sharedDefaults?.set(frameRate, forKey: "frameRate")
        Mirror.sharedDefaults?.set(bitrate, forKey: "bitrate")
    }
}

extension MirrorSettings {
    nonisolated init?(payload: UnsafeRawBufferPointer) {
        guard payload.count >= 16 else { return nil }
        func value(_ index: Int) -> Int {
            Int(UInt32(littleEndian: payload.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)))
        }
        self.init(maxLongSide: max(value(0), 16), maxShortSide: max(value(1), 16),
                  frameRate: max(value(2), 1), bitrate: max(value(3), 500_000))
    }
}

/// SPS/PPS als Nutzdaten: [UInt8 NAL-Laengenfeld][UInt8 Anzahl], dann je Satz [UInt16 Laenge][Bytes].
nonisolated enum ParameterSets {
    static func encode(_ sets: [Data], nalLength: UInt8) -> Data {
        var data = Data([nalLength, UInt8(clamping: sets.count)])
        for set in sets {
            withUnsafeBytes(of: UInt16(clamping: set.count).littleEndian) { data.append(contentsOf: $0) }
            data.append(set)
        }
        return data
    }

    static func decode(_ buffer: UnsafeRawBufferPointer) -> (sets: [Data], nalLength: Int32)? {
        guard buffer.count >= 2, let base = buffer.baseAddress else { return nil }
        let nalLength = Int32(buffer[0])
        var offset = 2
        var sets: [Data] = []
        for _ in 0..<Int(buffer[1]) {
            guard offset + 2 <= buffer.count else { return nil }
            let length = Int(UInt16(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt16.self)))
            offset += 2
            guard offset + length <= buffer.count else { return nil }
            sets.append(Data(bytes: base + offset, count: length))
            offset += length
        }
        return (sets, nalLength)
    }
}

/// Duenne Huelle um die BSD-Sockets. Bewusst blockierend: Jede Verbindung hat ihren eigenen Lese-Thread,
/// geschrieben wird auf einer seriellen Queue. SO_NOSIGPIPE, sonst beendet ein Schreibversuch auf eine
/// geschlossene Verbindung den ganzen Prozess per SIGPIPE.
nonisolated enum UnixSocket {
    static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    static func connect(_ fd: Int32, path: String) -> Bool {
        guard var address = address(path) else { return false }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }

    /// Legt den Server-Socket an (alte Socket-Datei vorher weg). Liefert den lauschenden fd.
    static func listen(path: String) -> Int32? {
        guard var address = address(path) else { return nil }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 4) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    static func configure(_ fd: Int32, sendBuffer: Int32? = nil, receiveBuffer: Int32? = nil, sendTimeout: Int? = nil) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        if var size = sendBuffer {
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        }
        if var size = receiveBuffer {
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        }
        if let seconds = sendTimeout {
            var timeout = timeval(tv_sec: seconds, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        }
    }

    static func readExactly(_ fd: Int32, _ buffer: UnsafeMutableRawBufferPointer) -> Bool {
        guard var pointer = buffer.baseAddress else { return true }
        var remaining = buffer.count
        while remaining > 0 {
            let count = Darwin.recv(fd, pointer, remaining, 0)
            if count > 0 {
                pointer += count
                remaining -= count
            } else if count < 0, errno == EINTR {
                continue
            } else {
                return false    // 0 = Gegenseite hat geschlossen, < 0 = Fehler
            }
        }
        return true
    }

    /// false auch bei Zeitueberschreitung (SO_SNDTIMEO): Dann ist evtl. eine halbe Nachricht raus,
    /// der Strom also nicht mehr lesbar – der Aufrufer muss die Verbindung trennen.
    static func writeAll(_ fd: Int32, _ buffer: UnsafeRawBufferPointer) -> Bool {
        guard var pointer = buffer.baseAddress else { return true }
        var remaining = buffer.count
        while remaining > 0 {
            let count = Darwin.send(fd, pointer, remaining, 0)
            if count > 0 {
                pointer += count
                remaining -= count
            } else if count < 0, errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }
}

nonisolated enum MirrorMemory {
    /// Speicher, wie iOS ihn fuer die 50-MB-Grenze der Erweiterung zaehlt (phys_footprint), in MB.
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }
}
