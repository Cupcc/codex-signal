import Testing
import AppKit
import Foundation
import SignalCore
@testable import SignalApp

struct SessionNavigatorTests {
    private let threadID = "019a3f6e-1b2c-7d4e-8f90-123456789abc"

    private func session(_ source: SessionSource = .desktop) -> SignalSession {
        SignalSession(source: source, sessionId: threadID, turnId: "turn", project: "App",
                      phase: .running, updatedAt: 100)
    }

    @Test func testDesktopAndUnknownOpenExactThread() {
        for source in [SessionSource.desktop, .unknown] {
            #expect(SessionNavigator.plan(for: session(source)).target == .codexThread(URL(string: "codex://threads/\(threadID)")!))
        }
    }

    @Test func testResolvedSharedCLIUsesCLIActionWhileUnknownKeepsDesktopFallback() {
        var store = SessionStore()
        store.apply(SignalEvent(eventId: "e", source: .unknown, sessionId: threadID, turnId: "t", project: "App", kind: .completed, occurredAt: 100))
        #expect(SessionNavigator.plan(for: store.sessions[0]).target == .codexThread(URL(string: "codex://threads/\(threadID)")!))
        store.resolveUnknownSources([threadID: .cli])
        #expect(SessionNavigator.plan(for: store.sessions[0]).target == .terminalSession)
    }

    @Test func testRejectsRouteInjectionAndNonUUIDIDs() {
        for id in ["threads/new", threadID + "?prompt=test", threadID + "/wake", "demo-api", ""] {
            #expect(SessionNavigator.threadURL(sessionID: id) == nil)
        }
    }

    @Test func testCLIUsesExactSupportedTTYBeforeRecovery() {
        var value = session(.cli)
        value.terminalBundleID = "com.apple.Terminal"
        value.terminalTTY = "ttys009"
        #expect(SessionNavigator.plan(for: value).target == .terminal(bundleID: "com.apple.Terminal", tty: "/dev/ttys009"))
        value.terminalBundleID = "com.googlecode.iterm2"
        #expect(SessionNavigator.plan(for: value).target == .terminal(bundleID: "com.googlecode.iterm2", tty: "/dev/ttys009"))
    }

    @Test func testCLIWithoutCapturedTTYStillOffersTabNavigation() {
        var value = session(.cli)
        value.terminalBundleID = "com.github.wez.wezterm"
        value.terminalTTY = "/dev/ttys009"
        #expect(SessionNavigator.plan(for: value).target == .terminalSession)
        value.terminalBundleID = "com.apple.Terminal"
        value.terminalTTY = "/dev/ttys009\" & do shell script \"bad"
        #expect(SessionNavigator.plan(for: value).target == .terminalSession)
    }

    @Test func testTerminalSelectionUsesSourceAndNeverDefaultsToGhostty() {
        var value = session(.cli)
        let running = Set(SessionNavigator.scriptableTerminals)
        #expect(SessionNavigator.candidateTerminals(for: value, running: running) == SessionNavigator.scriptableTerminals)
        for bundle in running {
            value.terminalBundleID = bundle
            #expect(SessionNavigator.candidateTerminals(for: value, running: running) == [bundle])
            #expect(SessionNavigator.candidateTerminals(for: value, running: []).isEmpty)
            #expect(SessionNavigator.plan(for: value).actionTitle == "打开会话")
        }
        value.terminalBundleID = "com.github.wez.wezterm"
        #expect(SessionNavigator.candidateTerminals(for: value, running: running).isEmpty)
    }

    @Test func testDiscoveryFindsAnySupportedTerminalAndRejectsCrossAppDuplicates() async {
        let bundles = SessionNavigator.scriptableTerminals
        for expected in bundles {
            let result = await SessionNavigator.findTerminal(in: bundles) { bundle in
                bundle == expected ? .matches(["/dev/ttys009"]) : .notFound
            }
            #expect(result == .target(bundleID: expected, tty: "/dev/ttys009"))
        }
        let duplicate = await SessionNavigator.findTerminal(in: bundles) { _ in .matches(["/dev/ttys009"]) }
        #expect(duplicate == .failure(.ambiguous))
        let missing = await SessionNavigator.findTerminal(in: bundles) { _ in .notFound }
        #expect(missing == .failure(.notFound))
        let denied = await SessionNavigator.findTerminal(in: bundles) { _ in .denied }
        #expect(denied == .failure(.denied))
    }

