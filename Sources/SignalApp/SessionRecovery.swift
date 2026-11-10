import AppKit
import SignalCore

enum SessionRecovery {
    @MainActor
    static func open(_ session: SignalSession, preferredTerminal: TerminalPreference, reason: String) async -> SessionNavigationResult {
        guard let command = SessionNavigator.resumeCommand(for: session) else {
            return .init(message: "\(reason)；无法生成恢复命令", didNavigate: false, isFailure: true)
        }
        let workspace = NSWorkspace.shared
        let installed = Set(SessionNavigator.scriptableTerminals.filter {
            workspace.urlForApplication(withBundleIdentifier: $0) != nil
        })
        let running = Set(workspace.runningApplications.compactMap(\.bundleIdentifier))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        guard let bundle = terminal(for: session, preferred: preferredTerminal, installed: installed,
                                    running: running, frontmost: workspace.frontmostApplication?.bundleIdentifier),
              let script = script(bundleID: bundle, command: command) else {
            return .init(message: "未找到可用终端；已复制恢复命令", didNavigate: false, isFailure: true)
        }
        let result = await SessionNavigator.runScript(script)
        if result == .matched {
            return .init(message: "已填入恢复命令，按回车继续", didNavigate: true)
        }
        let failure = result == .denied ? "请允许自动化与辅助功能访问后重试" : "未能填入新标签页"
        return .init(message: "\(failure)；已复制恢复命令，可手动粘贴", didNavigate: false, isFailure: true)
    }

    static func terminal(for session: SignalSession, preferred: TerminalPreference, installed: Set<String>,
                         running: Set<String>, frontmost: String?) -> String? {
        let candidates = [preferred.bundleID, session.terminalBundleID, frontmost].compactMap { $0 }
            + SessionNavigator.scriptableTerminals.filter(running.contains)
            + SessionNavigator.scriptableTerminals
        return candidates.first { installed.contains($0) && SessionNavigator.scriptableTerminals.contains($0) }
    }

    static func script(bundleID: String, command: String) -> String? {
        guard SessionNavigator.scriptableTerminals.contains(bundleID), !command.isEmpty,
              !command.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        let text = SessionNavigator.appleScriptString(command)
        let body: String
        switch bundleID {
        case SessionNavigator.ghosttyBundleID:
            body = """
            tell application id "com.mitchellh.ghostty"
                if (count of windows) is 0 then
                    set targetWindow to new window
                    set targetTab to selected tab of targetWindow
                else
                    set targetTab to new tab in front window
                end if
                select tab targetTab
                set targetTerminal to focused terminal of targetTab
                repeat 40 times
                    if tty of targetTerminal is not "" then exit repeat
                    delay 0.05
                end repeat
                if tty of targetTerminal is "" then return "not-found"
                delay 0.2
                input text \(text) to targetTerminal
                focus targetTerminal
            end tell
            """
        case TerminalPreference.iTerm2.rawValue:
            body = """
            tell application id "com.googlecode.iterm2"
                if (count of windows) is 0 then
                    set targetWindow to create window with default profile
                    set targetTab to current tab of targetWindow
                else
                    set targetWindow to current window
                    tell targetWindow to set targetTab to create tab with default profile
                end if
                set targetSession to current session of targetTab
                delay 0.2
                tell targetSession to write text \(text) newline NO
                select targetWindow
                select targetTab
                select targetSession
                activate
            end tell
            """
        default:
            // Terminal has no native command for a new tab or input without Return.
            // Verify a new TTY and foreground focus before sending Paste.
            body = """
            tell application id "com.apple.Terminal"
                activate
                set oldTTYs to {}
                repeat with w in windows
                    repeat with t in tabs of w
                        set end of oldTTYs to tty of t
                    end repeat
                end repeat
                set hasWindow to (count of windows) > 0
                if hasWindow then set miniaturized of front window to false
            end tell
            tell application "System Events"
                tell first application process whose bundle identifier is "com.apple.Terminal"
                    if not frontmost then return "not-found"
                    if hasWindow then
                        keystroke "t" using command down
                    else
                        keystroke "n" using command down
                    end if
                end tell
            end tell
            set newTTY to ""
            repeat 40 times
                tell application id "com.apple.Terminal"
                    if (count of windows) > 0 then
                        set candidateTTY to tty of selected tab of front window
                        if candidateTTY is not "" and candidateTTY is not in oldTTYs then
                            set newTTY to candidateTTY
                            exit repeat
                        end if
                    end if
                end tell
                delay 0.05
            end repeat
            if newTTY is "" then return "not-found"
            delay 0.2
            tell application id "com.apple.Terminal"
                if tty of selected tab of front window is not newTTY then return "not-found"
            end tell
            if (the clipboard as text) is not \(text) then return "not-found"
            tell application "System Events"
                tell first application process whose bundle identifier is "com.apple.Terminal"
                    if not frontmost then return "not-found"
                    keystroke "v" using command down
                end tell
            end tell
            """
        }
        return "with timeout of 3 seconds\n\(body)\nreturn \"matched\"\nend timeout"
    }
}
