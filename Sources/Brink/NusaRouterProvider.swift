import Foundation

/// nusarouter.com dashboard session cookie (`nr_session`, httpOnly) from `login`,
/// read against its JSON account API: balance, plan token allowance, and keys.
final class NusaRouterProvider: UsageProvider {
    let id: String
    let displayName: String
    let login: WebLogin

    private static let apiBase = "https://api.nusarouter.com"

    init(id: String = "nusarouter", displayName: String = "NusaRouter") {
        self.id = id
        self.displayName = displayName
        self.login = WebLogin(
            id: id, displayName: displayName,
            loginURL: URL(string: "https://nusarouter.com/login")!,
            host: "nusarouter.com",
            signinHints: ["login", "register"],
            customUserAgent: SumopodProvider.userAgent,
            verify: { cookie in await NusaRouterProvider.fetchBalance(cookie: cookie) != nil }
        )
    }

    func fetch() async -> ProviderSnapshot {
        var snap = ProviderSnapshot(id: id, name: displayName, systemImage: "cloud", windows: [], error: nil)
        guard let cookie = await login.currentCookieHeader() else {
            return ClaudeProvider.demoSnapshot(id: id, name: displayName, systemImage: "cloud",
                                               note: L("Not signed in — Providers menu → Sign in to %@", displayName))
        }
        guard let balance = await Self.fetchBalance(cookie: cookie) else {
            snap.error = L("Session expired — sign in again from the Providers menu")
            return snap
        }
        var windows: [UsageWindow] = []
        if let lowest = await Self.fetchLowestPlanUsage(cookie: cookie) {
            windows.append(lowest)
        }
        // Balance last: a zero balance is what gates requests when no plan is left.
        windows.append(UsageWindow(label: "Balance", usedPercent: balance > 0 ? 0 : 100,
                                   valueText: "Balance", detail: SumopodProvider.formatUSD(balance)))
        snap.windows = windows
        snap.updatedAt = Date()
        return snap
    }

    // MARK: API

    static func fetchJSON(_ path: String, cookie: String) async -> (json: [String: Any]?, status: Int) {
        guard let url = URL(string: apiBase + path) else { return (nil, 0) }
        var request = URLRequest(url: url)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("Brink/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return (nil, 0) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (json, status)
    }

    static func fetchBalance(cookie: String) async -> Double? {
        let (json, status) = await fetchJSON("/account/balance", cookie: cookie)
        guard status == 200 else { return nil }
        return ClaudeProvider.number(json?["balance_usd"])
    }

    /// The plan with the least headroom left (token allowance), or nil when no plan is active.
    static func fetchLowestPlanUsage(cookie: String) async -> UsageWindow? {
        let (json, status) = await fetchJSON("/account/subscriptions", cookie: cookie)
        guard status == 200, let subs = json?["data"] as? [[String: Any]] else { return nil }
        let active = subs.filter { ($0["status"] as? String) == "active" }
        guard !active.isEmpty else { return nil }
        let remaining = active.map { sub -> Double in
            let cap = ClaudeProvider.number(sub["token_cap"]) ?? 0
            let used = ClaudeProvider.number(sub["tokens_used"]) ?? 0
            return cap > 0 ? max(cap - used, 0) : .infinity
        }
        guard let idx = remaining.indices.min(by: { remaining[$0] < remaining[$1] }) else { return nil }
        let sub = active[idx]
        let cap = ClaudeProvider.number(sub["token_cap"]) ?? 0
        let used = ClaudeProvider.number(sub["tokens_used"]) ?? 0
        guard cap > 0 else { return nil }
        let name = (sub["plan_name"] as? String) ?? "Plan"
        let resets = parseDate(sub["period_end"])
        return UsageWindow(label: name, usedPercent: min(used / cap * 100, 100), resetsAt: resets)
    }

    /// `period_end` arrives as `"2026-11-27 07:39:45"` in UTC.
    static func parseDate(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return fmt.date(from: s)
    }
}