    @Test func preferredTerminalMatchSkipsOtherApplications() async {
        var queried: [String] = []
        let result = await SessionNavigator.findTerminal(in: SessionNavigator.scriptableTerminals, preferred: .ghostty) { bundle in
            queried.append(bundle)
            return .matches(["/dev/ttys009"])
        }
        #expect(result == .target(bundleID: TerminalPreference.ghostty.rawValue, tty: "/dev/ttys009"))
        #expect(queried == [TerminalPreference.ghostty.rawValue])
    }

    @Test func preferredTerminalMissFallsBackWithoutQueryingItTwice() async {
        var queried: [String] = []
        let result = await SessionNavigator.findTerminal(in: SessionNavigator.scriptableTerminals, preferred: .ghostty) { bundle in
            queried.append(bundle)
            return bundle == TerminalPreference.iTerm2.rawValue ? .matches(["/dev/ttys004"]) : .notFound
        }
        #expect(result == .target(bundleID: TerminalPreference.iTerm2.rawValue, tty: "/dev/ttys004"))
        #expect(queried == [TerminalPreference.ghostty.rawValue, TerminalPreference.terminal.rawValue, TerminalPreference.iTerm2.rawValue])
        let absent = await SessionNavigator.findTerminal(in: [TerminalPreference.terminal.rawValue], preferred: .ghostty) { _ in
            .matches(["/dev/ttys003"])
        }
        #expect(absent == .target(bundleID: TerminalPreference.terminal.rawValue, tty: "/dev/ttys003"))
    }

    @Test func preferredTerminalKeepsAmbiguityAndPermissionFailuresVisible() async {
        for failure in [SessionNavigator.ScriptResult.matches(["/dev/ttys001", "/dev/ttys002"]), .denied] {
            var queried: [String] = []
            let result = await SessionNavigator.findTerminal(in: SessionNavigator.scriptableTerminals, preferred: .iTerm2) { bundle in
                queried.append(bundle)
                return failure
            }
            #expect(result == .failure(failure == .denied ? .denied : .ambiguous))
            #expect(queried == [TerminalPreference.iTerm2.rawValue])
        }
    }

    @Test func knownSourceTakesPrecedenceOverPreference() async {
        var value = session(.cli)
        value.terminalBundleID = TerminalPreference.terminal.rawValue
        let bundles = SessionNavigator.candidateTerminals(for: value, running: Set(SessionNavigator.scriptableTerminals))
        var queried: [String] = []
        let result = await SessionNavigator.findTerminal(in: bundles, preferred: .ghostty) { bundle in
            queried.append(bundle)
            return .matches(["/dev/ttys001"])
        }
        #expect(result == .target(bundleID: TerminalPreference.terminal.rawValue, tty: "/dev/ttys001"))
        #expect(queried == [TerminalPreference.terminal.rawValue])
    }

    @Test func testEachTerminalLookupIsReadOnlyAndReturnsValidatedTTYs() throws {
        for bundle in SessionNavigator.scriptableTerminals {
            let script = try #require(SessionNavigator.terminalLookupScript(bundleID: bundle, titles: ["会话标题"], liveTTYs: ["ttys009"]))
            #expect(script.contains("tell application id \"\(bundle)\""))
            #expect(!script.contains("activate"))
            #expect(!script.contains("focus"))
            #expect(!script.contains("contents of"))
            #expect(script.contains(bundle == "com.apple.Terminal" ? "custom title of candidateTerminal" : "name of candidateTerminal"))
        }
        #expect(SessionNavigator.scriptResult(text: "/dev/ttys001\n/dev/ttys002") == .matches(["/dev/ttys001", "/dev/ttys002"]))
        #expect(SessionNavigator.scriptResult(text: "/dev/ttys001\ninvalid") == .failed)
        #expect(SessionNavigator.terminalLookupScript(bundleID: "unsupported", titles: ["title"], liveTTYs: ["ttys009"]) == nil)
    }

