import AppKit
import WebKit

/// Presents a small in-app WKWebView so the user can sign in to ollama.com
/// (no official API key covers Cloud usage/quota, see `OllamaProvider`).
/// The WKWebView uses its own persistent data store, separate from — and
/// never touching — the user's system Chrome/Safari cookies. The captured
/// ollama.com session cookie is additionally written to disk, scoped to that
/// one domain, for `OllamaProvider` to use outside the WebView.
final class OllamaLogin: NSObject, WKNavigationDelegate, NSWindowDelegate {
    static let shared = OllamaLogin()

    private var window: NSWindow?
    private var webView: WKWebView?
    private var onComplete: (() -> Void)?
    private var isVerifying = false

    nonisolated private static var cookieFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Brink", isDirectory: true)
            .appendingPathComponent("ollama-cookie.json")
    }

    nonisolated static func loadCookie() -> String? {
        guard let data = try? Data(contentsOf: cookieFileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cookie = obj["cookie"] as? String, !cookie.isEmpty else { return nil }
        return cookie
    }

    nonisolated static func clearCookie() {
        try? FileManager.default.removeItem(at: cookieFileURL)
    }

    private static func saveCookie(_ cookie: String) {
        let dir = cookieFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONSerialization.data(withJSONObject: [
            "cookie": cookie, "savedAt": Date().timeIntervalSince1970,
        ]) else { return }
        try? data.write(to: cookieFileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cookieFileURL.path)
    }

    func presentLogin(onComplete: @escaping () -> Void) {
        PanelController.collapseSuspended = true
        self.onComplete = onComplete

        let config = WKWebViewConfiguration()
        // Persistent (not `.nonPersistent()`): Brink's own WKWebView storage, kept
        // between launches, so signing in is a one-time thing — next time this
        // opens (e.g. after the captured cookie expires) it's already logged in.
        // Still fully isolated from the system Chrome/Safari the user actually
        // browses with; there's no supported way to borrow another browser's live
        // session without reading its cookie store wholesale, which is a much
        // bigger permission than this needs.
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: config)
        webView.navigationDelegate = self
        self.webView = webView

        let window = NSWindow(contentRect: webView.frame, styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = L("Sign in to Ollama")
        window.contentView = webView
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        // Same treatment the edge panels get (see PanelController.configure): a plain
        // window can't join a fullscreen Space, so macOS parks it on the desktop Space
        // and it looks like it vanished the moment focus returns to a fullscreen app.
        window.level = .floating
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.window = window

        // Brink is a Dock-less accessory app (no Dock icon, no Cmd+Tab entry). A plain
        // window opened that way has no way back once focus leaves it, which looks like
        // it silently vanished. Go `.regular` for the lifetime of the login window so it
        // behaves like a normal window, then revert once it closes.
        NSApp.setActivationPolicy(.regular)
        webView.load(URLRequest(url: URL(string: "https://ollama.com/signin")!))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func closeAndRestorePolicy() {
        window?.close()
        NSApp.setActivationPolicy(.accessory)
        PanelController.collapseSuspended = false
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        PanelController.collapseSuspended = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Still on the sign-in page (or an SSO provider's domain) — keep waiting. The
        // sign-in form itself lives on the `signin.ollama.com` subdomain (path "/"),
        // so "signin" has to be checked in the host too, not just the path.
        guard let url = webView.url, url.host?.contains("ollama.com") == true,
              url.host?.contains("signin") != true, !url.path.contains("signin"),
              !isVerifying else { return }

        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            let relevant = cookies.filter { $0.domain.contains("ollama.com") }
            guard !relevant.isEmpty else { return }
            let header = relevant.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")

            // A redirect landing back on ollama.com mid-flow (e.g. an OAuth callback
            // step) can carry only the anonymous tracking cookie, not a real session.
            // Confirm against the server before treating this as "logged in" and
            // closing the window — otherwise the window can vanish while the user
            // is still in the middle of signing in.
            guard let self, !self.isVerifying else { return }
            self.isVerifying = true
            Task { @MainActor in
                let loggedIn = await OllamaProvider.verifyLoggedIn(cookie: header)
                self.isVerifying = false
                guard loggedIn else { return }
                Self.saveCookie(header)
                self.closeAndRestorePolicy()
                self.onComplete?()
            }
        }
    }
}
