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

/// Arrow tail pointing right (mockup v3: `polygon(0 0, 100% 50%, 0 100%)`).
struct ArrowTailShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
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
        for (key, file) in [("claude", "claude"), ("codex", "openai")] {
            if let url = Bundle.module.url(forResource: file, withExtension: "png"),
               let img = NSImage(contentsOf: url) {
                img.isTemplate = true
                dict[key] = img
            }
        }
        return dict
    }()

    // Multiple accounts for the same CLI (e.g. "claude-work") share that CLI's logo/glyph.
    private var logoKey: String {
        id.hasPrefix("claude") ? "claude" : (id.hasPrefix("codex") ? "codex" : id)
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

struct UsageRing: View {
    let snapshot: ProviderSnapshot
    let palette: Palette
    @State private var hovering = false

    private var percent: Double { snapshot.primary?.usedPercent ?? 0 }
    private var hasData: Bool { !snapshot.windows.isEmpty }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(palette.track, lineWidth: 5)
                Circle()
                    .trim(from: 0, to: hasData ? (snapshot.primary?.fraction ?? 0) : 0)
                    .stroke(UsageColor.color(for: snapshot, percent: percent),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.6), value: percent)
                ProviderIcon(id: snapshot.id, size: 18, color: palette.fg)
            }
            .frame(width: Layout.ringSize, height: Layout.ringSize)
            .scaleEffect(hovering ? 1.08 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.55), value: hovering)
            .opacity(hasData ? 1 : 0.35)

            Text(hasData ? "\(Int(percent.rounded()))%" : "--")
                .font(.system(size: 13.5, weight: .semibold))
                .monospacedDigit()
                .foregroundColor(palette.fg)
        }
        .frame(height: Layout.ringBlockHeight)
        .legibilityShadow(palette.textShadow)
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
                UsageRing(snapshot: snap, palette: palette)
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

// MARK: - Settings menu (shared by the edge panel and the detail card)

struct SettingsMenuItems: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var themeStore: ThemeStore

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
        Picker(L("Appearance"), selection: $themeStore.theme) {
            ForEach(Theme.allCases) { Text($0.title).tag($0) }
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
        Button(L("Sign in to Ollama")) {
            OllamaLogin.shared.presentLogin { store.refreshAll() }
        }
        Divider()
        Button(L("Quit Brink")) { NSApp.terminate(nil) }
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
        .contentShape(Rectangle())
        .onHover(perform: onHoverChanged)
        .contextMenu { SettingsMenuItems(store: store, themeStore: themeStore) }
        .animation(.timingCurve(0.32, 0.9, 0.35, 1, duration: 0.38), value: state.isExpanded)
        .forcedColorScheme(palette.colorScheme)
    }
}

// MARK: - Detail bubble

@MainActor
final class DetailState: ObservableObject {
    @Published var snapshot: ProviderSnapshot?
    @Published var tailY: CGFloat = 60     // relative to the card's top edge
    @Published var visible = false
}

struct DetailBubbleView: View {
    @ObservedObject var state: DetailState
    @ObservedObject var store: UsageStore
    @ObservedObject var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    private var palette: Palette { Palette.resolve(themeStore.theme, systemDark: colorScheme == .dark) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Tail (behind the body so the overlap is hidden)
            Surface(palette: palette, shape: ArrowTailShape())
                .frame(width: Layout.tailWidth, height: Layout.tailHeight)
                .offset(x: Layout.cardWidth - 1,
                        y: state.tailY - Layout.tailHeight / 2)
                .animation(.timingCurve(0.30, 0.90, 0.25, 1, duration: 0.4), value: state.tailY)

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
        .padding(.trailing, Layout.tailRoom)
        .padding(Layout.shadowPad)
        .opacity(state.visible ? 1 : 0)
        .offset(x: state.visible ? 0 : 14)
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
