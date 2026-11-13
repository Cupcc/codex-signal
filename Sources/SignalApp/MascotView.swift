import AppKit
import SwiftUI
import SignalCore

struct PhaseAppearance {
    let title: String
    let color: Color
    let asset: String
    let symbol: String

    init(_ phase: SessionPhase?, seen: Bool = false) {
        switch phase {
        case nil:
            self = .init(title: "空闲", color: .secondary, asset: "idle", symbol: "circle")
        case .running:
            self = .init(title: "运行中", color: Color(red: 0.48, green: 0.73, blue: 0.66), asset: "working", symbol: "circle.fill")
        case .approval:
            self = .init(title: seen ? "待确认（已查看）" : "待确认", color: Color(red: 0.93, green: 0.68, blue: 0.42), asset: "attention", symbol: "exclamationmark.circle.fill")
        case .question:
            self = .init(title: seen ? "待回答（已查看）" : "待回答", color: Color(red: 0.72, green: 0.67, blue: 1), asset: "question", symbol: "questionmark.circle.fill")
        case .completed:
            self = seen
                ? .init(title: "已查看", color: .secondary, asset: "idle", symbol: "circle")
                : .init(title: "待查看", color: Color(red: 0.48, green: 0.73, blue: 1), asset: "ready", symbol: "doc.text")
        case .failed:
            self = .init(title: "运行失败", color: Color(red: 1, green: 0.55, blue: 0.52), asset: "error", symbol: "exclamationmark.triangle.fill")
        case .stopped:
            self = .init(title: "已停止", color: Color(red: 0.67, green: 0.70, blue: 0.76), asset: "idle", symbol: "stop.circle")
        case .disconnected:
            self = .init(title: "暂时无法获取状态", color: Color(red: 0.67, green: 0.70, blue: 0.76), asset: "error", symbol: "antenna.radiowaves.left.and.right.slash")
        }
    }

    private init(title: String, color: Color, asset: String, symbol: String) {
        self.title = title
        self.color = color
        self.asset = asset
        self.symbol = symbol
    }
}

/// Codex sessions use the blue companion; Claude Code sessions use the orange crab.
enum MascotSkin: Equatable {
    case companion, crab

    init(_ source: SessionSource?) { self = source == .claude ? .crab : .companion }

    /// Layer file prefix; the companion keeps its original unprefixed names.
    var layerPrefix: String { self == .crab ? "crab-" : "" }
}

struct MascotView: View {
    var phase: SessionPhase?
    var seen = false
    var skin: MascotSkin = .companion
    var size: CGFloat = 56
    var motionActive = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false

    var body: some View {
        AnimatedMascot(state: PhaseAppearance(phase, seen: seen).asset, skin: skin, mini: size <= 28,
                       active: motionActive && visible, reduced: reduceMotion)
        .frame(width: size, height: size)
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .accessibilityHidden(true)
    }
}
