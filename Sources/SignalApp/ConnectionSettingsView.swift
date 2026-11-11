import AppKit
import SwiftUI

struct ConnectionSettingsView: View {
    @ObservedObject var connection: CodexConnection
    var isDemo = false
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if connection.isConfiguring {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol).foregroundStyle(connection.state == .receiving ? .green : .secondary)
                }
                Text("Codex").fontWeight(.medium)
                Text(isDemo ? "演示模式" : connection.status)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .accessibilityLabel("Codex 接入状态：\(isDemo ? "演示模式" : connection.status)")
                Spacer(minLength: 4)
                Button(actionTitle) { connection.configure() }
                    .disabled(isDemo || connection.isConfiguring)
                    .help(isDemo ? "演示模式不修改 Codex 配置" : "重建 Codex Signal 的 Hooks，保留其他 Hooks")
            }
            if !isDemo {
                if connection.needsReview {
                    Text("首次使用需在 Codex 中审阅 Hooks。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    DisclosureGroup("启用 Hooks", isExpanded: $showsDetails) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("桌面端：设置 → Hooks → 审阅并信任。")
                            HStack {
                                Text("CLI：运行 /hooks，审阅并信任。")
                                Spacer(minLength: 4)
                                Button("复制 /hooks") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString("/hooks", forType: .string)
                                }
                            }
                            Text("完成后开启新会话。")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 6)
                    }
                    .font(.caption)
                } else if case .failed(let message) = connection.state {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if connection.state == .pythonRequired {
                    HStack {
                        Text("安装后重试。")
                        Link("安装 Python ↗", destination: URL(string: "https://www.python.org/downloads/macos/")!)
                    }
                    .font(.caption)
                }
            }
        }
    }

    private var actionTitle: String {
        switch connection.state {
        case .configured, .receiving: return "重新配置"
        case .configuring: return "配置中…"
        case .failed, .pythonRequired: return "重试"
        case .idle: return "一键配置"
        }
    }

    private var symbol: String {
        switch connection.state {
        case .receiving: return "checkmark.circle.fill"
        case .configured: return "checkmark.circle"
        case .failed, .pythonRequired: return "exclamationmark.circle"
        default: return "link"
        }
    }
}
