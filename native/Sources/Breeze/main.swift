// Breeze Native — app entry, menus, lifecycle.

import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    var browser: BrowserController?
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        AdBlocker.shared.compileIfNeeded {}
        browser = BrowserController()
        NSApp.activate(ignoringOtherApps: true)
        browser?.showWhatsNewIfUpdated()
        Updater.shared.start()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ n: Notification) {
        if let tabs = browser?.tabs {
            Store.shared.openTabs = tabs.compactMap { $0.webView.url?.absoluteString }
            Store.shared.saveOpenTabs()
        }
        browser?.llm.shutdown()
    }
    @objc func newTab() { browser?.openNewTab() }
    @objc func closeTab() { if let t = browser?.current { browser?.closeTab(t) } }
    @objc func focusAddr() {
        guard let b = browser else { return }
        b.window.makeFirstResponder(b.address); b.address.currentEditor()?.selectAll(nil)
    }
    @objc func reload() { browser?.current?.webView.reload() }
    @objc func goBack() { browser?.current?.webView.goBack() }
    @objc func goForward() { browser?.current?.webView.goForward() }
    @objc func toggleSidebar() { browser?.toggleSidebar() }
    @objc func toggleAssistant() { browser?.toggleAssistant() }
    @objc func cycleTheme() { browser?.cycleThemeSetting() }
    @objc func openSettings() { browser?.openInternal(.settings) }
    @objc func openHistory() { browser?.openInternal(.history) }
    @objc func openBookmarks() { browser?.openInternal(.bookmarks) }
    @objc func openDownloads() { browser?.openInternal(.downloads) }
    @objc func openPasswords() { browser?.openInternal(.passwords) }
    @objc func openUpdates() { browser?.openInternal(.updates) }
    @objc func checkForUpdates() { Updater.shared.check(manual: true) }
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
fileMenu.addItem(mi("New Tab", #selector(AppDelegate.newTab), "t"))
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
