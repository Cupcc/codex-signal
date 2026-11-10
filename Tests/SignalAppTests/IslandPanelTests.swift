import AppKit
import Foundation
import Testing
@testable import SignalApp

@Suite(.serialized)
@MainActor
struct IslandPanelTests {
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
