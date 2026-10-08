import SwiftUI
import AppKit

// MARK: - Layout constants (mirror the design mockup)

enum Layout {
    static let tabWidth: CGFloat = 70        // total width incl. the 10pt curve room on the left
    static let tabBodyInset: CGFloat = 5     // body starts 10pt in from the tab's left edge
    static let curveZone: CGFloat = 49        // height of each S-curve
    static let ringSize: CGFloat = 43
    static let ringGap: CGFloat = 18
    static let ringBlockHeight: CGFloat = 43 + 6 + 16   // ring + gap + percent label
    static let tabPadding: CGFloat = 41       // vertical padding inside the tab

    static let stripWidth: CGFloat = 6
    static let stripHoverWidth: CGFloat = 10
    static let stripHeight: CGFloat = 153

    static let cardWidth: CGFloat = 266
    static let cardRadius: CGFloat = 17
    static let tailWidth: CGFloat = 14        // arrow tail (points at the ring)
    static let tailHeight: CGFloat = 23
    static let tailRoom: CGFloat = 16         // extra width right of the card for the tail
    static let shadowPad: CGFloat = 28        // transparent margin around the card for its shadow

    static func tabHeight(providers n: Int) -> CGFloat {
        tabPadding * 2 + CGFloat(n) * ringBlockHeight + CGFloat(max(n - 1, 0)) * ringGap
    }

    // Notch mode: compact rings flanking the (real or fake) notch.
    static let notchFallbackWidth: CGFloat = 180
    static let notchRadius: CGFloat = 9
    static let compactLabelWidth: CGFloat = 38
    static let compactGap: CGFloat = 10
    static let wingPadding: CGFloat = 12

    static let droppedRingSlot: CGFloat = 56
    static let droppedPadding: CGFloat = 18
    static let droppedRadius: CGFloat = 22
    static let droppedGap: CGFloat = 12

    static func notchExpandedSize(rings n: Int, barHeight h: CGFloat, minWidth: CGFloat) -> CGSize {
        let rings = droppedPadding * 2 + CGFloat(n) * droppedRingSlot + CGFloat(max(n - 1, 0)) * droppedGap
        return CGSize(width: max(rings, minWidth), height: h + 10 + ringBlockHeight + droppedPadding)
    }

    static func compactRingSize(barHeight h: CGFloat) -> CGFloat { min(22, max(h - 8, 14)) }

    static func wingWidth(rings n: Int, barHeight h: CGFloat) -> CGFloat {
        guard n > 0 else { return 0 }
        let block = compactRingSize(barHeight: h) + 4 + compactLabelWidth
        return wingPadding * 2 + CGFloat(n) * block + CGFloat(n - 1) * compactGap
    }

    /// Splits visible providers into the rings left and right of the notch.
    static func splitWings<T>(_ items: [T]) -> (left: [T], right: [T]) {
        let leftCount = (items.count + 1) / 2
        return (Array(items.prefix(leftCount)), Array(items.dropFirst(leftCount)))
    }
}

// MARK: - Shapes

/// The notch-style tab: flares out to the screen edge with an S-curve at top and bottom.
struct NotchTabShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let s = Layout.curveZone
        let x0 = rect.minX + Layout.tabBodyInset
        let xw = rect.maxX
        var p = Path()
        p.move(to: CGPoint(x: xw, y: rect.minY))
        p.addCurve(to: CGPoint(x: x0, y: rect.minY + s),
                   control1: CGPoint(x: xw, y: rect.minY + s * 0.62),
                   control2: CGPoint(x: x0, y: rect.minY + s * 0.30))
        p.addLine(to: CGPoint(x: x0, y: rect.maxY - s))
        p.addCurve(to: CGPoint(x: xw, y: rect.maxY),
                   control1: CGPoint(x: x0, y: rect.maxY - s * 0.30),
                   control2: CGPoint(x: xw, y: rect.maxY - s * 0.62))
        p.closeSubpath()
        _ = w; _ = h
        return p
    }
}

