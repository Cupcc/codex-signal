import Foundation

public struct SignalSession: Codable, Identifiable, Sendable, Equatable {
    public var id: String { source.rawValue + ":" + sessionId }
    public var source: SessionSource
    public var sessionId: String
    public var turnId: String
    public var project: String
    public var title: String?
    public var cwd: String?
    public var terminalTTY: String?
    public var terminalBundleID: String?
    public var displayTitle: String { title ?? project }
    public var phase: SessionPhase
    public var seen: Bool
    // Optional so state written by older versions continues to decode.
    public var dismissedAt: Double?
    public var updatedAt: Double
    public var requestId: String?
    public var isChild: Bool
    public var pending: Bool { phase.pending }
    public var isDismissed: Bool { dismissedAt != nil }
    public var isVisible: Bool { !isDismissed && !(seen && phase.terminal) }
    public var unread: Bool { !isDismissed && !seen && (phase.pending || phase.terminal) }
    public var ready: Bool { phase == .completed && unread }

    public init(
        source: SessionSource,
        sessionId: String,
        turnId: String,
        project: String,
        phase: SessionPhase,
        seen: Bool = false,
        updatedAt: Double,
        requestId: String? = nil,
        isChild: Bool = false,
        title: String? = nil,
        cwd: String? = nil,
        terminalTTY: String? = nil,
        terminalBundleID: String? = nil
    ) {
        self.source = source
        self.sessionId = sessionId
        self.turnId = turnId
        self.project = project
        self.phase = phase
        self.seen = seen
        self.updatedAt = updatedAt
        self.requestId = requestId
        self.isChild = isChild
        self.title = title
        self.cwd = cwd
        self.terminalTTY = terminalTTY
        self.terminalBundleID = terminalBundleID
    }
}

public struct SessionStore: Codable, Sendable {
    private enum PendingKind: String, Codable, Sendable {
        case approval, question

        init?(_ phase: SessionPhase) {
            switch phase {
            case .approval: self = .approval
            case .question: self = .question
            default: return nil
            }
        }

        var phase: SessionPhase { self == .approval ? .approval : .question }
    }

    private struct PendingRequest: Codable, Sendable {
        let requestID: String?
        let kind: PendingKind
        let occurredAt: Double
    }

    private struct Record: Codable, Sendable {
        var session: SignalSession
        var latestOccurredAt: Double
        // Separate from lifecycle ordering: metadata retries must not delay a real phase transition.
        var latestMetadataAt: Double?
        var retiredTurns: Set<String> = []
        var resolvedRequests: Set<String> = []
        var insertion: Int
        var pendingRequests: [PendingRequest]?

        var requests: [PendingRequest] {
            get {
                if let pendingRequests { return pendingRequests }
                guard let kind = PendingKind(session.phase) else { return [] }
                return [PendingRequest(requestID: session.requestId, kind: kind, occurredAt: session.updatedAt)]
            }
            set { pendingRequests = newValue }
        }

        mutating func projectPending(fallback: SessionPhase) {
            let selected = requests.enumerated().max {
                $0.element.occurredAt == $1.element.occurredAt
                    ? $0.offset < $1.offset : $0.element.occurredAt < $1.element.occurredAt
            }?.element
            if (fallback.pending || fallback == .running), let selected {
                session.phase = selected.kind.phase
                session.requestId = selected.requestID
            } else {
                session.phase = fallback
                session.requestId = nil
            }
        }

        mutating func clearRequests(resolved: Bool) {
            if resolved { resolvedRequests.formUnion(requests.compactMap(\.requestID)) }
            requests = []
        }
    }

    private var records: [String: Record] = [:]
    private var eventIDs: Set<String> = []
    private var eventOrder: [String] = []
    private var nextInsertion = 0

    public init() {}

    public var sessions: [SignalSession] {
        records.values.sorted { $0.insertion < $1.insertion }.map(\.session)
    }

