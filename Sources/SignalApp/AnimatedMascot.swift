import AppKit
import QuartzCore
import SwiftUI

/// AppKit supplies window visibility; Core Animation animates the artwork without
/// repeatedly decoding PNGs or invalidating the surrounding SwiftUI session list.
struct AnimatedMascot: NSViewRepresentable {
    var state: String
    var mini: Bool
    var active: Bool
    var reduced: Bool

    func makeNSView(context: Context) -> MascotAnimationView { MascotAnimationView() }

    func updateNSView(_ view: MascotAnimationView, context: Context) {
        view.configure(state: state, mini: mini, active: active, reduced: reduced)
    }

    static func dismantleNSView(_ view: MascotAnimationView, coordinator: ()) {
        view.stopObserving()
    }
}

@MainActor
final class MascotAnimationView: NSView {
    private static let resources: Bundle = {
        if let directory = Bundle.main.resourceURL,
           let bundle = Bundle(url: directory.appendingPathComponent("CodexSignal_SignalApp.bundle")) {
            return bundle
        }
        return .module
    }()
    private static var images: [String: CGImage] = [:]
    let canvas = CALayer()
    private(set) var parts: [String: CALayer] = [:]
    private var artwork: String?
    private var state = "idle"
    private var active = false
    private var reduced = false
    private var suspended = false
    private var observingWindow: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var accessibilityObserver: NSObjectProtocol?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        canvas.bounds = CGRect(x: 0, y: 0, width: 128, height: 128)
        canvas.anchorPoint = .zero
        layer?.addSublayer(canvas)
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspended = true; self?.syncPlayback() }
            })
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspended = false; self?.syncPlayback() }
            })
        }
        accessibilityObserver = center.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                   object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateReduction(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func stopObserving() {
        if let observingWindow { NotificationCenter.default.removeObserver(observingWindow) }
        observingWindow = nil
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { center.removeObserver($0) }
        workspaceObservers.removeAll()
        if let accessibilityObserver { center.removeObserver(accessibilityObserver) }
        accessibilityObserver = nil
        parts.values.forEach { $0.removeAllAnimations() }
    }

    deinit {
        if let observingWindow { NotificationCenter.default.removeObserver(observingWindow) }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { center.removeObserver($0) }
        if let accessibilityObserver { center.removeObserver(accessibilityObserver) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observingWindow { NotificationCenter.default.removeObserver(observingWindow) }
        observingWindow = nil
        if let window {
            observingWindow = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                                     object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncPlayback() }
            }
        }
        syncPlayback()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let scale = min(bounds.width, bounds.height) / 128
        canvas.position = CGPoint(x: (bounds.width - 128 * scale) / 2, y: (bounds.height - 128 * scale) / 2)
        canvas.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
        syncPlayback()
    }

    func configure(state: String, mini: Bool, active: Bool, reduced: Bool) {
        self.active = active
        let key = "\(mini ? "mini-" : "")\(state)"
        let reduce = reduced || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if artwork != key {
            artwork = key
            self.state = state
            self.reduced = reduce
            rebuild(key: key, mini: mini)
            if !reduce { animate() }
        } else {
            updateReduction(reduce)
        }
        syncPlayback()
    }

    private func updateReduction(_ value: Bool) {
        guard reduced != value else { return }
        reduced = value
        parts.values.forEach { $0.removeAllAnimations() }
        // Restoring motion resumes loops, never repeats an old request's entrance.
        if !value { animate(entrance: false) }
        syncPlayback()
    }

    private func rebuild(key: String, mini: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        canvas.sublayers?.forEach { $0.removeFromSuperlayer() }
        canvas.speed = 1
        canvas.timeOffset = 0
        canvas.beginTime = 0
        parts.removeAll()
        func node(_ name: String, parent: CALayer, pivot: CGPoint = CGPoint(x: 64, y: 64), image: Bool = true) -> CALayer {
            let result = CALayer()
            result.name = name
            result.bounds = CGRect(x: 0, y: 0, width: 128, height: 128)
            result.anchorPoint = CGPoint(x: pivot.x / 128, y: pivot.y / 128)
            result.position = pivot
            if image { result.contents = Self.image(named: "\(key)-\(name)") }
            result.contentsScale = 2
            parent.addSublayer(result)
            parts[name] = result
            return result
        }
        _ = node("ground", parent: canvas)
        let character = node("character", parent: canvas, image: false)
        let body = node("body", parent: character, pivot: CGPoint(x: 64, y: 63), image: false)
        let bodyArt = CALayer()
        bodyArt.frame = body.bounds
        bodyArt.contents = Self.image(named: "\(key)-body")
        body.addSublayer(bodyArt)
        _ = node("eyes", parent: body, pivot: CGPoint(x: 63, y: state == "working" ? (mini ? 72 : 71.5) : 62))
        if state == "idle" { node("open", parent: body).opacity = 0 }
        _ = node("left", parent: character, pivot: CGPoint(x: state == "working" ? 41 : 24, y: 84))
        _ = node("right", parent: character, pivot: CGPoint(x: state == "working" ? 86 : 105,
                                                          y: ["attention", "question"].contains(state) ? 62 : 84))
        _ = node("badge", parent: canvas, pivot: CGPoint(x: mini ? 104.5 : 108, y: mini ? 20.4 : 17))
        CATransaction.commit()
    }

    private static func image(named name: String) -> CGImage? {
        if let cached = images[name] { return cached }
        guard let url = resources.url(forResource: name, withExtension: "png", subdirectory: "Resources/MascotLayers"),
              let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            assertionFailure("Missing mascot animation layer: \(name)")
            return nil
        }
        images[name] = image
        return image
    }

    private func animate(entrance: Bool = true) {
        for track in MascotAnimation.tracks(for: state, entrance: entrance) {
            guard let part = parts[track.part] else { continue }
            let animation = track.animation()
            animation.beginTime = part.convertTime(CACurrentMediaTime(), from: nil) + track.delay
            part.add(animation, forKey: track.keyPath)
        }
    }

    private func syncPlayback() {
        // SwiftUI can render a representable with an empty AppKit visibleRect.
        // Use SwiftUI's lifecycle/mode flag and the window's visibility instead.
        let play = active && !reduced && !suspended && window?.occlusionState.contains(.visible) == true
            && !isHiddenOrHasHiddenAncestor
        if play && canvas.speed == 0 {
            let pausedTime = canvas.timeOffset
            canvas.speed = 1
            canvas.timeOffset = 0
            canvas.beginTime = 0
            canvas.beginTime = canvas.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
        } else if !play && canvas.speed != 0 {
            let time = canvas.convertTime(CACurrentMediaTime(), from: nil)
            canvas.speed = 0
            canvas.timeOffset = time
        }
    }
}
