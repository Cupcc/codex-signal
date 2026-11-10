import CryptoKit
import Darwin
import Foundation

public struct CodexTurnResolution: Sendable {
    public enum Outcome: String, Sendable { case completed, interrupted, failed }
    public let source: SessionSource
    public let sessionID: String
    public let turnID: String
    public let outcome: Outcome
    public let observedAt: Double

    public init(source: SessionSource, sessionID: String, turnID: String, outcome: Outcome, observedAt: Double) {
        self.source = source
        self.sessionID = sessionID
        self.turnID = turnID
        self.outcome = outcome
        self.observedAt = observedAt
    }
}

/// Metadata-only reads from the existing shared service; never starts or resumes a thread.
public enum CodexRuntimeStatus {
    public static func read(sessions: [SignalSession],
                            root: URL = CodexSessionIndex.defaultURL().deletingLastPathComponent()) -> [CodexTurnResolution] {
        let candidates = sessions.filter { !$0.phase.terminal }
        let managed = CodexSessionSource.sharedServiceSessionIDs(root: root, sessionIDs: Set(candidates.map(\.sessionId)))
        let tracked = candidates.filter { managed.contains($0.sessionId) }
        guard !tracked.isEmpty else { return [] }
        var result: [CodexTurnResolution] = []
        do {
            let connection = try CodexStatusConnection(path: root.appendingPathComponent("app-server-control/app-server-control.sock").path)
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
            guard try connection.request(method: "initialize", params: ["clientInfo": ["name": "codex_signal", "version": version]]) != nil else { return [] }
            try connection.send(["method": "initialized"])
            for session in tracked {
                let observedAt = Date().timeIntervalSince1970
                guard let response = try connection.request(method: "thread/turns/list", params: [
                    "threadId": session.sessionId, "limit": 20, "sortDirection": "desc", "itemsView": "notLoaded"
                ]) else { continue }
                if let resolution = resolution(response: response, session: session, observedAt: observedAt) {
                    result.append(resolution)
                }
            }
        } catch {
            // Missing service, older protocol, or I/O failure provides no lifecycle evidence.
        }
        return result
    }

    static func resolution(response: [String: Any], session: SignalSession, observedAt: Double) -> CodexTurnResolution? {
        guard let turns = response["data"] as? [[String: Any]],
              let turn = turns.first(where: { $0["id"] as? String == session.turnId }),
              let status = turn["status"] as? String,
              let outcome = CodexTurnResolution.Outcome(rawValue: status) else { return nil }
        return CodexTurnResolution(source: session.source, sessionID: session.sessionId, turnID: session.turnId, outcome: outcome, observedAt: observedAt)
    }
}

/// Codex's local control socket carries JSON-RPC over WebSocket (not stdio JSONL).
/// Each polling connection has one bounded lifetime and does not subscribe to threads.
private final class CodexStatusConnection {
    private var descriptor: Int32
    private let deadline = Date().addingTimeInterval(3)
    private var sequence = 0
    private let maximumMessageBytes = 1_048_576
    private enum Failure: Error { case transport, protocolMismatch }

    init(path: String) throws {
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.transport }
        do {
            var noSignal: Int32 = 1
            guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal))) == 0,
                  fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { throw Failure.transport }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8) + [0]
            guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.transport }
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let addressLength = socklen_t(address.sun_len)
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, addressLength) }
            }
            if connected != 0 {
                guard errno == EINPROGRESS else { throw Failure.transport }
                try ready(Int16(POLLOUT))
                var error: Int32 = 0
                var length = socklen_t(MemoryLayout.size(ofValue: error))
                guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { throw Failure.transport }
            }
            let key = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
            try write(Data("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n".utf8))
            var header = Data()
            while !header.suffix(4).elementsEqual([13, 10, 13, 10]) {
                guard header.count < 8192 else { throw Failure.protocolMismatch }
                header.append(try read(1))
            }
            let lines = String(decoding: header, as: UTF8.self).components(separatedBy: "\r\n")
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            guard lines.first?.hasPrefix("HTTP/1.1 101 ") == true,
                  lines.contains(where: {
                      let parts = $0.split(separator: ":", maxSplits: 1)
                      return parts.count == 2 && parts[0].lowercased() == "sec-websocket-accept"
                          && parts[1].trimmingCharacters(in: .whitespaces) == accept
                  }) else { throw Failure.protocolMismatch }
        } catch {
            close(descriptor)
            descriptor = -1
            throw error
        }
    }

    deinit { if descriptor >= 0 { close(descriptor) } }

    func request(method: String, params: [String: Any]) throws -> [String: Any]? {
        sequence += 1
        try send(["id": sequence, "method": method, "params": params])
        while true {
            let data = try message()
            guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.protocolMismatch }
            guard response["id"] as? Int == sequence else { continue }
            if response["error"] != nil { return nil }
            guard let result = response["result"] as? [String: Any] else { throw Failure.protocolMismatch }
            return result
        }
    }

    func send(_ object: [String: Any]) throws { try frame(try JSONSerialization.data(withJSONObject: object), opcode: 1) }

    private func frame(_ payload: Data, opcode: UInt8) throws {
        guard payload.count <= 65_535 else { throw Failure.protocolMismatch }
        var output = Data([0x80 | opcode])
        if payload.count < 126 { output.append(0x80 | UInt8(payload.count)) }
        else { output.append(contentsOf: [0xFE, UInt8(payload.count >> 8), UInt8(payload.count & 255)]) }
        let mask = (0..<4).map { _ in UInt8.random(in: .min ... .max) }
        output.append(contentsOf: mask)
        output.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        try write(output)
    }

    private func message() throws -> Data {
        var payload = Data()
        var started = false
        while true {
            let header = [UInt8](try read(2))
            let opcode = header[0] & 15
            guard header[0] & 0x70 == 0, header[1] & 0x80 == 0 else { throw Failure.protocolMismatch }
            var count = UInt64(header[1] & 127)
            if count == 126 || count == 127 {
                count = try read(count == 126 ? 2 : 8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            }
            guard count <= maximumMessageBytes, payload.count + Int(count) <= maximumMessageBytes else { throw Failure.protocolMismatch }
            let part = try read(Int(count))
            if opcode == 9 || opcode == 10 {
                guard header[0] & 0x80 != 0, count <= 125 else { throw Failure.protocolMismatch }
                if opcode == 9 { try frame(part, opcode: 10) }
                continue
            }
            guard (opcode == 1 && !started) || (opcode == 0 && started) else { throw Failure.protocolMismatch }
            started = true
            payload.append(part)
            if header[0] & 0x80 != 0 { return payload }
        }
    }

    private func ready(_ events: Int16) throws {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw Failure.transport }
        var descriptorState = pollfd(fd: descriptor, events: events, revents: 0)
        let result = poll(&descriptorState, 1, Int32(ceil(remaining * 1000)))
        if result < 0 && errno == EINTR { return try ready(events) }
        guard result > 0, descriptorState.revents & events != 0 else { throw Failure.transport }
    }

    private func read(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            try ready(Int16(POLLIN))
            let received = bytes.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress!.advanced(by: offset), count - offset, 0) }
            if received < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard received > 0 else { throw Failure.transport }
            offset += received
        }
        return Data(bytes)
    }

    private func write(_ data: Data) throws {
        var offset = 0
        while offset < data.count {
            try ready(Int16(POLLOUT))
            let sent = data.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress!.advanced(by: offset), data.count - offset, 0) }
            if sent < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard sent > 0 else { throw Failure.transport }
            offset += sent
        }
    }
}