    @discardableResult
    public mutating func apply(_ event: SignalEvent) -> Bool {
        guard (try? event.validated()) != nil else { return false }
        if event.source != .unknown { resolveUnknownSources([event.sessionId: event.source]) }
        let event = canonicalEvent(event)
        let id = event.source.rawValue + ":" + event.sessionId
        let eventKey = id + "\u{0}" + event.eventId
        guard !eventIDs.contains(eventKey) else { return false }
        remember(eventKey)
        let nextPhase = Self.phase(for: event.kind)

        guard var record = records[id] else {
            var initial = Record(
                session: SignalSession(
                    source: event.source,
                    sessionId: event.sessionId,
                    turnId: event.turnId,
                    project: event.project,
                    phase: nextPhase,
                    updatedAt: event.occurredAt,
                    requestId: nextPhase.pending ? event.requestId : nil,
                    isChild: event.isChild,
                    title: event.title, cwd: event.cwd,
                    terminalTTY: event.terminalTTY, terminalBundleID: event.terminalBundleID
                ),
                latestOccurredAt: event.occurredAt,
                latestMetadataAt: event.occurredAt,
                insertion: nextInsertion
            )
            initial.pendingRequests = initial.requests
            if event.kind == .resumed, let requestID = event.requestId {
                initial.resolvedRequests.insert(requestID)
            }
            records[id] = initial
            nextInsertion += 1
            return true
        }

        guard !record.retiredTurns.contains(event.turnId) else { return false }
        let newTurn = event.turnId != record.session.turnId
        let previous = record.session
        record.pendingRequests = record.requests
        if newTurn {
            guard event.kind == .started, event.occurredAt >= record.latestOccurredAt else { return false }
            record.retiredTurns.insert(record.session.turnId)
            record.resolvedRequests.removeAll()
            record.clearRequests(resolved: false)
            record.projectPending(fallback: .running)
        } else {
            guard event.kind != .started, !record.session.phase.terminal else { return false }
            if event.kind == .resumed, let requestID = event.requestId {
                // Completion is request evidence even when its waiting event arrives later.
                record.resolvedRequests.insert(requestID)
                let waiting = record.requests.contains { $0.requestID == requestID }
                record.requests.removeAll { $0.requestID == requestID }
                guard waiting else {
                    records[id] = record
                    return false
                }
                record.projectPending(fallback: .running)
            } else {
                guard event.occurredAt >= record.latestOccurredAt else { return false }
                if let kind = PendingKind(nextPhase) {
                    if let requestID = event.requestId, record.resolvedRequests.contains(requestID) { return false }
                    if record.requests.contains(where: { $0.requestID == event.requestId && $0.kind == kind }) {
                        guard record.session.phase == .disconnected else { return false }
                    } else {
                        record.requests.removeAll { $0.requestID == event.requestId }
                        record.requests.append(PendingRequest(requestID: event.requestId, kind: kind, occurredAt: event.occurredAt))
                    }
                } else if event.kind != .disconnected {
                    record.clearRequests(resolved: true)
                }
                record.projectPending(fallback: nextPhase)
            }
        }
        guard newTurn || previous.phase != record.session.phase || previous.requestId != record.session.requestId else {
            records[id] = record
            return false
        }
        record.latestOccurredAt = max(record.latestOccurredAt, event.occurredAt)

        record.session.turnId = event.turnId
        record.session.project = event.project
        if newTurn || event.occurredAt >= (record.latestMetadataAt ?? record.latestOccurredAt) {
            record.session.title = event.title ?? record.session.title
            record.session.cwd = event.cwd ?? record.session.cwd
            record.session.terminalTTY = newTurn ? event.terminalTTY : event.terminalTTY ?? record.session.terminalTTY
            record.session.terminalBundleID = newTurn ? event.terminalBundleID : event.terminalBundleID ?? record.session.terminalBundleID
            record.latestMetadataAt = event.occurredAt
        }
        record.session.seen = false
        record.session.dismissedAt = nil
        record.session.updatedAt = record.latestOccurredAt
        record.session.isChild = event.isChild
        records[id] = record
        return true
    }

    /// A duplicate lifecycle event may still carry a newly assigned title or terminal identity.
    /// Call separately from apply so metadata changes cannot trigger speech or unread attention.
    @discardableResult
    public mutating func updateMetadata(from event: SignalEvent) -> Bool {
        guard (try? event.validated()) != nil else { return false }
        let event = canonicalEvent(event)
        let id = event.source.rawValue + ":" + event.sessionId
        guard var record = records[id], event.turnId == record.session.turnId,
              event.occurredAt >= record.latestOccurredAt,
              event.occurredAt >= (record.latestMetadataAt ?? record.latestOccurredAt),
              event.title != nil || event.cwd != nil || event.terminalTTY != nil || event.terminalBundleID != nil else { return false }
        let previous = record.session
        record.session.title = event.title ?? record.session.title
        record.session.cwd = event.cwd ?? record.session.cwd
        record.session.terminalTTY = event.terminalTTY ?? record.session.terminalTTY
        record.session.terminalBundleID = event.terminalBundleID ?? record.session.terminalBundleID
        // Even an unchanged value is newer evidence. Persist its timestamp while reporting
        // only visible metadata changes to the caller.
        record.latestMetadataAt = event.occurredAt
        records[id] = record
        return record.session != previous
    }

    /// A failed metadata read must not create a second row for a known session.
    /// Keep explicit CLI and desktop identities separate; ambiguous evidence stays unknown.
    public func canonicalEvent(_ event: SignalEvent) -> SignalEvent {
        guard event.source == .unknown else { return event }
        let matches = [SessionSource.cli, .desktop].filter {
            records[$0.rawValue + ":" + event.sessionId] != nil
        }
        guard matches.count == 1 else { return event }
        var resolved = event
        resolved.source = matches[0]
        return resolved
    }

