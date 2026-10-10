import AppKit

final class DropdownPanel: NSPanel {
    let actionUndoManager = UndoManager()
    override var undoManager: UndoManager? { actionUndoManager }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class TodoFieldEditor: NSTextView {
    weak var sharedUndoManager: UndoManager?
    override var undoManager: UndoManager? { sharedUndoManager }
}

final class ItemTextField: NSTextField {
    var itemId: UUID?
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class TodoRowView: NSView {
    let itemId: UUID?
    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let field = ItemTextField(frame: .zero)
    var onToggle: (() -> Void)?
    private var disclosure: NSButton?
    private var indent: CGFloat

    init(itemId: UUID?, indent: CGFloat, collapsed: Bool?) {
        self.itemId = itemId
        self.indent = indent
        super.init(frame: .zero)
        updateDisclosure(collapsed)
        field.itemId = itemId
        field.isBordered = false
        field.drawsBackground = false
        field.font = .systemFont(ofSize: 13)
        field.textColor = .labelColor
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        addSubview(checkbox)
        addSubview(field)
    }

    func update(_ item: TodoItem, collapsed: Bool?) {
        indent = 26 + CGFloat(item.depth) * 20
        updateDisclosure(collapsed)
        checkbox.state = item.checked ? .on : .off
        if field.currentEditor() == nil {
            field.attributedStringValue = NSAttributedString(string: item.text, attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: item.checked ? NSColor.secondaryLabelColor : NSColor.labelColor,
                .strikethroughStyle: item.checked ? NSUnderlineStyle.single.rawValue : 0,
            ])
        }
        needsLayout = true
    }

    private func updateDisclosure(_ collapsed: Bool?) {
        if let collapsed {
            let disclosure = self.disclosure ?? NSButton()
            self.disclosure = disclosure
            let symbol = collapsed ? "chevron.right" : "chevron.down"
            disclosure.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Toggle sub-tasks")?
                .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
            disclosure.contentTintColor = .secondaryLabelColor
            disclosure.isBordered = false
            disclosure.target = self
            disclosure.action = #selector(toggleSubtasks)
            disclosure.refusesFirstResponder = true
            disclosure.toolTip = collapsed ? "Show sub-tasks" : "Hide sub-tasks"
            addSubview(disclosure)
        } else {
            disclosure?.removeFromSuperview()
            disclosure = nil
        }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    @objc private func toggleSubtasks() {
        onToggle?()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let effectiveIndent = min(indent, max(26, bounds.width - 96))
        disclosure?.frame = NSRect(x: effectiveIndent - 18, y: (bounds.height - 16) / 2, width: 16, height: 16)
        checkbox.frame = NSRect(x: effectiveIndent, y: (bounds.height - 18) / 2, width: 18, height: 18)
        let x = effectiveIndent + 24
        field.frame = NSRect(x: x, y: (bounds.height - 18) / 2, width: max(0, bounds.width - x - 8), height: 18)
    }
}

/// A clickable section title. Shows a chevron, and a count badge when the section is collapsed.
final class SectionHeaderView: NSView {
    static let badgeColor = NSColor(srgbRed: 0.80, green: 0.88, blue: 1.0, alpha: 1)

    var onClick: (() -> Void)?
    private let chevron = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private let badgeView = NSView()

    init(title: String, collapsed: Bool, badge: Int?, empty: Bool) {
        super.init(frame: .zero)
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(chevron)
        addSubview(titleLabel)
        addSubview(badgeView)
        badgeView.addSubview(badgeLabel)
        update(title: title, collapsed: collapsed, badge: badge, empty: empty)
    }

    func update(title: String, collapsed: Bool, badge: Int?, empty: Bool) {
        let symbol = collapsed ? "chevron.right" : "chevron.down"
        chevron.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        chevron.contentTintColor = empty ? .tertiaryLabelColor : .secondaryLabelColor

        titleLabel.stringValue = title.uppercased()
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = empty ? .tertiaryLabelColor : .secondaryLabelColor

        badgeView.wantsLayer = true
        badgeView.layer?.backgroundColor = Self.badgeColor.cgColor
        badgeView.layer?.cornerRadius = 7
        badgeLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        badgeLabel.textColor = .black
        badgeLabel.alignment = .center
        if let badge {
            badgeLabel.stringValue = "\(badge)"
            badgeView.isHidden = false
        } else {
            badgeView.isHidden = true
        }

        toolTip = empty ? "Click to add a todo" : "Click to fold"
        needsLayout = true
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let midY = bounds.height / 2
        chevron.frame = NSRect(x: 10, y: midY - 6, width: 12, height: 12)
        let titleSize = titleLabel.fittingSize
        let textSize = badgeLabel.fittingSize
        let badgeWidth = max(18, textSize.width + 10)
        let available = max(0, bounds.width - 36 - (badgeView.isHidden ? 0 : badgeWidth + 6))
        titleLabel.frame = NSRect(x: 28, y: midY - titleSize.height / 2,
                                 width: min(titleSize.width, available), height: titleSize.height)
        badgeView.frame = NSRect(x: titleLabel.frame.maxX + 6, y: midY - 7, width: badgeWidth, height: 14)
        badgeLabel.frame = NSRect(x: 0, y: (14 - textSize.height) / 2, width: badgeWidth, height: textSize.height)
    }
}

/// Flipped container that arranges sections as one list or as columns.
final class RowsView: NSView {
    static let rowHeight: CGFloat = 24
    static let columnWidth: CGFloat = 300
    private(set) var rows: [NSView] = []
    private var sections: [[NSView]] = []
    private var horizontal = false

    override var isFlipped: Bool { true }

    var preferredHeight: CGFloat {
        let count = horizontal ? sections.map(\.count).max() ?? 0 : rows.count
        return CGFloat(max(count, 1)) * Self.rowHeight
    }

    var preferredWidth: CGFloat {
        horizontal ? CGFloat(max(sections.count, 1)) * Self.columnWidth : 360
    }

    func setSections(_ newSections: [[NSView]], horizontal: Bool) {
        let nextRows = newSections.flatMap { $0 }
        let nextIDs = Set(nextRows.map(ObjectIdentifier.init))
        rows.filter { !nextIDs.contains(ObjectIdentifier($0)) }.forEach { $0.removeFromSuperview() }
        sections = newSections
        rows = nextRows
        self.horizontal = horizontal
        rows.filter { $0.superview !== self }.forEach { addSubview($0) }
        autoresizingMask = horizontal ? [] : [.width]
        setFrameSize(NSSize(
            width: horizontal ? preferredWidth : max(frame.width, 360),
            height: preferredHeight
        ))
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        if horizontal {
            for (column, section) in sections.enumerated() {
                for (rowIndex, row) in section.enumerated() {
                    row.frame = NSRect(
                        x: CGFloat(column) * Self.columnWidth,
                        y: CGFloat(rowIndex) * Self.rowHeight,
                        width: Self.columnWidth,
                        height: Self.rowHeight
                    )
                }
            }
        } else {
            for (rowIndex, row) in rows.enumerated() {
                row.frame = NSRect(
                    x: 0,
                    y: CGFloat(rowIndex) * Self.rowHeight,
                    width: bounds.width,
                    height: Self.rowHeight
                )
            }
        }
        window?.invalidateCursorRects(for: self)
    }

}
