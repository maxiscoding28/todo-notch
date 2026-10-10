import AppKit

private var failures = 0

func XCTAssertTrue(_ value: Bool, file: StaticString = #file, line: UInt = #line) {
    if !value { print("FAIL: \(file):\(line)"); failures += 1 }
}

func XCTAssertEqual<T: Equatable>(_ left: T, _ right: T, file: StaticString = #file, line: UInt = #line) {
    XCTAssertTrue(left == right, file: file, line: line)
}

func XCTAssertNil<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) {
    XCTAssertTrue(value == nil, file: file, line: line)
}

func XCTAssertLessThanOrEqual<T: Comparable>(_ left: T, _ right: T, file: StaticString = #file, line: UInt = #line) {
    XCTAssertTrue(left <= right, file: file, line: line)
}

@main
final class TodoNotchTests {
    static func main() throws {
        _ = NSApplication.shared
        let tests = TodoNotchTests()
        tests.testRoundTripAndCRLF()
        tests.testSortUsesOpenTopLevelTasks()
        tests.testRestoreAfterNeighborDeletion()
        tests.testRestoreMissingSectionAndParent()
        tests.testReconcileIdentityAfterInsertAndEdit()
        tests.testMergeIndependentEdits()
        tests.testMergeDeletionAndExternalInsertion()
        try tests.testLegacyConfigAndPathBoundary()
        tests.testHeaderHitAndRowReuse()
        tests.testDeepRowStaysInColumn()
        try tests.testCompletionDuringEditAndNativeUndo()
        try tests.testLoadedCompletionAndConfirmationPause()
        try tests.testSettingsScrolls()
        try tests.testConflictKeepsFileVersion()
        tests.testStoppedWatcherDoesNotRestart()
        print("Regression tests: \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
    func testRoundTripAndCRLF() {
        let text = "alpha\n\tA\n\t\t- sub\n\nother\n\t[x] X\n"
        XCTAssertEqual(TodoFile.parse(text).serialize(), text)
        XCTAssertEqual(TodoFile.parse(text.replacingOccurrences(of: "\n", with: "\r\n")).serialize(), text)
    }

    func testSortUsesOpenTopLevelTasks() {
        let file = TodoFile.parse("alpha\n\tA\n\t\t- sub\n\t[x] done\n\nbeta\n\tB\n\tC\n\ngamma\n\tG\n")
        XCTAssertEqual(file.sectionsByDescendingTodoCount(), ["beta", "alpha", "gamma"])
    }

    func testRestoreAfterNeighborDeletion() {
        var file = TodoFile.parse("alpha\n\tA\n\tb\n\nbeta\n\tB\n")
        let removed = file.removeSubtree(at: 1)
        _ = file.removeSubtree(at: 0)
        file.restore(removed)
        XCTAssertEqual(file.items.map(\.section), ["alpha", "beta"])
    }

    func testRestoreMissingSectionAndParent() {
        var file = TodoFile.parse("alpha\n\tA\n\t\t- child\n")
        let child = file.removeSubtree(at: 1)
        _ = file.removeSubtree(at: 0)
        file.conform(to: [])
        file.restore(child)
        XCTAssertEqual(file.sections, ["alpha"])
        XCTAssertEqual(file.items.first?.depth, 0)
        XCTAssertTrue(file.serialize().contains("child"))
    }

    func testReconcileIdentityAfterInsertAndEdit() {
        let base = TodoFile.parse("alpha\n\tA\n\tB\n")
        var remote = TodoFile.parse("alpha\n\tnew\n\tA\n\tB\n")
        remote.reconcile(with: base)
        XCTAssertEqual(remote.items[1].id, base.items[0].id)
        XCTAssertEqual(remote.items[2].id, base.items[1].id)
        var edited = TodoFile.parse("alpha\n\tchanged\n\tB\n")
        edited.reconcile(with: base)
        XCTAssertEqual(edited.items[0].id, base.items[0].id)
    }

    func testMergeIndependentEdits() {
        let base = TodoFile.parse("alpha\n\tA\n\tB\n")
        var local = base
        local.items[0].text = "local"
        var remote = TodoFile.parse("alpha\n\tA\n\tremote\n")
        remote.reconcile(with: base)
        XCTAssertEqual(TodoFile.merge(base: base, local: local, remote: remote)?.items.map(\.text), ["local", "remote"])
        remote.items[0].text = "conflict"
        XCTAssertNil(TodoFile.merge(base: base, local: local, remote: remote))
    }

    func testMergeDeletionAndExternalInsertion() {
        let base = TodoFile.parse("alpha\n\tA\n\tB\n")
        var local = base
        _ = local.removeSubtree(at: 0)
        var remote = TodoFile.parse("alpha\n\tA\n\tnew\n\tB\n")
        remote.reconcile(with: base)
        XCTAssertEqual(TodoFile.merge(base: base, local: local, remote: remote)?.items.map(\.text), ["new", "B"])
    }

    func testLegacyConfigAndPathBoundary() throws {
        let config = try JSONDecoder().decode(Config.self, from: Data(#"{"todoFile":"~/todo.txt","sources":[]}"#.utf8))
        XCTAssertEqual(config.sectionLayout, .vertical)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(Config.displayPath(URL(fileURLWithPath: home + "-other/file")), home + "-other/file")
    }

    func testHeaderHitAndRowReuse() {
        let container = RowsView(frame: NSRect(x: 0, y: 0, width: 600, height: 100))
        let header = SectionHeaderView(title: "alpha", collapsed: true, badge: 2, empty: false)
        let second = SectionHeaderView(title: "beta", collapsed: true, badge: nil, empty: true)
        container.setSections([[header], [second]], horizontal: true)
        container.layoutSubtreeIfNeeded()
        XCTAssertTrue(second.hitTest(NSPoint(x: 320, y: 10)) === second)
        var clicks = 0
        second.onClick = { clicks += 1 }
        second.mouseDown(with: NSEvent())
        XCTAssertEqual(clicks, 1)
        container.setSections([[second], [header]], horizontal: false)
        XCTAssertTrue(container.rows[0] === second)
    }

    func testDeepRowStaysInColumn() {
        let item = TodoItem(text: "Task", depth: 40, section: "alpha")
        let row = TodoRowView(itemId: item.id, indent: 826, collapsed: nil)
        row.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        row.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(row.field.frame.maxX, 300)
    }

    func testCompletionDuringEditAndNativeUndo() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try "alpha\n\tA\n\tB\n".write(to: url, atomically: true, encoding: .utf8)
        let controller = TodoPanelController(configuration: Config(todoFile: url.path, sources: []))
        let window = DropdownPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.view
        window.delegate = controller
        controller.view.layoutSubtreeIfNeeded()
        window.makeKeyAndOrderFront(nil)
        let scroll = controller.view.subviews.compactMap { $0 as? NSScrollView }.first!
        let rows = scroll.documentView as! RowsView
        let tasks = rows.rows.compactMap { $0 as? TodoRowView }
        tasks[0].checkbox.state = .on
        tasks[0].checkbox.performClick(nil)
        // performClick toggles the checkbox before it sends its action.
        if tasks[0].checkbox.state != .on { tasks[0].checkbox.performClick(nil) }
        window.makeFirstResponder(tasks[1].field)
        let editor = tasks[1].field.currentEditor() as! NSTextView
        editor.insertText(" edited", replacementRange: NSRange(location: 1, length: 0))
        let remote = "alpha\n\t[x] A\n\tB\n\tExternal\n"
        try remote.write(to: url, atomically: true, encoding: .utf8)
        RunLoop.main.run(until: Date().addingTimeInterval(3.1))
        let saved = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(saved.contains("B edited"))
        XCTAssertTrue(saved.contains("External"))
        XCTAssertTrue(!saved.contains("\t[x] A"))
        XCTAssertTrue(rows.rows.contains { $0 === tasks[1] })
        XCTAssertTrue(tasks[1].field.currentEditor() === editor)
        editor.insertText(" later", replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
        editor.breakUndoCoalescing()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(editor.undoManager === window.undoManager)
        window.undoManager?.undo()
        XCTAssertTrue(!editor.string.contains("later"))
        XCTAssertTrue(!(try String(contentsOf: url, encoding: .utf8)).contains("\tA\n"))
        window.makeFirstResponder(nil)
        window.undoManager?.undo()
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("\tA\n"))
        window.undoManager?.redo()
        XCTAssertTrue(!(try String(contentsOf: url, encoding: .utf8)).contains("\tA\n"))
        window.orderOut(nil)
    }

    func testStoppedWatcherDoesNotRestart() {
        let watcher = FileWatcher(path: "/nonexistent/" + UUID().uuidString)
        var callbacks = 0
        watcher.onChange = { callbacks += 1 }
        watcher.start()
        watcher.stop()
        RunLoop.main.run(until: Date().addingTimeInterval(2.1))
        XCTAssertEqual(callbacks, 0)
    }

    func testLoadedCompletionAndConfirmationPause() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try "alpha\n\t[x] Done\n\tParent\n\t\t- Child\n".write(to: url, atomically: true, encoding: .utf8)
        let controller = TodoPanelController(configuration: Config(todoFile: url.path, sources: []))
        let window = DropdownPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        window.delegate = controller
        window.contentView = controller.view
        window.makeKeyAndOrderFront(nil)
        controller.panelDidOpen()
        controller.view.layoutSubtreeIfNeeded()
        let scroll = controller.view.subviews.compactMap { $0 as? NSScrollView }.first!
        let rows = scroll.documentView as! RowsView
        let tasks = rows.rows.compactMap { $0 as? TodoRowView }
        window.makeFirstResponder(tasks[1].field)
        let editor = tasks[1].field.currentEditor() as! NSTextView
        editor.string = ""
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                    windowNumber: window.windowNumber, context: nil,
                                    characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}",
                                    isARepeat: false, keyCode: 51)!
        NSApp.sendEvent(event)
        XCTAssertTrue(window.attachedSheet != nil)
        RunLoop.main.run(until: Date().addingTimeInterval(2.8))
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("Done"))
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
        RunLoop.main.run(until: Date().addingTimeInterval(3.1))
        XCTAssertTrue(!(try String(contentsOf: url, encoding: .utf8)).contains("Done"))
        controller.panelWillClose()
        window.orderOut(nil)
    }

    func testSettingsScrolls() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try "alpha\n\tA\n".write(to: url, atomically: true, encoding: .utf8)
        let sources = (0..<20).map { SectionSource(kind: .single, path: "/missing/\($0)") }
        let controller = TodoPanelController(configuration: Config(todoFile: url.path, sources: sources))
        let settings = SettingsWindowController(panelController: controller)
        settings.show()
        let window = NSApp.windows.first { $0.title == "TodoNotch Settings" && $0.isVisible }!
        window.contentView?.layoutSubtreeIfNeeded()
        let scroll = window.contentView!.subviews.compactMap { $0 as? NSScrollView }.first!
        XCTAssertTrue(scroll.documentView!.isFlipped)
        XCTAssertTrue(scroll.documentView!.frame.height > scroll.contentView.bounds.height)
        window.close()
    }

    func testConflictKeepsFileVersion() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try "alpha\n\tA\n".write(to: url, atomically: true, encoding: .utf8)
        let controller = TodoPanelController(configuration: Config(todoFile: url.path, sources: []))
        let window = DropdownPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        window.delegate = controller
        window.contentView = controller.view
        window.makeKeyAndOrderFront(nil)
        controller.view.layoutSubtreeIfNeeded()
        let scroll = controller.view.subviews.compactMap { $0 as? NSScrollView }.first!
        let row = (scroll.documentView as! RowsView).rows.compactMap { $0 as? TodoRowView }.first!
        window.makeFirstResponder(row.field)
        let editor = row.field.currentEditor() as! NSTextView
        editor.insertText("local", replacementRange: NSRange(location: 0, length: 1))
        try "alpha\n\tremote\n".write(to: url, atomically: true, encoding: .utf8)
        row.checkbox.performClick(nil)
        XCTAssertTrue(window.attachedSheet != nil)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("remote"))
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "alpha\n\tremote\n")
        controller.panelWillClose()
        window.orderOut(nil)
    }
}
