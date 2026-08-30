import Foundation

/// kenari.id has a real JSON API behind its dashboard (unlike Ollama Cloud):
/// `GET /api/subscription` returns 200 with usage data when the session
/// cookie `login` (a `WebLogin`) captured is valid, or 401 `"no session"`
/// otherwise — no HTML scraping needed.
final class KenariProvider: UsageProvider {
    let id = "kenari"

    static let login = WebLogin(
        id: "kenari", displayName: "Kenari",
        loginURL: URL(string: "https://kenari.id/login")!,
        host: "kenari.id",
        signinHints: ["login"],
        verify: { cookie in await KenariProvider.fetchSubscription(cookie: cookie) != nil }
    )

    private static let subscriptionURL = URL(string: "https://kenari.id/api/subscription")!

    func fetch() async -> ProviderSnapshot {
        var snap = ProviderSnapshot(id: id, name: "Kenari", systemImage: "cloud", windows: [], error: nil)
        guard let cookie = Self.login.loadCookie() else {
            return ClaudeProvider.demoSnapshot(id: id, name: "Kenari", systemImage: "cloud",
                                               note: L("Not signed in — Providers menu → Sign in to Kenari"))
        }

        guard let json = await Self.fetchSubscription(cookie: cookie) else {
            Self.login.clearCookie()
            snap.error = L("Session expired — sign in again from the Providers menu")
            return snap
        }
        snap.windows = Self.parseUsage(json)
        snap.updatedAt = Date()
        if snap.windows.isEmpty { snap.error = L("No usage data in response") }
        return snap
    }

    /// Returns the parsed `/api/subscription` body, or nil if the cookie
    /// doesn't actually authenticate (401) or the request otherwise failed.
    static func fetchSubscription(cookie: String) async -> [String: Any]? {
        var request = URLRequest(url: subscriptionURL)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("Brink/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    // MARK: Parsing

    /// `window_5h` / `window_week` / `window_month` are each either null or
    /// `{used_frac: 0-1, resets_in_secs: Int}` — whichever windows the
    /// current plan has active show up as their own ring segments.
    static func parseUsage(_ json: [String: Any]) -> [UsageWindow] {
        let windows: [(String, String)] = [
            ("window_5h", "5 hours"), ("window_week", "Weekly"), ("window_month", "Monthly"),
        ]
        var result: [UsageWindow] = []
        for (key, label) in windows {
            guard let win = json[key] as? [String: Any],
                  let usedFrac = win["used_frac"] as? Double else { continue }
            let resets = (win["resets_in_secs"] as? Double).map { Date().addingTimeInterval($0) }
            result.append(UsageWindow(label: label, usedPercent: usedFrac * 100, resetsAt: resets))
        }
        return result
    }
}
