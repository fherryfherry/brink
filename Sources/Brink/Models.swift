import Foundation
import SwiftUI

// MARK: - Data model

struct UsageWindow: Identifiable {
    var id: String { label }
    var label: String            // "Current session", "All models (weekly)"...
    var usedPercent: Double      // 0...100
    var resetsAt: Date?

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

    private let providers: [UsageProvider]
    private var timer: Timer?

    init(providers: [UsageProvider]) {
        self.providers = providers
        self.snapshots = providers.map {
            ProviderSnapshot(id: $0.id, name: $0.id.capitalized,
                             systemImage: "hourglass", windows: [], error: nil)
        }
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
        Task {
            await MainActor.run { self.refreshingIDs.formUnion(self.providers.map(\.id)) }
            // Sequential, not parallel: providers share rate-limited endpoints
            // (see ClaudeProvider's 429 backoff), so fetching them all at once
            // would just make that worse. Updating the store as each one
            // finishes (instead of batching until the last one lands) is what
            // makes the per-ring spinner actually mean something.
            for provider in providers {
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
