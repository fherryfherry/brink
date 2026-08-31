import Foundation

/// Ollama Cloud has no documented usage/quota API (see
/// github.com/ollama/ollama issues #16448, #15663) — the only place the
/// numbers exist is the server-rendered `ollama.com/settings` page. This
/// scrapes that page's HTML with the session cookie `login` (a `WebLogin`)
/// captured. Fragile by nature: breaks if Ollama changes that page's markup,
/// and there is no refresh-token dance, so an expired cookie just asks the
/// user to sign in again.
final class OllamaProvider: UsageProvider {
    let id: String
    let displayName: String
    let login: WebLogin

    init(id: String = "ollama", displayName: String = "Ollama") {
        self.id = id
        self.displayName = displayName
        self.login = WebLogin(
            id: id, displayName: displayName,
            loginURL: URL(string: "https://ollama.com/signin")!,
            host: "ollama.com",
            // The sign-in form itself lives on the `signin.ollama.com` subdomain
            // (path "/"), so "signin" has to be checked in the host too, not just
            // a `/signin` path on the main domain.
            signinHints: ["signin"],
            verify: { cookie in (try? await OllamaProvider.fetchSettingsHTML(cookie: cookie)) != nil }
        )
    }

    private static let settingsURL = URL(string: "https://ollama.com/settings")!
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    func fetch() async -> ProviderSnapshot {
        var snap = ProviderSnapshot(id: id, name: displayName, systemImage: "cloud", windows: [], error: nil)
        guard let cookie = login.loadCookie() else {
            return ClaudeProvider.demoSnapshot(id: id, name: displayName, systemImage: "cloud",
                                               note: L("Not signed in — Providers menu → Sign in to Ollama"))
        }

        do {
            guard let html = try await Self.fetchSettingsHTML(cookie: cookie) else {
                login.clearCookie()
                snap.error = L("Session expired — sign in again from the Providers menu")
                return snap
            }
            snap.windows = Self.parseUsage(html)
            snap.updatedAt = Date()
            if snap.windows.isEmpty { snap.error = L("No usage data found on page") }
            return snap
        } catch {
            snap.error = error.localizedDescription
            return snap
        }
    }

    /// Fetches the settings page with the given cookie header. Returns nil
    /// (rather than throwing) if the cookie doesn't actually authenticate —
    /// i.e. the request got bounced to the sign-in form, which lives on the
    /// `signin.ollama.com` subdomain (path "/"), so the host has to be
    /// checked too, not just the path.
    static func fetchSettingsHTML(cookie: String) async throws -> String? {
        var request = URLRequest(url: settingsURL)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let finalURL = (response as? HTTPURLResponse)?.url ?? request.url
        if finalURL?.host?.contains("signin") == true || finalURL?.path.contains("signin") == true {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Parsing (scraped from the rendered HTML, not a JSON API)

    static func parseUsage(_ html: String) -> [UsageWindow] {
        var windows: [UsageWindow] = []
        if let pct = percent(after: "Session usage", in: html) {
            windows.append(UsageWindow(label: "Session", usedPercent: pct,
                                       resetsAt: relativeReset(after: "Sessions resume in", in: html)))
        }
        if let pct = percent(after: "Weekly usage", in: html) {
            windows.append(UsageWindow(label: "Weekly", usedPercent: pct,
                                       resetsAt: relativeReset(after: "Resets in", in: html)))
        }
        return windows
    }

    /// Matches `<label>usage</span> ... <span ...>N% used</span>` (or textual
    /// states like "Weekly limit reached", treated as 100%).
    private static func percent(after anchor: String, in html: String) -> Double? {
        let pattern = "\(NSRegularExpression.escapedPattern(for: anchor))</span>\\s*<span[^>]*>\\s*([^<]+?)\\s*</span"
        guard let text = firstMatch(pattern, in: html) else { return nil }
        if let digits = firstMatch("(\\d+)\\s*%", in: text) { return Double(digits) }
        return 100 // e.g. "Weekly limit reached" / "Session limit reached"
    }

    /// Matches `<anchor> N hour(s)/minute(s)/day(s).` and turns it into an absolute date.
    private static func relativeReset(after anchor: String, in html: String) -> Date? {
        guard let phrase = firstMatch("\(NSRegularExpression.escapedPattern(for: anchor))\\s*([^.<]+)\\.", in: html),
              let match = phrase.range(of: #"(\d+)\s*(minute|hour|day)s?"#, options: .regularExpression) else {
            return nil
        }
        let parts = phrase[match].split(separator: " ")
        guard parts.count >= 2, let count = Double(parts[0]) else { return nil }
        let unit = parts[1]
        let seconds: Double
        if unit.hasPrefix("minute") { seconds = count * 60 }
        else if unit.hasPrefix("hour") { seconds = count * 3600 }
        else { seconds = count * 86400 }
        return Date().addingTimeInterval(seconds)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }
}
