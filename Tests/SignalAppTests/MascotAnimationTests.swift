import AppKit
import QuartzCore
import SignalCore
import Testing
@testable import SignalApp

@MainActor
struct MascotAnimationTests {
    @Test func hostingWithAnEmptyVisibleRectStillPlaysAndPausePreservesTime() {
        _ = NSApplication.shared
        // No visible UI: model the occlusion notification from a visible panel.
        let window = VisibleMascotWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        let view = MascotAnimationView()
        defer { view.stopObserving(); window.contentView = nil }
        window.contentView = view
        view.configure(state: "working", mini: false, active: true, reduced: false)
        #expect(view.visibleRect.isEmpty)
        #expect(view.canvas.speed == 1)
        view.configure(state: "working", mini: false, active: false, reduced: false)
        let now = CACurrentMediaTime()
        #expect(view.canvas.speed == 0)
        #expect(view.canvas.convertTime(now, from: nil) == view.canvas.convertTime(now + 3, from: nil))
        let pausedTime = view.canvas.timeOffset
        view.configure(state: "working", mini: false, active: true, reduced: false)
        #expect(view.canvas.speed == 1)
        #expect(abs(view.canvas.convertTime(CACurrentMediaTime(), from: nil) - pausedTime) < 0.1)
    }

    @Test(arguments: [MascotSkin.companion, .crab])
    func everyPoseAndSizeLoadsCompleteLayeredArtwork(skin: MascotSkin) throws {
        for mini in [false, true] {
            for state in ["working", "idle", "attention", "question", "error", "ready"] {
                let view = MascotAnimationView()
                defer { view.stopObserving() }
                view.configure(state: state, skin: skin, mini: mini, active: true, reduced: true)
                for part in ["ground", "eyes", "left", "right", "badge"] {
                    #expect(view.parts[part]?.contents != nil, "Missing \(skin) / \(state) / \(mini) / \(part)")
                }
                #expect(view.parts["body"]?.sublayers?.first?.contents != nil)
                if state == "idle" { #expect(view.parts["open"]?.contents != nil) }
                #expect(view.parts.values.allSatisfy { ($0.animationKeys() ?? []).isEmpty })
            }
        }
    }

    @Test func claudeCodeSessionsUseTheCrab() {
        #expect(MascotSkin(.claude) == .crab)
        for source in [SessionSource.cli, .desktop, .unknown, nil] { #expect(MascotSkin(source) == .companion) }
        let companion = MascotAnimationView(), crab = MascotAnimationView()
        defer { companion.stopObserving(); crab.stopObserving() }
        companion.configure(state: "attention", mini: false, active: true, reduced: true)
        crab.configure(state: "attention", skin: .crab, mini: false, active: true, reduced: true)
        let lhs = companion.parts["right"]?.contents as AnyObject?, rhs = crab.parts["right"]?.contents as AnyObject?
        #expect(lhs != nil && rhs != nil && lhs !== rhs)
        // Switching skin with the same pose rebuilds the artwork.
        crab.configure(state: "attention", skin: .companion, mini: false, active: true, reduced: true)
        #expect(crab.parts["right"]?.contents as AnyObject? === lhs)
    }

    @Test func stateChangesReplaceLoopsAndDoNotReplayOnOrdinaryUpdates() throws {
        let view = MascotAnimationView()
        defer { view.stopObserving() }
        view.configure(state: "working", mini: false, active: true, reduced: false)
        #expect(view.parts["left"]?.animationKeys()?.isEmpty == false)
        view.configure(state: "attention", mini: false, active: true, reduced: false)
        #expect(view.parts["left"]?.animationKeys() == nil)
        let initial = try #require(view.parts["right"]?.animation(forKey: "transform.rotation.z"))
        #expect(initial.repeatCount == 0)
        view.configure(state: "attention", mini: false, active: false, reduced: false)
        view.configure(state: "attention", mini: false, active: true, reduced: false)
        let current = try #require(view.parts["right"]?.animation(forKey: "transform.rotation.z"))
        #expect(initial.beginTime == current.beginTime)
        #expect(view.canvas.speed == 0, "Detached/hidden views must not advance")
    }

    @Test func reducedMotionCancelsAnimationWithoutReplayingAnOldAlert() {
        let view = MascotAnimationView()
        defer { view.stopObserving() }
        view.configure(state: "question", mini: false, active: true, reduced: false)
        view.configure(state: "question", mini: false, active: true, reduced: true)
        #expect(view.parts.values.allSatisfy { ($0.animationKeys() ?? []).isEmpty })
        view.configure(state: "question", mini: false, active: true, reduced: false)
        #expect(view.parts.values.allSatisfy { ($0.animationKeys() ?? []).isEmpty })
        view.configure(state: "working", mini: false, active: true, reduced: false)
        #expect(view.parts["eyes"]?.animation(forKey: "transform.scale.y")?.repeatCount == .infinity)
    }

    @Test func alertsSettleAndOnlyWorkingAndIdleLoop() {
        for state in ["attention", "question", "error", "ready"] {
            let tracks = MascotAnimation.tracks(for: state)
            #expect(!tracks.isEmpty)
            #expect(tracks.allSatisfy { !$0.loops && $0.duration <= 1.2 })
            #expect(MascotAnimation.tracks(for: state, entrance: false).isEmpty)
            for track in tracks {
                #expect(track.values.last == (track.keyPath == "transform.scale" ? 1 : 0))
            }
        }
        for state in ["working", "idle"] {
            #expect(MascotAnimation.tracks(for: state, entrance: false).allSatisfy { $0.loops })
        }
    }
}

private final class VisibleMascotWindow: NSWindow {
    override var occlusionState: NSWindow.OcclusionState { .visible }
}
