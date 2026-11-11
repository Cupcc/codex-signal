import AppKit
import Combine
import Foundation
import Testing
@testable import SignalApp

@Suite(.serialized)
@MainActor
struct IslandPanelTests {
    enum CollapseTrigger: CaseIterable {
        case appDeactivated, collapseButton, menuBarToggle, noticePreview, nativeDismissalThenCollapse

        @MainActor func perform(model: AppModel, island: IslandPanel, settings: NSPopover) {
            switch self {
            case .appDeactivated:
                NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
                NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
            case .collapseButton:
                model.setExpanded(false)
            case .menuBarToggle:
                island.toggle()
            case .noticePreview:
                model.previewIslandNotice()
            case .nativeDismissalThenCollapse:
                settings.close()
                model.setExpanded(false)
            }
        }
    }

    private func withPanel(_ body: (AppModel, IslandPanel, NSWindow) async throws -> Void) async throws {
        _ = NSApplication.shared
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("signal-panel-\(UUID().uuidString)")
        let model = AppModel(dataDirectory: directory, demo: true)
        model.speechEnabled = false
        let island = IslandPanel(model: model)
        let window = try #require(NSApp.windows.first {
            !existing.contains(ObjectIdentifier($0)) && $0.title == "Codex Signal 会话伙伴岛"
        })
        defer {
            window.close()
            try? FileManager.default.removeItem(at: directory)
        }
        island.refresh()
        try await body(model, island, window)
    }

    private func expectFrame(_ actual: NSRect, matches expected: NSRect) {
        #expect(abs(actual.maxY - expected.maxY) <= 0.5)
        #expect(abs(actual.midX - expected.midX) <= 0.5)
        #expect(abs(actual.width - expected.width) <= 0.5)
        #expect(abs(actual.height - expected.height) <= 0.5)
    }

    private func openSettings(model: AppModel, window: NSWindow,
                              expansionDelay: Int, settingsDelay: Int) async throws -> NSPopover {
        var shownPopover: NSPopover?
        let observer = NotificationCenter.default.addObserver(
            forName: NSPopover.willShowNotification, object: nil, queue: .main
        ) { notification in
            MainActor.assumeIsolated { shownPopover = notification.object as? NSPopover }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        model.setExpanded(true)
        try await Task.sleep(for: .milliseconds(expansionDelay))
        window.makeKey()
        model.updateSettingsRequested = true
        try await Task.sleep(for: .milliseconds(settingsDelay))
        for _ in 0..<50 {
            if shownPopover?.contentViewController?.view.window?.parent === window { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let popover = try #require(shownPopover)
        try #require(popover.contentViewController?.view.window?.parent === window)
        try #require(model.expanded)
        return popover
    }

    @Test(arguments: CollapseTrigger.allCases,
          [20, 80, 400].flatMap { expansion in [20, 80, 400].map { (expansion, $0) } })
    func collapseClosesSettingsWithoutWaiting(trigger: CollapseTrigger, delays: (Int, Int)) async throws {
        try await withPanel { model, island, window in
            island.show()
            try await Task.sleep(for: .milliseconds(100))
            let compact = window.frame
            let settings = try await openSettings(model: model, window: window,
                                                  expansionDelay: delays.0, settingsDelay: delays.1)
            let settingsWindow = try #require(settings.contentViewController?.view.window)

            var collapsedBeforeSettingsClosed = false
            let expansion = model.$expanded.dropFirst().sink { expanded in
                if !expanded, settingsWindow.parent != nil { collapsedBeforeSettingsClosed = true }
            }
            defer { expansion.cancel() }

            var frames: [NSRect] = []
            let observers = [NSWindow.didMoveNotification, NSWindow.didResizeNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
                    MainActor.assumeIsolated { frames.append(window.frame) }
                }
            }
            defer { observers.forEach(NotificationCenter.default.removeObserver) }
            trigger.perform(model: model, island: island, settings: settings)
            #expect(!model.expanded, "Collapse must start in the same event, without waiting for a second animation")
            #expect(settingsWindow.parent == nil, "Detach settings before changing the panel's presentation")
            try await Task.sleep(for: .milliseconds(1000))
            #expect(!collapsedBeforeSettingsClosed)
            #expect(!model.expanded)
            #expect(!frames.isEmpty)
            #expect(frames.allSatisfy { abs($0.maxY - compact.maxY) <= 0.5 },
                    "Top offsets: \(frames.map { $0.maxY - compact.maxY })")
            // AppKit rounds intermediate origins and widths to whole points.
            // Interrupting that animation can accumulate a one-point center offset.
            #expect(frames.allSatisfy { abs($0.midX - compact.midX) <= 1 },
                    "Center offsets: \(frames.map { $0.midX - compact.midX })")
            if trigger == .noticePreview {
                #expect(model.islandNotice != nil)
            } else {
                expectFrame(window.frame, matches: compact)
            }
        }
    }

    @Test func collapseClosesNestedHelpAndSettingsBeforePublishing() async throws {
        try await withPanel { model, island, window in
            island.show()
            try await Task.sleep(for: .milliseconds(100))
            let settings = try await openSettings(model: model, window: window, expansionDelay: 80, settingsDelay: 80)
            let settingsView = try #require(settings.contentViewController?.view)
            let settingsWindow = try #require(settingsView.window)
            let help = NSPopover()
            let content = NSViewController()
            content.view = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 80))
            help.contentViewController = content
            help.show(relativeTo: settingsView.bounds, of: settingsView, preferredEdge: .maxX)
            defer { help.close() }
            let helpWindow = try #require(content.view.window)
            try #require(helpWindow.parent === settingsWindow)
            var collapsedWithAttachedPopover = false
            let expansion = model.$expanded.dropFirst().sink { expanded in
                if !expanded, settingsWindow.parent != nil || helpWindow.parent != nil {
                    collapsedWithAttachedPopover = true
                }
            }
            defer { expansion.cancel() }

            model.setExpanded(false)
            #expect(!model.expanded)
            #expect(!collapsedWithAttachedPopover)
            #expect(settingsWindow.parent == nil)
            #expect(helpWindow.parent == nil)
            try await Task.sleep(for: .milliseconds(400))

            let reopened = try await openSettings(model: model, window: window, expansionDelay: 80, settingsDelay: 80)
            #expect(reopened.isShown)
        }
    }

    @Test func refreshAndShowRepairDisplacementWithUnchangedTarget() async throws {
        try await withPanel { _, island, window in
            let expected = window.frame
            window.setFrameOrigin(NSPoint(x: expected.minX, y: expected.minY - 400))
            #expect(abs(window.frame.maxY - expected.maxY) >= 399)
            island.refresh()
            expectFrame(window.frame, matches: expected)

            window.setFrameOrigin(NSPoint(x: expected.minX + 120, y: expected.minY - 400))
            island.show()
            expectFrame(window.frame, matches: expected)
        }
    }

    @Test func idleMoveAndResizeReturnToTopWithoutAnotherUserAction() async throws {
        try await withPanel { _, island, window in
            island.show()
            try await Task.sleep(for: .milliseconds(100))
            let expected = window.frame
            window.setFrameOrigin(NSPoint(x: expected.minX, y: expected.minY - 400))
            try await Task.sleep(for: .milliseconds(100))
            expectFrame(window.frame, matches: expected)

            window.setFrame(NSRect(x: expected.minX + 120, y: expected.minY - 200,
                                   width: expected.width + 50, height: expected.height + 100), display: true)
            try await Task.sleep(for: .milliseconds(100))
            expectFrame(window.frame, matches: expected)
        }
    }

    @Test func interruptedAnimationsFinishAtLatestCollapsedFrame() async throws {
        try await withPanel { model, island, window in
            island.show()
            try await Task.sleep(for: .milliseconds(100))
            let compact = window.frame
            for delay in [20, 80, 150] {
                model.setExpanded(true)
                try await Task.sleep(for: .milliseconds(delay))
                model.setExpanded(false)
                try await Task.sleep(for: .milliseconds(20))
            }
            try await Task.sleep(for: .milliseconds(500))
            expectFrame(window.frame, matches: compact)

            model.previewIslandNotice()
            try await Task.sleep(for: .milliseconds(80))
            model.setExpanded(true)
            try await Task.sleep(for: .milliseconds(40))
            model.setExpanded(false)
            try await Task.sleep(for: .milliseconds(500))
            expectFrame(window.frame, matches: compact)
        }
    }

    @Test func immediateRefreshDuringAnimationCannotRestoreOldDestination() async throws {
        try await withPanel { model, island, window in
            island.show()
            try await Task.sleep(for: .milliseconds(100))
            let compact = window.frame
            model.setExpanded(true)
            try await Task.sleep(for: .milliseconds(80))
            model.setExpanded(false)
            island.refresh()
            expectFrame(window.frame, matches: compact)
            try await Task.sleep(for: .milliseconds(500))
            expectFrame(window.frame, matches: compact)
        }
    }
}
