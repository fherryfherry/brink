import Foundation

enum AccountKind: String, Codable, CaseIterable {
    case claude, codex, ollama, kenari, sumopod

    var label: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .ollama: return "Ollama"
        case .kenari: return "Kenari"
        case .sumopod: return "Sumopod AI"
        }
    }
}

/// One configured account/profile. `configDir` only applies to `.claude`
/// (a `CLAUDE_CONFIG_DIR`-style folder name under `~`, e.g. `.claude-work`)
/// and `.codex` (a `CODEX_HOME` folder name); Ollama/Kenari accounts are
/// distinguished purely by their own captured login cookie, keyed by `id`.
struct AccountConfig: Codable, Identifiable, Equatable {
    let id: String
    var kind: AccountKind
    var displayName: String
    var configDir: String?

    func makeProvider() -> UsageProvider {
        switch kind {
        case .claude:
            return ClaudeProvider(id: id, displayName: displayName, credentialsDir: configDir ?? ".claude")
        case .codex:
            return CodexProvider(id: id, displayName: displayName, codexHome: configDir)
        case .ollama:
            return OllamaProvider(id: id, displayName: displayName)
        case .kenari:
            return KenariProvider(id: id, displayName: displayName)
        case .sumopod:
            return SumopodProvider(id: id, displayName: displayName)
        }
    }
}

/// Persists the configured account list to
/// `~/Library/Application Support/Brink/accounts.json`. Seeded on first run
/// with the same single Claude + Codex accounts Brink always shipped with, so
/// upgrading doesn't change anyone's existing rings.
@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    @Published private(set) var accounts: [AccountConfig]

    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Brink", isDirectory: true)
            .appendingPathComponent("accounts.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let decoded = try? JSONDecoder().decode([AccountConfig].self, from: data), !decoded.isEmpty {
            accounts = decoded
        } else {
            // Matches what Brink always shipped with (Claude + Codex only) — Ollama,
            // Kenari, or a second Claude/Codex profile are per-user setups, added via
            // Providers > Accounts > Add account, not something to guess a default for.
            accounts = [
                AccountConfig(id: "claude", kind: .claude, displayName: "Claude", configDir: ".claude"),
                AccountConfig(id: "codex", kind: .codex, displayName: "Codex", configDir: nil),
            ]
            save()
        }
    }

    @discardableResult
    func add(kind: AccountKind, displayName: String, configDir: String?) -> AccountConfig {
        let id = "\(kind.rawValue)-\(UUID().uuidString.prefix(8))"
        let config = AccountConfig(id: id, kind: kind, displayName: displayName, configDir: configDir)
        accounts.append(config)
        save()
        return config
    }

    func remove(_ account: AccountConfig) {
        accounts.removeAll { $0.id == account.id }
        save()
        cleanUpCredentials(for: account)
    }

    /// Best-effort — leftover cache files are harmless, just unused bytes,
    /// but no reason to keep them around once the account itself is gone.
    private func cleanUpCredentials(for account: AccountConfig) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Brink", isDirectory: true)
        switch account.kind {
        case .claude:
            let file = account.id == "claude" ? "credentials.json" : "credentials-\(account.id).json"
            try? FileManager.default.removeItem(at: support.appendingPathComponent(file))
        case .codex:
            break // Codex reads Codex CLI's own auth.json; Brink caches nothing for it.
        case .sumopod:
            UserDefaults.standard.removeObject(forKey: "sumopodLoginHint-\(account.id)")
        case .ollama, .kenari:
            break // WebLogin reads live from WKWebsiteDataStore now; nothing on disk to remove.
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        let dir = Self.fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
