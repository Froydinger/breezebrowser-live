// Breeze Native — app entry, menus, lifecycle.

import Cocoa
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate {
    var browsers: [BrowserController] = []
    var activeBrowser: BrowserController? {
        browsers.first { $0.window.isKeyWindow } ?? browsers.first
    }
    func applicationDidFinishLaunching(_ n: Notification) {
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
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if let b = activeBrowser {
            b.openTab(url: url.absoluteString)
        } else {
            let b = BrowserController()
            browsers.append(b)
            b.openTab(url: url.absoluteString)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else { return }
        DispatchQueue.main.async {
            if let b = self.activeBrowser {
                b.openTab(url: url.absoluteString)
            } else {
                let b = BrowserController()
                self.browsers.append(b)
                b.openTab(url: url.absoluteString)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    @objc func windowClosed(_ notification: Notification) {
        if let win = notification.object as? NSWindow {
            browsers.removeAll { $0.window === win }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ n: Notification) {
        if let b = activeBrowser {
            Store.shared.openTabs = b.tabs.compactMap { $0.webView.url?.absoluteString }
            Store.shared.saveOpenTabs()
            b.llm.shutdown()
        }
    }
    @objc func newWindow() {
        let b = BrowserController(initialContent: .newTab)
        browsers.append(b)
    }
    @objc func newPrivateWindow() {
        let b = BrowserController(isPrivateWindow: true)
        browsers.append(b)
    }
    @objc func newTab() { activeBrowser?.openNewTab() }
    @objc func newChatTab() { activeBrowser?.newFullscreenChat() }
    @objc func newPrivateTab() { activeBrowser?.openNewTab(isPrivate: true) }
    @objc func closeTab() { if let t = activeBrowser?.current { activeBrowser?.closeTab(t) } }
    @objc func focusAddr() {
        guard let b = activeBrowser else { return }
        b.window.makeFirstResponder(b.address); b.address.currentEditor()?.selectAll(nil)
    }
    @objc func reload() { activeBrowser?.current?.webView.reload() }
    @objc func goBack() { activeBrowser?.current?.webView.goBack() }
    @objc func goForward() { activeBrowser?.current?.webView.goForward() }
    @objc func toggleSidebar() { activeBrowser?.toggleSidebar() }
    @objc func toggleAssistant() { activeBrowser?.toggleAssistant() }
    @objc func cycleTheme() { activeBrowser?.cycleThemeSetting() }
    @objc func openSettings() { activeBrowser?.openInternal(.settings) }
    @objc func openHistory() { activeBrowser?.openInternal(.history) }
    @objc func openBookmarks() { activeBrowser?.openInternal(.bookmarks) }
    @objc func openDownloads() { activeBrowser?.openInternal(.downloads) }
    @objc func openPasswords() { activeBrowser?.openInternal(.passwords) }
    @objc func openUpdates() { activeBrowser?.openInternal(.updates) }
    @objc func checkForUpdates() { Updater.shared.check(manual: true) }
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
editItem.submenu = editMenu

// View
let viewItem = NSMenuItem(); mainMenu.addItem(viewItem)
let viewMenu = NSMenu(title: "View")
viewMenu.addItem(mi("Reload Page", #selector(AppDelegate.reload), "r"))
viewMenu.addItem(mi("Toggle Sidebar", #selector(AppDelegate.toggleSidebar), "s"))
viewMenu.addItem(mi("Toggle Assistant", #selector(AppDelegate.toggleAssistant), "e"))
viewMenu.addItem(mi("Cycle Theme", #selector(AppDelegate.cycleTheme), "d", [.command, .shift]))
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
