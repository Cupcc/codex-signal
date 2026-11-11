import AppKit
import Combine
import Darwin

@main
struct SignalApplication {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) { }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var lockDescriptor: Int32 = -1
    private var model: AppModel!
    private var panel: IslandPanel!
    private var statusItem: NSStatusItem!
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        let demo = args.contains("--demo")
        let directory: URL
        if let index = args.firstIndex(of: "--data-dir"), args.indices.contains(index + 1) {
            directory = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        } else if demo {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-signal-demo", isDirectory: true)
        } else {
            directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Codex Signal", isDirectory: true)
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            lockDescriptor = Darwin.open(directory.appendingPathComponent("instance.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
            guard lockDescriptor >= 0, flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
                fputs("Codex Signal is already using this data directory.\n", stderr)
                NSApp.terminate(nil)
                return
            }
        } catch {
            fputs("Codex Signal cannot create its data directory.\n", stderr)
            NSApp.terminate(nil)
            return
        }
        let codexHome: URL
        if let index = args.firstIndex(of: "--codex-home"), args.indices.contains(index + 1) {
            codexHome = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        } else {
            codexHome = CodexConnection.defaultCodexHome
        }
        model = AppModel(dataDirectory: directory, demo: demo, codexHome: codexHome)
        panel = IslandPanel(model: model)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "◈ Signal"
        statusItem.button?.toolTip = "Codex Signal · 会话伙伴岛"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        model.$sessions.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.statusItem.button?.title = self.model.pendingCount > 0 ? "◈ \(self.model.pendingCount)" : (self.model.readyCount > 0 ? "▤ \(self.model.readyCount)" : "◈ Signal")
            }
        }.store(in: &subscriptions)
        panel.show()
        if !demo {
            model.updater.start()
            // Replay runs must opt in with an isolated Codex home before writing hooks.
            if !args.contains("--data-dir") || args.contains("--codex-home") { model.connection.configureAfterInstallation() }
            if model.sessions.isEmpty { model.setExpanded(true) }
        }
        if demo || args.contains("--expanded") { model.setExpanded(true) }
    }

    @objc private func togglePanel() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "展开会话", action: #selector(expandPanel), keyEquivalent: "")
            menu.addItem(withTitle: "打开数据目录", action: #selector(openData), keyEquivalent: "")
            menu.addItem(.separator())
            let update = menu.addItem(withTitle: updateMenuTitle, action: #selector(updateApp), keyEquivalent: "")
            update.isEnabled = !model.updater.isBusy
            menu.autoenablesItems = false
            menu.addItem(withTitle: "GitHub 手动下载…", action: #selector(downloadManually), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "关于 Codex Signal", action: #selector(about), keyEquivalent: "")
            for item in menu.items { item.target = self }
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else { panel.toggle() }
    }
    private var updateMenuTitle: String {
        switch model.updater.state {
        case .ready: return "重启并更新…"
        case .available: return "下载更新…"
        case .checking: return "正在检查更新…"
        case .downloading: return "正在下载更新…"
        case .installing: return "正在准备重启…"
        default: return "检查更新…"
        }
    }
    @objc private func updateApp() {
        switch model.updater.state {
        case .ready: model.updater.install()
        case .available: model.updater.downloadAvailable()
        default: model.updater.check()
        }
        model.setExpanded(true)
        model.updateSettingsRequested = true
        panel.show()
    }
    @objc private func downloadManually() { model.updater.openDownloadPage() }
    @objc private func expandPanel() { model.setExpanded(true); panel.show() }
    @objc private func openData() { NSWorkspace.shared.open(model.dataDirectory) }
    @objc private func about() {
        AppProduct.showAbout()
    }
}
