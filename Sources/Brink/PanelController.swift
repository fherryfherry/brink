import AppKit
import SwiftUI
import Combine

@MainActor
final class PanelState: ObservableObject {
    @Published var isExpanded = false
    @Published var notchWidth: CGFloat = 0   // notch mode: gap left between the two wings
    @Published var barHeight: CGFloat = 0    // notch mode: height of the bar (notch / menu bar)
    @Published var notchCollapsed = CGRect.zero   // notch mode: compact bar, screen coords
    @Published var notchExpanded = CGRect.zero    // notch mode: dropped-down panel, screen coords
    @Published var windowMinX: CGFloat = 0        // notch mode: panel's left edge, to place the rects
}

/// Owns the borderless edge panel and the detail-bubble panel.
@MainActor
final class PanelController {
    /// Set by `OllamaLogin` while its sign-in window is open: the panel is a
    /// separate always-on-top window, and its own hover/collapse machinery has
    /// no idea a login flow is in progress on top of it, so it can collapse
    /// (and animate/reposition) out from under an unrelated window. Simplest
    /// fix is to just not touch the panel at all for that window's lifetime.
    static var collapseSuspended = false

    private let store: UsageStore
    private let themeStore: ThemeStore
    private let state = PanelState()
    private let detail = DetailState()

    private var panel: NSPanel!
    private var detailPanel: NSPanel!
    private var collapseTask: Task<Void, Never>?

    private let collapsedWidth: CGFloat = 14
    private let expandedWidth: CGFloat = Layout.tabWidth + 24   // + shadow / curve room

    private var panelHovered = false
    private var detailHovered = false
    private var menuOpen = false
    private var visibilityObserver: AnyCancellable?
    private var placementObserver: AnyCancellable?
    private var screenObserver: NSObjectProtocol?
    private var menuObservers: [NSObjectProtocol] = []

    private var isNotch: Bool { themeStore.placement == .notch }

