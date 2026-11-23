//
//  MirrorEncoder.swift
//  DashMirror – gemeinsam fuer App und Broadcast-Erweiterung
//
//  H.264-Encoder (VideoToolbox, Hardware) fuer das Bildschirmbild. Laeuft in der Broadcast-Erweiterung
//  mit ihrer 50-MB-Grenze und in der App fuers Testbild. Verkleinert auf die Groesse des Autodisplays,
//  BEVOR kodiert wird – das spart Speicher im Encoder und Bytes auf dem Socket.
//
//  Fuer niedrige Latenz: Low-Latency-Ratensteuerung, Echtzeitmodus, keine B-Bilder (kein Umsortieren),
//  Schluesselbild alle 2 s bzw. sofort auf Anfrage der App.
//

import CoreMedia
import CoreVideo
import Foundation
import Synchronization
import VideoToolbox

nonisolated final class MirrorEncoder: @unchecked Sendable {
    struct Output: Sendable {
        var parameterSets: [Data]?   // nur bei Schluesselbildern
        var nalLength: UInt8
        var data: Data               // AVCC: NAL-Einheiten mit Laengenpraefix
        var keyframe: Bool
        var captureTime: UInt64
        var orientation: UInt8
    }

    struct PixelSize: Equatable, CustomStringConvertible {
        var width: Int
        var height: Int
        static let zero = PixelSize(width: 0, height: 0)
        var description: String { "\(width)x\(height)" }
    }

    struct Counters {
        var encoded = 0
        var skippedRate = 0
        var skippedBusy = 0
        var flushes = 0
    }

    /// Hoechstens so viele Bilder gleichzeitig im Encoder, darueber wird ausgelassen.
    private static let maxInFlight = 4

    /// Kommt auf einem VideoToolbox-Thread.
    var onOutput: (@Sendable (Output) -> Void)?

    private let lock = NSLock()
    private var settings: MirrorSettings
    private var session: VTCompressionSession?
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var size = PixelSize.zero
    private var sourceFormat: OSType = 0
    private var lastAccepted: UInt64 = 0
    private var counters = Counters()
    /// Ohne Low-Latency-Encoder (z. B. Simulator) halten Encoder Bilder fuer die Vorausschau zurueck und
    /// ignorieren MaxFrameDelayCount (-12900). Dann nach jedem Bild die Ausgabe erzwingen.
    private var completeEachFrame = false
    // Atomar statt unter `lock`: Die Ausgabe von VideoToolbox kann auch synchron INNERHALB von
    // EncodeFrame kommen, und dort ist `lock` schon gehalten (NSLock ist nicht rekursiv).
    private let forceKeyframe = Atomic<Bool>(true)
    private let inFlight = Atomic<Int>(0)
    /// Zeitpunkt der letzten Ausgabe (Mirror.now), fuer den Notausgang bei zurueckgehaltenen Bildern.
    private let lastOutput = Atomic<UInt64>(0)

    init(settings: MirrorSettings) {
        self.settings = settings
    }

    deinit { teardown() }

    func requestKeyframe() {
        forceKeyframe.store(true, ordering: .relaxed)
    }

    func update(_ new: MirrorSettings) {
        lock.lock()
        defer { lock.unlock() }
        guard new != settings else { return }
        settings = new
        MirrorLog.write("Encoder: neue Vorgaben \(new)")
        // Groesse: Das naechste Bild rechnet die Zielgroesse neu und baut die Sitzung bei Bedarf neu.
        // Bitrate und Bildrate gehen live.
        guard let session else { return }
        Self.set(session, kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: new.bitrate))
        Self.set(session, kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: new.frameRate))
        Self.set(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: new.frameRate * 2))
    }

    func takeCounters() -> Counters {
        lock.lock()
        defer { counters = Counters(); lock.unlock() }
        return counters
    }

    func invalidate() {
        lock.lock()
        teardown()
        lock.unlock()
    }

    /// - Parameters:
    ///   - orientation: CGImagePropertyOrientation des Bildes, wird unveraendert an die App weitergereicht.
    ///   - backlog: Nachrichten, die noch auf dem Socket warten.
    /// - Returns: false, wenn das Bild ausgelassen wurde.
    @discardableResult
    func encode(_ pixelBuffer: CVPixelBuffer, orientation: UInt8, captureTime: UInt64, backlog: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        // Bildrate begrenzen. 10 % Toleranz – sonst fiele bei 60 Hz Lieferung und 60 eingestellt jedes
        // leicht verfruehte Bild heraus.
        let interval = 1_000_000_000 / UInt64(max(settings.frameRate, 1))
        if lastAccepted != 0, captureTime > lastAccepted, captureTime - lastAccepted < interval * 9 / 10 {
            counters.skippedRate += 1
            return false
        }
        // Rueckstau: Encoder oder Socket kommen nicht nach -> Bild VOR dem Kodieren auslassen. Danach waere es
        // zu spaet: Ein fehlendes kodiertes Bild macht alle folgenden bis zum naechsten Schluesselbild kaputt.
        if backlog >= 3 {
            counters.skippedBusy += 1
            return false
        }
        if inFlight.load(ordering: .relaxed) >= Self.maxInFlight {
            // Notausgang: Manche Encoder halten Bilder zurueck, bis neue nachkommen. Fuettert man sie dann nicht
            // mehr, kommt nie wieder etwas heraus (gemessen am 23.11.2026 im Simulator: 2 Bilder rein, 0 raus,
            // danach jedes Bild "Rueckstau"). Nach 0,5 s ohne Ausgabe werden die gehaltenen Bilder ausgeleitet.
            guard let session, Mirror.now() > lastOutput.load(ordering: .relaxed) + 500_000_000 else {
                counters.skippedBusy += 1
                return false
            }
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            counters.flushes += 1
        }

        let source = PixelSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let target = Self.targetSize(for: source, settings: settings)
        if session == nil || target != size || format != sourceFormat {
            guard rebuild(size: target, format: format) else { return false }
        }
        guard let session else { return false }

        var input = pixelBuffer
        if target != source {
            guard let scaled = scale(pixelBuffer) else {
                counters.skippedBusy += 1
                return false
            }
            input = scaled
        }

        lastAccepted = captureTime
        let force = forceKeyframe.exchange(false, ordering: .relaxed)
        let properties = force ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary : nil
        inFlight.add(1, ordering: .relaxed)
        let pts = CMTime(value: CMTimeValue(captureTime), timescale: 1_000_000_000)
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: input, presentationTimeStamp: pts,
            duration: .invalid, frameProperties: properties, infoFlagsOut: nil
        ) { [weak self] status, flags, sample in
            self?.finish(status: status, flags: flags, sample: sample, captureTime: captureTime, orientation: orientation)
        }
        guard status == noErr else {
            inFlight.subtract(1, ordering: .relaxed)
            forceKeyframe.store(true, ordering: .relaxed)
            MirrorLog.write("Encoder FEHLER beim Kodieren: \(status)")
            if status == kVTInvalidSessionErr { teardown() }
            return false
        }
        if completeEachFrame {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: pts)
        }
        counters.encoded += 1
        return true
    }

    /// Zielgroesse: so gross wie das Autodisplay, nie groesser als die Quelle, Kanten gerade (H.264 mag das).
    /// Lange und kurze Seite getrennt, weil die Quelle hochkant ist und das Bild erst in der App gedreht wird.
    static func targetSize(for source: PixelSize, settings: MirrorSettings) -> PixelSize {
        let long = Double(max(source.width, source.height))
        let short = Double(min(source.width, source.height))
        guard long > 0, short > 0 else { return source }
        let scale = min(1, Double(settings.maxLongSide) / long, Double(settings.maxShortSide) / short)
        func even(_ value: Double) -> Int { max(16, Int((value / 2).rounded()) * 2) }
        return PixelSize(width: even(Double(source.width) * scale), height: even(Double(source.height) * scale))
    }

    // MARK: Sitzung

    private func rebuild(size newSize: PixelSize, format: OSType) -> Bool {
        teardown()
        var created: VTCompressionSession?
        let lowLatency = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String: true] as CFDictionary
        var status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: Int32(newSize.width), height: Int32(newSize.height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: lowLatency, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        var mode = "Low-Latency"
        if status != noErr || created == nil {
            // z. B. im Simulator: kein Low-Latency-Encoder -> normaler Encoder
            mode = "Standard"
            status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault, width: Int32(newSize.width), height: Int32(newSize.height),
                codecType: kCMVideoCodecType_H264, encoderSpecification: nil, imageBufferAttributes: nil,
                compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        }
        guard status == noErr, let created else {
            MirrorLog.write("Encoder FEHLER: Sitzung \(newSize) nicht angelegt (\(status))")
            return false
        }
        Self.set(created, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        Self.set(created, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        Self.set(created, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        Self.set(created, kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: settings.bitrate))
        Self.set(created, kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: settings.frameRate))
        Self.set(created, kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: settings.frameRate * 2))
        Self.set(created, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 2))
        // Jedes Bild sofort ausgeben, nichts fuer Vorausschau zurueckhalten (Latenz + Verklemmungsschutz).
        Self.set(created, kVTCompressionPropertyKey_MaxFrameDelayCount, NSNumber(value: 0))
        VTCompressionSessionPrepareToEncodeFrames(created)
        lastOutput.store(Mirror.now(), ordering: .relaxed)
        completeEachFrame = mode != "Low-Latency"
        session = created

        var newTransfer: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &newTransfer)
        transfer = newTransfer

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: format,
            kCVPixelBufferWidthKey as String: newSize.width,
            kCVPixelBufferHeightKey as String: newSize.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        var newPool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                [kCVPixelBufferPoolMinimumBufferCountKey as String: 3] as CFDictionary,
                                attributes as CFDictionary, &newPool)
        pool = newPool

        size = newSize
        sourceFormat = format
        forceKeyframe.store(true, ordering: .relaxed)
        MirrorLog.write("Encoder: \(newSize) H.264 \(mode), \(settings.frameRate) B/s, "
                        + "\(settings.bitrate / 1_000_000) Mbit/s, Quelle \(Self.fourCC(format)), "
                        + "Speicher \(MirrorMemory.footprintMB()) MB")
        return true
    }

    private func teardown() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        if let transfer { VTPixelTransferSessionInvalidate(transfer) }
        session = nil
        transfer = nil
        pool = nil
        size = .zero
    }

    private func scale(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        guard let pool, let transfer else { return nil }
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output) == kCVReturnSuccess,
              let output,
              VTPixelTransferSessionTransferImage(transfer, from: source, to: output) == noErr else { return nil }
        return output
    }

    // MARK: Ausgabe

    private func finish(status: OSStatus, flags: VTEncodeInfoFlags, sample: CMSampleBuffer?,
                        captureTime: UInt64, orientation: UInt8) {
        inFlight.subtract(1, ordering: .relaxed)
        lastOutput.store(Mirror.now(), ordering: .relaxed)
        guard status == noErr else {
            MirrorLog.write("Encoder FEHLER im Ergebnis: \(status)")
            forceKeyframe.store(true, ordering: .relaxed)
            return
        }
        // Vom Encoder selbst verworfene Bilder sind unkritisch: Auf die verweist kein Folgebild.
        guard let sample, !flags.contains(.frameDropped), let block = CMSampleBufferGetDataBuffer(sample) else { return }

        let keyframe = Self.isKeyframe(sample)
        var nalLength: Int32 = 4
        var parameterSets: [Data]?
        if let format = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            _ = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLength)
            if keyframe {
                parameterSets = (0..<count).compactMap { index in
                    var pointer: UnsafePointer<UInt8>?
                    var length = 0
                    guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                        parameterSetSizeOut: &length, parameterSetCountOut: nil,
                        nalUnitHeaderLengthOut: nil) == noErr, let pointer else { return nil }
                    return Data(bytes: pointer, count: length)
                }
            }
        }

        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let copied = data.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        guard copied == kCMBlockBufferNoErr else {
            forceKeyframe.store(true, ordering: .relaxed)
            return
        }
        onOutput?(Output(parameterSets: parameterSets, nalLength: UInt8(clamping: nalLength), data: data,
                         keyframe: keyframe, captureTime: captureTime, orientation: orientation))
    }

    static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]],
              let first = attachments.first else { return true }
        return (first[kCMSampleAttachmentKey_NotSync as String] as? Bool) != true
    }

    private static func set(_ session: VTSession, _ key: CFString, _ value: CFTypeRef?) {
        let status = VTSessionSetProperty(session, key: key, value: value)
        if status != noErr { MirrorLog.write("Encoder: \(key) nicht gesetzt (\(status))") }
    }

    private static func fourCC(_ code: OSType) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii) ?? "\(code)"
    }
}
