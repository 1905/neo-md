import AppKit
import MDCore

/// The Render tab outline (frame 03): an `OUTLINE` title over a source-list table of headings.
/// A click or arrow key calls `onSelect`. `highlight(line:)` follows the preview scroll without calling it.
@MainActor
final class OutlineSidebar: NSView, NSTableViewDataSource, NSTableViewDelegate {
    static let width: CGFloat = 220
    static let indentPerLevel: CGFloat = 12

    /// The user picked a heading. The owner scrolls the preview to `item.line`.
    var onSelect: ((OutlineItem) -> Void)?

    /// Headings of the last render. A new list reloads the table and keeps the highlight on the current line.
    var items: [OutlineItem] = [] {
        didSet {
            guard items != oldValue else { return }
            tableView.reloadData()
            highlight(line: visibleLine)
        }
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    /// Source line at the top of the preview, from the last `highlight(line:)`.
    private var visibleLine = 1
    /// True while the selection changes from code, so `onSelect` does not scroll the preview back.
    private var selectingFromCode = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        titleLabel.attributedStringValue = NSAttributedString(string: "OUTLINE", attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .kern: 0.7,
        ])

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("heading"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.backgroundColor = .clear
        tableView.rowHeight = 24
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.allowsEmptySelection = true
        tableView.focusRingType = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked(_:))

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false

        for view in [titleLabel, scrollView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18),
            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        updateBackground()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    // MARK: - Highlight

    /// Selects the last heading at or above `line` (none if the first heading is below it).
    /// Scrolls the table, never the preview.
    func highlight(line: Int) {
        visibleLine = line
        let row = Self.row(forLine: line, in: items)
        selectingFromCode = true
        defer { selectingFromCode = false }
        if let row {
            if tableView.selectedRow != row {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            tableView.scrollRowToVisible(row)
        } else {
            tableView.deselectAll(nil)
        }
    }

    /// Index of the last item with `line ≤ line`, or nil.
    static func row(forLine line: Int, in items: [OutlineItem]) -> Int? {
        items.lastIndex { $0.line <= line }
    }

    // MARK: - User selection

    /// A click on a row, also on the row that is already selected.
    @objc private func rowClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        guard items.indices.contains(row) else { return }
        onSelect?(items[row])
    }

    /// Arrow keys. A click that changes the row lands here first, then in `rowClicked`; the second scroll is a no-op.
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !selectingFromCode else { return }
        let row = tableView.selectedRow
        guard items.indices.contains(row), NSApp.currentEvent?.type == .keyDown else { return }
        onSelect?(items[row])
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: OutlineCell.identifier, owner: self) as? OutlineCell ?? OutlineCell()
        cell.configure(with: items[row])
        return cell
    }
}

/// One heading row: indent `(level - 1) * 12` pt, tail truncation, level ≥ 3 dimmed.
@MainActor
private final class OutlineCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("OutlineCell")

    private let label = NSTextField(labelWithString: "")
    private var indent: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        indent = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4)
        NSLayoutConstraint.activate([
            indent,
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(with item: OutlineItem) {
        label.stringValue = item.text
        label.textColor = item.level <= 2 ? .labelColor : .secondaryLabelColor
        indent.constant = 4 + CGFloat(max(item.level - 1, 0)) * OutlineSidebar.indentPerLevel
        toolTip = item.text
    }
}
