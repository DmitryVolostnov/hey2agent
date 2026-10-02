import Network
import XCTest
@testable import VoiceLoopLink

/// Real TLS-PSK round trip over localhost: the right code connects and exchanges
/// messages, a wrong code never gets through.
@MainActor
final class LinkTests: XCTestCase {
    private var listener: NWListener!
    private var serverSide: LinkConnection?

    private func startServer(code: String, onCommand: @escaping (LinkCommand) -> Void) throws -> NWEndpoint.Port {
        listener = try NWListener(using: VoiceLoopLink.parameters(code: code), on: .any)
        let ready = expectation(description: "listener ready")
        listener.stateUpdateHandler = { state in if case .ready = state { ready.fulfill() } }
        listener.newConnectionHandler = { [weak self] nw in
            MainActor.assumeIsolated {
                let c = LinkConnection(nw)
                c.onState = { [weak c] state in
                    if case .ready = state {
                        c?.send(LinkEnvelope(snapshot: LinkSnapshot(
                            mac: "Test Mac", enabled: true, muted: false, active: nil,
                            sessions: [LinkSession(id: "s1", project: "p", title: "Чат", status: "working", since: 0)],
                            recent: [])))
                    }
                }
                c.onEnvelope = { env in if let cmd = env.command { onCommand(cmd) } }
                self?.serverSide = c
                c.start()
            }
        }
        listener.start(queue: .main)
        wait(for: [ready], timeout: 5)
        return listener.port!
    }

    private func client(port: NWEndpoint.Port, code: String) -> LinkConnection {
        LinkConnection(NWConnection(host: "127.0.0.1", port: port, using: VoiceLoopLink.parameters(code: code)))
    }

    func testRightCodeExchangesMessages() throws {
        let gotCommand = expectation(description: "server got command")
        let port = try startServer(code: "123456") { cmd in
            if cmd == .dictate(session: "s1") { gotCommand.fulfill() }
        }
        let gotSnapshot = expectation(description: "client got snapshot")
        let c = client(port: port, code: "123456")
        c.onEnvelope = { env in
            if env.snapshot?.sessions.first?.title == "Чат" {
                gotSnapshot.fulfill()
                c.send(LinkEnvelope(command: .dictate(session: "s1")))
            }
        }
        c.start()
        wait(for: [gotSnapshot, gotCommand], timeout: 5)
        c.cancel()
        listener.cancel()
    }

    func testWrongCodeIsRejected() throws {
        let port = try startServer(code: "123456") { _ in XCTFail("command must not arrive") }
        let failed = expectation(description: "client failed")
        let c = client(port: port, code: "654321")
        c.onEnvelope = { _ in XCTFail("no data with a wrong code") }
        c.onState = { state in
            switch state {
            case .failed, .waiting: failed.fulfill()
            case .ready: XCTFail("must not connect with a wrong code")
            default: break
            }
        }
        c.start()
        wait(for: [failed], timeout: 5)
        c.cancel()
        listener.cancel()
    }
}
