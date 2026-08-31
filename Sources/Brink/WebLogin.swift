import AppKit
import WebKit

/// Presents a small in-app WKWebView so the user can sign in to a provider
/// that has no API key / OAuth token flow Brink can read from disk (see
/// `OllamaProvider`, `KenariProvider`). One instance per service — each gets
/// its own captured session cookie, scoped to that service's domain, written
/// to `~/Library/Application Support/Brink/<id>-cookie.json`.
///
/// The WKWebView uses Brink's own persistent data store, separate from — and
/// never touching — the user's system Chrome/Safari cookies. There's no
/// supported way to borrow another browser's live session without reading
/// its cookie store wholesale, which is a much bigger permission than this
/// needs.
final class WebLogin: NSObject, WKNavigationDelegate, NSWindowDelegate {
    let id: String
    let displayName: String
    let loginURL: URL
    /// Substring identifying the service's own domain, e.g. "ollama.com".
    let host: String
    /// Substrings that mean "still on a login/sign-in page or host" — checked
    /// against both the host and the path, since some providers host the
    /// actual form on a subdomain (e.g. `signin.ollama.com`) rather than a
    /// `/login`-ish path on the main domain.
    let signinHints: [String]
    /// Confirms a cookie captured mid-flow is an actual signed-in session
    /// before closing the window — a redirect landing back on the service's
    /// domain mid-OAuth can carry only anonymous/tracking cookies, and
    /// closing on that would strand the user mid-login.
    let verify: (String) async -> Bool

    init(id: String, displayName: String, loginURL: URL, host: String,
         signinHints: [String], verify: @escaping (String) async -> Bool) {
        self.id = id
        self.displayName = displayName
        self.loginURL = loginURL
        self.host = host
        self.signinHints = signinHints
        self.verify = verify
    }

    private var window: NSWindow?
    private var webView: WKWebView?
    private var onComplete: (() -> Void)?
    private var isVerifying = false
    private var urlObservation: NSKeyValueObservation?

    nonisolated private var cookieFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Brink", isDirectory: true)
            .appendingPathComponent("\(id)-cookie.json")
    }

    nonisolated func loadCookie() -> String? {
        guard let data = try? Data(contentsOf: cookieFileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cookie = obj["cookie"] as? String, !cookie.isEmpty else { return nil }
        return cookie
    }

    nonisolated func clearCookie() {
        try? FileManager.default.removeItem(at: cookieFileURL)
    }

    private func saveCookie(_ cookie: String) {
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
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: config)
        webView.navigationDelegate = self
        self.webView = webView
        // Some login pages (e.g. kenari.id, a client-routed SPA) redirect an
        // already-authenticated session with a `pushState` route change
        // instead of a real page load, which never fires `didFinish`. KVO on
        // `url` catches that too, since it's backed by `window.location`.
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
            self?.checkLoginState(webView: webView)
        }

        let window = NSWindow(contentRect: webView.frame, styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = L("Sign in to %@", displayName)
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
        webView.load(URLRequest(url: loginURL))
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
        checkLoginState(webView: webView)
    }

    private func checkLoginState(webView: WKWebView) {
        // Still on the sign-in page (or an SSO provider's domain) — keep waiting.
        guard let url = webView.url, url.host?.contains(host) == true,
              !signinHints.contains(where: { url.host?.contains($0) == true || url.path.contains($0) }),
              !isVerifying else { return }

        let host = self.host
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            let relevant = cookies.filter { $0.domain.contains(host) }
            guard !relevant.isEmpty else { return }
            let header = relevant.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")

            guard let self, !self.isVerifying else { return }
            self.isVerifying = true
            Task { @MainActor in
                let loggedIn = await self.verify(header)
                self.isVerifying = false
                guard loggedIn else { return }
                self.saveCookie(header)
                self.closeAndRestorePolicy()
                self.onComplete?()
            }
        }
    }
}
