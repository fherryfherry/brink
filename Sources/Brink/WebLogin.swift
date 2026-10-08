import AppKit
import WebKit
import os

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
    let session: Session
    let customUserAgent: String?

    /// Where the signed-in session lives; `verify` and `currentCredential()` get it as a string.
    enum Session {
        /// Cookie header built from the service's cookies.
        case cookies
        /// Raw `localStorage[key]` on the login URL's origin (e.g. a Supabase session); `isFresh` says when it's usable.
        /// `silentReauthURL` (given the last value seen, if any) is a no-UI sign-in to load offscreen once the site can't refresh it.
        case localStorage(key: String, isFresh: (String) -> Bool, silentReauthURL: (String?) -> URL?)
    }

    private static let log = Logger(subsystem: "com.semihtali.brink", category: "WebLogin")

    init(id: String, displayName: String, loginURL: URL, host: String,
         signinHints: [String], session: Session = .cookies, customUserAgent: String? = nil,
         verify: @escaping (String) async -> Bool) {
        self.id = id
        self.displayName = displayName
        self.loginURL = loginURL
        self.host = host
        self.signinHints = signinHints
        self.session = session
        self.customUserAgent = customUserAgent
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

    /// The current session credential (cookie header or localStorage value), nil if not signed in.
    @MainActor
    func currentCredential() async -> String? {
        switch session {
        case .cookies:
            return await currentCookieHeader()
        case let .localStorage(key, isFresh, silentReauthURL):
            if let inflight = inflightRead { return await inflight.value }
            let task = Task { @MainActor in
                await self.readLocalStorage(key: key, isFresh: isFresh, silentReauthURL: silentReauthURL)
            }
            inflightRead = task
            defer { inflightRead = nil }
            return await task.value
        }
    }

    // One offscreen read at a time: two pages refreshing the same single-use refresh token race and can get the session revoked.
    private var inflightRead: Task<String?, Never>?
    private var lastReauthAttempt: Date?
    private static let reauthRetryInterval: TimeInterval = 10 * 60

    /// Loads the site offscreen so its own JS refreshes an expired session (Brink never refreshes it itself), falling back to a silent re-sign-in.
    @MainActor
    private func readLocalStorage(key: String, isFresh: (String) -> Bool,
                                  silentReauthURL: (String?) -> URL?) async -> String? {
        guard let origin = URL(string: "/", relativeTo: loginURL)?.absoluteURL else { return nil }
        let page = OffscreenPage(webView: makeWebView(frame: .zero), logPrefix: id)
        await page.load(origin)
        let afterLoad = await poll(key, in: page.webView, isFresh: isFresh, timeout: 15, giveUpIfEmptyAfter: 3)
        if let afterLoad, isFresh(afterLoad) { return afterLoad }
        Self.log.notice("\(self.id, privacy: .public): session \(afterLoad == nil ? "missing" : "still expired", privacy: .public) after reload")

        if let last = lastReauthAttempt, Date().timeIntervalSince(last) < Self.reauthRetryInterval { return afterLoad }
        guard let reauth = silentReauthURL(afterLoad ?? lastSeenValue) else { return afterLoad }
        lastReauthAttempt = Date()
        Self.log.notice("\(self.id, privacy: .public): trying silent re-sign-in")
        await page.load(reauth)
        let callbackURL = page.webView.url
        let afterReauth = await poll(key, in: page.webView, isFresh: isFresh, timeout: 25)
        let ok = afterReauth.map(isFresh) ?? false
        Self.log.notice("\(self.id, privacy: .public): silent re-sign-in \(ok ? "succeeded" : "failed", privacy: .public) via \(Self.describe(callbackURL), privacy: .public), now on \(Self.describe(page.webView.url), privacy: .public)")
        if ok { lastReauthAttempt = nil }
        return afterReauth ?? afterLoad
    }

    // Last non-empty value read, so a silent re-sign-in can still hint the account after the site wiped its storage.
    private var lastSeenValue: String?

    /// Host + path + parameter names (and only `error*` values) of a URL, so logs never carry tokens.
    private static func describe(_ url: URL?) -> String {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "-" }
        let fragment = URLComponents(string: "?" + (components.fragment ?? ""))?.queryItems ?? []
        let items = (components.queryItems ?? []) + fragment
        let params = items.map { $0.name.hasPrefix("error") ? "\($0.name)=\($0.value ?? "")" : $0.name }
        return (components.host ?? "") + components.path + (params.isEmpty ? "" : " [\(params.joined(separator: ", "))]")
    }

    /// Polls until the stored value is fresh, gone, or `timeout` passes; returns the last value (nil if empty).
    @MainActor
    private func poll(_ key: String, in webView: WKWebView, isFresh: (String) -> Bool,
                      timeout: TimeInterval, giveUpIfEmptyAfter: TimeInterval? = nil) async -> String? {
        let start = Date()
        var value = ""
        while Date().timeIntervalSince(start) < timeout {
            value = await Self.localStorageValue(key, in: webView)
            if !value.isEmpty {
                lastSeenValue = value
                if isFresh(value) { return value }
            } else if let giveUp = giveUpIfEmptyAfter, Date().timeIntervalSince(start) > giveUp {
                return nil
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return value.isEmpty ? nil : value
    }

    @MainActor
    private static func localStorageValue(_ key: String, in webView: WKWebView) async -> String {
        let keyLiteral = String(decoding: (try? JSONSerialization.data(withJSONObject: [key])) ?? Data(), as: UTF8.self)
        let js = "localStorage.getItem(\(keyLiteral)[0]) || ''"
        return ((try? await webView.evaluateJavaScript(js)) as? String) ?? ""
    }

    @MainActor
    private func makeWebView(frame: NSRect) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: frame, configuration: config)
        webView.customUserAgent = customUserAgent
        return webView
    }

    @MainActor
    func presentLogin(onComplete: @escaping () -> Void) {
        PanelController.collapseSuspended = true
        self.onComplete = onComplete

        let webView = makeWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640))
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
            let credential: String?
            switch session {
            case .cookies: credential = await currentCookieHeader()
            case let .localStorage(key, _, _):
                let value = await Self.localStorageValue(key, in: webView)
                credential = value.isEmpty ? nil : value
            }
            guard let credential, await verify(credential) else { return }
            closeAndRestorePolicy()
            onComplete?()
        }
    }
}

