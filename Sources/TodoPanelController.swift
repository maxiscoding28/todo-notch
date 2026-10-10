import AppKit

final class TodoPanelController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
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
    private let hintLabel = NSTextField(labelWithString: "↑↓ move  ·  ↩ add  ·  ⇥ nest  ·  ⇧⌘L layout")

    private var file = TodoFile(sections: [], items: [])
    private var diskBase = TodoFile(sections: [], items: [])
    private var pendingDiskRefresh = false
    private var rowCache: [UUID: TodoRowView] = [:]
    private var headerCache: [String: SectionHeaderView] = [:]
    private var displayOrder: [String] = []
    private var conflictAlert: NSAlert?
    private var deletionAlert: NSAlert?
    private var completionTokens: [UUID: UUID] = [:]
    private var sourceSections: [String] = []
    private let fieldEditor = TodoFieldEditor()
    private static let collapsedKey = "collapsedSections"
    private var collapsed = Set(UserDefaults.standard.stringArray(forKey: TodoPanelController.collapsedKey) ?? [])
    private var collapsedItems = Set<UUID>()
    private var lastKnownContent: String?
    private var watcher: FileWatcher?
    private var keyMonitor: Any?
    private var isRebuilding = false
    private var pendingDelete: (id: UUID, focus: UUID?, focusPrevious: Bool)?
    private var pendingCompletionDeletes: [UUID: DispatchWorkItem] = [:]

    /// The row field that holds the cursor. Reads the window's first responder, so it is correct before any typing.
    private var currentEditingField: ItemTextField? {
        if let editor = view.window?.firstResponder as? NSTextView {
            if let field = rowCache.values.first(where: { $0.field.currentEditor() === editor })?.field { return field }
        }
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

    init(configuration: Config = Config.load()) {
        config = configuration
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
        pendingCompletionDeletes.values.forEach { $0.cancel() }
        pendingCompletionDeletes.removeAll()
        completionTokens.removeAll()
        rowCache.removeAll()
        headerCache.removeAll()
        collapsedItems.removeAll()
        displayOrder = []
        view.window?.undoManager?.removeAllActions()
        lastKnownContent = nil
        file = TodoFile(sections: [], items: [])
        diskBase = file
        pendingDiskRefresh = false
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
        let previousLayout = config.sectionLayout
        config = Config.load()
        sourceSections = config.requiredSections()
        if fileURL != previousFile {
            startWatching()
        } else {
            syncSections()
            if config.sectionLayout != previousLayout { rebuild(resetScrollPosition: true) }
        }
    }

    // MARK: UI

    private func buildUI() {
        headerLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        headerLabel.textColor = .labelColor

        hintLabel.font = .systemFont(ofSize: 10)
        hintLabel.textColor = .secondaryLabelColor

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = config.sectionLayout == .horizontal
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        rowsView.frame = NSRect(x: 0, y: 0, width: 360, height: 0)
        rowsView.autoresizingMask = [.width]
        scrollView.documentView = rowsView

        for v in [headerLabel, scrollView, hintLabel] as [NSView] {
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
            hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -14),
            hintLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
        ])
    }

    func preferredHeight() -> CGFloat {
        let scrollerHeight: CGFloat = config.sectionLayout == .horizontal ? 14 : 0
        let rowsHeight = min(rowsView.preferredHeight + scrollerHeight + 4, 520)
        return 12 + 18 + 6 + rowsHeight + 8 + 14 + 10
    }

    func preferredWidth() -> CGFloat {
        config.sectionLayout == .horizontal ? max(380, rowsView.preferredWidth + 12) : 380
    }

    private func rebuild(
        focus: UUID? = nil,
        cursorAtStart: Bool = false,
        resetScrollPosition: Bool = false
    ) {
        let active = currentEditingField
        let activeID = active?.itemId
        let selection = active?.currentEditor()?.selectedRange
        if active != nil { _ = commitFocusedText() }
        let anchor = rowsView.rows.first { $0.frame.intersects(scrollView.contentView.bounds) }
        let anchorOffset = anchor.map {
            NSPoint(x: scrollView.contentView.bounds.minX - $0.frame.minX,
                    y: scrollView.contentView.bounds.minY - $0.frame.minY)
        }
        isRebuilding = true
        let liveIDs = Set(file.items.map(\.id))
        rowCache = rowCache.filter { liveIDs.contains($0.key) }
        collapsedItems.formIntersection(liveIDs)
        headerCache = headerCache.filter { file.sections.contains($0.key) }
        let sorted = file.sectionsByDescendingTodoCount()
        if activeID == nil || resetScrollPosition { displayOrder = sorted }
        else {
            displayOrder = displayOrder.filter { file.sections.contains($0) }
            displayOrder += sorted.filter { !displayOrder.contains($0) }
        }
        let grouped = Dictionary(grouping: file.items, by: \.section)

        var sectionRows: [[NSView]] = []
        for section in displayOrder {
            var rows: [NSView] = []
            let items = grouped[section] ?? []
            let open = items.filter(Self.isOpenTask).count
            let folded = isCollapsed(section)
            let header = headerCache[section] ?? SectionHeaderView(
                title: section,
                collapsed: folded,
                badge: folded && open > 0 ? open : nil,
                empty: !items.contains { !Self.isBlank($0) }
            )
            header.update(title: section, collapsed: folded, badge: folded && open > 0 ? open : nil,
                          empty: !items.contains { !Self.isBlank($0) })
            headerCache[section] = header
            header.onClick = { [weak self] in self?.headerClicked(section) }
            rows.append(header)
            if !folded {
                var collapsedDepth: Int?
                for (offset, item) in items.enumerated() {
                    if let depth = collapsedDepth {
                        if item.depth > depth { continue }
                        collapsedDepth = nil
                    }
                    let hasSubtasks = offset + 1 < items.count && items[offset + 1].depth > item.depth
                    let itemCollapsed = hasSubtasks ? collapsedItems.contains(item.id) : nil
                    rows.append(makeRow(item, collapsed: itemCollapsed))
                    if itemCollapsed == true { collapsedDepth = item.depth }
                }
            }
            sectionRows.append(rows)
        }
        let horizontal = config.sectionLayout == .horizontal
        let visibleIDs = Set(sectionRows.flatMap { $0 }.compactMap { ($0 as? TodoRowView)?.itemId })
        if resetScrollPosition || activeID.map({ !visibleIDs.contains($0) }) == true {
            view.window?.makeFirstResponder(nil)
        }
        scrollView.hasHorizontalScroller = horizontal
        rowsView.setSections(sectionRows, horizontal: horizontal)
        if resetScrollPosition {
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        let openCount = file.items.filter(Self.isOpenTask).count
        headerLabel.stringValue = Self.dateFormatter.string(from: Date())
            + "   ·   \(openCount) open"

        isRebuilding = false
        onHeightChange?()
        view.layoutSubtreeIfNeeded()
        if !resetScrollPosition, let anchor, anchor.superview === rowsView, let anchorOffset {
            scrollView.contentView.scroll(to: NSPoint(x: max(0, anchor.frame.minX + anchorOffset.x),
                                                     y: max(0, anchor.frame.minY + anchorOffset.y)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        if let focus, let row = rowCache[focus], row.superview === rowsView {
            view.layoutSubtreeIfNeeded()
            view.window?.makeFirstResponder(row.field)
            if cursorAtStart {
                row.field.currentEditor()?.selectedRange = NSRange(location: 0, length: 0)
            } else {
                placeCursorAtEnd(row.field)
            }
            scrollToVisible(row)
        } else if resetScrollPosition, let activeID, let row = rowCache[activeID], row.superview === rowsView {
            view.window?.makeFirstResponder(row.field)
            if let selection { row.field.currentEditor()?.selectedRange = selection }
            scrollToVisible(row)
        }
    }

    private func makeRow(_ item: TodoItem, collapsed: Bool?) -> TodoRowView {
        let row = rowCache[item.id] ?? TodoRowView(
            itemId: item.id, indent: 26 + CGFloat(item.depth) * 20, collapsed: collapsed
        )
        rowCache[item.id] = row
        row.update(item, collapsed: collapsed)
        row.onToggle = { [weak self] in self?.toggleSubtasks(for: item.id) }
        row.checkbox.target = self
        row.checkbox.action = #selector(toggleCheck(_:))
        row.field.delegate = self
        return row
    }

    // MARK: Sections

    /// An empty section is always collapsed. Other sections follow the saved fold state.
    private func isCollapsed(_ section: String) -> Bool {
        !file.items.contains { $0.section == section } || collapsed.contains(section)
    }

    private static func isBlank(_ item: TodoItem) -> Bool {
        item.isBlank
    }

    /// An unchecked top-level task with text. Badges and the header count only these.
    private static func isOpenTask(_ item: TodoItem) -> Bool {
        item.isOpenTask
    }

    /// Removes blank tasks with no sub-tasks from a section. These are drafts the user did not fill in.
    private func dropBlankDrafts(in section: String) {
        var i = 0
        while i < file.items.count {
            if file.items[i].section == section, Self.isBlank(file.items[i]), subtaskCount(at: i) == 0 {
                file.items.remove(at: i)
            } else {
                i += 1
            }
        }
    }

    private func setCollapsed(_ section: String, _ value: Bool) {
        if value { collapsed.insert(section) } else { collapsed.remove(section) }
        UserDefaults.standard.set(Array(collapsed).sorted(), forKey: Self.collapsedKey)
    }

    /// Section names from the configured folder sources.
    private func requiredSections() -> [String] {
        if sourceSections.isEmpty { sourceSections = config.requiredSections() }
        return sourceSections
    }

    /// What applying `newConfig` does to the section list of its todo file. Tasks are never removed.
    func preview(_ newConfig: Config, required: [String]? = nil) -> ConfigPreview {
        let current: TodoFile
        if newConfig.todoURL == fileURL {
            current = file
        } else if let text = try? String(contentsOf: newConfig.todoURL, encoding: .utf8) {
            current = TodoFile.parse(text)
        } else {
            current = TodoFile(sections: [], items: [])
        }
        let newRequired = required ?? newConfig.requiredSections()
        var after = current
        after.conform(to: newRequired)
        let before = Set(current.sections)
        let afterSet = Set(after.sections)
        let required = Set(newRequired)
        let oldRequired = Set(requiredSections())
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
        sourceSections = config.requiredSections()
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
            let collapsing = !collapsed.contains(section)
            if collapsing { dropBlankDrafts(in: section) }
            setCollapsed(section, collapsing)
            saveNonEmpty()
            rebuild()
        } else {
            setCollapsed(section, false)
            let item = TodoItem(text: "", section: section)
            file.items.insert(item, at: file.endIndex(of: section))
            rebuild(focus: item.id)
        }
    }

    private func toggleSubtasks(for id: UUID) {
        _ = commitFocusedText()
        if collapsedItems.contains(id) {
            collapsedItems.remove(id)
        } else {
            collapsedItems.insert(id)
        }
        saveNonEmpty()
        rebuild()
    }

    private func toggleLayout() {
        _ = commitFocusedText()
        saveNonEmpty()
        var updated = config
        updated.sectionLayout = config.sectionLayout == .vertical ? .horizontal : .vertical
        updated.save()
    }

    private func scrollToVisible(_ row: TodoRowView) {
        let clip = scrollView.contentView
        var origin = clip.bounds.origin
        let r = row.frame
        if r.maxX > origin.x + clip.bounds.width {
            origin.x = r.maxX - clip.bounds.width
        } else if r.minX < origin.x {
            origin.x = r.minX
        }
        if r.maxY > origin.y + clip.bounds.height {
            origin.y = r.maxY - clip.bounds.height
        } else if r.minY < origin.y {
            origin.y = r.minY
        }
        clip.scroll(to: NSPoint(x: max(0, origin.x), y: max(0, origin.y)))
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: File

    func refreshFromDisk() {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        guard content != lastKnownContent else { return }
        guard !isEditing, pendingDelete == nil, conflictAlert == nil else { pendingDiskRefresh = true; return }
        var remote = TodoFile.parse(content)
        remote.reconcile(with: diskBase)
        guard let merged = TodoFile.merge(base: diskBase, local: file, remote: remote) else {
            showFileConflict(remote: remote, content: content)
            return
        }
        lastKnownContent = content
        diskBase = remote
        pendingDiskRefresh = false
        file = merged
        file.conform(to: requiredSections())
        if file.serialize() != content { saveNonEmpty() }
        scheduleLoadedCompletions()
        rebuild()
    }

    private var isEditing: Bool { currentEditingField != nil }

    // MARK: Panel lifecycle

    func panelDidOpen() {
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
            saveNonEmpty()
        }
        if pendingDiskRefresh { refreshFromDisk() }
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
        if event.keyCode == 37, flags.contains([.command, .shift]),
           !flags.contains(.option), !flags.contains(.control) {
            toggleLayout()
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
        var cursorAtStart = false
        if let field = currentEditingField, let idx = index(of: field) {
            let text = field.stringValue as NSString
            let length = text.length
            let selected = field.currentEditor()?.selectedRange ?? NSRange(location: length, length: 0)
            let location = selected.location == NSNotFound ? length : min(selected.location, length)
            let selectionEnd = location + min(selected.length, length - location)
            let base = file.items[idx].depth
            let section = file.items[idx].section
            if location == 0, selected.length == 0 {
                file.items[idx].text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                item = TodoItem(text: "", depth: base, section: section)
                file.items.insert(item, at: idx)
            } else {
                file.items[idx].text = text.substring(to: location)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let remainder = text.substring(from: selectionEnd)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let end = file.subtreeRange(at: idx).upperBound
                item = TodoItem(text: remainder, depth: base, section: section)
                file.items.insert(item, at: end)
                cursorAtStart = !remainder.isEmpty
            }
        } else {
            guard let section = file.sections.first(where: { !isCollapsed($0) }) ?? file.sections.first else { return }
            setCollapsed(section, false)
            item = TodoItem(text: "", section: section)
            file.items.insert(item, at: file.endIndex(of: section))
        }
        saveNonEmpty()
        rebuild(focus: item.id, cursorAtStart: cursorAtStart)
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
        for i in file.subtreeRange(at: idx) {
            file.items[i].depth = max(0, file.items[i].depth + delta)
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
        file.subtreeRange(at: index).count - 1
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
        _ = commitFocusedText()
        guard prepareToWrite() else { return }
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
        if let alert = deletionAlert {
            alert.window.sheetParent?.endSheet(alert.window)
            deletionAlert = nil
        }
    }

    private func showOverlay(title: String, detail: String) {
        guard let window = view.window else { cancelPendingDelete(); return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        deletionAlert = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.pendingDelete != nil else { return }
            if response == .alertFirstButtonReturn { self.confirmPendingDelete() }
            else { self.cancelPendingDelete() }
        }
    }

    private func deleteSubtree(at index: Int) {
        let removal = file.removeSubtree(at: index)
        cancelCompletions(for: removal.items)
        registerRestoration(removal, name: "Delete Task")
    }

    private func scheduleCompletionDelete(id: UUID) {
        pendingCompletionDeletes.removeValue(forKey: id)?.cancel()
        let token = UUID()
        completionTokens[id] = token
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.completionTokens[id] == token else { return }
            self.fadeCompletedItem(id: id)
        }
        pendingCompletionDeletes[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    private func fadeCompletedItem(id: UUID) {
        if pendingDelete != nil || conflictAlert != nil {
            scheduleCompletionDelete(id: id)
            return
        }
        guard let idx = file.items.firstIndex(where: { $0.id == id }), file.items[idx].checked else {
            pendingCompletionDeletes.removeValue(forKey: id)
            return
        }
        let token = completionTokens[id]
        let row = rowCache[id]
        guard view.window?.isVisible == true, let row else {
            deleteCompletedItem(id: id)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.25
            row.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.completionTokens[id] == token else { return }
            self.deleteCompletedItem(id: id)
        }
    }

    private func deleteCompletedItem(id: UUID) {
        if pendingDelete != nil || conflictAlert != nil { scheduleCompletionDelete(id: id); return }
        _ = commitFocusedText()
        guard prepareToWrite() else { scheduleCompletionDelete(id: id); return }
        pendingCompletionDeletes.removeValue(forKey: id)
        guard let idx = file.items.firstIndex(where: { $0.id == id }), file.items[idx].checked else { return }
        var removal = file.removeSubtree(at: idx)
        cancelCompletions(for: removal.items)
        removal.items[0].checked = false
        registerRestoration(removal, name: "Complete Task")
        saveNonEmpty()
        rebuild()
    }

    private func registerRestoration(_ removal: TodoFile.Removal, name: String) {
        guard let manager = view.window?.undoManager else { return }
        if !manager.isUndoing && !manager.isRedoing {
            (currentEditingField?.currentEditor() as? NSTextView)?.breakUndoCoalescing()
            while manager.groupingLevel > 0 { manager.endUndoGrouping() }
            manager.beginUndoGrouping()
        }
        manager.registerUndo(withTarget: self) { target in target.restoreRemoval(removal, name: name) }
        manager.setActionName(name)
        if !manager.isUndoing && !manager.isRedoing { manager.endUndoGrouping() }
    }

    private func restoreRemoval(_ removal: TodoFile.Removal, name: String) {
        _ = commitFocusedText()
        guard prepareToWrite(), let first = removal.items.first else { return }
        file.restore(removal)
        setCollapsed(first.section, false)
        if let parent = removal.parent { collapsedItems.remove(parent) }
        view.window?.undoManager?.registerUndo(withTarget: self) { target in
            _ = target.commitFocusedText()
            guard target.prepareToWrite() else { return }
            guard let index = target.file.items.firstIndex(where: { $0.id == first.id }) else { return }
            let redo = target.file.removeSubtree(at: index)
            target.cancelCompletions(for: redo.items)
            target.registerRestoration(removal, name: name)
            target.saveNonEmpty()
            target.rebuild()
        }
        saveNonEmpty()
        rebuild(focus: first.id)
    }

    private func cancelCompletions(for items: [TodoItem]) {
        for item in items {
            pendingCompletionDeletes.removeValue(forKey: item.id)?.cancel()
            completionTokens.removeValue(forKey: item.id)
            rowCache[item.id]?.alphaValue = 1
        }
    }

    private func scheduleLoadedCompletions() {
        cancelCompletions(for: file.items.filter { !$0.checked })
        let ids = Set(file.items.map(\.id))
        for id in Array(pendingCompletionDeletes.keys) where !ids.contains(id) {
            pendingCompletionDeletes.removeValue(forKey: id)?.cancel()
            completionTokens.removeValue(forKey: id)
        }
        for item in file.items where item.checked && pendingCompletionDeletes[item.id] == nil {
            scheduleCompletionDelete(id: item.id)
        }
    }

    /// Saves without empty draft items, so the file never holds blank todo lines.
    private func saveNonEmpty() {
        guard prepareToWrite() else { return }
        var copy = file
        copy.items.removeAll { $0.text.isEmpty }
        let content = copy.serialize()
        guard content != lastKnownContent else { return }
        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            lastKnownContent = content
            diskBase = copy
            pendingDiskRefresh = false
        } catch {
            NSSound.beep()
        }
    }

    private func prepareToWrite() -> Bool {
        guard conflictAlert == nil else { return false }
        do {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            guard content != lastKnownContent else { return true }
            var remote = TodoFile.parse(content)
            remote.reconcile(with: diskBase)
            guard let merged = TodoFile.merge(base: diskBase, local: file, remote: remote) else {
                showFileConflict(remote: remote, content: content)
                return false
            }
            file = merged
            diskBase = remote
            lastKnownContent = content
            pendingDiskRefresh = false
            scheduleLoadedCompletions()
            return true
        } catch {
            NSSound.beep()
            return false
        }
    }

    private func showFileConflict(remote: TodoFile, content: String) {
        guard conflictAlert == nil else { return }
        let alert = NSAlert()
        alert.messageText = "The todo file changed outside TodoNotch."
        alert.informativeText = "Both edits change the same task. Choose which version to keep."
        alert.addButton(withTitle: "Use File Version")
        alert.addButton(withTitle: "Keep App Version")
        conflictAlert = alert
        let resolve: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            self.isRebuilding = true
            self.view.window?.makeFirstResponder(nil)
            self.isRebuilding = false
            self.conflictAlert = nil
            self.diskBase = remote
            self.lastKnownContent = content
            if response == .alertFirstButtonReturn { self.file = remote }
            self.pendingDiskRefresh = false
            self.saveNonEmpty()
            self.scheduleLoadedCompletions()
            self.rebuild()
        }
        if let window = view.window, window.isVisible { alert.beginSheetModal(for: window, completionHandler: resolve) }
        else { resolve(alert.runModal()) }
    }

    // MARK: Actions

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        guard client is ItemTextField else { return nil }
        fieldEditor.isFieldEditor = true
        fieldEditor.allowsUndo = true
        fieldEditor.sharedUndoManager = sender.undoManager
        return fieldEditor
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        guard let field = obj.object as? ItemTextField, let editor = field.currentEditor() as? NSTextView else { return }
        editor.allowsUndo = true
        editor.breakUndoCoalescing()
    }

    @objc private func toggleCheck(_ sender: NSButton) {
        guard let row = sender.superview as? TodoRowView,
              let id = row.itemId,
              let idx = file.items.firstIndex(where: { $0.id == id }) else { return }
        _ = commitFocusedText()
        cancelCompletions(for: [file.items[idx]])
        file.items[idx].checked = sender.state == .on
        saveNonEmpty()
        if sender.state == .on { scheduleCompletionDelete(id: id) }
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
            // Refresh after the field editor releases its current task.
        } else {
            file.items[idx].text = text
        }
        saveNonEmpty()
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isEditing else { return }
            if self.pendingDiskRefresh { self.refreshFromDisk() }
            self.rebuild()
        }
    }

}