    @Test func testGhosttyUsesTTYDespiteDuplicateOrChangedTitles() {
        var value = session(.cli)
        value.terminalBundleID = "com.mitchellh.ghostty"
        value.terminalTTY = "/dev/ttys009"
        value.title = "同一个任务名称"
        let plan = SessionNavigator.plan(for: value)
        #expect(plan.target == .terminal(bundleID: "com.mitchellh.ghostty", tty: "/dev/ttys009"))
        #expect(plan.actionTitle == "打开会话")
        value.title = "重命名后的会话"
        #expect(SessionNavigator.plan(for: value).target == plan.target)
        value.terminalTTY = nil
        #expect(SessionNavigator.plan(for: value).target == .terminalSession)
    }

    @Test func testSharedGhosttyMatchesWholeTitleAndLiveCodexTTYBeforeFocusing() throws {
        var value = session(.cli)
        value.title = "修复 API 登录"
        let titles = SessionNavigator.terminalTitles(for: value)
        #expect(titles.contains("修复 API 登录 | App"))
        #expect(titles.contains("修复 API 登录"))
        #expect(titles.contains("⠋ 修复 API 登录"))
        #expect(titles.contains("⠋ 修复 API 登录 | App"))
        #expect(titles.contains("[ ! ] Action Required | 修复 API 登录 | App"))
        #expect(!titles.contains("App"))
        #expect(!titles.contains("修复 API"))
        let script = try #require(SessionNavigator.terminalLookupScript(bundleID: "com.mitchellh.ghostty", titles: titles, liveTTYs: ["ttys002"]))
        #expect(script.contains("terminalTTY is in allowedTTYs and terminalName is in allowedNames"))
        #expect(script.contains("return candidates as text"))
        #expect(!script.contains("focus"))
        #expect(!script.contains("activate"))
        #expect(SessionNavigator.terminalLookupScript(bundleID: "com.mitchellh.ghostty", titles: titles, liveTTYs: []) == nil)
        #expect(SessionNavigator.terminalLookupScript(bundleID: "com.mitchellh.ghostty", titles: ["bad\nname"], liveTTYs: ["ttys002"]) == nil)
    }

    @Test func testGhosttyTitleEscapingAndTruncationKeepMatchingBounded() {
        var value = session(.cli)
        value.title = String(repeating: "界", count: 49)
        #expect(SessionNavigator.terminalTitles(for: value).contains(String(repeating: "界", count: 45) + "... | App"))
        #expect(SessionNavigator.appleScriptString("a\"b\\c") == "\"a\\\"b\\\\c\"")
        value.title = nil
        #expect(SessionNavigator.terminalTitles(for: value).isEmpty)
    }

