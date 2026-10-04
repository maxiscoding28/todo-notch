import AppKit

/// Edits the todo file path and the folder sources that become sections.
final class SettingsWindowController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private let panelController: TodoPanelController
    private var draft: Config
    private var window: NSWindow!

    private let fileField = NSTextField()
    private let sourcesStack = NSStackView()
    private let previewLabel = NSTextField(wrappingLabelWithString: "")
    private let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var overlay: NSView?

    init(panelController: TodoPanelController) {
        self.panelController = panelController
        self.draft = panelController.config
        super.init()
        buildWindow()
    }

    var isVisible: Bool { window.isVisible }

    func show() {
        draft = panelController.config
        hideOverlay()
        reloadForm()
        NSApp.unhide(nil)
        NSApp.activate()
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Layout

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "TodoNotch Settings"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.delegate = self
        let content = NSView()
        window.contentView = content

        let fileTitle = sectionTitle("Todo file")
        fileField.placeholderString = "~/todo.txt"
        fileField.delegate = self
        let chooseFile = NSButton(title: "Choose…", target: self, action: #selector(chooseFile))
        let fileRow = NSStackView(views: [fileField, chooseFile])
        fileRow.spacing = 8

        let sourcesTitle = sectionTitle("Sections from folders")
        let sourcesHelp = helpLabel(
            "“Contents of” makes a section for each folder inside it. “Folder” makes one section. "
                + "Sections you type in the todo file are kept too."
        )
        sourcesStack.orientation = .vertical
        sourcesStack.alignment = .leading
        sourcesStack.spacing = 6

        let addChildren = NSButton(title: "Add contents of folder…", target: self, action: #selector(addChildren))
        let addSingle = NSButton(title: "Add single folder…", target: self, action: #selector(addSingle))
        let addRow = NSStackView(views: [addChildren, addSingle])
        addRow.spacing = 8

        previewLabel.font = .systemFont(ofSize: 11)
        previewLabel.textColor = .secondaryLabelColor
        let keepNote = helpLabel("Removing a source never deletes tasks. Its sections stay, unsynced.")

        applyButton.target = self
        applyButton.action = #selector(applyClicked)
        applyButton.keyEquivalent = "\r"
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [cancelButton, applyButton])
        buttons.spacing = 8

        let main = NSStackView(views: [
            fileTitle, fileRow, sourcesTitle, sourcesHelp, sourcesStack, addRow, previewLabel, keepNote,
        ])
        main.orientation = .vertical
        main.alignment = .leading
        main.spacing = 8
        main.setCustomSpacing(20, after: fileRow)
        main.setCustomSpacing(14, after: addRow)

        for v in [main, buttons] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            main.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            main.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            main.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            fileRow.widthAnchor.constraint(equalTo: main.widthAnchor),
            sourcesStack.widthAnchor.constraint(equalTo: main.widthAnchor),
            previewLabel.widthAnchor.constraint(equalTo: main.widthAnchor),
            sourcesHelp.widthAnchor.constraint(equalTo: main.widthAnchor),
            buttons.topAnchor.constraint(greaterThanOrEqualTo: main.bottomAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            content.widthAnchor.constraint(equalToConstant: 560),
        ])
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func helpLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func reloadForm() {
        fileField.stringValue = draft.todoFile
        sourcesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if draft.sources.isEmpty {
            sourcesStack.addArrangedSubview(helpLabel("No folder sources. Only sections typed in the file show."))
        }
        for (index, source) in draft.sources.enumerated() {
            sourcesStack.addArrangedSubview(sourceRow(source, index: index))
        }
        updatePreview()
    }

    private func sourceRow(_ source: SectionSource, index: Int) -> NSView {
        let kind = NSTextField(labelWithString: source.kind == .children ? "Contents of" : "Folder")
        kind.font = .systemFont(ofSize: 11, weight: .medium)
        kind.textColor = .secondaryLabelColor
        kind.widthAnchor.constraint(equalToConstant: 72).isActive = true

        let path = NSTextField(labelWithString: source.path)
        path.font = .systemFont(ofSize: 12)
        path.lineBreakMode = .byTruncatingMiddle
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let names = source.sectionNames()
        let result = NSTextField(labelWithString: names.isEmpty ? "folder not found" : "→ " + names.joined(separator: ", "))
        result.font = .systemFont(ofSize: 11)
        result.textColor = names.isEmpty ? .systemOrange : .tertiaryLabelColor
        result.lineBreakMode = .byTruncatingTail
        result.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)

        let remove = NSButton(
            image: NSImage(systemSymbolName: "minus.circle", accessibilityDescription: "Remove")!,
            target: self,
            action: #selector(removeSource(_:))
        )
        remove.isBordered = false
        remove.tag = index
        remove.toolTip = "Remove this source"

        let row = NSStackView(views: [kind, path, result, NSView(), remove])
        row.spacing = 8
        row.distribution = .fill
        return row
    }

    private func updatePreview() {
        let preview = panelController.preview(draft)
        let list = preview.sections.isEmpty ? "none" : preview.sections.joined(separator: ", ")
        previewLabel.stringValue = "Sections after Apply: " + list
    }

    // MARK: Actions

    func controlTextDidChange(_ obj: Notification) {
        draft.todoFile = fileField.stringValue.trimmingCharacters(in: .whitespaces)
        updatePreview()
    }

    @objc private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = draft.todoURL.deletingLastPathComponent()
        panel.message = "Choose the todo file. To start a new file, type its path in the field instead."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.draft.todoFile = Config.displayPath(url)
            self.reloadForm()
        }
    }

    @objc private func addChildren() { pickFolder(kind: .children) }
    @objc private func addSingle() { pickFolder(kind: .single) }

    private func pickFolder(kind: SectionSource.Kind) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = kind == .single
        panel.message = kind == .children
            ? "Each folder inside the chosen folder becomes a section."
            : "Each chosen folder becomes one section."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            for url in panel.urls {
                let source = SectionSource(kind: kind, path: Config.displayPath(url))
                if !self.draft.sources.contains(source) { self.draft.sources.append(source) }
            }
            self.reloadForm()
        }
    }

    @objc private func removeSource(_ sender: NSButton) {
        guard draft.sources.indices.contains(sender.tag) else { return }
        draft.sources.remove(at: sender.tag)
        reloadForm()
    }

    @objc private func cancelClicked() {
        window.close()
    }

    @objc private func applyClicked() {
        draft.todoFile = fileField.stringValue.trimmingCharacters(in: .whitespaces)
        if draft.todoFile.isEmpty { draft.todoFile = Config.initial.todoFile }
        let preview = panelController.preview(draft)
        if preview.changesStructure {
            showConfirm(preview)
        } else {
            commit()
        }
    }

    private func commit() {
        hideOverlay()
        draft.save()
        window.close()
    }

    // MARK: Confirm overlay

    private func showConfirm(_ preview: ConfigPreview) {
        var lines: [String] = []
        if preview.newFile { lines.append("Switch to \(draft.todoFile).") }
        if !preview.added.isEmpty {
            lines.append("+\(preview.added.count) section\(preview.added.count == 1 ? "" : "s"): " + preview.added.joined(separator: ", "))
        }
        if !preview.removed.isEmpty {
            lines.append("−\(preview.removed.count) empty section\(preview.removed.count == 1 ? "" : "s"): " + preview.removed.joined(separator: ", "))
        }
        if !preview.unsynced.isEmpty {
            lines.append("Stop syncing: " + preview.unsynced.joined(separator: ", "))
        }
        lines.append("Tasks are kept.")

        guard let content = window.contentView else { return }
        let dim = OverlayView()
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        card.layer?.cornerRadius = 10
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = NSColor.separatorColor.cgColor

        let title = NSTextField(labelWithString: "Reorganize the todo file?")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: lines.joined(separator: "\n"))
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        let back = NSButton(title: "Cancel  esc", target: self, action: #selector(hideOverlay))
        let ok = NSButton(title: "Apply  ↩", target: self, action: #selector(confirmApply))
        back.keyEquivalent = "\u{1b}"
        ok.keyEquivalent = "\r"
        applyButton.keyEquivalent = ""
        cancelButton.keyEquivalent = ""

        for v in [title, detail, back, ok] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(v)
        }
        card.translatesAutoresizingMaskIntoConstraints = false
        dim.translatesAutoresizingMaskIntoConstraints = false
        dim.addSubview(card)
        content.addSubview(dim)
        NSLayoutConstraint.activate([
            dim.topAnchor.constraint(equalTo: content.topAnchor),
            dim.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            dim.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            dim.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            card.centerXAnchor.constraint(equalTo: dim.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: dim.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 400),
            title.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            title.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            ok.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 12),
            ok.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            ok.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            back.centerYAnchor.constraint(equalTo: ok.centerYAnchor),
            back.trailingAnchor.constraint(equalTo: ok.leadingAnchor, constant: -8),
        ])
        overlay = dim
    }

    @objc private func confirmApply() {
        commit()
    }

    @objc private func hideOverlay() {
        overlay?.removeFromSuperview()
        overlay = nil
        applyButton.keyEquivalent = "\r"
        cancelButton.keyEquivalent = "\u{1b}"
    }

    func windowWillClose(_ notification: Notification) {
        hideOverlay()
    }
}
