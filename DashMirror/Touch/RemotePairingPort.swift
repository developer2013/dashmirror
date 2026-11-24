//
//  RemotePairingPort.swift
//  DashMirror
//
//  Experiment "Touch im Auto": Port des Remote-Pairing-Dienstes des iPhones per Bonjour finden
//  (`_remotepairing._tcp`, bevorzugt auf der Loopback-Schnittstelle – wie StikDebug). Normal ist 49152
//  (gefunden am 24.11.2026); gesucht wird nur, wenn die Verbindung dort scheitert.
//

import Foundation
import Network

nonisolated enum RemotePairingPort {
    static let standard: UInt16 = 49152

    /// Port des Dienstes oder nil (nichts gefunden, keine Freigabe fuers lokale Netz, Zeit abgelaufen).
    static func discover(timeout: TimeInterval = 5) async -> UInt16? {
        await withCheckedContinuation { continuation in
            PortDiscovery(timeout: timeout) { continuation.resume(returning: $0) }.start()
        }
    }
}

/// Eine Suche: Browser -> Dienst waehlen -> kurz verbinden, um den aufgeloesten Port zu lesen.
/// Alles auf einer eigenen Warteschlange; `finish` wird genau einmal gerufen.
nonisolated private final class PortDiscovery: @unchecked Sendable {
    private let queue = DispatchQueue(label: "DashMirror.RemotePairingPort")
    private let timeout: TimeInterval
    private var finish: ((UInt16?) -> Void)?
    private var browser: NWBrowser?
    private var connection: NWConnection?

    init(timeout: TimeInterval, finish: @escaping (UInt16?) -> Void) {
        self.timeout = timeout
        self.finish = finish
    }

    /// Wie StikDebug 3.2.0 (JITEnableContext.swift): Peer-to-Peer erlaubt, Domain "local.", Loopback am
    /// Schnittstellennamen erkannt, Port auch im Zustand .waiting gelesen (die Probeverbindung darf scheitern –
    /// es geht nur um den aufgeloesten Endpunkt).
    private static var parameters: NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        return parameters
    }

    func start() {
        queue.async { [self] in
            let browser = NWBrowser(for: .bonjour(type: "_remotepairing._tcp", domain: "local."),
                                    using: Self.parameters)
            self.browser = browser
            browser.browseResultsChangedHandler = { [self] results, _ in
                guard connection == nil else { return }
                let services = results.filter { if case .service = $0.endpoint { true } else { false } }
                let loopback = services.first { $0.interfaces.contains { $0.name.hasPrefix("lo") } }
                guard let endpoint = (loopback ?? services.first)?.endpoint else { return }
                resolve(endpoint)
            }
            browser.stateUpdateHandler = { [self] state in
                switch state {
                case .waiting(let error):
                    // Typisch: keine Freigabe fuers lokale Netz (kDNSServiceErr_NoAuth -65555).
                    MirrorLog.write("Touch: Bonjour wartet – \(error)")
                case .failed(let error):
                    MirrorLog.write("Touch: Bonjour fehlgeschlagen – \(error)")
                    done(nil)
                default:
                    break
                }
            }
            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [self] in done(nil) }
        }
    }

    private func resolve(_ endpoint: NWEndpoint) {
        let connection = NWConnection(to: endpoint, using: Self.parameters)
        self.connection = connection
        connection.pathUpdateHandler = { [self] path in
            if path.status == .satisfied { readPort(from: connection) }
        }
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready, .waiting:
                readPort(from: connection)
            case .failed:
                done(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func readPort(from connection: NWConnection) {
        if case .hostPort(_, let port)? = connection.currentPath?.remoteEndpoint {
            done(port.rawValue)
        }
    }

    private func done(_ port: UInt16?) {
        guard let finish else { return }
        self.finish = nil
        browser?.cancel()
        connection?.cancel()
        browser = nil
        connection = nil
        finish(port)
    }
}
