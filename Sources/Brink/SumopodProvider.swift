import Foundation

/// Supabase session from `localStorage["sumopod-auth"]` as a Bearer token; the site's own JS refreshes it, never Brink.
final class SumopodProvider: UsageProvider {
    let id: String
    let displayName: String
    let login: WebLogin

    private static let balanceURL = URL(string: "https://api-gate-v2.sumopod.com/webhook/sumopod/ai/balance")!
    private static let sessionKey = "sumopod-auth"
    // Google sign-in refuses embedded WKWebViews with the default user agent.
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    init(id: String = "sumopod", displayName: String = "Sumopod AI") {
        self.id = id
        self.displayName = displayName
        self.login = WebLogin(
            id: id, displayName: displayName,
            loginURL: URL(string: "https://sumopod.com/login")!,
            host: "sumopod.com",
            signinHints: ["login", "register", "auth"],
            session: .localStorage(key: Self.sessionKey,
                                   isFresh: { Session(json: $0)?.isExpired == false },
                                   silentReauthURL: { [hintKey = Self.hintKey(id)] last in
                                       let session = last.flatMap(Session.init(json:))
                                       guard session == nil || session?.provider == "google",
                                             let email = session?.email ?? UserDefaults.standard.string(forKey: hintKey)
                                       else { return nil }
                                       return SumopodProvider.googleReauthURL(email: email)
                                   }),
            customUserAgent: Self.userAgent,
            verify: { json in
                guard let token = Session(json: json)?.accessToken else { return false }
                return await SumopodProvider.fetchBalance(token: token).balance != nil
            }
        )
    }

    // Google account to hint a silent re-sign-in with, kept even after the site wipes its session.
    private static func hintKey(_ id: String) -> String { "sumopodLoginHint-\(id)" }

    private static let supabaseAuthorizeURL = "https://dhsrwbufpdvuptdzeieo.supabase.co/auth/v1/authorize"

    /// Supabase forwards `prompt`/`login_hint` to Google, so this signs back in with no UI while Google's own session is alive.
    static func googleReauthURL(email: String) -> URL? {
        var components = URLComponents(string: supabaseAuthorizeURL)
        components?.queryItems = [
            URLQueryItem(name: "provider", value: "google"),
            URLQueryItem(name: "redirect_to", value: "https://sumopod.com/auth/callback"),
            URLQueryItem(name: "prompt", value: "none"),
            URLQueryItem(name: "login_hint", value: email),
        ]
        return components?.url
    }

    struct Session {
        var accessToken: String
        var expiresAt: Date?
        var email: String?
        var provider: String?

        var isExpired: Bool { expiresAt.map { $0.timeIntervalSinceNow < 60 } ?? false }

        init?(json: String) {
            guard let root = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
                  let token = root["access_token"] as? String else { return nil }
            accessToken = token
            expiresAt = ClaudeProvider.number(root["expires_at"]).map { Date(timeIntervalSince1970: $0) }
            let user = root["user"] as? [String: Any]
            email = user?["email"] as? String
            provider = (user?["app_metadata"] as? [String: Any])?["provider"] as? String
        }
    }

    // Reused until it expires, so the offscreen page only loads about once an hour.
    private var cachedSession: Session?

    func fetch() async -> ProviderSnapshot {
        var snap = ProviderSnapshot(id: id, name: displayName, systemImage: "dollarsign.circle",
                                    windows: [], error: nil)
        let session: Session
        if let cached = cachedSession, !cached.isExpired {
            session = cached
        } else if let json = await login.currentCredential(), let fresh = Session(json: json) {
            session = fresh
            if fresh.provider == "google", let email = fresh.email {
                UserDefaults.standard.set(email, forKey: Self.hintKey(id))
            }
        } else {
            cachedSession = nil
            var demo = ClaudeProvider.demoSnapshot(id: id, name: displayName, systemImage: "dollarsign.circle",
                                                   note: L("Not signed in — Providers menu → Sign in to %@", displayName))
            demo.windows = [Self.balanceWindow(2.99)]
            return demo
        }
        guard !session.isExpired else {
            cachedSession = nil
            snap.error = L("Session expired — sign in again from the Providers menu")
            return snap
        }

        let (balance, status) = await Self.fetchBalance(token: session.accessToken)
        guard let balance else {
            cachedSession = nil
            snap.error = status == 401
                ? L("Session expired — sign in again from the Providers menu")
                : L("HTTP %d", status)
            return snap
        }
        cachedSession = session
        snap.windows = [Self.balanceWindow(balance)]
        snap.updatedAt = Date()
        return snap
    }

    /// A zero/negative balance reads as "fully used" so the ring turns red.
    static func balanceWindow(_ balance: Double) -> UsageWindow {
        UsageWindow(label: "AI balance", usedPercent: balance > 0 ? 0 : 100, resetsAt: nil,
                    valueText: formatUSD(balance))
    }

    static func formatUSD(_ value: Double) -> String {
        let sign = value < 0 ? "-" : ""
        let v = abs(value)
        if v < 100 { return String(format: "%@$%.2f", sign, v) }
        if v < 10_000 { return String(format: "%@$%.0f", sign, v) }
        return String(format: "%@$%.1fk", sign, v / 1000)
    }

    static func fetchBalance(token: String) async -> (balance: Double?, status: Int) {
        var request = URLRequest(url: balanceURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://sumopod.com", forHTTPHeaderField: "Origin")
        request.setValue("Brink/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return (nil, 0) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let balance = ClaudeProvider.number(json["balance"]) else { return (nil, status) }
        return (balance, status)
    }
}
