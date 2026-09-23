// Breeze Native — app entry, menus, lifecycle.

import Cocoa
import Carbon
import CoreServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    var browsers: [BrowserController] = []
    var keyMonitor: Any?
    private var savedOpenTabsForTermination = false
    private var closedWindowIds = Set<ObjectIdentifier>()
    var activeBrowser: BrowserController? {
        if let key = browsers.first(where: { isUsable($0) && $0.window.isKeyWindow }) { return key }
        // Nothing key (Breeze is in the background): the frontmost window, not the oldest.
        return frontToBack(browsers.filter(isUsable)).first
    }
    private func frontToBack(_ list: [BrowserController]) -> [BrowserController] {
        let zOrder = NSApp.orderedWindows
        func depth(_ b: BrowserController) -> Int { zOrder.firstIndex { $0 === b.window } ?? Int.max }
        return list.sorted { depth($0) < depth($1) }
    }
    func applicationDidFinishLaunching(_ n: Notification) {
        // Before any window exists, so no tracking area can be installed first.
        CampoCrashWorkaround.install()
        LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
        NSApp.setActivationPolicy(.regular)
        AdBlocker.shared.compileIfNeeded {}
        let b = BrowserController()
        browsers.append(b)
        NSApp.activate(ignoringOtherApps: true)
        b.showWhatsNewIfUpdated()
        Updater.shared.start()
        
        NotificationCenter.default.addObserver(self, selector: #selector(windowClosed(_:)), name: NSWindow.willCloseNotification, object: nil)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command), let browser = self.activeBrowser, event.window === browser.window else { return event }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "f":
                browser.openFindBar()
                return nil
            case "g":
                flags.contains(.shift) ? browser.findPrevious() : browser.findNextMatch()
                return nil
            case "+", "=":
                browser.zoomPage(by: 0.1)
                return nil
            case "-":
                browser.zoomPage(by: -0.1)
                return nil
            case "0":
                browser.resetPageZoom()
                return nil
            default:
                return event
            }
        }
    }

    /// A breeze:// URL handed to us by the system (or another app) names an
    /// internal page, not a website. Without this it became a tab trying to load
    /// an unknown scheme.
    private func openBreezeURL(_ url: URL, in browser: BrowserController) -> Bool {
        guard url.scheme?.lowercased() == "breeze" else { return false }
        let slug = (url.host?.isEmpty == false ? url.host! : String(url.absoluteString.dropFirst("breeze://".count)))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let page = InternalPage(rawValue: slug.lowercased()) else { return true }
        browser.openInternal(page)
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !urls.isEmpty else { return }
        openExternalURLs(urls)
    }
    @objc func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else { return }
        DispatchQueue.main.async { self.openExternalURLs([url]) }
    }

    /// A link from another app goes to the window you'd expect: the frontmost
    /// normal window on this Space, then any other open normal window, and only
    /// then a new one. This used to be `activeBrowser`, but nothing in Breeze is
    /// key while you're clicking in another app, so it fell back to the OLDEST
    /// window, often one buried behind others or on another Space. The tab opened
    /// there, out of sight, and the window you were looking at showed a new tab
    /// page that never finished loading. The target is also brought to the front
    /// now, so the page always shows up where you can see it.
    private func openExternalURLs(_ urls: [URL]) {
        let b = linkTargetBrowser() ?? {
            let fresh = BrowserController()
            browsers.append(fresh)
            return fresh
        }()
        for url in urls where !openBreezeURL(url, in: b) {
            b.openTab(url: url.absoluteString)
        }
        if b.window.isMiniaturized { b.window.deminiaturize(nil) }
        b.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func linkTargetBrowser() -> BrowserController? {
        let open = browsers.filter { !$0.isPrivateWindow && isOpen($0) }
        let onScreen = frontToBack(open.filter { $0.window.isVisible })
        return onScreen.first { $0.window.isOnActiveSpace }
            ?? onScreen.first
            ?? open.first { $0.window.isMiniaturized }
    }
    @objc func windowClosed(_ notification: Notification) {
        guard let win = notification.object as? NSWindow else { return }
        closedWindowIds.insert(ObjectIdentifier(win))
        guard let index = browsers.firstIndex(where: { $0.window === win }) else { return }

        browsers.remove(at: index).finalizeWindowClosure()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        saveRestorableOpenTabs()
        savedOpenTabsForTermination = true
        return .terminateNow
    }
    func applicationWillTerminate(_ n: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if !savedOpenTabsForTermination {
            saveRestorableOpenTabs()
        }
        for b in browsers {
            b.llm.shutdown()
        }
    }

    private func saveRestorableOpenTabs() {
        Store.shared.openTabs = restorableBrowsers().flatMap { $0.restorableTabURLs() }
        Store.shared.saveOpenTabs()
    }

    /// Normal windows whose tabs belong in the saved session. Minimised windows
    /// count: they're still open, just not visible.
    func restorableBrowsers() -> [BrowserController] {
        browsers.filter { !$0.isPrivateWindow && isOpen($0) }
    }

    private func isOpen(_ browser: BrowserController) -> Bool {
        !closedWindowIds.contains(ObjectIdentifier(browser.window))
    }

    private func isUsable(_ browser: BrowserController) -> Bool {
        !closedWindowIds.contains(ObjectIdentifier(browser.window)) && browser.window.isVisible
    }
    @objc func newWindow() {
        let b = BrowserController(initialContent: .newTab)
        browsers.append(b)
    }
    @objc func newPrivateWindow() {
        let b = BrowserController(isPrivateWindow: true)
        browsers.append(b)
    }
    @objc func newTab() { (activeBrowser ?? makeBrowser()).openNewTab() }
    @objc func newChatTab() { (activeBrowser ?? makeBrowser()).newFullscreenChat() }
    @objc func newPrivateTab() { (activeBrowser ?? makeBrowser()).openNewTab(isPrivate: true) }
    @objc func closeTab() { if let t = activeBrowser?.current { activeBrowser?.closeTab(t) } }
    @objc func focusAddr() {
        guard let b = activeBrowser else { return }
        b.window.makeFirstResponder(b.address); b.address.currentEditor()?.selectAll(nil)
    }
    @objc func reload() { activeBrowser?.reloadCurrentTab() }
    @objc func hardReload() { activeBrowser?.hardReloadCurrentTab() }
    @objc func goBack() { activeBrowser?.current?.webView.goBack() }
    @objc func goForward() { activeBrowser?.current?.webView.goForward() }
    @objc func zoomIn() { activeBrowser?.zoomPage(by: 0.1) }
    @objc func zoomOut() { activeBrowser?.zoomPage(by: -0.1) }
    @objc func resetZoom() { activeBrowser?.resetPageZoom() }
    @objc func findInPage() { activeBrowser?.openFindBar() }
    @objc func findNext() { activeBrowser?.findNextMatch() }
    @objc func findPrevious() { activeBrowser?.findPrevious() }
    @objc func toggleSidebar() { activeBrowser?.toggleSidebar() }
    @objc func toggleAssistant() { activeBrowser?.toggleAssistant() }
    @objc func cycleTheme() { activeBrowser?.cycleThemeSetting() }
    @objc func freeUpMemory() { activeBrowser?.freeUpMemory(userInitiated: true) }
    @objc func openSettings() { activeBrowser?.openInternal(.settings) }
    @objc func openHistory() { activeBrowser?.openInternal(.history) }
    @objc func openBookmarks() { activeBrowser?.openInternal(.bookmarks) }
    @objc func openDownloads() { activeBrowser?.openInternal(.downloads) }
    @objc func openPasswords() { activeBrowser?.openInternal(.passwords) }
    @objc func openUpdates() { activeBrowser?.openInternal(.updates) }
    @objc func checkForUpdates() { Updater.shared.check(manual: true) }
    private func makeBrowser() -> BrowserController {
        let b = BrowserController(initialContent: .newTab)
        browsers.append(b)
        return b
    }
    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(AppDelegate.toggleAssistant) {
            if activeBrowser?.current?.isChatTab == true {
                return false
            }
        }
        return true
    }
}

