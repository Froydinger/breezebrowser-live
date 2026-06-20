// Download tracking via WKDownload (macOS 11.3+). Files land in ~/Downloads.

import Cocoa
import WebKit

enum DLState: String { case progressing, completed, cancelled, failed }

final class DownloadItem {
    let id = UUID().uuidString
    var filename: String
    var url: String
    var localURL: URL?
    var received: Int64 = 0
    var total: Int64 = 0
    var state: DLState = .progressing
    let ts = Date().timeIntervalSince1970 * 1000
    weak var wk: WKDownload?
    var obs: NSKeyValueObservation?

    init(filename: String, url: String) { self.filename = filename; self.url = url }

    var dict: [String: Any] {
        ["id": id, "filename": filename, "receivedBytes": received,
         "totalBytes": total, "state": state.rawValue, "ts": ts]
    }
}
