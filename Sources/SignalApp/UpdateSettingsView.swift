import SwiftUI

struct UpdateSettingsView: View {
    @ObservedObject var updater: UpdateController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("自动检查并下载更新", isOn: $updater.automatic)
                .help("启动时及每 6 小时检查更新；下载完成后，由你选择重启安装。")
            Text(updater.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("更新状态：\(updater.status)")
            HStack {
                switch updater.state {
                case .ready:
                    Button("重启并更新") { updater.install() }
                case .available:
                    Button("下载更新") { updater.downloadAvailable() }
                default:
                    Button("检查更新") { updater.check() }.disabled(updater.isBusy)
                }
                Spacer()
                Link("GitHub 手动下载 ↗", destination: UpdateRelease.downloadPage)
            }
        }
    }
}