/// Arrow tail pointing right (mockup v3: `polygon(0 0, 100% 50%, 0 100%)`), or up in notch mode.
struct ArrowTailShape: Shape {
    var up = false
    func path(in rect: CGRect) -> Path {
        var p = Path()
        if up {
            p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        } else {
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        p.closeSubpath()
        return p
    }
}

/// Flat top, rounded bottom corners: the black bar that extends the notch sideways.
struct NotchWingShape: Shape {
    var radius: CGFloat
    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height / 2, rect.width / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// Rounded on the left side only (collapsed strip).
struct LeftRoundedRect: Shape {
    var radius: CGFloat
    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height / 2, rect.width)
        var p = Path()
        p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + r), control: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.maxY), control: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Provider icons (vector, from the mockup)

struct ClaudeIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 24
        var p = Path()
        let lines: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (12, 2.5, 12, 8), (12, 16, 12, 21.5), (2.5, 12, 8, 12), (16, 12, 21.5, 12),
            (5.2, 5.2, 9.1, 9.1), (14.9, 14.9, 18.8, 18.8), (5.2, 18.8, 9.1, 14.9), (14.9, 9.1, 18.8, 5.2),
        ]
        for (x1, y1, x2, y2) in lines {
            p.move(to: CGPoint(x: rect.minX + x1 * s, y: rect.minY + y1 * s))
            p.addLine(to: CGPoint(x: rect.minX + x2 * s, y: rect.minY + y2 * s))
        }
        return p
    }
}

struct CodexIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 24
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var p = Path()
        p.move(to: pt(12, 3)); p.addLine(to: pt(19.4, 7.3)); p.addLine(to: pt(19.4, 16.7))
        p.addLine(to: pt(12, 21)); p.addLine(to: pt(4.6, 16.7)); p.addLine(to: pt(4.6, 7.3)); p.closeSubpath()
        p.move(to: pt(12, 8.4)); p.addLine(to: pt(15.1, 10.2)); p.addLine(to: pt(15.1, 13.8))
        p.addLine(to: pt(12, 15.6)); p.addLine(to: pt(8.9, 13.8)); p.addLine(to: pt(8.9, 10.2)); p.closeSubpath()
        return p
    }
}

struct ProviderIcon: View {
    let id: String
    var size: CGFloat
    var color: Color

    private static let logos: [String: NSImage] = {
        var dict: [String: NSImage] = [:]
        for (key, file) in [("claude", "claude"), ("codex", "openai"), ("ollama", "ollama"), ("kenari", "kenari")] {
            if let url = Bundle.module.url(forResource: file, withExtension: "png"),
               let img = NSImage(contentsOf: url) {
                img.isTemplate = true
                dict[key] = img
            }
        }
        return dict
    }()

    // Account ids are "<kind>" or "<kind>-<suffix>", so every account of a kind shares its logo.
    private var logoKey: String {
        String(id.prefix(while: { $0 != "-" }))
    }