    /// Re-key existing unknown records without replaying events or resetting attention.
    @discardableResult
    public mutating func resolveUnknownSources(_ sources: [String: SessionSource]) -> Bool {
        var changed = false
        for (sessionID, source) in sources where source != .unknown {
            let oldID = "unknown:" + sessionID
            let newID = source.rawValue + ":" + sessionID
            guard var record = records.removeValue(forKey: oldID) else { continue }
            record.session.source = source
            if let known = records[newID] {
                var latest = known.latestOccurredAt >= record.latestOccurredAt ? known : record
                latest.insertion = min(known.insertion, record.insertion)
                latest.retiredTurns.formUnion(known.retiredTurns.union(record.retiredTurns))
                if known.session.turnId == record.session.turnId {
                    latest.resolvedRequests.formUnion(known.resolvedRequests.union(record.resolvedRequests))
                    if !latest.session.phase.terminal {
                        var merged: [PendingRequest] = []
                        for request in (known.requests + record.requests).sorted(by: { $0.occurredAt < $1.occurredAt }) {
                            if let id = request.requestID, latest.resolvedRequests.contains(id) { continue }
                            if !merged.contains(where: { $0.requestID == request.requestID }) { merged.append(request) }
                        }
                        latest.requests = merged
                        latest.projectPending(fallback: latest.session.phase.pending ? .running : latest.session.phase)
                    } else {
                        latest.clearRequests(resolved: true)
                    }
                    if known.session.phase == record.session.phase && known.session.requestId == record.session.requestId {
                        latest.session.seen = known.session.seen || record.session.seen
                        latest.session.dismissedAt = [known.session.dismissedAt, record.session.dismissedAt].compactMap { $0 }.max()
                    }
                } else {
                    latest.retiredTurns.insert(latest.session.turnId == known.session.turnId ? record.session.turnId : known.session.turnId)
                }
                record = latest
            }
            records[newID] = record
            let prefix = oldID + "\u{0}"
            var deduplicated = Set<String>()
            eventOrder = eventOrder.compactMap { key in
                let migrated = key.hasPrefix(prefix) ? newID + "\u{0}" + key.dropFirst(prefix.count) : key
                return deduplicated.insert(migrated).inserted ? migrated : nil
            }
            eventIDs = deduplicated
            changed = true
        }
        return changed
    }

    /// Refresh metadata independently of lifecycle events; never resets attention or wait time.
    @discardableResult
    public mutating func updateTitles(_ titles: [String: String]) -> Bool {
        var changed = false
        for id in Array(records.keys) {
            guard var record = records[id],
                  let title = titles[record.session.sessionId],
                  let normalized = CodexSessionIndex.normalizedTitle(title),
                  normalized != record.session.title else { continue }
            record.session.title = normalized
            records[id] = record
            changed = true
        }
        return changed
    }

    /// Repair missed terminal hooks from exact-turn runtime evidence, silently.
    @discardableResult
    public mutating func reconcile(_ resolution: CodexTurnResolution) -> Bool {
        guard resolution.observedAt.isFinite, resolution.observedAt >= 0 else { return false }
        let id = resolution.source.rawValue + ":" + resolution.sessionID
        guard var record = records[id], record.session.turnId == resolution.turnID,
              !record.session.phase.terminal, record.latestOccurredAt <= resolution.observedAt,
              (record.latestMetadataAt ?? record.latestOccurredAt) <= resolution.observedAt else { return false }
        record.clearRequests(resolved: true)
        switch resolution.outcome {
        case .completed: record.projectPending(fallback: .completed)
        case .interrupted: record.projectPending(fallback: .stopped)
        case .failed: record.projectPending(fallback: .failed)
        }
        // Observation time is not event time: an already queued new-turn hook
        // must still be accepted even if it predates this poll.
        records[id] = record
        return true
    }

    public mutating func markSeen(_ id: String) {
        records[id]?.session.seen = true
    }

    /// Acknowledge this reminder without changing the source task or request.
    /// Only a new lifecycle transition may make it visible again.
    public mutating func dismiss(_ id: String) {
        guard records[id] != nil, records[id]?.session.isDismissed == false else { return }
        records[id]?.session.dismissedAt = Date().timeIntervalSince1970
        records[id]?.session.seen = true
    }

    /// Expire reminders while retaining lifecycle ordering and replay protection.
    @discardableResult
    public mutating func dismissExpired(before cutoff: Double, at timestamp: Double) -> [String] {
        var expired: [String] = []
        for id in Array(records.keys) {
            guard var record = records[id], !record.session.isDismissed,
                  record.session.updatedAt <= cutoff else { continue }
            record.session.dismissedAt = timestamp
            record.session.seen = true
            records[id] = record
            expired.append(id)
        }
        return expired
    }

    public func sortedSessions() -> [SignalSession] {
        records.values.sorted {
            if $0.session.updatedAt != $1.session.updatedAt {
                return $0.session.updatedAt < $1.session.updatedAt
            }
            return $0.insertion < $1.insertion
        }.map(\.session)
    }

    private mutating func remember(_ id: String) {
        eventIDs.insert(id)
        eventOrder.append(id)
        if eventOrder.count > 4096 {
            eventIDs.remove(eventOrder.removeFirst())
        }
    }

    private static func phase(for kind: EventKind) -> SessionPhase {
        switch kind {
        case .started, .resumed: return .running
        case .approval: return .approval
        case .question: return .question
        case .completed: return .completed
        case .failed: return .failed
        case .stopped: return .stopped
        case .disconnected: return .disconnected
        }
    }

}
