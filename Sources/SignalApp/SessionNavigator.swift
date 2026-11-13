import AppKit
import SignalCore

struct SessionNavigationPlan: Equatable {
    enum Target: Equatable {
        case codexThread(URL)
        case terminal(bundleID: String, tty: String)
        case terminalSession
        /// No original tab to find; resume the session in a new terminal tab.
        case recover
        case copyResume(String)
        case copyID(String)
    }

    let target: Target
    let actionTitle: String
    let actionSymbol: String
    let detail: String
}

struct SessionNavigationResult {
    let message: String
    let didNavigate: Bool
    var isFailure = false
}

/// Prefer stable terminal identifiers. Shared-service sessions additionally
/// support a unique complete title match among live Codex TTYs; never match a project alone.
/// Deep-link routing and exact Terminal/iTerm TTY selection were compared with
/// CodeIsland's TerminalActivator. Recovery fills a new tab without executing the command.
enum SessionNavigator {
    static let codexBundleID = "com.openai.codex"
    static let ghosttyBundleID = "com.mitchellh.ghostty"
    static let scriptableTerminals = TerminalPreference.allCases.compactMap(\.bundleID)

    static func threadURL(sessionID: String) -> URL? {
        guard UUID(uuidString: sessionID) != nil else { return nil }
        return URL(string: "codex://threads/\(sessionID)")
    }

