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

    static func aggregatePhase(_ sessions: [SignalSession]) -> SessionPhase? {
        let active = sessions.filter(\.isVisible)
        if let pending = active.filter(\.pending).min(by: { $0.updatedAt < $1.updatedAt }) { return pending.phase }
        if active.contains(where: { $0.phase == .running }) { return .running }
        if let problem = active.last(where: { $0.phase == .failed || $0.phase == .disconnected }) { return problem.phase }
        if active.contains(where: \.ready) { return .completed }
        return active.last?.phase
    }

    static func receiving(_ events: [SignalEvent], sessions: [SignalSession], current: IslandNotice?) -> IslandNotice? {
        var items = current?.reconciled(with: sessions)?.sessions ?? []
        for event in events {
            guard let phase = phase(for: event.kind), !(event.isChild && event.kind == .completed),
                  let session = sessions.first(where: {
                      $0.sessionId == event.sessionId && $0.source == event.source && $0.turnId == event.turnId
                          && $0.phase == phase && (!phase.pending || $0.requestId == event.requestId) && !$0.seen && !$0.isDismissed
                  }) else { continue }
            items.removeAll { $0.id == session.id }
            items.append(session)
        }
        guard !items.isEmpty else { return nil }
        if let current, Set(items.map(identity)) == Set(current.sessions.map(identity)) { return current.reconciled(with: sessions) }
        return IslandNotice(sessions: items)
    }

    func reconciled(with latest: [SignalSession]) -> IslandNotice? {
        let items = sessions.compactMap { previous in
            latest.first { Self.identity($0) == Self.identity(previous) && !$0.seen && !$0.isDismissed }
        }
        return items.isEmpty ? nil : IslandNotice(id: id, sessions: items)
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
