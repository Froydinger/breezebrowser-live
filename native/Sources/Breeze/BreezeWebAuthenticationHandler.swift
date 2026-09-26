import AppKit
import AuthenticationServices
import WebKit

/// Lets Breeze, when selected as the macOS default browser, show system OAuth
/// requests in a normal Breeze tab. Google rejects an app-owned embedded login
/// view; this keeps the verified browser chrome and the system callback intact.
@MainActor
final class BreezeWebAuthenticationHandler: NSObject, ASWebAuthenticationSessionWebBrowserSessionHandling {
    static let shared = BreezeWebAuthenticationHandler()

    private final class PendingRequest {
        let request: ASWebAuthenticationSessionRequest
        weak var browser: BrowserController?
        weak var webView: WKWebView?
        let tabID: UUID
        let previousTabID: UUID?
        let privateWindow: Bool

        init(request: ASWebAuthenticationSessionRequest, browser: BrowserController,
             tab: Tab, previousTabID: UUID?, privateWindow: Bool) {
            self.request = request
            self.browser = browser
            webView = tab.webView
            tabID = tab.id
            self.previousTabID = previousTabID
            self.privateWindow = privateWindow
        }
    }

    private var requests: [String: PendingRequest] = [:]

    nonisolated func begin(_ request: ASWebAuthenticationSessionRequest) {
        NSLog("BreezeAuth: browser received auth request for %@%@", request.url.host ?? "unknown", request.url.path)
        Task { @MainActor in Self.shared.beginOnMainActor(request) }
    }

    private func beginOnMainActor(_ request: ASWebAuthenticationSessionRequest) {
        NSLog("BreezeAuth: handling auth request on Breeze main thread")
        guard request.url.scheme?.lowercased() == "https" else {
            request.cancelWithError(NSError(domain: "BreezeWebAuthentication", code: 2,
                                            userInfo: [NSLocalizedDescriptionKey: "Breeze only accepts secure sign-in requests."]))
            return
        }
        guard let app = NSApp.delegate as? AppDelegate else {
            request.cancelWithError(NSError(domain: "BreezeWebAuthentication", code: 1,
                                            userInfo: [NSLocalizedDescriptionKey: "Breeze could not open the sign-in tab."]))
            return
        }

        let privateWindow = request.shouldUseEphemeralSession
        let browser: BrowserController
        if privateWindow {
            browser = BrowserController(isPrivateWindow: true, initialContent: .empty)
            app.browsers.append(browser)
        } else if let current = app.authenticationTargetBrowser() {
            browser = current
        } else {
            browser = BrowserController(initialContent: .newTab)
            app.browsers.append(browser)
        }

        let previousTabID = browser.current?.id
        let tab = browser.openWebAuthenticationTab(url: request.url, isPrivate: privateWindow) { tab in
            self.requests[request.uuid.uuidString] = PendingRequest(
                request: request, browser: browser, tab: tab,
                previousTabID: previousTabID, privateWindow: privateWindow
            )
        }
        if browser.window.isMiniaturized { browser.window.deminiaturize(nil) }
        browser.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        _ = tab
    }

    nonisolated func cancel(_ request: ASWebAuthenticationSessionRequest) {
        Task { @MainActor in Self.shared.cancelOnMainActor(request) }
    }

    private func cancelOnMainActor(_ request: ASWebAuthenticationSessionRequest) {
        guard let pending = requests.removeValue(forKey: request.uuid.uuidString) else { return }
        dismiss(pending)
    }

    /// Called before normal custom-scheme handling. A match is completed through
    /// AuthenticationServices, then the temporary tab is closed and the user's
    /// previous Breeze tab is restored.
    func completeIfCallback(_ url: URL, from webView: WKWebView) -> Bool {
        guard let entry = requests.first(where: { $0.value.webView === webView }),
              matches(entry.value.request, url: url) else { return false }
        NSLog("BreezeAuth: matched auth callback scheme=%@ host=%@ path=%@",
              url.scheme ?? "none", url.host ?? "none", url.path)
        requests.removeValue(forKey: entry.key)
        entry.value.request.complete(withCallbackURL: url)
        DispatchQueue.main.async { [weak self] in self?.dismiss(entry.value) }
        return true
    }

    func isHandling(_ webView: WKWebView) -> Bool {
        requests.values.contains { $0.webView === webView }
    }

    private func matches(_ request: ASWebAuthenticationSessionRequest, url: URL) -> Bool {
        if #available(macOS 14.4, *), let callback = request.callback {
            return callback.matchesURL(url)
        }
        return request.callbackURLScheme?.caseInsensitiveCompare(url.scheme ?? "") == .orderedSame
    }

    private func dismiss(_ pending: PendingRequest) {
        guard let browser = pending.browser,
              let tab = browser.tabs.first(where: { $0.id == pending.tabID }) else { return }
        if pending.privateWindow {
            browser.window.performClose(nil)
            return
        }
        browser.closeTab(tab)
        if let previousTabID = pending.previousTabID,
           let index = browser.tabs.firstIndex(where: { $0.id == previousTabID }) {
            browser.select(index)
        }
    }
}
