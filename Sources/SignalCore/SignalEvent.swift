import Foundation

public enum SessionSource: String, Codable, Sendable {
    case cli, desktop, unknown
    /// Claude Code, in any client. Its terminal metadata identifies the tab.
    case claude

    public var isCodex: Bool { self != .claude }
    /// Runs in a terminal tab and can be resumed with a shell command.
    public var isTerminalClient: Bool { self == .cli || self == .claude }
}

public enum EventKind: String, Codable, Sendable {
    case started, approval, question, resumed, completed, failed, stopped, disconnected
}

public enum SessionPhase: String, Codable, Sendable {
    case running, approval, question, completed, failed, stopped, disconnected

    public var pending: Bool { self == .approval || self == .question }

    public var terminal: Bool { self == .completed || self == .failed || self == .stopped }
}

public struct SignalEvent: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var eventId: String
    public var source: SessionSource
    public var sessionId: String
    public var turnId: String
    public var requestId: String?
    public var project: String
    public var title: String?
    public var cwd: String?
    public var terminalTTY: String?
    public var terminalBundleID: String?
    public var kind: EventKind
    public var occurredAt: Double
    public var isChild: Bool

    public init(
        schemaVersion: Int = 1,
        eventId: String,
        source: SessionSource,
        sessionId: String,
        turnId: String,
        requestId: String? = nil,
        project: String,
        kind: EventKind,
        occurredAt: Double,
        isChild: Bool = false,
        title: String? = nil,
        cwd: String? = nil,
        terminalTTY: String? = nil,
        terminalBundleID: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.eventId = eventId
        self.source = source
        self.sessionId = sessionId
        self.turnId = turnId
        self.requestId = requestId
        self.project = project
        self.kind = kind
        self.occurredAt = occurredAt
        self.isChild = isChild
        self.title = title
        self.cwd = cwd
        self.terminalTTY = terminalTTY
        self.terminalBundleID = terminalBundleID
    }

    public func validated() throws -> SignalEvent {
        guard schemaVersion == 1 else { throw ValidationError.unsupportedVersion }
        guard occurredAt.isFinite, occurredAt >= 0, occurredAt < 253_402_300_800 else { throw ValidationError.invalidTimestamp }
        for (field, value, limit) in [
            ("eventId", eventId, 512),
            ("sessionId", sessionId, 512),
            ("turnId", turnId, 512),
            ("project", project, 256)
        ] {
            try Self.validate(value, field: field, limit: limit)
        }
        if let requestId { try Self.validate(requestId, field: "requestId", limit: 512) }
        if let title { try Self.validate(title, field: "title", limit: 1024) }
        if let cwd {
            try Self.validate(cwd, field: "cwd", limit: 4096)
            guard cwd.hasPrefix("/") else { throw ValidationError.invalidField("cwd") }
        }
        if let terminalTTY {
            guard terminalTTY.range(of: #"^/dev/(ttys[0-9]+|tty[0-9]+|pts/[0-9]+)$"#, options: .regularExpression) != nil else {
                throw ValidationError.invalidField("terminalTTY")
            }
        }
        if let terminalBundleID {
            try Self.validate(terminalBundleID, field: "terminalBundleID", limit: 256)
            guard terminalBundleID.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil else {
                throw ValidationError.invalidField("terminalBundleID")
            }
        }
        return self
    }

    private static func validate(_ value: String, field: String, limit: Int) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf8.count <= limit,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ValidationError.invalidField(field)
        }
    }

    public enum ValidationError: Error, Equatable {
        case unsupportedVersion
        case invalidTimestamp
        case invalidField(String)
    }
}