    static func normalizedTTY(_ value: String?) -> String? {
        guard let value else { return nil }
        let path = value.hasPrefix("/dev/") ? value : "/dev/" + value
        // No quotes, control characters, paths or shell/AppleScript syntax may enter a script.
        guard path.range(of: #"\A/dev/tty[a-zA-Z0-9]+\z"#, options: .regularExpression) != nil else { return nil }
        return path
    }

    static func plan(for session: SignalSession) -> SessionNavigationPlan {
        if session.source.isTerminalClient {
            if let bundle = session.terminalBundleID, scriptableTerminals.contains(bundle),
               let tty = normalizedTTY(session.terminalTTY) {
                return .init(target: .terminal(bundleID: bundle, tty: tty),
                             actionTitle: "打开会话", actionSymbol: "arrow.up.right", detail: "返回原来的标签页")
            }
            // Title matching relies on Codex's tab titles; Claude Code titles tabs from the conversation.
            if session.source == .claude {
                return .init(target: .recover, actionTitle: "打开会话",
                             actionSymbol: "arrow.up.right", detail: "在新标签页恢复会话")
            }
            return .init(target: .terminalSession, actionTitle: "打开会话",
                         actionSymbol: "arrow.up.right", detail: "返回原来的标签页")
        } else if let url = threadURL(sessionID: session.sessionId) {
            return .init(target: .codexThread(url), actionTitle: "打开会话",
                         actionSymbol: "arrow.up.right", detail: "")
        }
        return .init(target: .copyID(session.sessionId), actionTitle: "复制会话标识",
                     actionSymbol: "doc.on.doc", detail: "")
    }

    static func resumeCommand(for session: SignalSession) -> String? {
        guard UUID(uuidString: session.sessionId) != nil else { return nil }
        let id = shellQuote(session.sessionId)
        let command = session.source == .claude ? "claude --resume \(id)" : "codex resume \(id)"
        guard let cwd = session.cwd, cwd.hasPrefix("/"),
              !cwd.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return command }
        return "cd -- \(shellQuote(cwd)) && \(command)"
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    @MainActor
    static func open(_ session: SignalSession, peers: [SignalSession] = [], preferredTerminal: TerminalPreference = .automatic) async -> SessionNavigationResult {
        let result = await openOriginal(session, peers: peers, preferredTerminal: preferredTerminal)
        guard result.isFailure else { return result }
        return await SessionRecovery.open(session, preferredTerminal: preferredTerminal, reason: result.message)
    }

    @MainActor
    private static func openOriginal(_ session: SignalSession, peers: [SignalSession], preferredTerminal: TerminalPreference) async -> SessionNavigationResult {
        switch plan(for: session).target {
        case .codexThread(let link):
            // The running copy may differ from Launch Services' default installation.
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: codexBundleID).first
            guard let appURL = running?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: codexBundleID) else {
                return .init(message: "未找到 Codex", didNavigate: false, isFailure: true)
            }
            if running?.isHidden == true { running?.unhide() }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            let accepted: Bool = await withCheckedContinuation { continuation in
                NSWorkspace.shared.open([link], withApplicationAt: appURL, configuration: configuration) { _, error in
                    continuation.resume(returning: error == nil)
                }
            }
            // URL delivery is observable; actual thread rendering belongs to the destination app.
            return accepted ? .init(message: "已打开", didNavigate: true)
                : .init(message: "无法打开 Codex 会话", didNavigate: false, isFailure: true)
        case .terminal(let bundleID, let tty):
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else {
                return .init(message: "终端已关闭", didNavigate: false, isFailure: true)
            }
            guard let script = terminalScript(bundleID: bundleID, tty: tty) else {
                return navigationResult(.failed)
            }
            return navigationResult(await runScript(script))
        case .terminalSession:
            let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            let bundles = candidateTerminals(for: session, running: running)
            guard !bundles.isEmpty else {
                let unsupported = session.terminalBundleID.map { !scriptableTerminals.contains($0) } ?? false
                return .init(message: unsupported ? "暂不支持打开此终端的标签页" : "终端未打开", didNavigate: false, isFailure: true)
            }
            let titles = terminalTitles(for: session)
            guard !titles.isEmpty else {
                return .init(message: "会话标题尚未就绪，请稍后重试", didNavigate: false, isFailure: true)
            }
            guard !peers.contains(where: { $0.sessionId != session.sessionId && !titles.isDisjoint(with: terminalTitles(for: $0)) }) else {
                return .init(message: "会话重名，请先重命名", didNavigate: false, isFailure: true)
            }
            let ttys = await liveCodexTTYs()
            guard !ttys.isEmpty else { return navigationResult(.notFound) }
            let search = await findTerminal(in: bundles, preferred: preferredTerminal) { bundle in
                guard let script = terminalLookupScript(bundleID: bundle, titles: titles, liveTTYs: ttys) else { return .failed }
                return await runScript(script)
            }
            switch search {
            case .target(let bundle, let tty):
                guard let script = terminalScript(bundleID: bundle, tty: tty) else { return navigationResult(.failed) }
                return navigationResult(await runScript(script))
            case .failure(let error): return navigationResult(error)
            }
        case .recover:
            return .init(message: "未找到原标签页", didNavigate: false, isFailure: true)
        case .copyResume(let command):
            copy(command)
            return .init(message: "已复制恢复命令", didNavigate: false)
        case .copyID(let id):
            copy(id)
            return .init(message: "已复制会话标识", didNavigate: false)
        }
    }

    /// Codex's default OSC title is activity + thread-name + project-name.
    /// The complete alternatives below account for activity only, not fuzzy substrings.
    static func terminalTitles(for session: SignalSession) -> Set<String> {
        guard let title = session.title, let title = CodexSessionIndex.normalizedTitle(title) else { return [] }
        func truncated(_ value: String, count: Int) -> String {
            value.count <= count ? value : String(value.prefix(count - 3)) + "..."
        }
        let thread = truncated(title, count: 48)
        let project = truncated(session.project, count: 24)
        let names = [thread, thread + " | " + project]
        let activities = ["", "⠋ ", "⠙ ", "⠹ ", "⠸ ", "⠼ ", "⠴ ", "⠦ ", "⠧ ", "⠇ ", "⠏ ",
                          "[ ! ] Action Required | ", "[ . ] Action Required | "]
        return Set(names.flatMap { name in activities.flatMap { [$0 + name, "● " + $0 + name] } })
    }

    static func appleScriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func candidateTerminals(for session: SignalSession, running: Set<String>) -> [String] {
        if let bundle = session.terminalBundleID {
            return scriptableTerminals.contains(bundle) && running.contains(bundle) ? [bundle] : []
        }
        return scriptableTerminals.filter(running.contains)
    }

    enum TerminalSearchResult: Equatable {
        case target(bundleID: String, tty: String)
        case failure(ScriptResult)
    }

    static func findTerminal(in bundles: [String], preferred: TerminalPreference = .automatic,
                             lookup: (String) async -> ScriptResult) async -> TerminalSearchResult {
        var remaining = bundles
        if let bundle = preferred.bundleID, remaining.contains(bundle) {
            remaining.removeAll { $0 == bundle }
            switch await lookup(bundle) {
            case .matches(let found):
                if found.count == 1 { return .target(bundleID: bundle, tty: found[0]) }
                if found.count > 1 { return .failure(.ambiguous) }
            case .notFound: break
            case let error: return .failure(error)
            }
        }
        var matches: [(bundle: String, tty: String)] = []
        // Without a preferred match, discover everywhere before focusing anything.
        for bundle in remaining {
            switch await lookup(bundle) {
            case .matches(let found): matches += found.map { (bundle, $0) }
            case .notFound: continue
            case let error: return .failure(error)
            }
        }
        guard matches.count == 1 else { return .failure(matches.isEmpty ? .notFound : .ambiguous) }
        return .target(bundleID: matches[0].bundle, tty: matches[0].tty)
    }

    /// Read-only discovery. Never activates a window while checking another app.
    static func terminalLookupScript(bundleID: String, titles: Set<String>, liveTTYs: [String]) -> String? {
        let ttys = liveTTYs.compactMap(normalizedTTY)
        guard scriptableTerminals.contains(bundleID), !titles.isEmpty, !ttys.isEmpty,
              titles.allSatisfy({ $0.utf8.count <= 2048 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else { return nil }
        let names = titles.sorted().map(appleScriptString).joined(separator: ", ")
        let devices = ttys.map(appleScriptString).joined(separator: ", ")
        let titleProperty = bundleID == "com.apple.Terminal" ? "custom title" : "name"
        let candidate = """
        set terminalTTY to tty of candidateTerminal
        set terminalName to \(titleProperty) of candidateTerminal
        considering case, diacriticals, punctuation, white space
            if terminalTTY is in allowedTTYs and terminalName is in allowedNames then
                set end of candidates to terminalTTY
            end if
        end considering
        """
        let traversal: String
        switch bundleID {
        case ghosttyBundleID:
            traversal = """
            repeat with candidateTerminal in terminals
                \(candidate)
            end repeat
            """
        case "com.apple.Terminal":
            traversal = """
            repeat with w in windows
                repeat with candidateTerminal in tabs of w
                    \(candidate)
                end repeat
            end repeat
            """
        default:
            traversal = """
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with candidateTerminal in sessions of t
                        \(candidate)
                    end repeat
                end repeat
            end repeat
            """
        }
        return """
        with timeout of 3 seconds
            set allowedNames to {\(names)}
            set allowedTTYs to {\(devices)}
            set candidates to {}
            tell application id "\(bundleID)"
                try
                    \(traversal)
                on error number -1728
                    return "unsupported"
                end try
            end tell
            if (count of candidates) is 0 then return "not-found"
            set AppleScript's text item delimiters to linefeed
            return candidates as text
        end timeout
        """
    }

    private static func liveCodexTTYs() async -> [String] {
        await Task.detached(priority: .userInitiated) {
            // Targeted process queries keep output small and never inspect command arguments or environment.
            func output(_ executable: String, _ arguments: [String]) -> String? {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                let done = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in done.signal() }
                do { try process.run() } catch { return nil }
                guard done.wait(timeout: .now() + 2) == .success else { process.terminate(); return nil }
                guard process.terminationStatus == 0 else { return nil }
                return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            }
            guard let processes = output("/usr/bin/pgrep", ["-x", "codex"]) else { return [] }
            let pids = processes.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }.prefix(128)
            guard !pids.isEmpty,
                  let ttyOutput = output("/bin/ps", ["-p", pids.map(String.init).joined(separator: ","), "-o", "tty="]) else { return [] }
            return ttyOutput.split(whereSeparator: \.isWhitespace).compactMap { normalizedTTY(String($0)) }
        }.value
    }

    @MainActor
    private static func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    /// Return true only after selecting the exact TTY. Never match by a directory or title.
    static func terminalScript(bundleID: String, tty: String) -> String? {
        guard let tty = normalizedTTY(tty), scriptableTerminals.contains(bundleID) else { return nil }
        let body: String
        if bundleID == "com.apple.Terminal" {
            body = """
            tell application id "com.apple.Terminal"
                repeat with w in windows
                    try
                        repeat with t in tabs of w
                            if tty of t is "\(tty)" then
                                set miniaturized of w to false
                                set selected tab of w to t
                                set index of w to 1
                                activate
                                return "matched"
                            end if
                        end repeat
                    end try
                end repeat
            end tell
            """
        } else if bundleID == ghosttyBundleID {
            // Ghostty 1.4 exposes a TTY on each surface, including background tabs
            // and splits. Its native focus command selects the surface and tab.
            // Do not call activate: that can summon the quick terminal instead.
            body = """
            tell application id "com.mitchellh.ghostty"
                set candidates to {}
                repeat with t in terminals
                    try
                        set terminalTTY to tty of t
                    on error number -1728
                        return "unsupported"
                    end try
                    considering case
                        if terminalTTY is "\(tty)" then set end of candidates to contents of t
                    end considering
                end repeat
                if (count of candidates) > 1 then return "ambiguous"
                if (count of candidates) is 1 then
                    set targetTerminal to item 1 of candidates
                    focus targetTerminal
                    return "matched"
                end if
            end tell
            """
        } else {
            body = """
            tell application id "com.googlecode.iterm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty)" then
                                select w
                                select t
                                select s
                                activate
                                return "matched"
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            """
        }
        return "with timeout of 3 seconds\n\(body)\nreturn \"not-found\"\nend timeout"
    }

    enum ScriptResult: Equatable {
        case matched, denied, timedOut, notFound, unsupported, ambiguous, failed
        case matches([String])
    }

    static func navigationResult(_ result: ScriptResult) -> SessionNavigationResult {
        let message: String
        switch result {
        case .matched: return .init(message: "已打开", didNavigate: true)
        case .denied: message = "请允许访问终端后重试"
        case .timedOut: message = "打开超时，请重试"
        case .notFound: message = "未找到标签页，可能已关闭"
        case .unsupported: message = "请更新终端后重试"
        case .ambiguous: message = "标签页重名，请先重命名"
        case .failed, .matches: message = "无法打开，请重试"
        }
        return .init(message: message, didNavigate: false, isFailure: true)
    }

    static func scriptResult(text: String) -> ScriptResult {
        switch text {
        case "matched": return .matched
        case "unsupported": return .unsupported
        case "ambiguous": return .ambiguous
        case "not-found": return .notFound
        default:
            let lines = text.split(separator: "\n").map(String.init)
            guard !lines.isEmpty, lines.count <= 128,
                  lines.allSatisfy({ $0.hasPrefix("/dev/") && normalizedTTY($0) == $0 }) else { return .failed }
            return .matches(lines)
        }
    }

    static func runScript(_ script: String) async -> ScriptResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]
                let output = Pipe()
                let errors = Pipe()
                process.standardOutput = output
                process.standardError = errors
                let completed = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in completed.signal() }
                do { try process.run() }
                catch { continuation.resume(returning: .failed); return }
                guard completed.wait(timeout: .now() + 5) == .success else {
                    process.terminate()
                    continuation.resume(returning: .timedOut)
                    return
                }
                let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let error = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if error.contains("-1743") || error.contains("-1719") || error.contains("(1002)") { continuation.resume(returning: .denied) }
                else if error.contains("-1712") { continuation.resume(returning: .timedOut) }
                else if process.terminationStatus != 0 { continuation.resume(returning: .failed) }
                else {
                    continuation.resume(returning: scriptResult(text: text))
                }
            }
        }
    }
}
