import AppKit
import SwiftUI
import Combine

@MainActor
final class PanelState: ObservableObject {
    @Published var isExpanded = false
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
    private var menuObservers: [NSObjectProtocol] = []

    init(store: UsageStore, themeStore: ThemeStore) {
        self.store = store
        self.themeStore = themeStore
        makeMainPanel()
        makeDetailPanel()
        positionPanel(expanded: false)
        panel.orderFrontRegardless()
        installFarAwayCollapse()
        installMenuTrackingGuard()
        visibilityObserver = themeStore.$hiddenProviders.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.positionPanel(expanded: self.state.isExpanded)
            }
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
                self.showDetail(for: first.id, ringCenterY: y)
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
            onRingHover: { [weak self] id, centerY in
                self?.showDetail(for: id, ringCenterY: centerY)
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

    private var screen: NSScreen? { NSScreen.main ?? NSScreen.screens.first }

    private var panelHeight: CGFloat {
        max(Layout.tabHeight(providers: themeStore.visible(store.snapshots).count), Layout.stripHeight) + 24
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
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.state.isExpanded, !self.menuOpen, !Self.collapseSuspended,
                      let screen = self.screen else { return }
                if NSEvent.mouseLocation.x < screen.frame.maxX - self.farAwayDistance {
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
        menuObservers = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.menuOpen = true
                    self.hoverChanged()
                }
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
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
        positionPanel(expanded: true)
        state.isExpanded = true
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
            self.positionPanel(expanded: false)
        }
    }

    // MARK: Detail bubble

    private func showDetail(for id: String, ringCenterY: CGFloat) {
        guard let snap = store.snapshots.first(where: { $0.id == id }), let screen else { return }
        let panelFrame = panel.frame
        let ringScreenY = panelFrame.maxY - ringCenterY   // SwiftUI global y is top-down

        // Measure the card for this snapshot.
        let probe = NSHostingView(rootView:
            DetailCardContent(snapshot: snap, palette: .resolve(themeStore.theme, systemDark: false))
                .padding(EdgeInsets(top: 13, leading: 15, bottom: 15, trailing: 15))
                .frame(width: Layout.cardWidth)
        )
        let cardHeight = max(probe.fittingSize.height, 100)
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
        let frame = NSRect(x: x, y: cardTopY + Layout.shadowPad - winH, width: winW, height: winH)

        let wasVisible = detail.visible
        let sameProvider = detail.snapshot?.id == id
        detail.snapshot = snap

        if !wasVisible {
            // Fresh open: place instantly, then pop in.
            detail.tailY = tailY
            detailPanel.setFrame(frame, display: true, animate: false)
            detailPanel.orderFrontRegardless()
            DispatchQueue.main.async { self.detail.visible = true }
        } else {
            // Already open: glide to the new ring (content crossfades via SwiftUI).
            if !sameProvider || abs(detailPanel.frame.midY - frame.midY) > 0.5 {
                detail.tailY = tailY
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.40
                    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.30, 0.90, 0.25, 1)
                    self.detailPanel.animator().setFrame(frame, display: true)
                }
            }
        }
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
