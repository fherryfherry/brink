import SwiftUI
import AppKit

// MARK: - Theme choice (persisted)

enum Theme: String, CaseIterable, Identifiable {
    case black, glass, system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .black: return L("Black")
        case .glass: return L("Liquid Glass")
        case .system: return L("System")
        }
    }
}

// MARK: - Panel placement (persisted)

enum Placement: String, CaseIterable, Identifiable {
    case edge, notch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .edge: return L("Right edge")
        case .notch: return L("Notch")
        }
    }
}

@MainActor
final class ThemeStore: ObservableObject {
    private static let key = "theme"
    private static let placementKey = "placement"

    @Published var theme: Theme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Self.key) }
    }

    @Published var placement: Placement {
        didSet { UserDefaults.standard.set(placement.rawValue, forKey: Self.placementKey) }
    }

    /// "" = system default; otherwise a code from L10n.available. Changing it
    /// re-renders every view (they observe this store), so it applies instantly.
    @Published var language: String = L10n.override {
        didSet { L10n.override = language }
    }

    // MARK: Provider visibility (Providers menu). At least one always stays visible.

    private static let hiddenKey = "hiddenProviders"

    @Published var hiddenProviders: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: ThemeStore.hiddenKey) ?? []) {
        didSet { UserDefaults.standard.set(Array(hiddenProviders).sorted(), forKey: Self.hiddenKey) }
    }

    func setVisible(_ id: String, _ visible: Bool, all: [String]) {
        if visible {
            hiddenProviders.remove(id)
        } else if all.filter({ !hiddenProviders.contains($0) }).count > 1 {
            hiddenProviders.insert(id)
        }
    }

    func visible(_ snapshots: [ProviderSnapshot]) -> [ProviderSnapshot] {
        let shown = snapshots.filter { !hiddenProviders.contains($0.id) }
        return shown.isEmpty ? snapshots : shown
    }

    init() {
        theme = Theme(rawValue: UserDefaults.standard.string(forKey: Self.key) ?? "") ?? .black
        placement = Placement(rawValue: UserDefaults.standard.string(forKey: Self.placementKey) ?? "") ?? .edge
    }
}

// MARK: - Resolved palette

struct Palette {
    var isGlass: Bool
    var isDark: Bool

    var fg: Color
    var muted: Color
    var soft: Color
    var track: Color
    var barTrack: Color
    var cardBorder: Color
    var tint: Color        // colour laid over the blur (or the solid surface for .black)
    var stripTint: Color
    var textShadow: Bool = false   // soft shadow under text/icons (clear glass over photos)

    static func resolve(_ theme: Theme, systemDark: Bool) -> Palette {
        switch theme {
        case .black:
            return Palette(
                isGlass: false, isDark: true,
                fg: .white,
                muted: .white.opacity(0.48),
                soft: .white.opacity(0.72),
                track: .white.opacity(0.16),
                barTrack: .white.opacity(0.17),
                cardBorder: .clear,
                tint: Color(red: 8/255, green: 8/255, blue: 10/255).opacity(0.95),
                stripTint: Color(red: 10/255, green: 10/255, blue: 12/255).opacity(0.88)
            )
        case .glass, .system:
            // Both are adaptive on macOS 26; on older systems they fall back to
            // frosted blur following (glass = light) / (system = light or dark).
            if #available(macOS 26, *) { return adaptive }
            return theme == .system && systemDark ? dark : light
        }
    }

    private static let light = Palette(
        isGlass: true, isDark: false,
        fg: Color(red: 0x17/255, green: 0x17/255, blue: 0x1c/255),
        muted: Color(red: 15/255, green: 20/255, blue: 30/255).opacity(0.52),
        soft: Color(red: 15/255, green: 20/255, blue: 30/255).opacity(0.74),
        track: Color(red: 15/255, green: 20/255, blue: 30/255).opacity(0.15),
        barTrack: Color(red: 15/255, green: 20/255, blue: 30/255).opacity(0.14),
        cardBorder: .white.opacity(0.65),
        tint: .white.opacity(0.22),
        stripTint: .white.opacity(0.45)
    )

    /// Adaptive glass: Apple's regular Liquid Glass flips light/dark from what is
    /// behind it, and `.primary` / `.secondary` follow it (vibrancy), so type stays
    /// legible over a white web page and over a dark wallpaper alike.
    private static let adaptive = Palette(
        isGlass: true, isDark: false,
        fg: .primary,
        muted: .secondary,
        soft: .primary.opacity(0.8),
        track: .primary.opacity(0.18),
        barTrack: .primary.opacity(0.18),
        cardBorder: .clear,
        tint: .clear,
        stripTint: .white.opacity(0.35),
        textShadow: false
    )

    private static let dark = Palette(
        isGlass: true, isDark: true,
        fg: .white,
        muted: .white.opacity(0.52),
        soft: .white.opacity(0.76),
        track: .white.opacity(0.18),
        barTrack: .white.opacity(0.18),
        cardBorder: .white.opacity(0.16),
        tint: .black.opacity(0.28),
        stripTint: .white.opacity(0.25),
        textShadow: true
    )

    var colorScheme: ColorScheme? { fg == .primary ? nil : (isDark ? .dark : .light) }  // nil = don't force
    var appearance: NSAppearance.Name { isDark ? .darkAqua : .aqua }
    var material: NSVisualEffectView.Material { isDark ? .hudWindow : .popover }
}

// MARK: - Blur (backdrop) view

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var appearance: NSAppearance.Name

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.blendingMode = .behindWindow
        v.state = .active
        v.isEmphasized = true
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.appearance = NSAppearance(named: appearance)
    }
}

// MARK: - Surface = glass (or blur fallback) clipped to any shape
//
// macOS 26+  → real Liquid Glass via SwiftUI `.glassEffect(in:)`. The *content* is
//              placed inside the glass so its type gets adaptive vibrancy.
// macOS 13–15 → NSVisualEffectView blur + tint overlay ("frosted glass").

extension View {
    /// Wraps `self` in a themed surface of the given shape.
    @ViewBuilder
    func brinkSurface<S: Shape>(_ palette: Palette, shape: S, tint: Color? = nil, border: Bool = false) -> some View {
        if palette.isGlass {
            if #available(macOS 26, *) {
                self.glassEffect(.regular.interactive(), in: shape)
            } else {
                self.background(FrostedFallback(palette: palette, shape: shape, tint: tint, border: border))
            }
        } else {
            self.background(shape.fill(tint ?? palette.tint))
        }
    }
}

/// A content-less surface (strip, tail).
struct Surface<S: Shape>: View {
    var palette: Palette
    var shape: S
    var tint: Color? = nil
    var border: Bool = false

    var body: some View {
        Color.clear.brinkSurface(palette, shape: shape, tint: tint, border: border)
    }
}

struct FrostedFallback<S: Shape>: View {
    var palette: Palette
    var shape: S
    var tint: Color?
    var border: Bool

    var body: some View {
        ZStack {
            // Give the AppKit view an explicit, finite frame: SwiftUI may otherwise
            // hand it NaN during the first layout pass (AppKit asserts on that).
            GeometryReader { geo in
                let w = geo.size.width.isFinite ? max(geo.size.width, 1) : 1
                let h = geo.size.height.isFinite ? max(geo.size.height, 1) : 1
                VisualEffectBlur(material: palette.material, appearance: palette.appearance)
                    .frame(width: w, height: h)
            }
            .clipShape(shape)
            shape.fill(tint ?? palette.tint)
            if border {
                shape.stroke(palette.cardBorder, lineWidth: 1)
            }
        }
    }
}
