import AppKit
import WebKit

/// Presents a small in-app WKWebView so the user can sign in to a provider
/// that has no API key / OAuth token flow Brink can read from disk (see
/// `OllamaProvider`, `KenariProvider`). One instance per service.
///
/// The WKWebView uses Brink's own persistent data store (`.default()`),
/// separate from — and never touching — the user's system Chrome/Safari
/// cookies. Cookies are read live from that store on every fetch rather than
/// captured once into a file: a saved snapshot goes stale the moment the
/// service rotates/refreshes the session cookie (a normal thing for a site
/// to do), even though the live session in `.default()` is still perfectly
/// valid — reading live instead means Brink is never more stale than the
/// WKWebView itself.
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
    /// Confirms a cookie header is an actual signed-in session before closing
    /// the window — a redirect landing back on the service's domain mid-OAuth
    /// can carry only anonymous/tracking cookies, and closing on that would
    /// strand the user mid-login.
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

    /// The live cookie header for this service, straight from Brink's
    /// persistent WKWebView data store — nil if there's currently no session
    /// (never logged in, or it expired) rather than whatever was true the
    /// last time someone happened to have the login window open.
    func currentCookieHeader() async -> String? {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        let relevant = cookies.filter { $0.domain.contains(host) }
        guard !relevant.isEmpty else { return nil }
        return relevant.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    func presentLogin(onComplete: @escaping () -> Void) {
        PanelController.collapseSuspended = true
        self.onComplete = onComplete

        let config = WKWebViewConfiguration()
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

        guard !isVerifying else { return }
        isVerifying = true
        Task { @MainActor in
            defer { isVerifying = false }
            guard let header = await currentCookieHeader(), await verify(header) else { return }
            closeAndRestorePolicy()
            onComplete?()
        }
    }
}
