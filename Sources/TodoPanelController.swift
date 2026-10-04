import AppKit
import ServiceManagement

final class TodoPanelController: NSObject, NSTextFieldDelegate {
    var onHeightChange: (() -> Void)?
    var onClose: (() -> Void)?

    private(set) var config = Config.load()
    var fileURL: URL { config.todoURL }

    let view: NSVisualEffectView = {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = 14
        v.layer?.masksToBounds = true
        return v
    }()

    private let headerLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let rowsView = RowsView()
    private let hintLabel = NSTextField(labelWithString: "↑↓ move  ·  ↩ add  ·  ⇥ nest  ·  esc close")
    private let loginBox = NSButton(checkboxWithTitle: "Open at login", target: nil, action: nil)

    private var file = TodoFile(sections: [], items: [])
    private static let collapsedKey = "collapsedSections"
    private var collapsed = Set(UserDefaults.standard.stringArray(forKey: TodoPanelController.collapsedKey) ?? [])
    private var lastKnownContent: String?
    private var watcher: FileWatcher?
    private var keyMonitor: Any?
    private var isRebuilding = false
    private var pendingDelete: (id: UUID, focus: UUID?, focusPrevious: Bool)?
    private var overlay: NSView?

    /// The row field that holds the cursor. Reads the window's first responder, so it is correct before any typing.
    private var currentEditingField: ItemTextField? {
        guard let responder = view.window?.firstResponder as? NSView else { return nil }
        var node: NSView? = responder
        while let current = node {
            if let field = current as? ItemTextField { return field }
            node = current.superview
        }
        return nil
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d"
        return f
    }()

    override init() {
        super.init()
        buildUI()
        startWatching()
        NotificationCenter.default.addObserver(
            self, selector: #selector(configChanged), name: Config.didChange, object: nil
        )
    }

