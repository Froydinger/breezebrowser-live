// Internal pages (settings, updates, history, bookmarks, downloads, passwords):
// the polished Electron HTML is bundled and loaded into a WKWebView, with a
// native `breezeInternal` bridge injected so the pages behave like in Electron.

import Cocoa
import WebKit

enum InternalPage: String {
    case updates, settings, history, bookmarks, downloads, passwords

    var file: String {
        switch self {
        case .passwords: return "passwords.html"
        default: return "\(rawValue).html"
        }
    }
    var title: String {
        switch self {
        case .updates: return "What's New"
        case .settings: return "Settings"
        case .history: return "History"
        case .bookmarks: return "Bookmarks"
        case .downloads: return "Downloads"
        case .passwords: return "Passwords"
        }
    }

    /// Resolve the HTML file: bundled Resources/ui first, dev fallback to repo ui/.
    func fileURL() -> URL? {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("ui/\(file)"),
           FileManager.default.fileExists(atPath: r.path) { return r }
        for p in ["../ui/\(file)", "ui/\(file)"] {
            let u = URL(fileURLWithPath: p)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }
}

/// JS injected at documentStart on file:// pages — defines window.breezeInternal.
/// Query methods round-trip through the `breezeMsg` handler + a promise registry;
/// `theme` and settings are answered from values the native side bakes in via
/// evaluateJavaScript right after navigation commits.
let breezeBridgeJS = """
(function () {
  if (location.protocol !== 'file:') return;
  window.__bzReq = {}; var __id = 0;
  window.__bzResolve = function (id, json) {
    var r = window.__bzReq[id]; if (r) { r(JSON.parse(json)); delete window.__bzReq[id]; }
  };
  function call(method, args) {
    return new Promise(function (res) {
      var id = ++__id; window.__bzReq[id] = res;
      window.webkit.messageHandlers.breezeMsg.postMessage({ id: id, method: method, args: args || {} });
    });
  }
  function send(method, args) {
    window.webkit.messageHandlers.breezeMsg.postMessage({ method: method, args: args || {} });
  }
  if (window.__bzTheme === undefined) window.__bzTheme = 'light';
  if (window.__bzSettings === undefined) window.__bzSettings = {};
  window.breezeInternal = {
    get theme() { return window.__bzTheme; },
    getSettings: function () { return Promise.resolve(window.__bzSettings); },
    getSuggestions: function () { return Promise.resolve([]); },
    setSetting: function (key, value) { send('setSetting', { key: key, value: value }); },
    onSettings: function (cb) { window.__bzOnSettings = cb; },
    onTheme: function (cb) { window.__bzOnTheme = cb; },
    getBookmarks: function () { return call('getBookmarks'); },
    removeBookmark: function (url) { send('removeBookmark', { url: url }); },
    onBookmarks: function (cb) { window.__bzOnBookmarks = cb; },
    getHistory: function () { return call('getHistory'); },
    clearHistory: function () { send('clearHistory'); },
    deleteHistoryItem: function (url, ts) { send('deleteHistoryItem', { url: url, ts: ts }); },
    getDownloads: function () { return call('getDownloads'); },
    onDownloads: function (cb) { window.__bzOnDownloads = cb; },
    cancelDownload: function (id) { send('cancelDownload', { id: id }); },
    openDownload: function (id) { send('openDownload', { id: id }); },
    showDownload: function (id) { send('showDownload', { id: id }); },
    clearDownloads: function () { send('clearDownloads'); },
    setSitePermission: function (origin, permission, value) { send('setSitePermission', { origin: origin, permission: permission, value: value }); },
    getReminders: function () { return call('getReminders'); },
    deleteReminder: function (id) { send('deleteReminder', { id: id }); },
    onReminders: function (cb) { window.__bzOnReminders = cb; },
    clearBrowsingData: function (opts) { return call('clearBrowsingData', opts); },
    resetBrowser: function () { return call('resetBrowser'); },
    setSecret: function (key, value) { send('setSecret', { key: key, value: value }); },
    hasSecret: function (key) { return call('hasSecret', { key: key }); },
    deleteSecret: function (key) { send('deleteSecret', { key: key }); },
    isDefaultBrowser: function () { return Promise.resolve(false); },
    makeDefaultBrowser: function () { send('makeDefaultBrowser'); },
    switchToTab: function (id) { send('switchToTab', { id: id }); },
    getChats: function () { return call('getChats'); },
    openChat: function (id) { send('openChat', { id: id }); },
    deleteChat: function (id) { send('deleteChat', { id: id }); },
    askAI: function (text) { send('askAI', { text: text }); },
    aiReady: function () { return Promise.resolve(false); },
    onAIReady: function () {},
    getModelInfo: function () { return Promise.resolve({}); },
    setAIModel: function (tier) { send('setAIModel', { tier: tier }); },
    onFocusInput: function () {},
    importSources: function () { return Promise.resolve([]); },
    importFromBrowser: function () { return Promise.resolve({ ok: false }); },
    importHTML: function () { return Promise.resolve({ ok: false }); },
    vaultList: function () { return call('vaultList'); },
    vaultAdd: function (s, u, p) { send('vaultAdd', { site: s, username: u, password: p }); },
    vaultDelete: function (id) { send('vaultDelete', { id: id }); },
    vaultImportCSV: function (csv) { send('vaultImportCSV', { csv: csv }); },
    onVault: function (cb) { window.__bzOnVault = cb; },
    onVaultImported: function () {}
  };
})();
"""
