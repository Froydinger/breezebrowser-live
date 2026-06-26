import Cocoa

enum SuggestionType {
    case bookmark
    case history
    case search
    case task        // a Nav /slash Task
}

struct SuggestionItem {
    let title: String
    let url: String
    let type: SuggestionType
    var subtitle: String = ""
}

protocol AddressSuggestionsDelegate: AnyObject {
    func didSelectSuggestion(_ url: String)
    func textChanged(to text: String)
}

private final class RoundedSuggestionRowView: NSTableRowView {
    private var hovering = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard hovering || isSelected else { return }
        let color = isSelected
            ? Theme.shared.palette.accent.withAlphaComponent(0.22)
            : Theme.shared.palette.surfaceHover
        color.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 2), xRadius: 14, yRadius: 14).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        drawBackground(in: dirtyRect)
    }
}

final class AddressSuggestionsPopover: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let rowHeight: CGFloat = 40
    private let maxVisibleRows = 7
    private let vPad: CGFloat = 8
    private let popover = NSPopover()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let viewCtrl = NSViewController()
    
    private var suggestions: [SuggestionItem] = []
    weak var delegate: AddressSuggestionsDelegate?
    weak var targetField: NSTextField?
    
    // Flag to prevent selection changes from re-triggering text changes
    var isInternalUpdate = false
    
    override init() {
        super.init()
        setupUI()
    }
    
    private func setupUI() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.headerView = nil
        tableView.rowHeight = rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.target = self
        tableView.action = #selector(clickedRow)
        tableView.refusesFirstResponder = true
        
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SuggestionCol"))
        col.width = 400
        tableView.addTableColumn(col)
        
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: vPad, left: 0, bottom: vPad, right: 0)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 280))
        container.wantsLayer = true
        container.layer?.cornerRadius = 14
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        scrollView.frame = container.bounds
        scrollView.autoresizingMask = [.width, .height]
        container.addSubview(scrollView)

        viewCtrl.view = container

        popover.contentViewController = viewCtrl
        popover.behavior = .transient
        popover.animates = false
    }

    /// Match the Breeze palette (called on every show in case the theme changed).
    private func styleForTheme() {
        let p = Theme.shared.palette
        popover.appearance = NSAppearance(named: p.isDark ? .darkAqua : .aqua)
        viewCtrl.view.layer?.backgroundColor = (p.isDark ? p.bg : NSColor.white).cgColor
        viewCtrl.view.layer?.borderColor = NSColor.white.withAlphaComponent(p.isDark ? 0.12 : 0.0).cgColor
    }

    func show(relativeTo textField: NSTextField, items: [SuggestionItem], preferredEdge: NSRectEdge = .minY) {
        let previousField = targetField
        self.targetField = textField
        self.suggestions = items
        styleForTheme()
        tableView.reloadData()

        if items.isEmpty {
            popover.close()
            return
        }

        let visibleRows = min(items.count, maxVisibleRows)
        let height = CGFloat(visibleRows) * rowHeight + vPad * 2
        let width = max(textField.bounds.width, 380)
        let size = NSSize(width: width, height: height)
        viewCtrl.view.frame.size = size
        popover.contentSize = size
        scrollView.hasVerticalScroller = items.count > maxVisibleRows
        
        let needsNewAnchor = popover.isShown && previousField !== textField
        if needsNewAnchor { popover.close() }
        if !popover.isShown {
            popover.show(relativeTo: textField.bounds, of: textField, preferredEdge: preferredEdge)
            if let window = textField.window {
                DispatchQueue.main.async {
                    window.makeKeyAndOrderFront(nil)
                    window.makeFirstResponder(textField)
                    if let editor = textField.currentEditor() as? NSTextView {
                        let len = textField.stringValue.count
                        editor.selectedRange = NSRange(location: len, length: 0)
                    }
                }
            }
        }
        
        // Reset selection without triggering the text field update
        isInternalUpdate = true
        tableView.selectRowIndexes(IndexSet(), byExtendingSelection: false)
        isInternalUpdate = false
    }
    
    func hide() {
        popover.close()
    }
    
    var isShown: Bool { popover.isShown }
    
    @objc private func clickedRow() {
        let row = tableView.clickedRow
        if row >= 0 && row < suggestions.count {
            delegate?.didSelectSuggestion(suggestions[row].url)
            hide()
        }
    }
    
    // MARK: - Keyboard Navigation
    
    func moveSelectionDown() {
        guard !suggestions.isEmpty else { return }
        let next = min(tableView.selectedRow + 1, suggestions.count - 1)
        isInternalUpdate = true
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
        isInternalUpdate = false
        updateTextFieldForSelection()
    }
    
    func moveSelectionUp() {
        guard !suggestions.isEmpty else { return }
        let prev = max(tableView.selectedRow - 1, -1) // -1 unselects
        isInternalUpdate = true
        tableView.selectRowIndexes(IndexSet(integer: prev), byExtendingSelection: false)
        if prev >= 0 { tableView.scrollRowToVisible(prev) }
        isInternalUpdate = false
        updateTextFieldForSelection()
    }
    
    func triggerSelected() -> Bool {
        let row = tableView.selectedRow
        guard row >= 0 && row < suggestions.count else { return false }
        delegate?.didSelectSuggestion(suggestions[row].url)
        hide()
        return true
    }
    
    private func updateTextFieldForSelection() {
        let row = tableView.selectedRow
        if row >= 0 && row < suggestions.count {
            delegate?.textChanged(to: suggestions[row].url)
        }
    }
    
    // MARK: - NSTableViewDataSource & Delegate
    
    func numberOfRows(in tableView: NSTableView) -> Int {
        return suggestions.count
    }
    
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = suggestions[row]
        let id = NSUserInterfaceItemIdentifier("SuggestionCell")
        var cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView
        
        if cell == nil {
            cell = NSTableCellView()
            cell?.identifier = id
            
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.tag = 101
            
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.font = .systemFont(ofSize: 14, weight: .medium)
            tf.lineBreakMode = .byTruncatingTail
            tf.tag = 102

            let urlF = NSTextField(labelWithString: "")
            urlF.translatesAutoresizingMaskIntoConstraints = false
            urlF.font = .systemFont(ofSize: 12.5)
            urlF.textColor = .secondaryLabelColor
            urlF.lineBreakMode = .byTruncatingTail
            urlF.tag = 103

            cell?.addSubview(icon)
            cell?.addSubview(tf)
            cell?.addSubview(urlF)

            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell!.leadingAnchor, constant: 17),
                icon.centerYAnchor.constraint(equalTo: cell!.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),

                tf.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
                tf.centerYAnchor.constraint(equalTo: cell!.centerYAnchor),

                urlF.leadingAnchor.constraint(equalTo: tf.trailingAnchor, constant: 10),
                urlF.trailingAnchor.constraint(lessThanOrEqualTo: cell!.trailingAnchor, constant: -16),
                urlF.centerYAnchor.constraint(equalTo: cell!.centerYAnchor)
            ])
            
            urlF.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        
        if let icon = cell?.viewWithTag(101) as? NSImageView {
            switch item.type {
            case .bookmark: icon.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil)
            case .history: icon.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
            case .search: icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
            case .task:
                let slug = item.url.hasPrefix("/") ? String(item.url.dropFirst()) : item.url
                let sym = BreezeTask.match(slug)?.symbol ?? "bolt.fill"
                icon.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)
            }
            icon.contentTintColor = item.type == .task ? Theme.shared.palette.accent : Theme.shared.palette.textSoft
        }

        let p = Theme.shared.palette
        if let tf = cell?.viewWithTag(102) as? NSTextField {
            tf.stringValue = item.title.isEmpty ? item.url : item.title
            tf.textColor = p.text
        }

        if let urlF = cell?.viewWithTag(103) as? NSTextField {
            urlF.stringValue = item.type == .task
                ? item.subtitle
                : item.url.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
            urlF.textColor = p.textSoft
        }
        
        return cell
    }
    
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("SuggestionRowView")
        var rowView = tableView.makeView(withIdentifier: id, owner: self) as? RoundedSuggestionRowView
        if rowView == nil {
            rowView = RoundedSuggestionRowView()
            rowView?.identifier = id
        }
        return rowView
    }
    
    func tableViewSelectionDidChange(_ notification: Notification) {
        let p = Theme.shared.palette
        tableView.enumerateAvailableRowViews { rowView, _ in
            if let cell = rowView.view(atColumn: 0) as? NSTableCellView {
                if let tf = cell.viewWithTag(102) as? NSTextField { tf.textColor = p.text }
                if let urlF = cell.viewWithTag(103) as? NSTextField { urlF.textColor = p.textSoft }
            }
        }
    }
}