    /// Loads the file at the configured path and watches it. Creates the file when it does not exist.
    private func startWatching() {
        watcher?.stop()
        lastKnownContent = nil
        file = TodoFile(sections: [], items: [])
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            var empty = TodoFile(sections: [], items: [])
            empty.conform(to: requiredSections())
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? empty.serialize().write(to: fileURL, atomically: true, encoding: .utf8)
        }
        refreshFromDisk()
        let w = FileWatcher(path: fileURL.path)
        w.onChange = { [weak self] in self?.refreshFromDisk() }
        w.start()
        watcher = w
    }

    @objc private func configChanged() {
        let previousFile = fileURL
        config = Config.load()
        if fileURL != previousFile {
            startWatching()
        } else {
            syncSections()
        }
    }

    // MARK: UI

    private func buildUI() {
        headerLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        headerLabel.textColor = .labelColor

        hintLabel.font = .systemFont(ofSize: 10)
        hintLabel.textColor = .secondaryLabelColor

        loginBox.font = .systemFont(ofSize: 10)
        loginBox.controlSize = .mini
        loginBox.target = self
        loginBox.action = #selector(loginToggled(_:))
        loginBox.state = SMAppService.mainApp.status == .enabled ? .on : .off

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        rowsView.frame = NSRect(x: 0, y: 0, width: 360, height: 0)
        rowsView.autoresizingMask = [.width]
        scrollView.documentView = rowsView

        for v in [headerLabel, scrollView, hintLabel, loginBox] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            headerLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -14),
            scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
            scrollView.bottomAnchor.constraint(equalTo: hintLabel.topAnchor, constant: -8),
            hintLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            hintLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
            loginBox.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            loginBox.centerYAnchor.constraint(equalTo: hintLabel.centerYAnchor),
        ])
    }

    func preferredHeight() -> CGFloat {
        let rows = CGFloat(max(rowsView.rows.count, 1))
        let rowsHeight = min(rows * RowsView.rowHeight + 4, 520)
        return 12 + 18 + 6 + rowsHeight + 8 + 14 + 10
    }

    private func rebuild(focus: UUID? = nil) {
        isRebuilding = true
        view.window?.makeFirstResponder(nil)

        var rows: [NSView] = []
        for section in file.sections {
            let items = file.items.filter { $0.section == section }
            let open = items.filter { $0.depth == 0 && !$0.checked }.count
            let folded = isCollapsed(section)
            let header = SectionHeaderView(
                title: section,
                collapsed: folded,
                badge: folded && open > 0 ? open : nil,
                empty: items.isEmpty
            )
            header.onClick = { [weak self] in self?.headerClicked(section) }
            rows.append(header)
            if !folded { rows += items.map(makeRow) }
        }
        rowsView.setRows(rows)

        let openCount = file.items.filter { $0.depth == 0 && !$0.checked }.count
        headerLabel.stringValue = Self.dateFormatter.string(from: Date())
            + "   ·   \(openCount) open"

        isRebuilding = false
        onHeightChange?()

        if let focus, let row = rows.compactMap({ $0 as? TodoRowView }).first(where: { $0.itemId == focus }) {
            view.layoutSubtreeIfNeeded()
            view.window?.makeFirstResponder(row.field)
            placeCursorAtEnd(row.field)
            scrollToVisible(row)
        }
    }

    private func makeRow(_ item: TodoItem) -> TodoRowView {
        let row = TodoRowView(itemId: item.id, indent: 26 + CGFloat(item.depth) * 20)
        row.checkbox.state = item.checked ? .on : .off
        row.checkbox.target = self
        row.checkbox.action = #selector(toggleCheck(_:))
        if item.checked {
            row.field.attributedStringValue = NSAttributedString(string: item.text, attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        } else {
            row.field.stringValue = item.text
        }
        row.field.delegate = self
        return row
    }

    // MARK: Sections

    /// An empty section is always collapsed. Other sections follow the saved fold state.
    private func isCollapsed(_ section: String) -> Bool {
        !file.items.contains { $0.section == section } || collapsed.contains(section)
    }

    private func setCollapsed(_ section: String, _ value: Bool) {
        if value { collapsed.insert(section) } else { collapsed.remove(section) }
        UserDefaults.standard.set(Array(collapsed).sorted(), forKey: Self.collapsedKey)
    }

    /// Section names from the configured folder sources.
    private func requiredSections() -> [String] {
        config.requiredSections()
    }

    /// What applying `newConfig` does to the section list of its todo file. Tasks are never removed.
    func preview(_ newConfig: Config) -> ConfigPreview {
        let current: TodoFile
        if newConfig.todoURL == fileURL {
            current = file
        } else if let text = try? String(contentsOf: newConfig.todoURL, encoding: .utf8) {
            current = TodoFile.parse(text)
        } else {
            current = TodoFile(sections: [], items: [])
        }
        let newRequired = newConfig.requiredSections()
        var after = current
        after.conform(to: newRequired)
        let before = Set(current.sections)
        let afterSet = Set(after.sections)
        let required = Set(newRequired)
        let oldRequired = Set(config.requiredSections())
        return ConfigPreview(
            sections: after.sections,
            added: after.sections.filter { !before.contains($0) },
            removed: current.sections.filter { !afterSet.contains($0) },
            unsynced: after.sections.filter { oldRequired.contains($0) && !required.contains($0) },
            newFile: newConfig.todoURL != fileURL
        )
    }

    /// Adds sections for new source folders. Saves only when the structure changes.
    func syncSections() {
        guard !isEditing else { return }
        let before = file.serialize()
        file.conform(to: requiredSections())
        if file.serialize() != before {
            saveNonEmpty()
            rebuild()
        }
    }

    private func headerClicked(_ section: String) {
        _ = commitFocusedText()
        if file.items.contains(where: { $0.section == section }) {
            setCollapsed(section, !collapsed.contains(section))
            saveNonEmpty()
            rebuild()
        } else {
            setCollapsed(section, false)
            let item = TodoItem(text: "", section: section)
            file.items.insert(item, at: file.endIndex(of: section))
            rebuild(focus: item.id)
        }
    }

    private func scrollToVisible(_ row: TodoRowView) {
        let clip = scrollView.contentView
        var origin = clip.bounds.origin
        let r = row.frame
        if r.maxY > origin.y + clip.bounds.height {
            origin.y = r.maxY - clip.bounds.height
        } else if r.minY < origin.y {
            origin.y = r.minY
        }
        clip.scroll(to: NSPoint(x: 0, y: max(0, origin.y)))
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: File

    func refreshFromDisk() {
        guard !isEditing, let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        guard content != lastKnownContent else { return }
        lastKnownContent = content
        file = TodoFile.parse(content)
        file.conform(to: requiredSections())
        if file.serialize() != content { saveNonEmpty() }
        rebuild()
    }

    private var isEditing: Bool { currentEditingField != nil }

    private func save() {
        let content = file.serialize()
        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            lastKnownContent = content
        } catch {
            NSSound.beep()
        }
    }

    // MARK: Panel lifecycle

    func panelDidOpen() {
        loginBox.state = SMAppService.mainApp.status == .enabled ? .on : .off
        syncSections()
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, let window = self.view.window, event.window === window else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    func panelWillClose() {
        hideOverlay()
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
        if let field = currentEditingField, let idx = index(of: field) {
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty || subtaskCount(at: idx) == 0 {
                file.items[idx].text = text
            }
        }
        isRebuilding = true
        view.window?.makeFirstResponder(nil)
        isRebuilding = false
        file.items.removeAll { $0.text.isEmpty }
        if file.serialize() != lastKnownContent {
            save()
        }
        rebuild()
    }

    // MARK: Keys

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if pendingDelete != nil {
            switch event.keyCode {
            case 36, 76: confirmPendingDelete()
            case 53: cancelPendingDelete()
            default: break
            }
            return true
        }
        if flags.contains(.command) { return false }
        switch event.keyCode {
        case 53:
            onClose?()
            return true
        case 48:
            if flags.contains(.shift) { shiftFocused(by: -1) } else { shiftFocused(by: 1) }
            return true
        case 36, 76:
            returnPressed()
            return true
        case 126:
            moveFocus(by: -1)
            return true
        case 125:
            moveFocus(by: 1)
            return true
        case 51, 117:
            guard let field = currentEditingField, let idx = index(of: field) else { return false }
            let length = (field.stringValue as NSString).length
            let selection = field.currentEditor()?.selectedRange
            let allSelected = length > 0 && selection?.location == 0 && selection?.length == length
            if length == 0 || (allSelected && subtaskCount(at: idx) > 0) {
                deleteFocused()
                return true
            }
            return false
        default:
            return false
        }
    }

    private func index(of field: ItemTextField) -> Int? {
        guard let id = field.itemId else { return nil }
        return file.items.firstIndex { $0.id == id }
    }

    private func commitFocusedText() -> Int? {
        guard let field = currentEditingField, let idx = index(of: field) else { return nil }
        file.items[idx].text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return idx
    }

    /// Moves the cursor to the previous or next visible task. Skips section headers and collapsed sections.
    /// With no cursor, Down goes to the first task and Up goes to the last task.
    private func moveFocus(by delta: Int) {
        let visible = rowsView.rows.compactMap { $0 as? TodoRowView }.filter { $0.itemId != nil }
        guard !visible.isEmpty else { return }
        guard let field = currentEditingField,
              let pos = visible.firstIndex(where: { $0.field === field }) else {
            focus(delta > 0 ? visible[0] : visible[visible.count - 1])
            return
        }
        let target = pos + delta
        guard visible.indices.contains(target) else { return }
        let targetRow = visible[target]
        if field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let idx = index(of: field) {
            requestDelete(id: file.items[idx].id, focus: targetRow.itemId)
            return
        }
        _ = commitFocusedText()
        saveNonEmpty()
        focus(targetRow)
    }

    private func focus(_ row: TodoRowView) {
        view.window?.makeFirstResponder(row.field)
        placeCursorAtEnd(row.field)
        scrollToVisible(row)
    }

    private func placeCursorAtEnd(_ field: NSTextField) {
        let length = (field.stringValue as NSString).length
        field.currentEditor()?.selectedRange = NSRange(location: length, length: 0)
    }

    private func returnPressed() {
        let item: TodoItem
        if let idx = commitFocusedText() {
            let base = file.items[idx].depth
            let section = file.items[idx].section
            var end = idx + 1
            while end < file.items.count, file.items[end].section == section, file.items[end].depth > base { end += 1 }
            item = TodoItem(text: "", depth: base, section: section)
            file.items.insert(item, at: end)
        } else {
            guard let section = file.sections.first(where: { !isCollapsed($0) }) ?? file.sections.first else { return }
            setCollapsed(section, false)
            item = TodoItem(text: "", section: section)
            file.items.insert(item, at: file.endIndex(of: section))
        }
        saveNonEmpty()
        rebuild(focus: item.id)
    }

    private func shiftFocused(by delta: Int) {
        guard let idx = commitFocusedText() else { return }
        let base = file.items[idx].depth
        let section = file.items[idx].section
        if delta > 0 {
            guard idx > 0, file.items[idx - 1].section == section, file.items[idx - 1].depth >= base else { return }
        } else {
            guard base > 0 else { return }
        }
        var i = idx
        while i < file.items.count, i == idx || (file.items[i].section == section && file.items[i].depth > base) {
            file.items[i].depth = max(0, file.items[i].depth + delta)
            i += 1
        }
        saveNonEmpty()
        rebuild(focus: file.items[idx].id)
    }

    private func deleteFocused() {
        guard let field = currentEditingField, let idx = index(of: field) else { return }
        requestDelete(id: file.items[idx].id, focusPrevious: true)
    }

    /// The number of sub-tasks under the item at `index`.
    private func subtaskCount(at index: Int) -> Int {
        let base = file.items[index].depth
        let section = file.items[index].section
        var end = index + 1
        while end < file.items.count, file.items[end].section == section, file.items[end].depth > base { end += 1 }
        return end - index - 1
    }

    /// Deletes a task at once when it has no sub-tasks. Else shows the confirm overlay first.
    private func requestDelete(id: UUID, focus: UUID? = nil, focusPrevious: Bool = false) {
        guard let idx = file.items.firstIndex(where: { $0.id == id }) else { return }
        let count = subtaskCount(at: idx)
        guard count > 0 else {
            performDelete(id: id, focus: focus, focusPrevious: focusPrevious)
            return
        }
        isRebuilding = true
        view.window?.makeFirstResponder(nil)
        isRebuilding = false
        pendingDelete = (id, focus, focusPrevious)
        showOverlay(
            title: "Delete this task and \(count) subtask\(count == 1 ? "" : "s")?",
            detail: file.items[idx].text
        )
    }

    private func performDelete(id: UUID, focus: UUID?, focusPrevious: Bool) {
        guard let idx = file.items.firstIndex(where: { $0.id == id }) else { return }
        var target = focus
        if focusPrevious, idx > 0, file.items[idx - 1].section == file.items[idx].section {
            target = file.items[idx - 1].id
        }
        deleteSubtree(at: idx)
        saveNonEmpty()
        rebuild(focus: target)
    }

    @objc private func confirmPendingDelete() {
        guard let pending = pendingDelete else { return }
        hideOverlay()
        performDelete(id: pending.id, focus: pending.focus, focusPrevious: pending.focusPrevious)
    }

    /// Closes the overlay. The task keeps its saved text, so the rebuild restores it.
    @objc private func cancelPendingDelete() {
        guard let pending = pendingDelete else { return }
        hideOverlay()
        rebuild(focus: pending.id)
    }

    private func hideOverlay() {
        pendingDelete = nil
        overlay?.removeFromSuperview()
        overlay = nil
    }

    private func showOverlay(title: String, detail: String) {
        overlay?.removeFromSuperview()
        let dim = OverlayView()
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        dim.translatesAutoresizingMaskIntoConstraints = false

        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        card.layer?.cornerRadius = 10
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        let detailLabel = NSTextField(labelWithString: detail.isEmpty ? "This task has no text." : detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let cancel = NSButton(title: "Cancel  esc", target: self, action: #selector(cancelPendingDelete))
        let delete = NSButton(title: "Delete  ↩", target: self, action: #selector(confirmPendingDelete))
        delete.hasDestructiveAction = true
        delete.keyEquivalent = "\r"
        for b in [cancel, delete] {
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
            b.refusesFirstResponder = true
        }

        for v in [titleLabel, detailLabel, cancel, delete] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(v)
        }
        dim.addSubview(card)
        view.addSubview(dim)

        NSLayoutConstraint.activate([
            dim.topAnchor.constraint(equalTo: view.topAnchor),
            dim.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            dim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            card.centerXAnchor.constraint(equalTo: dim.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: dim.centerYAnchor),
            card.widthAnchor.constraint(equalTo: dim.widthAnchor, constant: -40),
            titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -14),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -14),
            delete.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 10),
            delete.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            delete.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
            cancel.centerYAnchor.constraint(equalTo: delete.centerYAnchor),
            cancel.trailingAnchor.constraint(equalTo: delete.leadingAnchor, constant: -8),
        ])
        overlay = dim
    }

    private func deleteSubtree(at index: Int) {
        let base = file.items[index].depth
        let section = file.items[index].section
        var end = index + 1
        while end < file.items.count, file.items[end].section == section, file.items[end].depth > base { end += 1 }
        file.items.removeSubrange(index..<end)
    }

    /// Saves without empty draft items, so the file never holds blank todo lines.
    private func saveNonEmpty() {
        var copy = file
        copy.items.removeAll { $0.text.isEmpty }
        let content = copy.serialize()
        guard content != lastKnownContent else { return }
        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            lastKnownContent = content
        } catch {
            NSSound.beep()
        }
    }

    // MARK: Actions

    @objc private func toggleCheck(_ sender: NSButton) {
        guard let row = sender.superview as? TodoRowView,
              let id = row.itemId,
              let idx = file.items.firstIndex(where: { $0.id == id }) else { return }
        _ = commitFocusedText()
        file.items[idx].checked = sender.state == .on
        saveNonEmpty()
        rebuild()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard !isRebuilding, let field = obj.object as? ItemTextField, let idx = index(of: field) else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty, subtaskCount(at: idx) > 0 {
            let id = file.items[idx].id
            DispatchQueue.main.async { [weak self] in
                self?.requestDelete(id: id)
            }
            return
        } else if text.isEmpty {
            deleteSubtree(at: idx)
        } else if text == file.items[idx].text {
            return
        } else {
            file.items[idx].text = text
        }
        saveNonEmpty()
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isEditing else { return }
            self.rebuild()
        }
    }

    @objc private func loginToggled(_ sender: NSButton) {
        do {
            if sender.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSSound.beep()
        }
        sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}
