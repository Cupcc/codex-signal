import AppKit
import Combine
import OSLog
import QuartzCore
import SwiftUI

private final class SignalPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { makeKey() }
        super.sendEvent(event)
    }
}

private final class SignalHostingView: NSHostingView<IslandView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class IslandLayoutState: ObservableObject {
    @Published var layout = IslandLayout()
    @Published var expandedContentHeight: CGFloat?
}

@MainActor
final class IslandPanel {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CodexSignal", category: "Windowing")
    private let model: AppModel
    private let panel: SignalPanel
    private let hosting: SignalHostingView
    private let layoutState = IslandLayoutState()
    private var subscriptions = Set<AnyCancellable>()
    private var keyMonitor: Any?
    private var outsideClickMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var screenID: NSNumber?
    private var targetFrame: NSRect = .zero
    private var frameAnimationID: UUID?

    init(model: AppModel) {
        self.model = model
        hosting = SignalHostingView(rootView: IslandView(model: model, layoutState: layoutState))
        // The root view lives for the life of the panel, preserving settings,
        // scroll position and SwiftUI animation identity across mode changes.
        hosting.sizingOptions = []
        panel = SignalPanel(contentRect: NSRect(origin: .zero, size: layoutState.layout.expandedSize),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "Codex Signal 会话伙伴岛"
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = false
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true
        screenID = NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        model.$expanded.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh(animated: true) }
        }.store(in: &subscriptions)
        model.$islandNotice.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh(animated: true) }
        }.store(in: &subscriptions)
        layoutState.$expandedContentHeight.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh(animated: true) }
        }.store(in: &subscriptions)
        Publishers.CombineLatest(model.$sessions, model.$sessionFilter)
            .sink { [weak self] _, _ in
                DispatchQueue.main.async { self?.refresh(animated: true) }
            }.store(in: &subscriptions)
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        Publishers.Merge(NotificationCenter.default.publisher(for: NSWindow.didMoveNotification, object: panel),
                         NotificationCenter.default.publisher(for: NSWindow.didResizeNotification, object: panel))
            .sink { [weak self] _ in
                guard self?.frameAnimationID == nil else { return }
                DispatchQueue.main.async { self?.restoreAnchorIfNeeded() }
            }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)
            .sink { [weak self] notification in
                guard let self, self.contains(notification.object as? NSWindow) else { return }
                // Wait for AppKit to finish transferring focus, including to a
                // settings popover attached to this panel.
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.contains(NSApp.keyWindow) else { return }
                    self.collapse()
                }
            }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in self?.collapse() }
            .store(in: &subscriptions)
        // Nonactivating panels can be key while another app remains active.
        // Observe workspace activation as well to cover Command-Tab from there.
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] notification in
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                self?.collapse()
            }.store(in: &subscriptions)
        // A panel shown at launch need not have taken keyboard focus yet.
        // Mouse-only global monitoring also covers clicks in the active app.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.collapse() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, event.window === self.panel, self.panel.isKeyWindow else { return false }
                switch event.keyCode {
                case 53:
                    self.model.setExpanded(false)
                    return true
                case 125:
                    self.model.moveSelection(1)
                    return true
                case 126:
                    self.model.moveSelection(-1)
                    return true
                case 36, 76:
                    if let id = self.model.selectedID,
                       let session = self.model.visibleSessions.first(where: { $0.id == id }) {
                        self.model.openSource(session)
                    }
                    return true
                default:
                    return false
                }
            }
            return consumed ? nil : event
        }
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    private func contains(_ window: NSWindow?) -> Bool {
        var candidate = window
        while let current = candidate {
            if current === panel { return true }
            candidate = current.parent
        }
        return false
    }

    private func collapse() {
        guard model.expanded else { return }
        model.setExpanded(false)
    }

    func show() {
        refresh()
        panel.orderFrontRegardless()
    }

    func toggle() {
        model.setExpanded(!model.expanded)
        panel.orderFrontRegardless()
        if model.expanded { panel.makeKey() }
    }

    func refresh(animated: Bool = false) {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) == screenID
        }) ?? NSScreen.main ?? NSScreen.screens.first else { return }
        screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let geometry = IslandScreenGeometry(
            screenWidth: screen.frame.width,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryLeftWidth: screen.auxiliaryTopLeftArea?.width,
            auxiliaryRightWidth: screen.auxiliaryTopRightArea?.width,
            menuBarHeight: max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        )
        let top = geometry.hasNotch ? screen.frame.maxY : screen.visibleFrame.maxY - 8
        let layout = IslandLayout(geometry: geometry,
                                  availableWidth: screen.visibleFrame.width - 24,
                                  availableHeight: top - screen.visibleFrame.minY - 12,
                                  contentHeight: layoutState.expandedContentHeight)
        if layoutState.layout != layout { layoutState.layout = layout }
        let frame = layout.frame(expanded: model.expanded, alerting: model.islandNotice != nil, centerX: screen.frame.midX,
                                 top: top, scale: screen.backingScaleFactor)
        let shouldAnimate = animated && panel.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if targetFrame == frame {
            if shouldAnimate && frameAnimationID != nil { return }
            if frameAnimationID == nil && frameMatchesTarget { return }
        }
        targetFrame = frame
        let animationID = UUID()
        frameAnimationID = animationID
        NSAnimationContext.runAnimationGroup { context in
            context.duration = shouldAnimate ? (model.expanded || model.islandNotice != nil ? 0.30 : 0.20) : 0
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.8, 0.24, 1)
            // A zero-duration proxy update also replaces any unfinished frame animation.
            panel.animator().setFrame(frame, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.frameAnimationID == animationID else { return }
                self.frameAnimationID = nil
                self.panel.invalidateShadow()
                self.restoreAnchorIfNeeded()
            }
        }
        if !model.expanded { panel.resignKey() }
    }

    private var frameMatchesTarget: Bool {
        let actual = panel.frame
        let tolerance = 1 / max(1, panel.backingScaleFactor)
        return abs(actual.midX - targetFrame.midX) <= tolerance
            && abs(actual.maxY - targetFrame.maxY) <= tolerance
            && abs(actual.width - targetFrame.width) <= tolerance
            && abs(actual.height - targetFrame.height) <= tolerance
    }

    private func restoreAnchorIfNeeded() {
        guard frameAnimationID == nil, targetFrame != .zero, !frameMatchesTarget else { return }
        Self.logger.notice("Correcting panel drift: expanded=\(self.model.expanded), actual=\(NSStringFromRect(self.panel.frame), privacy: .public), target=\(NSStringFromRect(self.targetFrame), privacy: .public)")
        refresh()
    }
}