    var body: some View {
        Group {
            if let logo = Self.logos[logoKey] {
                Image(nsImage: logo)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .foregroundColor(color)
            } else {
                switch logoKey {
                case "claude":
                    ClaudeIcon().stroke(color, style: StrokeStyle(lineWidth: size * 0.1, lineCap: .round))
                case "codex":
                    CodexIcon().stroke(color, style: StrokeStyle(lineWidth: size * 0.08, lineCap: .round, lineJoin: .round))
                case "sumopod":
                    Image(systemName: "dollarsign.circle").font(.system(size: size * 0.85, weight: .semibold)).foregroundColor(color)
                default:
                    Image(systemName: "sparkle").font(.system(size: size * 0.8, weight: .semibold)).foregroundColor(color)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Helpers

extension View {
    @ViewBuilder
    func forcedColorScheme(_ scheme: ColorScheme?) -> some View {
        if let scheme { self.environment(\.colorScheme, scheme) } else { self }
    }
}

// MARK: - Legibility shadow for type/icons on clear glass

extension View {
    func legibilityShadow(_ on: Bool) -> some View {
        shadow(color: .black.opacity(on ? 0.35 : 0), radius: on ? 2 : 0, y: on ? 1 : 0)
    }
}

// MARK: - Usage ring

extension ProviderSnapshot {
    var ringPercent: Double { primary?.usedPercent ?? 0 }
    var ringLabel: String {
        guard !windows.isEmpty else { return "--" }
        return primary?.valueText ?? "\(Int(ringPercent.rounded()))%"
    }
}

/// The ring itself (track, usage arc, refresh spin, error badge), shared by both placements.
struct RingArc: View {
    let snapshot: ProviderSnapshot
    let palette: Palette
    let isRefreshing: Bool
    var size: CGFloat
    var lineWidth: CGFloat
    var iconSize: CGFloat
    @State private var spin = false

    private var percent: Double { snapshot.ringPercent }
    private var hasData: Bool { !snapshot.windows.isEmpty }
    // Demo (not signed in yet) always carries a note in `error` — that's not
    // a failed refresh, it's an expected "not configured" state with its own
    // faded/"--" look already, so it doesn't also get the failure badge.
    private var hasError: Bool { snapshot.error != nil && !snapshot.isDemo }
    // While refreshing, spin a short arc of the ring's own color instead of a
    // separate loading element; the real percent arc reappears once it lands.
    private var arcEnd: Double {
        if isRefreshing { return 0.22 }
        guard hasData, let primary = snapshot.primary else { return 0 }
        return primary.isBalance ? 1 : primary.fraction
    }

    var body: some View {
        ZStack {
            Circle().stroke(palette.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: arcEnd)
                .stroke(UsageColor.color(for: snapshot, percent: percent),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(.easeOut(duration: 0.6), value: percent)
                .animation(spin ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .easeOut(duration: 0.3),
                           value: spin)
                .onChange(of: isRefreshing) { spin = $0 }
            ProviderIcon(id: snapshot.id, size: iconSize, color: palette.fg)
        }
        .frame(width: size, height: size)
        .opacity(hasData ? 1 : 0.35)
        .overlay(alignment: .topTrailing) {
            if hasError && !isRefreshing {
                Circle()
                    .fill(Color.red)
                    .overlay(Circle().stroke(.black.opacity(0.25), lineWidth: 1))
                    .frame(width: 7, height: 7)
                    .offset(x: 1, y: -1)
            }
        }
    }
}

struct UsageRing: View {
    let snapshot: ProviderSnapshot
    let palette: Palette
    let isRefreshing: Bool
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 6) {
            RingArc(snapshot: snapshot, palette: palette, isRefreshing: isRefreshing,
                    size: Layout.ringSize, lineWidth: 5, iconSize: 18)
                .scaleEffect(hovering ? 1.08 : 1)
                .animation(.spring(response: 0.28, dampingFraction: 0.55), value: hovering)

            Text(snapshot.ringLabel)
                .font(.system(size: 13.5, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundColor(palette.fg)
        }
        .frame(height: Layout.ringBlockHeight)
        .legibilityShadow(palette.textShadow)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// Notch mode: a small ring with its value beside it, sized to fit the menu bar height.
struct CompactRing: View {
    let snapshot: ProviderSnapshot
    let palette: Palette
    let isRefreshing: Bool
    var size: CGFloat
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            RingArc(snapshot: snapshot, palette: palette, isRefreshing: isRefreshing,
                    size: size, lineWidth: 2.5, iconSize: size * 0.48)
            Text(snapshot.ringLabel)
                .font(.system(size: 11.5, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundColor(palette.fg)
                .frame(width: Layout.compactLabelWidth, alignment: .leading)
        }
        .scaleEffect(hovering ? 1.06 : 1)
        .animation(.spring(response: 0.28, dampingFraction: 0.55), value: hovering)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// MARK: - Ring column + tab

struct RingCenterKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

struct TabView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var themeStore: ThemeStore
    let palette: Palette
    var onRingHover: (String, CGFloat) -> Void   // id, ring centre y (window coords, top-left origin)
    @State private var centers: [String: CGFloat] = [:]

    private var visible: [ProviderSnapshot] { themeStore.visible(store.snapshots) }

    var body: some View {
        VStack(spacing: Layout.ringGap) {
            ForEach(visible) { snap in
                UsageRing(snapshot: snap, palette: palette,
                          isRefreshing: store.refreshingIDs.contains(snap.id))
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: RingCenterKey.self,
                                               value: [snap.id: geo.frame(in: .global).midY])
                    })
                    .onHover { inside in
                        if inside, let y = centers[snap.id] { onRingHover(snap.id, y) }
                    }
            }
        }
        .onPreferenceChange(RingCenterKey.self) { centers = $0 }
        .padding(.vertical, Layout.tabPadding)
        .padding(.leading, Layout.tabBodyInset)
        .frame(width: Layout.tabWidth, height: Layout.tabHeight(providers: visible.count))
        .brinkSurface(palette, shape: NotchTabShape())
    }
}

/// Notch mode: compact rings flank the notch; on hover the bar drops down into large rings.
struct NotchBarView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var themeStore: ThemeStore
    @ObservedObject var state: PanelState
    var onRingHover: (String, CGFloat) -> Void   // id, ring centre x (window coords)
    @State private var centers: [String: CGFloat] = [:]

    // Always black so the bar reads as part of the physical notch.
    private let palette = Palette.resolve(.black, systemDark: true)

    private var visible: [ProviderSnapshot] { themeStore.visible(store.snapshots) }

    var body: some View {
        let compact = state.notchCollapsed, dropped = state.notchExpanded
        let shape = state.isExpanded ? dropped : compact
        let wings = Layout.splitWings(visible)
        // GeometryReader pins content top-left; a bare ZStack would grow to the hidden ring row and get centred.
        GeometryReader { _ in ZStack(alignment: .topLeading) {
            NotchWingShape(radius: state.isExpanded ? Layout.droppedRadius : Layout.notchRadius)
                .fill(Color.black)
                .frame(width: shape.width, height: shape.height)
                .offset(x: shape.minX - state.windowMinX)

            HStack(spacing: 0) {
                wing(wings.left)
                Color.clear.frame(width: state.notchWidth)
                wing(wings.right)
            }
            .frame(width: compact.width, height: state.barHeight)
            .offset(x: compact.minX - state.windowMinX)
            .opacity(state.isExpanded ? 0 : 1)

            HStack(spacing: Layout.droppedGap) {
                ForEach(visible) { snap in
                    UsageRing(snapshot: snap, palette: palette,
                              isRefreshing: store.refreshingIDs.contains(snap.id))
                        .frame(width: Layout.droppedRingSlot)
                        .background(GeometryReader { geo in
                            Color.clear.preference(key: RingCenterKey.self,
                                                   value: [snap.id: geo.frame(in: .global).midX])
                        })
                        .onHover { inside in
                            if inside, let x = centers[snap.id] { onRingHover(snap.id, x) }
                        }
                }
            }
            .frame(width: dropped.width)
            .offset(x: dropped.minX - state.windowMinX, y: state.barHeight + 10)
            .opacity(state.isExpanded ? 1 : 0)
            .scaleEffect(state.isExpanded ? 1 : 0.85, anchor: .top)
            .allowsHitTesting(state.isExpanded)
        } }
        .onPreferenceChange(RingCenterKey.self) { centers = $0 }
        .animation(.timingCurve(0.32, 0.9, 0.35, 1, duration: 0.38), value: state.isExpanded)
    }

    private func wing(_ snaps: [ProviderSnapshot]) -> some View {
        HStack(spacing: Layout.compactGap) {
            ForEach(snaps) { snap in
                CompactRing(snapshot: snap, palette: palette,
                            isRefreshing: store.refreshingIDs.contains(snap.id),
                            size: Layout.compactRingSize(barHeight: state.barHeight))
            }
        }
        .padding(.horizontal, snaps.isEmpty ? 0 : Layout.wingPadding)
        .frame(width: Layout.wingWidth(rings: snaps.count, barHeight: state.barHeight))
    }
}

// MARK: - Settings menu (shared by the edge panel and the detail card)

struct SettingsMenuItems: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var themeStore: ThemeStore
    @ObservedObject private var accountStore = AccountStore.shared

    var body: some View {
        Button(L("Refresh now")) { store.refreshAll() }
        Divider()
        Menu(L("Providers")) {
            ForEach(store.snapshots) { snap in
                Toggle(snap.name, isOn: Binding(
                    get: { !themeStore.hiddenProviders.contains(snap.id) },
                    set: { themeStore.setVisible(snap.id, $0, all: store.snapshots.map(\.id)) }
                ))
            }
        }
        Menu(L("Accounts")) {
            ForEach(accountStore.accounts.filter { [.ollama, .kenari, .sumopod].contains($0.kind) }) { account in
                Button(L("Sign in to %@", account.displayName)) {
                    store.webLogin(for: account.id)?.presentLogin { store.refreshAll() }
                }
            }
            Divider()
            Menu(L("Add account")) {
                Button(L("Claude…")) { addClaude() }
                Button(L("Codex…")) { addCodex() }
                Button(L("Ollama…")) { addOllama() }
                Button(L("Kenari…")) { addKenari() }
                Button(L("Sumopod AI…")) { addSumopod() }
            }
            Menu(L("Remove account")) {
                ForEach(accountStore.accounts) { account in
                    Button(account.displayName) { removeAccount(account) }
                }
            }
        }
        Picker(L("Appearance"), selection: $themeStore.theme) {
            ForEach(Theme.allCases) { Text($0.title).tag($0) }
        }
        Picker(L("Position"), selection: $themeStore.placement) {
            ForEach(Placement.allCases) { Text($0.title).tag($0) }
        }
        Picker(L("Language"), selection: $themeStore.language) {
            Text(L("System default")).tag("")
            Divider()
            ForEach(L10n.available, id: \.code) { Text($0.name).tag($0.code) }
        }
        Toggle(L("Launch at login"), isOn: Binding(
            get: { LaunchAtLogin.isEnabled },
            set: { LaunchAtLogin.set($0) }
        ))
        Toggle(L("Notifications"), isOn: Binding(
            get: { Notifier.shared.isEnabled },
            set: { Notifier.shared.setEnabled($0) }
        ))
        Button(L("Test notification")) { Notifier.shared.sendTest() }
        Divider()
        Button(L("Quit Brink")) { NSApp.terminate(nil) }
    }

    // MARK: Add / remove accounts

    private func addClaude() {
        guard let (name, dir) = AccountPrompt.nameAndFolder(
            title: L("Add Claude account"),
            message: L("The config folder must already exist under your home directory (this is what CLAUDE_CONFIG_DIR points Claude Code at for that profile)."),
            label1: L("Display name"), placeholder1: "Claude (personal)",
            label2: L("Config folder (under ~)"), placeholder2: ".claude-personal",
            folderRequired: true
        ) else { return }
        accountStore.add(kind: .claude, displayName: name, configDir: dir)
    }

    private func addCodex() {
        guard let (name, dir) = AccountPrompt.nameAndFolder(
            title: L("Add Codex account"),
            message: L("The config folder must already exist under your home directory (this is what CODEX_HOME points Codex CLI at for that profile). Leave blank for the default ~/.codex."),
            label1: L("Display name"), placeholder1: "Codex (personal)",
            label2: L("Config folder (under ~), optional"), placeholder2: ".codex-personal",
            folderRequired: false
        ) else { return }
        accountStore.add(kind: .codex, displayName: name, configDir: dir)
    }

    private func addOllama() {
        guard let name = AccountPrompt.text(
            title: L("Add Ollama account"), message: L("A display name for this account."),
            placeholder: "Ollama"
        ) else { return }
        let config = accountStore.add(kind: .ollama, displayName: name, configDir: nil)
        store.webLogin(for: config.id)?.presentLogin { store.refreshAll() }
    }

    private func addKenari() {
        guard let name = AccountPrompt.text(
            title: L("Add Kenari account"), message: L("A display name for this account."),
            placeholder: "Kenari"
        ) else { return }
        let config = accountStore.add(kind: .kenari, displayName: name, configDir: nil)
        store.webLogin(for: config.id)?.presentLogin { store.refreshAll() }
    }

    private func addSumopod() {
        guard let name = AccountPrompt.text(
            title: L("Add Sumopod AI account"), message: L("A display name for this account."),
            placeholder: "Sumopod AI"
        ) else { return }
        let config = accountStore.add(kind: .sumopod, displayName: name, configDir: nil)
        store.webLogin(for: config.id)?.presentLogin { store.refreshAll() }
    }

    private func removeAccount(_ account: AccountConfig) {
        guard AccountPrompt.confirmRemove(displayName: account.displayName) else { return }
        accountStore.remove(account)
    }
}

// MARK: - Panel root

struct PanelRootView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var state: PanelState
    @ObservedObject var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    var onHoverChanged: (Bool) -> Void
    var onRingHover: (String, CGFloat) -> Void
    @State private var stripHover = false

    private var palette: Palette { Palette.resolve(themeStore.theme, systemDark: colorScheme == .dark) }

    var body: some View {
        Group {
            if themeStore.placement == .notch {
                NotchBarView(store: store, themeStore: themeStore, state: state, onRingHover: onRingHover)
            } else {
                edgeBody
            }
        }
        .contentShape(Rectangle())
        .onHover(perform: onHoverChanged)
        .contextMenu { SettingsMenuItems(store: store, themeStore: themeStore) }
    }

    private var edgeBody: some View {
        ZStack(alignment: .trailing) {
            // Collapsed strip
            Surface(palette: palette, shape: LeftRoundedRect(radius: 6), tint: palette.stripTint)
                .frame(width: stripHover ? Layout.stripHoverWidth : Layout.stripWidth,
                       height: Layout.stripHeight)
                .opacity(state.isExpanded ? 0 : 1)
                .animation(.easeOut(duration: 0.2), value: stripHover)
                .onHover { stripHover = $0 }

            // Expanded tab
            TabView(store: store, themeStore: themeStore, palette: palette, onRingHover: onRingHover)
                .offset(x: state.isExpanded ? 0 : Layout.tabWidth * 1.1)
                .opacity(state.isExpanded ? 1 : 0)
                .allowsHitTesting(state.isExpanded)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .animation(.timingCurve(0.32, 0.9, 0.35, 1, duration: 0.38), value: state.isExpanded)
        .forcedColorScheme(palette.colorScheme)
    }
}

// MARK: - Detail bubble

@MainActor
final class DetailState: ObservableObject {
    @Published var snapshot: ProviderSnapshot?
    @Published var tailY: CGFloat = 60     // relative to the card's top edge
    @Published var tailX: CGFloat = 133    // relative to the card's left edge (tail on top)
    @Published var tailOnTop = false       // notch mode: card hangs below the ring
    @Published var visible = false
}

struct DetailBubbleView: View {
    @ObservedObject var state: DetailState
    @ObservedObject var store: UsageStore
    @ObservedObject var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    private var palette: Palette { Palette.resolve(themeStore.theme, systemDark: colorScheme == .dark) }

    var body: some View {
        let up = state.tailOnTop
        ZStack(alignment: .topLeading) {
            // Tail (behind the body so the overlap is hidden)
            Surface(palette: palette, shape: ArrowTailShape(up: up))
                .frame(width: up ? Layout.tailHeight : Layout.tailWidth,
                       height: up ? Layout.tailWidth : Layout.tailHeight)
                .offset(x: up ? state.tailX - Layout.tailHeight / 2 : Layout.cardWidth - 1,
                        y: up ? -(Layout.tailWidth - 1) : state.tailY - Layout.tailHeight / 2)
                .animation(.timingCurve(0.30, 0.90, 0.25, 1, duration: 0.4), value: state.tailY)
                .animation(.timingCurve(0.30, 0.90, 0.25, 1, duration: 0.4), value: state.tailX)

            // Body
            ZStack(alignment: .topLeading) {
                if let snap = state.snapshot {
                    DetailCardContent(snapshot: snap, palette: palette)
                        .id(snap.id)
                        .transition(.opacity.combined(with: .offset(y: 6)))
                }
            }
            .animation(.easeInOut(duration: 0.15), value: state.snapshot?.id)
            .padding(EdgeInsets(top: 13, leading: 15, bottom: 15, trailing: 15))
            .frame(width: Layout.cardWidth, alignment: .topLeading)
            .brinkSurface(palette,
                          shape: RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous),
                          border: true)
        }
        .padding(up ? .top : .trailing, Layout.tailRoom)
        .padding(Layout.shadowPad)
        .opacity(state.visible ? 1 : 0)
        .offset(x: state.visible || up ? 0 : 14, y: state.visible || !up ? 0 : -10)
        .animation(.spring(response: 0.42, dampingFraction: 0.68), value: state.visible)
        .contentShape(Rectangle())
        .contextMenu { SettingsMenuItems(store: store, themeStore: themeStore) }
        .forcedColorScheme(palette.colorScheme)
    }
}

struct DetailCardContent: View {
    let snapshot: ProviderSnapshot
    let palette: Palette


    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ProviderIcon(id: snapshot.id, size: 14.5, color: palette.fg)
                Text(L("%@ Usage", snapshot.name))
                    .font(.system(size: 14, weight: .semibold))
                if snapshot.isDemo {
                    Text(L("DEMO"))
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(palette.track))
                }
            }
            .foregroundColor(palette.fg)
            .padding(.bottom, 11)

            if snapshot.windows.isEmpty {
                Text(snapshot.error ?? L("No data"))
                    .font(.system(size: 12.5))
                    .foregroundColor(palette.muted)
            } else {
                ForEach(Array(snapshot.windows.enumerated()), id: \.element.id) { idx, window in
                    if let value = window.valueText {
                        HStack(alignment: .firstTextBaseline) {
                            Text(L(window.label))
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundColor(palette.fg)
                            Spacer()
                            Text(value)
                                .font(.system(size: 15, weight: .semibold))
                                .monospacedDigit()
                                .foregroundColor(UsageColor.color(for: snapshot, percent: window.usedPercent))
                        }
                        .padding(.bottom, idx == snapshot.windows.count - 1 ? 0 : 12)
                    } else {
                        HStack(alignment: .firstTextBaseline) {
                            Text(L(window.label))
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundColor(palette.fg)
                            Spacer()
                            if let reset = window.resetText {
                                Text(reset)
                                    .font(.system(size: 10.5))
                                    .foregroundColor(palette.muted)
                            }
                        }
                        .padding(.bottom, 6)

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 4).fill(palette.barTrack)
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(UsageColor.color(for: snapshot, percent: window.usedPercent))
                                    .frame(width: max(7, geo.size.width * window.fraction))
                            }
                        }
                        .frame(height: 4.5)
                        .padding(.bottom, 5.5)

                        Text(L("%d%% Used", Int(window.usedPercent.rounded())))
                            .font(.system(size: 10.5))
                            .foregroundColor(palette.soft)
                            .padding(.bottom, idx == snapshot.windows.count - 1 ? 0 : 12)
                    }
                }
            }

            if let error = snapshot.error, !snapshot.windows.isEmpty || snapshot.isDemo {
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundColor(.orange.opacity(0.9))
                    .lineLimit(2)
                    .padding(.top, 10)
            }
        }
        .legibilityShadow(palette.textShadow)
    }
}
