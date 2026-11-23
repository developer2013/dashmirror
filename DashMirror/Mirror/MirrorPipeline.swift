//
//  MirrorPipeline.swift
//  DashMirror
//
//  Baut aus den empfangenen H.264-Daten CMSampleBuffer und reicht sie an alle angemeldeten Anzeigen
//  (AVSampleBufferVideoRenderer, Hardware-Decoder). Laeuft auf dem Lese-Thread des Empfangs.
//
//  Regeln, damit nie ein kaputtes Bild erscheint:
//  - Eine neue Anzeige (oder eine nach Fehler/Flush) bekommt erst ab dem naechsten Schluesselbild Daten.
//  - Fehlt eins, wird es bei der Quelle angefordert (hoechstens alle 300 ms).
//  - Jedes Bild ist "sofort anzeigen" markiert – kein Zeitplan, kein Puffer, minimale Latenz.
//

import AVFoundation
import CoreMedia

nonisolated final class MirrorPipeline: @unchecked Sendable {
    struct Stats {
        var frames = 0
        var bytes = 0
        var keyframes = 0
        var dropped = 0
        var latencyTotal: UInt64 = 0
        var latencySamples = 0
    }

    var onHello: (@Sendable (MirrorSource?) -> Void)?
    var onOrientation: (@Sendable (UInt8) -> Void)?
    var onDimensions: (@Sendable (Int, Int) -> Void)?
    var requestKeyframe: (@Sendable () -> Void)?

    private final class Slot {
        let renderer: AVSampleBufferVideoRenderer
        var needsKeyframe = true
        init(renderer: AVSampleBufferVideoRenderer) { self.renderer = renderer }
    }

    private let lock = NSLock()
    private var client = 0
    private var format: CMVideoFormatDescription?
    private var orientation: UInt8 = 0
    private var slots: [ObjectIdentifier: Slot] = [:]
    private var stats = Stats()
    private var lastKeyframeRequest: UInt64 = 0

    // MARK: Anzeigen an- und abmelden (Hauptthread)

    func attach(_ renderer: AVSampleBufferVideoRenderer) {
        lock.withLock {
            slots[ObjectIdentifier(renderer)] = Slot(renderer: renderer)
            askForKeyframe(force: true)
        }
    }

    func detach(_ renderer: AVSampleBufferVideoRenderer) {
        lock.withLock { slots[ObjectIdentifier(renderer)] = nil }
    }

    /// Zaehler seit dem letzten Aufruf.
    func takeStats() -> Stats {
        lock.withLock {
            defer { stats = Stats() }
            return stats
        }
    }

    // MARK: Empfang (Lese-Thread)

    /// Neue Quelle: altes Format verwerfen, alle Anzeigen warten aufs erste Schluesselbild.
    func reset(client id: Int) {
        lock.withLock {
            client = id
            format = nil
            for slot in slots.values {
                slot.renderer.flush()
                slot.needsKeyframe = true
            }
        }
    }

    func handle(client id: Int, header: MirrorHeader, payload: UnsafeRawBufferPointer) {
        lock.lock()
        defer { lock.unlock() }
        guard id == client else { return }      // Nachzuegler einer abgeloesten Quelle
        switch header.type {
        case .hello: onHello?(payload.first.flatMap(MirrorSource.init(rawValue:)))
        case .parameterSets: updateFormat(payload)
        case .frame: enqueue(header, payload)
        default: break
        }
    }

    private func updateFormat(_ payload: UnsafeRawBufferPointer) {
        guard let (sets, nalLength) = ParameterSets.decode(payload), !sets.isEmpty else {
            MirrorLog.write("Empfang FEHLER: SPS/PPS unlesbar")
            return
        }
        let copies = sets.map { data -> UnsafeMutablePointer<UInt8> in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
            data.copyBytes(to: pointer, count: data.count)
            return pointer
        }
        defer { copies.forEach { $0.deallocate() } }
        let pointers = copies.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)
        var description: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
            parameterSetSizes: sizes, nalUnitHeaderLength: nalLength, formatDescriptionOut: &description)
        guard status == noErr, let description else {
            MirrorLog.write("Empfang FEHLER: Bildformat nicht anlegbar (\(status))")
            return
        }
        if let format, CMFormatDescriptionEqual(format, otherFormatDescription: description) { return }
        format = description
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        MirrorLog.write("Empfang: Bildformat \(dimensions.width)x\(dimensions.height)")
        onDimensions?(Int(dimensions.width), Int(dimensions.height))
    }

    private func enqueue(_ header: MirrorHeader, _ payload: UnsafeRawBufferPointer) {
        stats.frames += 1
        stats.bytes += payload.count + MirrorHeader.size
        if header.isKeyframe { stats.keyframes += 1 }
        let now = Mirror.now()
        if header.timestamp > 0, now > header.timestamp, now - header.timestamp < 5_000_000_000 {
            stats.latencyTotal += now - header.timestamp
            stats.latencySamples += 1
        }
        if header.orientation != orientation {
            orientation = header.orientation
            onOrientation?(orientation)
        }

        guard !slots.isEmpty else { return }       // z. B. Fahrsperre: empfangen ja, anzeigen nein
        guard let format else {
            stats.dropped += 1
            askForKeyframe()
            return
        }
        guard let sample = Self.makeSample(payload, format: format, keyframe: header.isKeyframe) else {
            stats.dropped += 1
            return
        }
        for slot in slots.values {
            let renderer = slot.renderer
            // Nach Hintergrund, Bildschirmwechsel o. Ae. steigt der Decoder aus – dann neu anfangen.
            if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
                MirrorLog.write("Anzeige: Decoder neu gestartet (\(renderer.error?.localizedDescription ?? "unterbrochen"))")
                renderer.flush()
                slot.needsKeyframe = true
                askForKeyframe()
            }
            if slot.needsKeyframe {
                guard header.isKeyframe else {
                    stats.dropped += 1
                    continue
                }
                slot.needsKeyframe = false
            }
            renderer.enqueue(sample)
        }
    }

    /// Erwartet gehaltenes `lock`.
    private func askForKeyframe(force: Bool = false) {
        let now = Mirror.now()
        guard force || now - lastKeyframeRequest > 300_000_000 else { return }
        lastKeyframeRequest = now
        requestKeyframe?()
    }

    private static func makeSample(_ payload: UnsafeRawBufferPointer, format: CMVideoFormatDescription,
                                   keyframe: Bool) -> CMSampleBuffer? {
        guard let base = payload.baseAddress, payload.count > 0 else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: payload.count,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                dataLength: payload.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                blockBufferOut: &block) == kCMBlockBufferNoErr,
              let block,
              CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0,
                                            dataLength: payload.count) == kCMBlockBufferNoErr else { return nil }
        var sample: CMSampleBuffer?
        var size = payload.count
        guard CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
                sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            let yes: CFBoolean = kCFBooleanTrue
            CFDictionarySetValue(dictionary,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(yes).toOpaque())
            if !keyframe {
                CFDictionarySetValue(dictionary,
                                     Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(yes).toOpaque())
            }
        }
        return sample
    }
}
