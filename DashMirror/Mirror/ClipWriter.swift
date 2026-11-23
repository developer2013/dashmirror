//
//  ClipWriter.swift
//  DashMirror
//
//  Schreibt einen ReplayBuffer.Snapshot als MP4 – ohne Neukodieren: AVAssetWriterInput mit
//  outputSettings nil uebernimmt das H.264 so, wie die Erweiterung es kodiert hat ("Passthrough").
//  Das dauert fuer 30 s nur Bruchteile einer Sekunde und kostet kaum Strom.
//
//  Die Ausrichtung kommt als Track-Transform in die Datei (wie bei Kamera-Videos): Fotos & Co. drehen beim
//  Abspielen, die Bilder selbst bleiben unangetastet. Gleiche Drehrichtung wie im Auto (MirrorVideoView).
//  Nur Bild, kein Ton – den Spielton bekommt die App nicht (die Erweiterung schickt nur Video).
//

import AVFoundation
import ImageIO

nonisolated enum ClipWriter {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// - Returns: Laenge des Clips in Sekunden.
    static func write(_ snapshot: ReplayBuffer.Snapshot, to url: URL) async throws -> Double {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: snapshot.format)
        input.expectsMediaDataInRealTime = false
        let dimensions = CMVideoFormatDescriptionGetDimensions(snapshot.format)
        input.transform = transform(orientation: snapshot.orientation,
                                    size: CGSize(width: Int(dimensions.width), height: Int(dimensions.height)))
        guard writer.canAdd(input) else { throw Failure(description: "Video-Spur nicht moeglich") }
        writer.add(input)
        guard writer.startWriting() else {
            throw Failure(description: "Start: \(writer.error?.localizedDescription ?? "unbekannt")")
        }
        writer.startSession(atSourceTime: .zero)

        let frames = snapshot.frames
        let start = frames[0].time
        var lastPTS: Int64 = -1
        var end = CMTime.zero
        for (index, frame) in frames.enumerated() {
            // Streng steigende Zeiten (gleiche Aufnahmezeit kommt praktisch nie vor, waere aber ungueltig).
            let pts = max(Int64(frame.time - start), lastPTS + 1_000)
            lastPTS = pts
            let next = index + 1 < frames.count ? Int64(frames[index + 1].time - start) : pts + 33_333_333
            let duration = CMTime(value: max(next - pts, 1_000), timescale: 1_000_000_000)
            let time = CMTime(value: pts, timescale: 1_000_000_000)
            end = time + duration
            guard let sample = makeSample(frame, format: snapshot.format, time: time, duration: duration) else {
                throw Failure(description: "Bild \(index) nicht verpackbar")
            }
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            guard input.append(sample) else {
                throw Failure(description: "Bild \(index): \(writer.error?.localizedDescription ?? "unbekannt")")
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: end)
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw Failure(description: "Abschluss: \(writer.error?.localizedDescription ?? "Status \(writer.status.rawValue)")")
        }
        return end.seconds
    }

    /// Dreht wie MirrorVideoView.rotation (ReplayKit-Lesart, gemessen im BMW am 23.11.2026) und schiebt das
    /// Ergebnis zurueck in den positiven Bereich – so erwarten es Player beim Track-Transform.
    static func transform(orientation: UInt8, size: CGSize) -> CGAffineTransform {
        let angle = MirrorVideoView.rotation(for: CGImagePropertyOrientation(rawValue: UInt32(orientation)) ?? .up).angle
        guard angle != 0 else { return .identity }
        let rotation = CGAffineTransform(rotationAngle: angle)
        let box = CGRect(origin: .zero, size: size).applying(rotation)
        return rotation.concatenating(CGAffineTransform(translationX: -box.minX, y: -box.minY))
    }

    private static func makeSample(_ frame: ReplayBuffer.Frame, format: CMVideoFormatDescription,
                                   time: CMTime, duration: CMTime) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        let length = frame.data.count
        guard CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: length,
                flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == kCMBlockBufferNoErr,
              let block else { return nil }
        let copied = frame.data.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return false }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0,
                                                 dataLength: length) == kCMBlockBufferNoErr
        }
        guard copied else { return nil }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var size = length
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { return nil }
        if !frame.keyframe,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
