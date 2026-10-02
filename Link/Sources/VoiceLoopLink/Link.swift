import CryptoKit
import Foundation
import Network

public enum VoiceLoopLink {
    public static let serviceType = "_voiceloop._tcp"

    /// TLS with a pre-shared key derived from the 6-digit pairing code shown on the Mac.
    /// Without the code a device on the same Wi-Fi can neither read nor send anything.
    public static func parameters(code: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let key = HMAC<SHA256>.authenticationCode(
            for: Data("voice-loop-pairing-v1".utf8),
            using: SymmetricKey(data: Data(code.utf8)))
        let keyData = Data(key).withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("voice-loop".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions,
                                                keyData as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(
            tls.securityProtocolOptions,
            tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        let params = NWParameters(tls: tls, tcp: tcp)
        params.includePeerToPeer = true
        return params
    }
}

/// Newline-delimited JSON over an NWConnection. All callbacks arrive on the main queue.
@MainActor
public final class LinkConnection {
    public let connection: NWConnection
    public var onEnvelope: ((LinkEnvelope) -> Void)?
    public var onState: ((NWConnection.State) -> Void)?
    private var buffer = Data()

    public init(_ connection: NWConnection) {
        self.connection = connection
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.onState?(state) }
        }
        connection.start(queue: .main)
        receive()
    }

    public func send(_ envelope: LinkEnvelope) {
        guard var data = try? JSONEncoder().encode(envelope) else { return }
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    public func cancel() {
        connection.cancel()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
            [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data { self.buffer.append(data); self.drain() }
                if error == nil && !isComplete { self.receive() }
            }
        }
    }

    private func drain() {
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let env = try? JSONDecoder().decode(LinkEnvelope.self, from: line) {
                onEnvelope?(env)
            }
        }
    }
}

/// Six random digits, shown on the Mac and typed once on the iPhone.
public func makePairingCode() -> String {
    String(format: "%06d", Int.random(in: 0...999_999))
}