    @Test func testInstalledTerminalScriptsCompileWithoutRunningThem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for bundle in SessionNavigator.scriptableTerminals {
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) != nil else { continue }
            let lookup = try #require(SessionNavigator.terminalLookupScript(bundleID: bundle, titles: ["引号 \" 与 \\ | App"], liveTTYs: ["ttys002"]))
            let focus = try #require(SessionNavigator.terminalScript(bundleID: bundle, tty: "/dev/ttys002"))
            let recovery = try #require(SessionRecovery.script(bundleID: bundle, command: "codex resume '\(threadID)'"))
            for script in [lookup, focus, recovery] {
                let source = root.appendingPathComponent("script.applescript")
                try script.write(to: source, atomically: true, encoding: .utf8)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
                process.arguments = ["-o", root.appendingPathComponent("script.scpt").path, source.path]
                try process.run()
                process.waitUntilExit()
                #expect(process.terminationStatus == 0)
            }
        }
    }

    @Test func testGhosttyTargetsAllSurfacesAndRejectsAmbiguityBeforeFocus() throws {
        let script = try #require(SessionNavigator.terminalScript(bundleID: "com.mitchellh.ghostty", tty: "ttys009"))
        #expect(script.contains("repeat with t in terminals"))
        #expect(script.contains("tty of t"))
        #expect(script.contains("if (count of candidates) > 1 then return \"ambiguous\""))
        #expect(script.contains("focus targetTerminal"))
        #expect(!script.contains("activate"))
        #expect(!script.contains("name of"))
        #expect(!script.contains("input text"))
        #expect(SessionNavigator.terminalScript(bundleID: "com.mitchellh.ghostty", tty: "ttys009\n") == nil)
    }

    @Test func testResumeCommandQuotesDirectoryWithoutEvaluation() {
        var value = session(.cli)
        value.cwd = "/tmp/a'b $HOME `echo nope`"
        #expect(SessionNavigator.resumeCommand(for: value) == "cd -- '/tmp/a'\"'\"'b $HOME `echo nope`' && codex resume '\(threadID)'")
        value.cwd = "/tmp/line\nbreak"
        #expect(SessionNavigator.resumeCommand(for: value) == "codex resume '\(threadID)'")
    }

    @Test func recoveryUsesPreferredThenSourceThenAvailableTerminal() {
        var value = session(.cli)
        value.terminalBundleID = TerminalPreference.ghostty.rawValue
        let installed = Set(SessionNavigator.scriptableTerminals)
        #expect(SessionRecovery.terminal(for: value, preferred: .iTerm2, installed: installed,
                                        running: [], frontmost: nil) == TerminalPreference.iTerm2.rawValue)
        #expect(SessionRecovery.terminal(for: value, preferred: .automatic, installed: installed,
                                        running: [], frontmost: nil) == TerminalPreference.ghostty.rawValue)
        value.terminalBundleID = "unsupported"
        #expect(SessionRecovery.terminal(for: value, preferred: .iTerm2, installed: [TerminalPreference.terminal.rawValue],
                                        running: [], frontmost: nil) == TerminalPreference.terminal.rawValue)
        value.terminalBundleID = nil
        #expect(SessionRecovery.terminal(for: value, preferred: .automatic, installed: installed,
                                        running: [TerminalPreference.ghostty.rawValue], frontmost: nil) == TerminalPreference.ghostty.rawValue)
        #expect(SessionRecovery.terminal(for: value, preferred: .automatic, installed: [],
                                        running: [], frontmost: nil) == nil)
    }

    @Test func recoveryRejectsInputThatCouldExecuteBeforeReturn() throws {
        for bundle in SessionNavigator.scriptableTerminals {
            for command in ["", "codex resume '\(threadID)'\n", "echo bad\r", "echo bad\u{1b}", "echo bad\t"] {
                #expect(SessionRecovery.script(bundleID: bundle, command: command) == nil)
            }
            var value = session(.cli)
            value.cwd = "/tmp/路径 '\" \\n $HOME `echo nope`"
            let command = try #require(SessionNavigator.resumeCommand(for: value))
            let script = try #require(SessionRecovery.script(bundleID: bundle, command: command))
            #expect(script.contains(SessionNavigator.appleScriptString(command)))
            #expect(!script.contains("do script"))
            #expect(!script.contains("send key \"enter\""))
            #expect(!script.contains("key code 36"))
            #expect(!script.contains("keystroke return"))
            if bundle == TerminalPreference.iTerm2.rawValue { #expect(script.contains("newline NO")) }
        }
        #expect(SessionRecovery.script(bundleID: "unsupported", command: "echo hello") == nil)
    }

    @Test func testTTYScriptRejectsUntrustedValuesAndUnsupportedApplications() {
        #expect(SessionNavigator.normalizedTTY("ttys001\n") == nil)
        #expect(SessionNavigator.terminalScript(bundleID: "com.apple.Terminal", tty: "/dev/../etc/passwd") == nil)
        #expect(SessionNavigator.terminalScript(bundleID: "bad\"", tty: "ttys001") == nil)
        let script = SessionNavigator.terminalScript(bundleID: "com.apple.Terminal", tty: "ttys001")!
        #expect(script.contains("tty of t is \"/dev/ttys001\""))
        #expect(script.contains("return \"matched\""))
        #expect(!(script.contains("do script")))
        #expect(!(script.contains("do shell script")))
    }

    @Test func claudeReturnsToItsTabOrResumesInANewOne() {
        var value = session(.claude)
        value.terminalBundleID = TerminalPreference.ghostty.rawValue
        value.terminalTTY = "/dev/ttys013"
        #expect(SessionNavigator.plan(for: value).target == .terminal(bundleID: "com.mitchellh.ghostty", tty: "/dev/ttys013"))
        // Claude Code's tab titles come from the conversation, so never fall back to title matching.
        value.terminalTTY = nil
        #expect(SessionNavigator.plan(for: value).target == .recover)
        value.terminalBundleID = "com.microsoft.VSCode"
        value.terminalTTY = "/dev/ttys013"
        #expect(SessionNavigator.plan(for: value).target == .recover)
        value.cwd = "/tmp/a'b"
        #expect(SessionNavigator.resumeCommand(for: value) == "cd -- '/tmp/a'\"'\"'b' && claude --resume '\(threadID)'")
    }
}
