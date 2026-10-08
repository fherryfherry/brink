import Foundation
import SwiftUI
import Combine

// MARK: - Data model

struct UsageWindow: Identifiable {
    var id: String { label }
    var label: String            // "Current session", "All models (weekly)"...
    var usedPercent: Double      // 0...100
    var resetsAt: Date?
    var valueText: String? = nil // shown instead of a percent for non-quota windows, e.g. a "$2.99" balance

    var isBalance: Bool { valueText != nil }
    var fraction: Double { min(max(usedPercent / 100.0, 0), 1) }

    var resetText: String? {
        guard let resetsAt else { return nil }
        let seconds = resetsAt.timeIntervalSinceNow
        if seconds <= 0 { return L("Resets soon") }
        if seconds < 3600 {
            return L("Resets in %d min", Int(seconds / 60))
        }
        if seconds < 86400 {
            let h = Int(seconds / 3600)
            let m = Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)
            return m > 0 ? L("Resets in %d h %d min", h, m) : L("Resets in %d h", h)
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE HH:mm"
        return L("Resets %@", fmt.string(from: resetsAt))
    }
}

struct ProviderSnapshot: Identifiable {
    let id: String               // "claude", "codex"
    var name: String
    var systemImage: String
    var windows: [UsageWindow]
    var error: String?
    var isDemo: Bool = false
    var accent: Color? = nil     // fixed brand color; nil = percent-based scale
    var updatedAt: Date?

    var primary: UsageWindow? { windows.first }
}

// MARK: - Ring color scale

enum UsageColor {
    static let claudeOrange = Color(red: 0.85, green: 0.47, blue: 0.34) // #D97757

    static func color(for snapshot: ProviderSnapshot, percent: Double) -> Color {
        snapshot.accent ?? color(for: percent)
    }

    static func color(for percent: Double) -> Color {
        if percent < 50.0 { return Color(red: 0x2f/255, green: 0xd4/255, blue: 0x87/255) } // #2FD487
        if percent < 70.0 { return Color(red: 0xf2/255, green: 0xdf/255, blue: 0x2a/255) } // #F2DF2A
        return Color(red: 1.0, green: 0x44/255, blue: 0.0)                                 // #FF4400
    }
}

// MARK: - Provider protocol

protocol UsageProvider {
    var id: String { get }
    func fetch() async -> ProviderSnapshot
}

// MARK: - Store

@MainActor
final class UsageStore: ObservableObject {
    @Published var snapshots: [ProviderSnapshot] = []
    @Published var lastRefresh: Date?
    /// Provider ids currently mid-fetch, so rings can show a spinner instead
    /// of silently sitting there (or silently failing) with no feedback.
    @Published var refreshingIDs: Set<String> = []

    private var providers: [UsageProvider] = []
    private var timer: Timer?
    private var accountsObserver: AnyCancellable?

    /// Providers are rebuilt from `AccountStore.shared.accounts` whenever it
    /// changes (an account added/removed from the menu), rather than fixed at
    /// launch — snapshots for accounts that still exist are kept as-is, new
    /// ones get fetched immediately, removed ones just drop off.
    init() {
        // @Published's publisher replays the current value to new subscribers
        // immediately, so this alone also does the initial build.
        accountsObserver = AccountStore.shared.$accounts.sink { [weak self] configs in
            self?.rebuildProviders(from: configs)
        }
    }

    /// Looks up the `WebLogin` for an Ollama/Kenari account so the menu can
    /// present its sign-in window (Claude/Codex read local credentials, so
    /// they have no login flow to trigger from here).
    func webLogin(for id: String) -> WebLogin? {
        switch providers.first(where: { $0.id == id }) {
        case let p as OllamaProvider: return p.login
        case let p as KenariProvider: return p.login
        case let p as SumopodProvider: return p.login
        default: return nil
        }
    }

    private func rebuildProviders(from configs: [AccountConfig]) {
        let newProviders = configs.map { $0.makeProvider() }
        let newOrder = newProviders.map(\.id)
        let newIDs = Set(newOrder)
        let existingIDs = Set(snapshots.map(\.id))

        var kept = snapshots.filter { newIDs.contains($0.id) }
        for provider in newProviders where !existingIDs.contains(provider.id) {
            kept.append(ProviderSnapshot(id: provider.id, name: provider.id.capitalized,
                                         systemImage: "hourglass", windows: [], error: nil))
        }
        kept.sort { (newOrder.firstIndex(of: $0.id) ?? 0) < (newOrder.firstIndex(of: $1.id) ?? 0) }

        providers = newProviders
        snapshots = kept

        let addedIDs = newIDs.subtracting(existingIDs)
        if !addedIDs.isEmpty { refresh(ids: addedIDs) }
    }

    func startAutoRefresh(interval: TimeInterval = 120) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.refreshAll() }
        }
        refreshAll()
    }

    func refreshAll() {
        refresh(ids: Set(providers.map(\.id)))
    }

    private func refresh(ids requested: Set<String>) {
        // Skip ids already mid-fetch, e.g. launch's initial build and the timer's first tick firing together.
        let ids = requested.subtracting(refreshingIDs)
        guard !ids.isEmpty else { return }
        refreshingIDs.formUnion(ids)
        Task {
            // Sequential, not parallel: providers share rate-limited endpoints
            // (see ClaudeProvider's 429 backoff), so fetching them all at once
            // would just make that worse. Updating the store as each one
            // finishes (instead of batching until the last one lands) is what
            // makes the per-ring spinner actually mean something.
            for provider in providers where ids.contains(provider.id) {
                let snap = await provider.fetch()
                if let idx = snapshots.firstIndex(where: { $0.id == provider.id }) {
                    snapshots[idx] = snap
                } else {
                    snapshots.append(snap)
                }
                refreshingIDs.remove(provider.id)
            }
            lastRefresh = Date()
            Notifier.shared.observe(snapshots)
        }
    }
}
