import Foundation
import Combine

struct HookInstallation: Codable, Sendable {
    let changed: Bool
    let hooksPath: String
    let backupPath: String?
}

enum HookAgent: String, Sendable {
    case codex, claude

    var title: String { self == .codex ? "Codex" : "Claude Code" }
    var receiptName: String { self == .codex ? "codex-connection.json" : "claude-connection.json" }
    /// Codex asks the user to trust new hooks; Claude Code reloads its settings by itself.
    var needsTrustReview: Bool { self == .codex }

    func defaultHome(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let variable = self == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"
        if let path = environment[variable], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(self == .codex ? ".codex" : ".claude", isDirectory: true)
    }
}

enum HookInstallationError: LocalizedError {
    case pythonRequired
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .pythonRequired: return "安装 Python 3 后重试。"
        case .failed(let message): return message
        }
    }
}

struct HookInstaller: Sendable {
    let agent: HookAgent
    let resources: URL?
    let home: URL
    let dataDirectory: URL

    func install(force: Bool) throws -> HookInstallation {
        guard let script = resources?.appendingPathComponent("Bridge/configure_hooks.py"),
              FileManager.default.fileExists(atPath: script.path) else {
            throw HookInstallationError.failed("应用内的配置组件缺失，请重新安装 Codex Signal。")
        }
        let python = try findPython()
        var arguments = ["-E", "-s", script.path, "--agent", agent.rawValue, "--config-home", home.path, "--data-dir", dataDirectory.path]
        if force { arguments.append("--force") }
        let result = try Self.run(python, arguments: arguments, timeout: 15)
        guard result.status == 0 else {
            let message = (try? JSONSerialization.jsonObject(with: result.output) as? [String: String])?["error"]
            throw HookInstallationError.failed(message ?? "配置未完成，请重试。")
        }
        return try JSONDecoder().decode(HookInstallation.self, from: result.output)
    }

    private func findPython() throws -> String {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .map { String($0) + "/python3" }
        let candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"] + paths + ["/usr/bin/python3"]
        var checked = Set<String>()
        for candidate in candidates where checked.insert(candidate).inserted && FileManager.default.isExecutableFile(atPath: candidate) {
            // Apple's Python launcher can request developer tools when none are
            // installed. A background setup must never open that installer.
            if candidate == "/usr/bin/python3",
               (try? Self.run("/usr/bin/xcode-select", arguments: ["-p"], timeout: 3).status) != 0 { continue }
            let probe = try? Self.run(candidate, arguments: ["-E", "-s", "-c", "import sys, sqlite3; sys.exit(0 if sys.version_info >= (3, 9) else 1)"], timeout: 3)
            if probe?.status == 0 { return candidate }
        }
        throw HookInstallationError.pythonRequired
    }

    private static func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            throw HookInstallationError.failed("配置超时，请重试。")
        }
        return (process.terminationStatus, output.fileHandleForReading.readDataToEndOfFile())
    }
}

@MainActor
final class HookConnection: ObservableObject {
    enum State: Equatable {
        case idle, configuring, configured, receiving, pythonRequired, unavailable
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var installation: HookInstallation?
    let agent: HookAgent
    private let installer: HookInstaller
    private let installationID: String
    private var task: Task<Void, Never>?
    private var receivedEventAt: Date?

    private struct Receipt: Codable {
        enum Outcome: Codable {
            case pending, pythonRequired, unavailable
            case installed(HookInstallation)
            case failed(String)
        }
        var schemaVersion = 1
        let installationID: String
        let home: String
        let outcome: Outcome

        // Receipts written before Claude Code support name the home after Codex.
        private enum CodingKeys: String, CodingKey {
            case schemaVersion, installationID, outcome
            case home = "codexHome"
        }
    }

    nonisolated static func installationIdentifier(for bundle: Bundle = .main) -> String {
        let executable = bundle.executableURL ?? bundle.bundleURL
        let attributes = (try? FileManager.default.attributesOfItem(atPath: executable.path)) ?? [:]
        let device = (attributes[.systemNumber] as? NSNumber)?.stringValue ?? ""
        let file = (attributes[.systemFileNumber] as? NSNumber)?.stringValue ?? ""
        let created = (attributes[.creationDate] as? Date)?.timeIntervalSince1970.bitPattern ?? 0
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return "\(bundle.bundleIdentifier ?? "CodexSignal")|\(version)|\(build)|\(device)|\(file)|\(created)"
    }

