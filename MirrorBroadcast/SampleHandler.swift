//
//  SampleHandler.swift
//  MirrorBroadcast – ReplayKit-Broadcast-Erweiterung
//
//  iOS reicht hier jedes Bild des iPhone-Bildschirms herein, solange die Uebertragung laeuft – egal welche
//  App vorn ist (das Spiel). Wir kodieren es als H.264 und schicken es ueber den Unix-Socket im gemeinsamen
//  Container an die App, die es aufs Autodisplay legt.
//
//  Harte Grenze: 50 MB Speicher, sonst beendet iOS die Erweiterung ohne Rueckfrage. Deshalb kein SwiftUI,
//  keine Bildkopien: Der Puffer von ReplayKit geht direkt (bzw. verkleinert) in den Hardware-Encoder.
//  Den Ton braucht es nicht – iOS spielt den Spielton ohnehin ueber CarPlay ab.
//

import CoreMedia
import ReplayKit

final class SampleHandler: RPBroadcastSampleHandler {
    private var streamer: MirrorStreamer?
    private var timebase = mach_timebase_info_data_t()

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        mach_timebase_info(&timebase)
        let settings = MirrorSettings.load()
        MirrorLog.write("=== Uebertragung gestartet – \(settings), Speicher \(MirrorMemory.footprintMB()) MB ===")
        guard let streamer = MirrorStreamer(settings: settings, source: .screen) else {
            finishBroadcastWithError(NSError(domain: "DashMirror", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Gemeinsamer Container fehlt – App-Gruppe in den Entitlements prüfen.",
            ]))
            return
        }
        self.streamer = streamer
        streamer.start()
    }

    override func broadcastPaused() {
        MirrorLog.write("Uebertragung pausiert")
    }

    override func broadcastResumed() {
        MirrorLog.write("Uebertragung fortgesetzt")
        streamer?.encoder.requestKeyframe()
    }

    override func broadcastFinished() {
        MirrorLog.write("=== Uebertragung beendet ===")
        streamer?.stop()
        streamer = nil
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video, let streamer,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // ReplayKit liefert IMMER hochkant und sagt hier, wie das Bild zu drehen ist (EXIF-Wert).
        let orientation = (CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString,
                                           attachmentModeOut: nil) as? NSNumber)?.uint8Value ?? 1
        let captureTime = captureTime(of: sampleBuffer)
        autoreleasepool {
            streamer.push(pixelBuffer, orientation: orientation, captureTime: captureTime)
        }
    }

    /// Erfassungszeit aus dem Zeitstempel von ReplayKit (Host-Uhr), umgerechnet auf CLOCK_UPTIME_RAW in ns.
    /// So misst die App die Latenz ab dem Bildschirm statt erst ab hier. Passt der Wert nicht, gilt "jetzt".
    private func captureTime(of sampleBuffer: CMSampleBuffer) -> UInt64 {
        let now = Mirror.now()
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid, timebase.denom != 0 else { return now }
        let ticks = CMClockConvertHostTimeToSystemUnits(pts)
        let nanos = ticks * UInt64(timebase.numer) / UInt64(timebase.denom)
        return nanos <= now && now - nanos < 2_000_000_000 ? nanos : now
    }
}
