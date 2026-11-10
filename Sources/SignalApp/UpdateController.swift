import AppKit
import Combine

@MainActor
final class UpdateController: ObservableObject {
    enum State: Equatable {
        case idle, checking, current, available(UpdatePackage), downloading(UpdatePackage)
        case ready(UpdatePackage, URL), installing, failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published var automatic: Bool {
        didSet {
            defaults.set(automatic, forKey: "automaticallyDownloadUpdates")
            if automatic { check() }
        }
    }
    let currentVersion: String
    private let defaults: UserDefaults
    private let service: UpdateService
    private let directory: URL
    private let bundleURL: URL
    private var timer: Timer?
    private var task: Task<Void, Never>?

    init(dataDirectory: URL, defaults: UserDefaults = .standard, service: UpdateService = UpdateService(), bundle: Bundle = .main) {
        self.defaults = defaults
        self.service = service
        directory = dataDirectory.appendingPathComponent("Updates", isDirectory: true)
        bundleURL = bundle.bundleURL
        currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
        automatic = defaults.object(forKey: "automaticallyDownloadUpdates") as? Bool ?? true
        let receipt = directory.appendingPathComponent("result.txt")
        if let result = try? String(contentsOf: receipt, encoding: .utf8) {
            if result.trimmingCharacters(in: .whitespacesAndNewlines) == "failed" {
                state = .failed("安装失败，已尝试恢复旧版。请前往 GitHub 手动下载。")
            }
            try? FileManager.default.removeItem(at: receipt)
        }
    }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    var status: String {
        switch state {
        case .idle: return "当前版本 \(currentVersion)"
        case .checking: return "正在检查更新…"
        case .current: return "已是最新版本 · \(currentVersion)"
        case .available(let package): return "发现新版本 \(package.version)"
        case .downloading(let package): return "正在下载 \(package.version)…"
        case .ready(let package, _): return "\(package.version) 已就绪"
        case .installing: return "正在准备重启…"
        case .failed(let message): return message
        }
    }

    func start() {
        guard timer == nil, bundleURL.pathExtension == "app" else { return }
        // Preserve installation failure feedback until the user retries.
        if automatic, case .idle = state { check() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.automatic else { return }
                self.check()
            }
        }
    }

    func check() {
        guard !isBusy else { return }
        if case .ready = state { return }
        guard let version = AppVersion(currentVersion) else {
            state = .failed("开发版无法自动更新，请前往 GitHub 下载。")
            return
        }
        state = .checking
        task = Task {
            do {
                if let package = try await service.latest(after: version) {
                    state = .available(package)
                    if automatic { await download(package) }
                } else { state = .current }
            } catch { state = .failed(error.localizedDescription) }
        }
    }

    func downloadAvailable() {
        guard case .available(let package) = state else { return }
        state = .downloading(package)
        task = Task { await download(package) }
    }

    private func download(_ package: UpdatePackage) async {
        state = .downloading(package)
        do {
            let app = try await service.download(package, into: directory)
            state = .ready(package, app)
        } catch { state = .failed(error.localizedDescription) }
    }

    func install() {
        guard case .ready(let package, let staged) = state else { return }
        state = .installing
        task = Task {
            var replacement: URL?
            do {
                let prepared = try await service.prepareInstallation(staged: staged, destination: bundleURL, version: package.version)
                replacement = prepared
                let resource = bundleURL.appendingPathComponent("Contents/Resources/CodexSignal_SignalApp.bundle/Resources/install-update.sh")
                guard FileManager.default.isReadableFile(atPath: resource.path) else {
                    throw UpdateError.commandFailed
                }
                let helper = staged.deletingLastPathComponent().appendingPathComponent("install.sh")
                try FileManager.default.copyItem(at: resource, to: helper)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = [helper.path, String(ProcessInfo.processInfo.processIdentifier), prepared.path,
                                     bundleURL.path, directory.appendingPathComponent("result.txt").path,
                                     staged.deletingLastPathComponent().path, directory.deletingLastPathComponent().path]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                NSApp.terminate(nil)
            } catch {
                if let replacement { try? FileManager.default.removeItem(at: replacement) }
                state = .failed(error.localizedDescription)
            }
        }
    }

    func openDownloadPage() { NSWorkspace.shared.open(UpdateRelease.downloadPage) }
}