/// Offscreen WKWebView that can be awaited until its page finishes loading (or fails).
@MainActor
private final class OffscreenPage: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let webView: WKWebView
    private let logPrefix: String
    private var loaded: CheckedContinuation<Void, Never>?
    private static let log = Logger(subsystem: "com.semihtali.brink", category: "OffscreenPage")

    init(webView: WKWebView, logPrefix: String) {
        self.webView = webView
        self.logPrefix = logPrefix
        super.init()
        webView.navigationDelegate = self
        // Forwards the page's console errors/warnings (e.g. a rejected token refresh) to the unified log.
        let forward = """
        ['error','warn'].forEach(function(level){var orig=console[level];console[level]=function(){try{window.webkit.messageHandlers.brinkConsole.postMessage(level+': '+Array.prototype.map.call(arguments,function(a){try{return a instanceof Error?a.message:typeof a==='object'?JSON.stringify(a):String(a)}catch(e){return String(a)}}).join(' '))}catch(e){}return orig.apply(console,arguments)}});
        """
        let controller = webView.configuration.userContentController
        controller.addUserScript(WKUserScript(source: forward, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.add(WeakScriptHandler(self), name: "brinkConsole")
    }

    deinit {
        let controller = webView.configuration.userContentController
        MainActor.assumeIsolated { controller.removeScriptMessageHandler(forName: "brinkConsole") }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let text = (message.body as? String ?? "").prefix(500)
        Self.log.notice("\(self.logPrefix, privacy: .public) console \(String(text), privacy: .public)")
    }

    func load(_ url: URL) async {
        await withCheckedContinuation { continuation in
            loaded = continuation
            webView.load(URLRequest(url: url))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Self.log.notice("\(self.logPrefix, privacy: .public) load failed: \(error.localizedDescription, privacy: .public)")
        finish()
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Self.log.notice("\(self.logPrefix, privacy: .public) load failed: \(error.localizedDescription, privacy: .public)")
        finish()
    }

    private func finish() {
        loaded?.resume()
        loaded = nil
    }
}

/// WKUserContentController retains its handlers strongly; this breaks the page ↔ controller cycle.
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
