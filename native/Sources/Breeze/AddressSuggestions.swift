import Cocoa

enum SuggestionType {
    case bookmark
    case history
    case search
}

struct SuggestionItem {
    let title: String
    let url: String
    let type: SuggestionType
}

protocol AddressSuggestionsDelegate: AnyObject {
    func didSelectSuggestion(_ url: String)
    func textChanged(to text: String)
}

final class AddressSuggestionsPopover: NSObject, NSTableViewDataSource, NSTableViewDelegate {
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
        tableView.rowHeight = 32
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.target = self
        tableView.action = #selector(clickedRow)
        
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SuggestionCol"))
        col.width = 400
        tableView.addTableColumn(col)
        
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 450, height: 280))
        scrollView.frame = container.bounds
        scrollView.autoresizingMask = [.width, .height]
        container.addSubview(scrollView)
        
        viewCtrl.view = container
        
        popover.contentViewController = viewCtrl
        popover.behavior = .transient
        popover.animates = false
    }
    
    func show(relativeTo textField: NSTextField, items: [SuggestionItem]) {
        self.targetField = textField
        self.suggestions = items
        tableView.reloadData()
        
        if items.isEmpty {
            popover.close()
            return
        }
        
        if !popover.isShown {
            popover.show(relativeTo: textField.bounds, of: textField, preferredEdge: .minY)
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
            tf.font = .systemFont(ofSize: 13, weight: .medium)
            tf.lineBreakMode = .byTruncatingTail
            tf.tag = 102
            
            let urlF = NSTextField(labelWithString: "")
            urlF.translatesAutoresizingMaskIntoConstraints = false
            urlF.font = .systemFont(ofSize: 12)
            urlF.textColor = .secondaryLabelColor
            urlF.lineBreakMode = .byTruncatingTail
            urlF.tag = 103
            
            cell?.addSubview(icon)
            cell?.addSubview(tf)
            cell?.addSubview(urlF)
            
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell!.leadingAnchor, constant: 14),
                icon.centerYAnchor.constraint(equalTo: cell!.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 14),
                icon.heightAnchor.constraint(equalToConstant: 14),
                
                tf.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
                tf.centerYAnchor.constraint(equalTo: cell!.centerYAnchor),
                
                urlF.leadingAnchor.constraint(equalTo: tf.trailingAnchor, constant: 10),
                urlF.trailingAnchor.constraint(lessThanOrEqualTo: cell!.trailingAnchor, constant: -14),
                urlF.centerYAnchor.constraint(equalTo: cell!.centerYAnchor)
            ])
            
            urlF.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        
        if let icon = cell?.viewWithTag(101) as? NSImageView {
            switch item.type {
            case .bookmark: icon.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil)
            case .history: icon.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
            case .search: icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
            }
            icon.contentTintColor = .secondaryLabelColor
        }
        
        if let tf = cell?.viewWithTag(102) as? NSTextField {
            tf.stringValue = item.title.isEmpty ? item.url : item.title
            tf.textColor = (tableView.selectedRow == row) ? .selectedControlTextColor : .labelColor
        }
        
        if let urlF = cell?.viewWithTag(103) as? NSTextField {
            let u = item.url.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
            urlF.stringValue = u
            urlF.textColor = (tableView.selectedRow == row) ? .selectedControlTextColor.withAlphaComponent(0.7) : .secondaryLabelColor
        }
        
        return cell
    }
    
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("SuggestionRowView")
        var rowView = tableView.makeView(withIdentifier: id, owner: self) as? NSTableRowView
        if rowView == nil {
            rowView = NSTableRowView()
            rowView?.identifier = id
        }
        return rowView
    }
    
    func tableViewSelectionDidChange(_ notification: Notification) {
        tableView.enumerateAvailableRowViews { rowView, row in
            if let cell = rowView.view(atColumn: 0) as? NSTableCellView {
                let isSelected = tableView.selectedRow == row
                if let tf = cell.viewWithTag(102) as? NSTextField {
                    tf.textColor = isSelected ? .selectedControlTextColor : .labelColor
                }
                if let urlF = cell.viewWithTag(103) as? NSTextField {
                    urlF.textColor = isSelected ? .selectedControlTextColor.withAlphaComponent(0.7) : .secondaryLabelColor
                }
            }
        }
    }
}