func mi(_ title: String, _ sel: Selector, _ key: String = "",
        _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
    if !key.isEmpty { item.keyEquivalentModifierMask = mods }
    return item
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

let mainMenu = NSMenu()

// App menu
let appItem = NSMenuItem(); mainMenu.addItem(appItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "About Breeze", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
appMenu.addItem(.separator())
appMenu.addItem(withTitle: "Check for Updates…", action: #selector(AppDelegate.checkForUpdates), keyEquivalent: "")
appMenu.addItem(.separator())
appMenu.addItem(mi("Settings…", #selector(AppDelegate.openSettings), ","))
appMenu.addItem(.separator())
appMenu.addItem(withTitle: "Hide Breeze", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
appMenu.addItem(.separator())
appMenu.addItem(withTitle: "Quit Breeze", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appItem.submenu = appMenu

// File
let fileItem = NSMenuItem(); mainMenu.addItem(fileItem)
let fileMenu = NSMenu(title: "File")
    fileMenu.addItem(mi("New Window", #selector(AppDelegate.newWindow), "n"))
    fileMenu.addItem(mi("New Private Window", #selector(AppDelegate.newPrivateWindow), "N", [.command, .shift]))
    fileMenu.addItem(mi("New Tab", #selector(AppDelegate.newTab), "t"))
    fileMenu.addItem(mi("New Chat", #selector(AppDelegate.newChatTab), "T", [.command, .shift]))
    fileMenu.addItem(mi("New Private Tab", #selector(AppDelegate.newPrivateTab), "t", [.command, .option]))
    fileMenu.addItem(mi("Close Tab", #selector(AppDelegate.closeTab), "w"))
    fileMenu.addItem(.separator())
fileMenu.addItem(mi("Open Location…", #selector(AppDelegate.focusAddr), "l"))
fileMenu.addItem(.separator())
fileMenu.addItem(withTitle: "Check for Updates…", action: #selector(AppDelegate.checkForUpdates), keyEquivalent: "")
fileItem.submenu = fileMenu

// Edit
let editItem = NSMenuItem(); mainMenu.addItem(editItem)
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(mi("Undo", Selector(("undo:")), "z"))
editMenu.addItem(mi("Redo", Selector(("redo:")), "Z", [.command, .shift]))
editMenu.addItem(.separator())
editMenu.addItem(mi("Cut", #selector(NSText.cut(_:)), "x"))
editMenu.addItem(mi("Copy", #selector(NSText.copy(_:)), "c"))
editMenu.addItem(mi("Paste", #selector(NSText.paste(_:)), "v"))
editMenu.addItem(mi("Select All", #selector(NSText.selectAll(_:)), "a"))
editMenu.addItem(.separator())
editMenu.addItem(mi("Find in Page…", #selector(AppDelegate.findInPage), "f"))
editMenu.addItem(mi("Find Next", #selector(AppDelegate.findNext), "g"))
editMenu.addItem(mi("Find Previous", #selector(AppDelegate.findPrevious), "G", [.command, .shift]))
editItem.submenu = editMenu

// View
let viewItem = NSMenuItem(); mainMenu.addItem(viewItem)
let viewMenu = NSMenu(title: "View")
viewMenu.addItem(mi("Reload Page", #selector(AppDelegate.reload), "r"))
viewMenu.addItem(mi("Reload Ignoring Cache", #selector(AppDelegate.hardReload), "R", [.command, .shift]))
viewMenu.addItem(.separator())
viewMenu.addItem(mi("Zoom In", #selector(AppDelegate.zoomIn), "+"))
viewMenu.addItem(mi("Zoom Out", #selector(AppDelegate.zoomOut), "-"))
viewMenu.addItem(mi("Actual Size", #selector(AppDelegate.resetZoom), "0"))
viewMenu.addItem(.separator())
viewMenu.addItem(mi("Toggle Sidebar", #selector(AppDelegate.toggleSidebar), "s"))
viewMenu.addItem(mi("Toggle Assistant", #selector(AppDelegate.toggleAssistant), "e"))
viewMenu.addItem(mi("Cycle Theme", #selector(AppDelegate.cycleTheme), "d", [.command, .shift]))
viewMenu.addItem(.separator())
viewMenu.addItem(mi("Free Up Memory", #selector(AppDelegate.freeUpMemory), "k", [.command, .shift]))
viewItem.submenu = viewMenu

// History
let histItem = NSMenuItem(); mainMenu.addItem(histItem)
let histMenu = NSMenu(title: "History")
histMenu.addItem(mi("Back", #selector(AppDelegate.goBack), "["))
histMenu.addItem(mi("Forward", #selector(AppDelegate.goForward), "]"))
histMenu.addItem(.separator())
histMenu.addItem(mi("Show All History", #selector(AppDelegate.openHistory), "y"))
histItem.submenu = histMenu

// Bookmarks
let bmItem = NSMenuItem(); mainMenu.addItem(bmItem)
let bmMenu = NSMenu(title: "Bookmarks")
bmMenu.addItem(mi("Show Bookmarks", #selector(AppDelegate.openBookmarks), "b", [.command, .option]))
bmMenu.addItem(mi("Downloads", #selector(AppDelegate.openDownloads), "j", [.command, .shift]))
bmMenu.addItem(mi("Passwords", #selector(AppDelegate.openPasswords), ""))
bmItem.submenu = bmMenu

// Window
let winItem = NSMenuItem(); mainMenu.addItem(winItem)
let winMenu = NSMenu(title: "Window")
winMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
winMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
winItem.submenu = winMenu
app.windowsMenu = winMenu

// Help
let helpItem = NSMenuItem(); mainMenu.addItem(helpItem)
let helpMenu = NSMenu(title: "Help")
helpMenu.addItem(withTitle: "What's New", action: #selector(AppDelegate.openUpdates), keyEquivalent: "")
helpItem.submenu = helpMenu
app.helpMenu = helpMenu

app.mainMenu = mainMenu
app.run()