    init(agent: HookAgent = .codex, dataDirectory: URL, home: URL? = nil, resources: URL? = Bundle.main.resourceURL,
         installationID: String = HookConnection.installationIdentifier()) {
        self.agent = agent
        installer = HookInstaller(agent: agent, resources: resources, home: home ?? agent.defaultHome(), dataDirectory: dataDirectory)
        self.installationID = installationID
    }

    var status: String {
        switch state {
        case .idle: return "尚未配置"
        case .configuring: return "正在配置…"
        case .configured: return "已配置 · 等待事件"
        case .receiving: return "已接收事件"
        case .pythonRequired: return "需要 Python 3"
        case .unavailable: return "未检测到"
        case .failed: return "配置失败"
        }
    }

    var isConfiguring: Bool { state == .configuring }
    var needsReview: Bool { state == .configured && agent.needsTrustReview }

    func configureAfterInstallation() {
        guard task == nil else { return }
        do {
            let receipt: Receipt?
            do {
                receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: receiptURL))
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                receipt = nil
            }
            if let receipt {
                guard receipt.schemaVersion == 1 else { throw CocoaError(.fileReadCorruptFile) }
                if receipt.installationID == installationID, receipt.home == installer.home.standardizedFileURL.path {
                    restore(receipt.outcome)
                    return
                }
            }
            // Never create a configuration directory for an agent the user has not run.
            guard agent == .codex || FileManager.default.fileExists(atPath: installer.home.path) else {
                try saveReceipt(.unavailable)
                state = .unavailable
                return
            }
            beginConfiguration(force: false)
        } catch {
            state = .failed("无法读取接入记录，请重试。")
        }
    }

    func configure() { beginConfiguration(force: true) }

    private var receiptURL: URL { installer.dataDirectory.appendingPathComponent(agent.receiptName) }

    private func saveReceipt(_ outcome: Receipt.Outcome) throws {
        let receipt = Receipt(installationID: installationID, home: installer.home.standardizedFileURL.path, outcome: outcome)
        try FileManager.default.createDirectory(at: installer.dataDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(receipt).write(to: receiptURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptURL.path)
    }

    private func restore(_ outcome: Receipt.Outcome) {
        switch outcome {
        case .pending: state = .failed("上次配置未完成，请重试。")
        case .installed(let installation):
            self.installation = installation
            state = .configured
        case .pythonRequired: state = .pythonRequired
        case .unavailable: state = .unavailable
        case .failed(let message): state = .failed(message)
        }
    }

    private func beginConfiguration(force: Bool) {
        guard task == nil else { return }
        do {
            // Record the attempt before running the installer. Failed or
            // interrupted attempts require a user retry, never a startup loop.
            try saveReceipt(.pending)
        } catch {
            state = .failed("无法保存接入记录，请重试。")
            return
        }
        let startedAt = Date()
        let wasReceiving = state == .receiving
        state = .configuring
        let installer = installer
        task = Task { [weak self] in
            let result = await Task.detached { Result { try installer.install(force: force) } }.value
            guard let self else { return }
            let outcome: Receipt.Outcome
            switch result {
            case .success(let installation):
                self.installation = installation
                let receivedDuringSetup = self.receivedEventAt.map { $0 >= startedAt } ?? false
                self.state = receivedDuringSetup || (!installation.changed && wasReceiving) ? .receiving : .configured
                outcome = .installed(installation)
            case .failure(HookInstallationError.pythonRequired):
                self.state = .pythonRequired
                outcome = .pythonRequired
            case .failure(let error):
                self.state = .failed(error.localizedDescription)
                outcome = .failed(error.localizedDescription)
            }
            do {
                try self.saveReceipt(outcome)
            } catch {
                self.state = .failed("无法保存接入结果，请重试。")
            }
            self.task = nil
        }
    }

    func receivedEvent() {
        receivedEventAt = Date()
        if state == .idle || state == .configured || state == .unavailable { state = .receiving }
    }
}
