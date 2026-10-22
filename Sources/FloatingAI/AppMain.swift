import AppKit
import Combine
import SwiftUI

@main @MainActor enum FloatingAIApplication {
    static func main() {
        let app = NSApplication.shared
        let delegate = ApplicationDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var store: AppStore!
    private var windows: NoteWindowManager!
    private var statusItem: NSStatusItem!
    private var newNoteWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var manageNotesWindow: NSWindow?
    private var isQuitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index = CommandLine.arguments.firstIndex(of: "--preview"), CommandLine.arguments.indices.contains(index + 1) {
            PreviewRenderer.run(outputDirectory: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true))
            return
        }
        store = AppStore()
        windows = NoteWindowManager(store: store)
        installMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Floating AI")
        statusItem.button?.toolTip = "Floating AI · Chat notes"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        rebuildStatusMenu(menu)
        windows.restore()
        store.connectAll()
        if store.notes.isEmpty { showSettings(nil) }
    }

    private func installMainMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Floating AI")
        appMenu.addItem(item("Settings…", action: #selector(showSettings(_:)), key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quit Floating AI", action: #selector(quit(_:)), key: "q"))
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(item("New Note…", action: #selector(newNote(_:)), key: "n"))
        fileMenu.addItem(item("Manage Notes…", action: #selector(manageNotes(_:))))
        fileItem.submenu = fileMenu
        menu.addItem(fileItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            editMenu.addItem(NSMenuItem(title: title, action: Selector(action), keyEquivalent: key))
        }
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApplication.shared.mainMenu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        windows.setInteractionForAll("statusMenu", active: true)
        rebuildStatusMenu(menu)
    }

    func menuDidClose(_ menu: NSMenu) { windows.setInteractionForAll("statusMenu", active: false) }

    private func rebuildStatusMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item("New Note…", action: #selector(newNote(_:)), key: "n"))
        menu.addItem(item("Manage Notes…", action: #selector(manageNotes(_:))))
        if !store.notes.isEmpty {
            menu.addItem(.separator())
            for note in store.notes {
                let title = note.title.isEmpty ? "Ask Me Anything" : note.title
                let noteItem = item((note.hasUnreadReply ? "● " : "") + title, action: #selector(openNote(_:)))
                noteItem.representedObject = note.id.uuidString
                noteItem.state = note.isVisible ? .on : .off
                menu.addItem(noteItem)
            }
            menu.addItem(.separator())
            menu.addItem(item("Show All Notes", action: #selector(showAll(_:))))
            menu.addItem(item("Hide All Notes", action: #selector(hideAll(_:))))
        }
        menu.addItem(.separator())
        menu.addItem(item("Settings…", action: #selector(showSettings(_:)), key: ","))
        menu.addItem(item("Quit Floating AI", action: #selector(quit(_:)), key: "q"))
    }

    private func item(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func newNote(_ sender: Any?) {
        if let newNoteWindow { activate(newNoteWindow); return }
        let view = NewNoteView(store: store, onCreated: { [weak self] note in
            guard let self else { return }
            self.newNoteWindow?.close()
            self.windows.show(note: note)
        }, onCancel: { [weak self] in self?.newNoteWindow?.close() })
        let window = makeDialog(title: "New Note", size: NSSize(width: 460, height: 410), root: view)
        newNoteWindow = window
        activate(window)
    }

    @objc private func showSettings(_ sender: Any?) {
        if let settingsWindow { activate(settingsWindow); return }
        let window = makeDialog(title: "Floating AI Settings", size: NSSize(width: 500, height: 650), root: SettingsView(store: store))
        settingsWindow = window
        activate(window)
    }

    @objc private func manageNotes(_ sender: Any?) {
        if let manageNotesWindow { activate(manageNotesWindow); return }
        let view = ManageNotesView(store: store,
                                  onShow: { [weak self] note in self?.windows.show(note: note) },
                                  onHide: { [weak self] note in self?.windows.hide(note: note) })
        let window = makeDialog(title: "Manage Notes", size: NSSize(width: 640, height: 480), root: view)
        window.styleMask.insert(.resizable)
        window.contentMinSize = NSSize(width: 560, height: 360)
        manageNotesWindow = window
        activate(window)
    }

    private func makeDialog<Content: View>(title: String, size: NSSize, root: Content) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title
        let content = NSHostingView(rootView: root)
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        let fittingSize = content.fittingSize
        window.setContentSize(NSSize(width: max(size.width, fittingSize.width), height: max(size.height, fittingSize.height)))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    private func activate(_ window: NSWindow) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === newNoteWindow { newNoteWindow = nil }
        if window === settingsWindow { settingsWindow = nil }
        if window === manageNotesWindow { manageNotesWindow = nil }
    }

    @objc private func openNote(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let note = store.notes.first(where: { $0.id.uuidString == id }) else { return }
        windows.show(note: note)
    }
    @objc private func showAll(_ sender: Any?) { windows.showAll() }
    @objc private func hideAll(_ sender: Any?) { windows.hideAll() }
    @objc private func quit(_ sender: Any?) { NSApplication.shared.terminate(sender) }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard store != nil else { return .terminateNow }
        guard !isQuitting else { return .terminateLater }
        isQuitting = true
        windows?.finishTitleEditingAll()
        store.persist()
        Task { @MainActor in
            await store.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
