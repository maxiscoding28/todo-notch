import AppKit

final class DropdownPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class ItemTextField: NSTextField {
    var itemId: UUID?
}

final class TodoRowView: NSView {
    let itemId: UUID?
    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let field = ItemTextField(frame: .zero)
    private let indent: CGFloat

    init(itemId: UUID?, indent: CGFloat) {
        self.itemId = itemId
        self.indent = indent
        super.init(frame: .zero)
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

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        checkbox.frame = NSRect(x: indent, y: (bounds.height - 18) / 2, width: 18, height: 18)
        let x = indent + 24
        field.frame = NSRect(x: x, y: (bounds.height - 18) / 2, width: max(40, bounds.width - x - 8), height: 18)
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
        badgeView.addSubview(badgeLabel)
        if let badge {
            badgeLabel.stringValue = "\(badge)"
        } else {
            badgeView.isHidden = true
        }

        addSubview(chevron)
        addSubview(titleLabel)
        addSubview(badgeView)
        toolTip = empty ? "Click to add a todo" : "Click to fold"
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
        titleLabel.frame = NSRect(x: 28, y: midY - titleSize.height / 2, width: titleSize.width, height: titleSize.height)
        let textSize = badgeLabel.fittingSize
        let badgeWidth = max(18, textSize.width + 10)
        badgeView.frame = NSRect(x: titleLabel.frame.maxX + 6, y: midY - 7, width: badgeWidth, height: 14)
        badgeLabel.frame = NSRect(x: 0, y: (14 - textSize.height) / 2, width: badgeWidth, height: textSize.height)
    }
}

/// Flipped container that stacks rows from the top at a fixed height.
final class RowsView: NSView {
    static let rowHeight: CGFloat = 24
    private(set) var rows: [NSView] = []

    override var isFlipped: Bool { true }

    func setRows(_ newRows: [NSView]) {
        rows.forEach { $0.removeFromSuperview() }
        rows = newRows
        rows.forEach { addSubview($0) }
        setFrameSize(NSSize(width: frame.width, height: CGFloat(rows.count) * Self.rowHeight))
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        for (i, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: CGFloat(i) * Self.rowHeight, width: bounds.width, height: Self.rowHeight)
        }
        window?.invalidateCursorRects(for: self)
    }
}

/// Covers the panel while a confirm card shows. Absorbs clicks so rows below get none.
final class OverlayView: NSView {
    override func mouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
}
