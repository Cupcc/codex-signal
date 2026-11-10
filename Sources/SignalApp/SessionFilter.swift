import SignalCore

enum SessionFilter {
    case all, pending, ready

    func includes(_ session: SignalSession) -> Bool {
        switch self {
        case .all: return true
        case .pending: return session.pending
        case .ready: return session.ready
        }
    }

    var emptyTitle: String {
        switch self {
        case .all: return "暂无会话提醒"
        case .pending: return "暂无待处理提醒"
        case .ready: return "暂无待查看结果"
        }
    }
}
