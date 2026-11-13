import Foundation
import SignalCore

/// A transient handoff, independent of speech and the persistent session list.
struct IslandNotice: Equatable, Identifiable {
    let id: UUID
    let sessions: [SignalSession]
    var primary: SignalSession { sessions[0] }

    private init(id: UUID = UUID(), sessions: [SignalSession]) {
        self.id = id
        self.sessions = sessions.sorted {
            let lhs = Self.priority($0.phase), rhs = Self.priority($1.phase)
            if lhs != rhs { return lhs < rhs }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
            return $0.id < $1.id
        }
    }

    static func aggregatePhase(_ sessions: [SignalSession]) -> SessionPhase? { aggregate(sessions).phase }

    /// The crab stands in only when every session behind the aggregate phase is
    /// Claude Code, so mixed running work keeps one steady character.
    static func aggregateSkin(_ sessions: [SignalSession]) -> MascotSkin {
        let drivers = aggregate(sessions).drivers
        return !drivers.isEmpty && drivers.allSatisfy { $0.source == .claude } ? .crab : .companion
    }

    private static func aggregate(_ sessions: [SignalSession]) -> (phase: SessionPhase?, drivers: [SignalSession]) {
        let active = sessions.filter(\.isVisible)
        if let pending = active.filter(\.pending).min(by: { $0.updatedAt < $1.updatedAt }) { return (pending.phase, [pending]) }
        let running = active.filter { $0.phase == .running }
        if !running.isEmpty { return (.running, running) }
        if let problem = active.last(where: { $0.phase == .failed || $0.phase == .disconnected }) { return (problem.phase, [problem]) }
        let ready = active.filter(\.ready)
        if !ready.isEmpty { return (.completed, ready) }
        return (active.last?.phase, active.suffix(1))
    }

    static func receiving(_ events: [SignalEvent], sessions: [SignalSession], current: IslandNotice?) -> IslandNotice? {
        let reconciled = current?.reconciled(with: sessions)
        var items = reconciled?.sessions ?? []
        for event in events {
            guard let session = currentSession(for: event, in: sessions) else { continue }
            items.removeAll { $0.id == session.id }
            items.append(session)
        }
        guard !items.isEmpty else { return nil }
        if let reconciled, Set(items.map(identity)) == Set(reconciled.sessions.map(identity)) { return reconciled }
        return IslandNotice(sessions: items)
    }

    func reconciled(with latest: [SignalSession]) -> IslandNotice? {
        let items = sessions.compactMap { previous -> SignalSession? in
            guard let session = Self.successor(of: previous, in: latest),
                  session.turnId == previous.turnId, session.phase == previous.phase,
                  session.requestId == previous.requestId, !session.seen, !session.isDismissed else { return nil }
            return session
        }
        return items.isEmpty ? nil : IslandNotice(id: id, sessions: items)
    }

    static func currentSession(for event: SignalEvent, in sessions: [SignalSession]) -> SignalSession? {
        guard let phase = phase(for: event.kind), !(event.isChild && event.kind == .completed) else { return nil }
        return sessions.first {
            $0.sessionId == event.sessionId && $0.source == event.source && $0.turnId == event.turnId
                && $0.phase == phase && (!phase.pending || $0.requestId == event.requestId) && !$0.seen && !$0.isDismissed
        }
    }

    static func successor(of previous: SignalSession, in latest: [SignalSession]) -> SignalSession? {
        if let exact = latest.first(where: { $0.id == previous.id }) { return exact }
        guard previous.source == .unknown else { return nil }
        let known = latest.filter { $0.sessionId == previous.sessionId && $0.source != .unknown }
        return known.count == 1 ? known[0] : nil
    }

    private static func identity(_ session: SignalSession) -> String {
        [session.id, session.turnId, session.phase.rawValue, session.requestId ?? ""].joined(separator: "\u{0}")
    }

    private static func priority(_ phase: SessionPhase) -> Int {
        switch phase {
        case .approval, .question: return 0
        case .failed, .disconnected: return 1
        default: return 2
        }
    }

    private static func phase(for kind: EventKind) -> SessionPhase? {
        switch kind {
        case .approval: return .approval
        case .question: return .question
        case .failed: return .failed
        case .completed: return .completed
        case .disconnected: return .disconnected
        default: return nil
        }
    }

    static var preview: IslandNotice {
        IslandNotice(sessions: [SignalSession(source: .desktop, sessionId: "preview", turnId: "preview",
                                             project: "Codex Signal", phase: .approval, updatedAt: 0)])
    }
}