    init(store: UsageStore, themeStore: ThemeStore) {
        self.store = store
        self.themeStore = themeStore
        makeMainPanel()
        makeDetailPanel()
        applyPlacement()
        panel.orderFrontRegardless()
        installFarAwayCollapse()
        installMenuTrackingGuard()
        visibilityObserver = themeStore.$hiddenProviders.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.layout() }
        }
        placementObserver = themeStore.$placement.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.hideDetail()
                self?.applyPlacement()
            }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }

        // BRINK_PREVIEW=1 → start expanded with the first card open (screenshots / design review).
        if ProcessInfo.processInfo.environment["BRINK_PREVIEW"] == "1" {
            panelHovered = true
            expand()
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self, let first = self.store.snapshots.first else { return }
                let n = self.store.snapshots.count
                let y = 12 + Layout.tabPadding + Layout.ringBlockHeight / 2
                _ = n
                self.showDetail(for: first.id, ringCenter: y)
            }
        }
    }

    // MARK: Panels

    private func makeMainPanel() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 140, height: 400),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        configure(panel)
        let root = PanelRootView(
            store: store, state: state, themeStore: themeStore,
            onHoverChanged: { [weak self] inside in
                self?.panelHovered = inside
                self?.hoverChanged()
            },
            onRingHover: { [weak self] id, center in
                self?.showDetail(for: id, ringCenter: center)
            }
        )
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []          // never let SwiftUI resize the window
        panel.contentView = host
    }

    private func makeDetailPanel() {
        detailPanel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        configure(detailPanel)
        let view = DetailBubbleView(state: detail, store: store, themeStore: themeStore)
            .onHover { [weak self] inside in
                self?.detailHovered = inside
                self?.hoverChanged()
            }
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        detailPanel.contentView = host
    }

    private func configure(_ p: NSPanel) {
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true
    }

    // MARK: Geometry

    private var edgeScreen: NSScreen? { NSScreen.main ?? NSScreen.screens.first }

    /// The built-in notched display if there is one, otherwise the menu-bar screen.
    private var notchScreen: NSScreen? {
        NSScreen.screens.first { $0.auxiliaryTopLeftArea != nil } ?? NSScreen.screens.first
    }

    private var screen: NSScreen? { isNotch ? notchScreen : edgeScreen }

    /// Width and height of the notch, or a fake notch-sized gap on screens without one.
    private func notchMetrics(_ screen: NSScreen) -> (width: CGFloat, height: CGFloat) {
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            return (screen.frame.width - left.width - right.width, screen.safeAreaInsets.top)
        }
        return (Layout.notchFallbackWidth, max(screen.frame.maxY - screen.visibleFrame.maxY, 24))
    }

    private var panelHeight: CGFloat {
        max(Layout.tabHeight(providers: themeStore.visible(store.snapshots).count), Layout.stripHeight) + 24
    }

    private func applyPlacement() {
        let level: NSWindow.Level = isNotch ? .init(NSWindow.Level.mainMenu.rawValue + 1) : .statusBar
        panel.level = level
        detailPanel.level = level
        collapseTask?.cancel()
        state.isExpanded = false
        layout()
    }

    private func layout() {
        if isNotch { positionNotch(expanded: state.isExpanded) } else { positionPanel(expanded: state.isExpanded) }
    }

    /// Expanded, the window covers both the compact bar and the dropped-down panel so the shape can morph between them.
    private func positionNotch(expanded: Bool) {
        guard let screen else { return }
        let (notchWidth, h) = notchMetrics(screen)
        let visible = themeStore.visible(store.snapshots)
        let wings = Layout.splitWings(visible)
        let left = Layout.wingWidth(rings: wings.left.count, barHeight: h)
        let right = Layout.wingWidth(rings: wings.right.count, barHeight: h)
        let top = screen.frame.maxY
        let collapsed = CGRect(x: screen.frame.midX - notchWidth / 2 - left, y: top - h,
                               width: left + notchWidth + right, height: h)
        let size = Layout.notchExpandedSize(rings: visible.count, barHeight: h, minWidth: notchWidth)
        let dropped = CGRect(x: screen.frame.midX - size.width / 2, y: top - size.height,
                             width: size.width, height: size.height)
        let frame = expanded ? collapsed.union(dropped) : collapsed
        state.notchWidth = notchWidth
        state.barHeight = h
        state.notchCollapsed = collapsed
        state.notchExpanded = dropped
        state.windowMinX = frame.minX
        panel.setFrame(frame, display: true, animate: false)
    }

    private func positionPanel(expanded: Bool) {
        guard let screen else { return }
        let width = expanded ? expandedWidth : collapsedWidth
        let h = panelHeight
        let y = screen.visibleFrame.midY - h / 2
        panel.setFrame(NSRect(x: screen.frame.maxX - width, y: y, width: width, height: h),
                       display: true, animate: false)
    }

    // MARK: Collapse when the cursor wanders far from the edge (mockup: > 480px)

    private var mouseMonitor: Any?
    private let farAwayDistance: CGFloat = 480

    private func installFarAwayCollapse() {
        // This fires on every mouse-moved event system-wide — potentially 100+/sec
        // while the cursor is in motion, e.g. while hovering the settings menu.
        // Global monitors already deliver on the main thread, so spawning a fresh
        // Task per event here (as this used to) meant creating and scheduling that
        // many Task objects a second, competing with AppKit's own menu-tracking
        // loop for the main thread and showing up as the menu's hover highlight
        // lagging behind the cursor.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state.isExpanded, !self.menuOpen, !Self.collapseSuspended,
                      let screen = self.screen else { return }
                let mouse = NSEvent.mouseLocation
                let far = self.isNotch ? mouse.y < self.panel.frame.minY - self.farAwayDistance / 2
                                       : mouse.x < screen.frame.maxX - self.farAwayDistance
                if far {
                    self.panelHovered = false
                    self.detailHovered = false
                    self.scheduleCollapse()
                }
            }
        }
    }

    // MARK: Hover logic

    /// SwiftUI's `.onHover` reports "exited" the instant the right-click context menu
    /// (Refresh, Providers, Sign in to Ollama, ...) pops up, since that menu is a
    /// separate overlay the mouse moves into — which would otherwise start the
    /// collapse timer and close the panel (and the menu with it) mid-click. Track
    /// NSMenu's own tracking session instead so an open menu always keeps it pinned.
    private func installMenuTrackingGuard() {
        let center = NotificationCenter.default
        // `queue: .main` already guarantees these run on the main thread — no
        // need to also bounce through a freshly spawned Task to reach the
        // MainActor, which just adds a scheduling round-trip on every single
        // submenu open/close as you navigate a nested menu (Accounts > Add
        // account > ...), noticeably enough to feel like hover lag.
        menuObservers = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.menuOpen = true
                    self.hoverChanged()
                }
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.menuOpen = false
                    self.hoverChanged()
                }
            },
        ]
    }

    private func hoverChanged() {
        if panelHovered || detailHovered || menuOpen || Self.collapseSuspended {
            collapseTask?.cancel()
            collapseTask = nil
            if !state.isExpanded { expand() }
        } else {
            scheduleCollapse()
        }
    }

    private func expand() {
        guard isNotch else {
            positionPanel(expanded: true)
            state.isExpanded = true
            return
        }
        // Grow the window first, then morph next runloop so the frame jump isn't animated.
        positionNotch(expanded: true)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panelHovered || self.detailHovered || self.menuOpen else { return }
            self.state.isExpanded = true
        }
    }

    private func scheduleCollapse() {
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self else { return }
            guard !self.panelHovered, !self.detailHovered, !self.menuOpen, !Self.collapseSuspended else { return }
            self.state.isExpanded = false
            self.hideDetail()
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, !self.state.isExpanded else { return }
            self.layout()
        }
    }

    // MARK: Detail bubble

    /// `ringCenter` is the ring's centre along the bar: y in edge mode, x in notch mode (window coords).
    private func showDetail(for id: String, ringCenter: CGFloat) {
        guard let snap = store.snapshots.first(where: { $0.id == id }), let screen else { return }
        let panelFrame = panel.frame

        // Measure the card for this snapshot.
        let probe = NSHostingView(rootView:
            DetailCardContent(snapshot: snap, palette: .resolve(themeStore.theme, systemDark: false))
                .padding(EdgeInsets(top: 13, leading: 15, bottom: 15, trailing: 15))
                .frame(width: Layout.cardWidth)
        )
        let cardHeight = max(probe.fittingSize.height, 100)
        let frame: NSRect
        if isNotch {
            // Card hangs below the bar, centred on the ring, clamped to the screen.
            let ringScreenX = panelFrame.minX + ringCenter
            var cardX = ringScreenX - Layout.cardWidth / 2
            cardX = min(max(cardX, screen.frame.minX + 10), screen.frame.maxX - 10 - Layout.cardWidth)
            let tailX = min(max(ringScreenX - cardX, 20), Layout.cardWidth - 20)
            let winW = Layout.cardWidth + Layout.shadowPad * 2
            let winH = cardHeight + Layout.tailRoom + Layout.shadowPad * 2
            let top = panelFrame.minY - 2 + Layout.shadowPad
            frame = NSRect(x: cardX - Layout.shadowPad, y: top - winH, width: winW, height: winH)
            detail.tailOnTop = true
            detail.tailX = tailX
        } else {
            frame = edgeDetailFrame(screen: screen, ringScreenY: panelFrame.maxY - ringCenter, cardHeight: cardHeight)
            detail.tailOnTop = false
        }

        let wasVisible = detail.visible
        let sameProvider = detail.snapshot?.id == id
        detail.snapshot = snap

        if !wasVisible {
            // Fresh open: place instantly, then pop in.
            detailPanel.setFrame(frame, display: true, animate: false)
            detailPanel.orderFrontRegardless()
            // The card's shadow margin overlaps the notch bar; keep the bar on top so its rings stay hoverable.
            if isNotch { panel.orderFrontRegardless() }
            DispatchQueue.main.async { self.detail.visible = true }
        } else if !sameProvider || abs(detailPanel.frame.midY - frame.midY) > 0.5
                    || abs(detailPanel.frame.midX - frame.midX) > 0.5 {
            // Already open: glide to the new ring (content crossfades via SwiftUI).
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.40
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.30, 0.90, 0.25, 1)
                self.detailPanel.animator().setFrame(frame, display: true)
            }
        }
    }

    /// Card to the left of the edge tab, its tail centred on the ring; also sets `detail.tailY`.
    private func edgeDetailFrame(screen: NSScreen, ringScreenY: CGFloat, cardHeight: CGFloat) -> NSRect {
        let winW = Layout.cardWidth + Layout.tailRoom + Layout.shadowPad * 2
        let winH = cardHeight + Layout.shadowPad * 2

        // Card top (screen coords, y up): centre the tail on the ring, clamped to the screen.
        var cardTopY = ringScreenY + 83                       // top edge, y-up
        let maxTop = screen.visibleFrame.maxY - 10
        let minTop = screen.visibleFrame.minY + cardHeight + 10
        cardTopY = min(max(cardTopY, minTop), maxTop)
        var tailY = cardTopY - ringScreenY                     // distance from card top, y-down
        tailY = min(max(tailY, 20), cardHeight - 20)

        let x = screen.frame.maxX - Layout.tabWidth - 12 - Layout.tailWidth - Layout.cardWidth - Layout.shadowPad
        detail.tailY = tailY
        return NSRect(x: x, y: cardTopY + Layout.shadowPad - winH, width: winW, height: winH)
    }

    private func hideDetail() {
        guard detail.visible else { return }
        detail.visible = false
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 320_000_000)
            guard let self, !self.detail.visible else { return }
            self.detailPanel.orderOut(nil)
            self.detail.snapshot = nil
        }
    }
}
