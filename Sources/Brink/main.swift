import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: UsageStore!
    private var themeStore: ThemeStore!
    private var controller: PanelController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = UsageStore(providers: [
            ClaudeProvider(),
            ClaudeProvider(id: "claude-work", displayName: "Claude (work)",
                           credentialsDir: ".claude-work"),
            CodexProvider(),
            OllamaProvider(),
        ])
        themeStore = ThemeStore()
        Notifier.shared.requestAuthorizationIfNeeded()
        controller = PanelController(store: store, themeStore: themeStore)
        store.startAutoRefresh(interval: 120)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // no Dock icon, no menu bar
let delegate = AppDelegate()
app.delegate = delegate
app.run()
