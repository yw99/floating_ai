import AppKit
import Combine
import FloatingAICore
import SwiftUI

/// Owns native panels; SwiftUI only describes each panel's contents.
@MainActor final class NoteWindowManager: NSObject {
    private let store: AppStore
    private var entries: [UUID: Entry] = [:]
    private var subscriptions = Set<AnyCancellable>()
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var applicationObserver: NSObjectProtocol?
    private var keyWindowObserver: NSObjectProtocol?
    private var workspaceObserver: NSObjectProtocol?
    // Compact nonactivating panels cannot stay key, so retain an explicit
    // selection until another note, dialog, or application receives input.
    private var selectedNoteID: UUID?
    private func compactSize(for note: NoteState) -> NSSize {
        NSSize(width: StoredNote.normalizedCompactWidth(note.compactWidth),
               height: StoredNote.normalizedCompactHeight(note.compactHeight))
    }

    init(store: AppStore) {
        self.store = store
        super.init()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.clampAllWindows() }
        }
        applicationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.selectNote(nil)
                self.scheduleUnfocusedCollapses()
            }
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self, let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            Task { @MainActor in
                self.selectNote(nil)
                self.scheduleUnfocusedCollapses()
            }
        }
        keyWindowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self, let window = notification.object as? NSWindow else { return }
            Task { @MainActor in
                guard window.isKeyWindow else { return }
                self.selectNote(self.entries.values.first(where: { $0.panel === window }))
            }
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.selectNote(nil)
                self.scheduleUnfocusedCollapses()
            }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            if let self {
                self.selectNote(self.entries.values.first(where: { $0.panel === event.window }))
                for entry in self.entries.values where entry.panel != event.window {
                    self.scheduleCollapse(entry)
                }
            }
            return event
        }
        store.$notes.dropFirst().sink { [weak self] _ in
            // New-note UI explicitly expands its note after it has been appended.
            // Restoring here also covers notes added through other entry points.
            Task { @MainActor in
                guard let self else { return }
                // Published emits before storage changes. Read the latest array
                // after yielding so queued additions cannot resurrect a deleted panel.
                let notes = self.store.notes
                let currentIDs = Set(notes.map(\.id))
                for id in Array(self.entries.keys) where !currentIDs.contains(id) { self.removeEntry(id) }
                for note in notes where self.entries[note.id] == nil && note.isVisible {
                    self.present(note: note, expanded: false)
                }
            }
        }.store(in: &subscriptions)
        store.$inactiveNoteOpacity.dropFirst().sink { [weak self] opacity in
            // @Published emits before the property's new value is stored.
            self?.updateOpacities(inactiveOpacity: AppDocument.normalizedInactiveNoteOpacity(opacity))
        }.store(in: &subscriptions)
        store.$keepNotesExpanded.dropFirst().sink { [weak self] keepExpanded in
            guard let self, keepExpanded else { return }
            for entry in self.entries.values where !entry.temporaryDragExpansion {
                entry.collapseWork?.cancel()
                entry.collapseWork = nil
                entry.automaticCollapseAfterDrag = false
            }
        }.store(in: &subscriptions)
        store.$requestedNoteID.compactMap { $0 }.sink { [weak self] id in
            Task { @MainActor in
                guard let self, let note = self.store.notes.first(where: { $0.id == id }) else { return }
                self.show(note: note)
            }
        }.store(in: &subscriptions)
    }

    func restore() {
        for note in store.notes where note.isVisible { present(note: note, expanded: false) }
    }

    func show(note: NoteState) { present(note: note, expanded: true) }

    /// Reopen the most recently used note even when it has been hidden. Passive
    /// restore/show-all operations do not change the order of recently used notes.
    @discardableResult func showMostRecentNote() -> Bool {
        if let modal = NSApp.modalWindow ?? entries.values.compactMap({ $0.panel.attachedSheet }).first {
            modal.makeKeyAndOrderFront(nil)
            return true
        }
        let note = store.recentNoteIDs.lazy.compactMap { id in self.store.notes.first { $0.id == id } }.first ?? store.notes.first
        guard let note else { return false }
        if let entry = entries[note.id], hasMarkedText(entry) {
            // Recalling a note must not commit or replace an in-progress IME draft.
            note.isVisible = true
            entry.collapseWork?.cancel()
            selectNote(entry)
            entry.panel.makeKeyAndOrderFront(nil)
            return true
        }
        show(note: note)
        return true
    }

    /// Collapse the note that has keyboard focus, as Esc does. Returns false when
    /// no expanded note is focused, so the global shortcut reopens the recent note.
    func collapseFocusedNote() -> Bool {
        guard let entry = entries.values.first(where: { $0.panel.isKeyWindow && $0.note.id == selectedNoteID }),
              entry.note.isVisible, entry.note.isExpanded, !entry.note.isHeaderOnly else { return false }
        collapse(entry)
        return true
    }

    func hide(note: NoteState) {
        guard let entry = entries[note.id] else { return }
        finishCompactResize(entry)
        finishTitleEditing(entry, force: true)
        saveFrame(entry)
        collapse(entry, force: true)
        entry.interactions.removeAll()
        clearShortcutNotice(entry)
        if selectedNoteID == note.id { selectNote(nil) }
        note.isVisible = false
        entry.panel.orderOut(nil)
        store.persist()
    }

    func hideAll() {
        for note in store.notes { hide(note: note) }
    }

    private func beginCompactResize(_ entry: Entry, edges: CompactResizeEdges, at point: NSPoint) -> Bool {
        guard entries[entry.note.id] === entry, entry.note.isVisible, entry.panel.isVisible,
              !entry.note.isExpanded, !entry.note.isDeleting, !entry.isDraggingWindow,
              entry.interactions.isEmpty, entry.panel.attachedSheet == nil, NSApp.modalWindow == nil,
              !hasMarkedText(entry), point.x.isFinite, point.y.isFinite,
              !edges.isEmpty, edges.rawValue & ~15 == 0,
              !edges.isSuperset(of: [.left, .right]), !edges.isSuperset(of: [.top, .bottom]) else { return false }
        NoteTitleField.cancelClickSequence(in: entry.panel)
        entry.collapseWork?.cancel()
        entry.panel.isMovableByWindowBackground = false
        let screen = entry.panel.screen ?? preferredScreen(for: entry.note)
        entry.compactResizeSession = CompactResizeSession(edges: edges, originalFrame: entry.panel.frame,
                                                          origin: point, area: screen.visibleFrame.insetBy(dx: 6, dy: 6))
        entry.interactions.insert("compactResize")
        selectNote(entry)
        return true
    }

    private func updateCompactResize(_ entry: Entry, to point: NSPoint) {
        guard entries[entry.note.id] === entry, let session = entry.compactResizeSession,
              !entry.note.isExpanded, point.x.isFinite, point.y.isFinite else { return }
        let frame = CompactResizeGeometry.resized(session.originalFrame, edges: session.edges,
                                                  delta: NSPoint(x: point.x - session.origin.x, y: point.y - session.origin.y),
                                                  within: session.area)
        entry.adjustingFrame = true
        entry.panel.setFrame(frame, display: true)
        entry.adjustingFrame = false
    }

    private func finishCompactResize(_ entry: Entry) {
        guard entries[entry.note.id] === entry, entry.compactResizeSession != nil else { return }
        entry.compactResizeSession = nil
        entry.panel.isMovableByWindowBackground = true
        entry.interactions.remove("compactResize")
        saveFrame(entry)
        updateOpacity(entry)
    }

    private func resetCompactSize(_ entry: Entry) {
        guard entries[entry.note.id] === entry, !entry.note.isExpanded, !entry.note.isDeleting,
              !entry.isDraggingWindow, !entry.interactions.contains("titleEditing"), !hasMarkedText(entry) else { return }
        finishCompactResize(entry)
        NoteTitleField.cancelClickSequence(in: entry.panel)
        let frame = entry.panel.frame
        entry.note.compactWidth = CompactResizeGeometry.defaultSize.width
        entry.note.compactHeight = CompactResizeGeometry.defaultSize.height
        entry.note.compactX = frame.minX
        entry.note.compactY = frame.maxY - CompactResizeGeometry.defaultSize.height
        setSize(entry, expanded: false)
        store.persist()
    }

    func showAll() {
        for note in store.notes { present(note: note, expanded: false) }
    }

    func setInteractionForAll(_ name: String, active: Bool) {
        for entry in entries.values { setInteraction(entry, name: name, active: active) }
    }

    func finishTitleEditingAll() {
        for entry in entries.values { finishTitleEditing(entry, force: true) }
    }

    private func present(note: NoteState, expanded: Bool) {
        guard store.notes.contains(where: { $0 === note }) else { return }
        let entry = entries[note.id] ?? makeEntry(note)
        finishCompactResize(entry)
        restoreHeader(entry)
        note.isVisible = true
        entry.panel.orderFrontRegardless()
        if expanded { expand(entry, focus: true) }
        else if !note.isExpanded { setSize(entry, expanded: false) }
        updateOpacity(entry)
        store.persist()
    }

    private func removeEntry(_ id: UUID) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        entry.collapseWork?.cancel()
        entry.collapseWork = nil
        clearShortcutNotice(entry)
        cancelHeaderCollapse(entry)
        entry.subscriptions.removeAll()
        entry.interactions.removeAll()
        entry.compactResizeSession = nil
        entry.panel.delegate = nil
        entry.manager = nil
        entry.panel.onEscape = nil
        entry.panel.onWindowDrag = nil
        entry.panel.onShortcut = nil
        entry.panel.makeFirstResponder(nil)
        entry.note.isVisible = false
        entry.panel.contentView = nil
        entry.panel.orderOut(nil)
        entry.panel.close()
        if selectedNoteID == id { selectNote(nil) }
    }

    private func requestDelete(_ entry: Entry) {
        guard entries[entry.note.id] === entry, store.canDeleteNote(entry.note) else { return }
        finishCompactResize(entry)
        finishTitleEditing(entry, force: true)
        setInteraction(entry, name: "deleteConfirmation", active: true)
        defer { setInteraction(entry, name: "deleteConfirmation", active: false) }
        store.requestDeleteNote(entry.note)
    }

    private func makeEntry(_ note: NoteState) -> Entry {
        let compactSize = compactSize(for: note)
        let panel = NotePanel(contentRect: NSRect(origin: .zero, size: compactSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .none
        panel.title = note.title

        let entry = Entry(note: note, panel: panel, manager: self)
        entries[note.id] = entry
        panel.delegate = entry
        panel.onEscape = { [weak self, weak entry] in
            guard let self, let entry else { return }
            self.collapse(entry)
        }
        panel.onWindowDrag = { [weak self, weak entry] active in
            guard let self, let entry else { return }
            self.windowDrag(entry, active: active)
        }
        panel.onShortcut = { [weak self, weak entry] event in
            guard let self, let entry else { return false }
            return self.handleShortcut(event, in: entry)
        }
        let actions = NoteWindowActions(
            expand: { [weak self, weak entry] in if let entry { self?.expand(entry, focus: true) } },
            collapse: { [weak self, weak entry] in if let entry { self?.collapse(entry) } },
            hide: { [weak self, weak note] in if let note { self?.hide(note: note) } },
            interaction: { [weak self, weak entry] name, active in if let entry { self?.setInteraction(entry, name: name, active: active) } },
            dragHover: { [weak self, weak entry] active in if let entry { self?.dragHover(entry, active: active) } },
            collapseTitle: { [weak self, weak entry] grace in if let entry { self?.collapseTitle(entry, grace: grace) } },
            delete: { [weak self, weak entry] in if let entry { self?.requestDelete(entry) } },
            beginCompactResize: { [weak self, weak entry] edges, point in
                guard let self, let entry else { return false }
                return self.beginCompactResize(entry, edges: edges, at: point)
            },
            updateCompactResize: { [weak self, weak entry] point in if let entry { self?.updateCompactResize(entry, to: point) } },
            endCompactResize: { [weak self, weak entry] in if let entry { self?.finishCompactResize(entry) } },
            resetSize: { [weak self, weak entry] in if let entry { self?.resetCompactSize(entry) } }
        )
        let hostingView = NoteHostingView(rootView: NoteView(note: note, store: store, actions: actions))
        hostingView.titleHeight = { [weak note] in note?.isExpanded == true ? 46 : (note?.compactHeight ?? 40) }
        hostingView.configureTitleMenu = { [weak self, weak entry] menu in
            guard let self, let entry else { menu.canDelete = false; return }
            menu.canDelete = self.store.canDeleteNote(entry.note)
            menu.onHide = actions.hide
            menu.onResetSize = entry.note.isExpanded || entry.note.isDeleting ? nil : actions.resetSize
            menu.onDelete = actions.delete
            menu.onInteraction = { actions.interaction("titleMenu", $0) }
        }
        panel.contentView = hostingView
        note.$title.sink { [weak panel] in panel?.title = $0 }.store(in: &entry.subscriptions)
        note.$isDeleting.sink { [weak self, weak entry] active in
            if let entry {
                if active { self?.finishCompactResize(entry) }
                self?.setInteraction(entry, name: "deleting", active: active)
            }
        }.store(in: &entry.subscriptions)
        note.$attachments.dropFirst().sink { [weak self, weak entry] attachments in
            guard let self, let entry else { return }
            if entry.temporaryDragExpansion && attachments.count > entry.dragAttachmentCount {
                entry.temporaryDragExpansion = false
                entry.interactions.remove("drag")
                self.expand(entry, focus: true)
            }
        }.store(in: &entry.subscriptions)

        let screen = preferredScreen(for: note)
        if note.compactX == nil || note.compactY == nil {
            let stagger = CGFloat((entries.count - 1) % 8) * 48
            note.compactX = Double(screen.visibleFrame.maxX - compactSize.width - 28)
            note.compactY = Double(screen.visibleFrame.maxY - compactSize.height - 28 - stagger)
        }
        setSize(entry, expanded: false)
        updateOpacity(entry)
        return entry
    }

    private func expand(_ entry: Entry, focus: Bool) {
        finishCompactResize(entry)
        restoreHeader(entry)
        finishTitleEditing(entry, force: true)
        entry.collapseWork?.cancel()
        if focus {
            for other in entries.values where other !== entry { collapse(other, automatic: true) }
            selectNote(entry)
        }
        entry.panel.allowsKeyboardFocus = focus
        entry.note.isExpanded = true
        updateOpacity(entry)
        entry.panel.styleMask.insert(.resizable)
        setSize(entry, expanded: true)
        if focus {
            entry.temporaryDragExpansion = false
            entry.note.hasUnreadReply = false
            entry.panel.makeKeyAndOrderFront(nil)
            entry.note.focusRequest = UUID()
        }
    }

    private func collapse(_ entry: Entry, force: Bool = false, automatic: Bool = false) {
        guard entry.note.isExpanded, !automatic || shouldAutomaticallyCollapse(entry) else { return }
        if entry.isDraggingWindow {
            if automatic { entry.automaticCollapseAfterDrag = true }
            else { entry.collapseAfterDrag = true }
            entry.forceCollapseAfterDrag = entry.forceCollapseAfterDrag || force
            entry.headerCollapseWork?.cancel()
            return
        }
        finishTitleEditing(entry, force: force)
        if !force && (hasMarkedText(entry) || !entry.interactions.isEmpty || entry.panel.attachedSheet != nil) { return }
        entry.collapseWork?.cancel()
        saveFrame(entry, persist: false)
        cancelHeaderCollapse(entry)
        entry.temporaryDragExpansion = false
        entry.note.isHeaderOnly = false
        entry.note.isExpanded = false
        entry.panel.allowsKeyboardFocus = false
        entry.panel.styleMask.remove(.resizable)
        releaseCompactFocus(entry)
        setSize(entry, expanded: false)
        updateOpacity(entry)
        store.persist()
    }

    private func collapseTitle(_ entry: Entry, grace: TimeInterval) {
        guard grace.isFinite, grace > 0 else { collapse(entry); return }
        guard entry.note.isExpanded, !entry.note.isHeaderOnly, !entry.isDraggingWindow else { return }
        finishTitleEditing(entry)
        guard !hasMarkedText(entry), entry.interactions.isEmpty, entry.panel.attachedSheet == nil else { return }
        entry.collapseWork?.cancel()
        saveFrame(entry, persist: false)
        // The hidden composer must stop receiving keys. The same visible title
        // can explicitly reacquire focus for the second click of a rename gesture.
        entry.panel.makeFirstResponder(nil)
        entry.note.isHeaderOnly = true
        entry.panel.allowsKeyboardFocus = false
        releaseCompactFocus(entry)
        entry.adjustingFrame = true
        let oldFrame = entry.panel.frame
        let headerFrame = NSRect(x: oldFrame.minX, y: oldFrame.maxY - 46, width: oldFrame.width, height: 46)
        entry.panel.styleMask.remove(.resizable)
        entry.panel.minSize = headerFrame.size
        entry.panel.maxSize = headerFrame.size
        entry.panel.setFrame(headerFrame, display: true)
        entry.adjustingFrame = false
        entry.headerCollapseDeadline = .now() + grace
        scheduleHeaderCollapse(entry)
    }

    private func scheduleHeaderCollapse(_ entry: Entry) {
        entry.headerCollapseWork?.cancel()
        guard entry.note.isHeaderOnly, !entry.isDraggingWindow, let deadline = entry.headerCollapseDeadline else { return }
        let token = UUID()
        entry.headerCollapseToken = token
        let work = DispatchWorkItem { [weak self, weak entry] in
            guard let self, let entry, entry.headerCollapseToken == token,
                  entry.note.isHeaderOnly, !entry.isDraggingWindow else { return }
            entry.headerCollapseWork = nil
            self.collapse(entry)
        }
        entry.headerCollapseWork = work
        DispatchQueue.main.asyncAfter(deadline: deadline, execute: work)
    }

    private func cancelHeaderCollapse(_ entry: Entry) {
        entry.headerCollapseWork?.cancel()
        entry.headerCollapseWork = nil
        entry.headerCollapseToken = nil
        entry.headerCollapseDeadline = nil
    }

    private func restoreHeader(_ entry: Entry) {
        guard entry.note.isHeaderOnly else { return }
        saveFrame(entry, persist: false)
        cancelHeaderCollapse(entry)
        entry.note.isHeaderOnly = false
        entry.panel.allowsKeyboardFocus = true
        entry.panel.styleMask.insert(.resizable)
        setSize(entry, expanded: true)
    }

    private func windowDrag(_ entry: Entry, active: Bool) {
        if active {
            finishCompactResize(entry)
            entry.isDraggingWindow = true
            entry.interactions.insert("windowDrag")
            entry.collapseWork?.cancel()
            entry.headerCollapseWork?.cancel()
            entry.headerCollapseToken = nil
        } else {
            entry.isDraggingWindow = false
            entry.interactions.remove("windowDrag")
            saveFrame(entry, persist: false)
            let shouldCollapse = entry.note.isHeaderOnly || entry.collapseAfterDrag ||
                (entry.automaticCollapseAfterDrag && shouldAutomaticallyCollapse(entry))
            let force = entry.forceCollapseAfterDrag
            entry.collapseAfterDrag = false
            entry.automaticCollapseAfterDrag = false
            entry.forceCollapseAfterDrag = false
            if shouldCollapse {
                collapse(entry, force: force)
            } else {
                if entry.needsScreenClamp { setSize(entry, expanded: entry.note.isExpanded) }
                store.persist()
            }
            entry.needsScreenClamp = false
        }
    }

    private func setInteraction(_ entry: Entry, name: String, active: Bool) {
        guard entries[entry.note.id] === entry else { return }
        if active {
            entry.interactions.insert(name)
            entry.collapseWork?.cancel()
            if name == "titleEditing" {
                // Restore before the field installs its editor; never redirect
                // focus to the composer or end this new rename session.
                restoreHeader(entry)
                // Compact notes gain keyboard focus only for an explicit rename.
                entry.panel.allowsKeyboardFocus = true
                selectNote(entry)
                entry.panel.makeKeyAndOrderFront(nil)
            }
        } else {
            let wasActive = entry.interactions.remove(name) != nil
            if name == "titleEditing", wasActive {
                entry.panel.allowsKeyboardFocus = entry.note.isExpanded
                if !entry.note.isExpanded {
                    entry.panel.makeFirstResponder(nil)
                    releaseCompactFocus(entry)
                }
            }
            scheduleCollapse(entry)
            if entry.note.isHeaderOnly { scheduleHeaderCollapse(entry) }
        }
        updateOpacity(entry)
    }

    private func releaseCompactFocus(_ entry: Entry) {
        guard entry.panel.isKeyWindow else { return }
        // A deliberate collapse/end of compact rename keeps the user's selection.
        entry.releasingCompactFocus = true
        entry.panel.resignKey()
        entry.releasingCompactFocus = false
    }

    private func selectNote(_ entry: Entry?) {
        if let entry, entries[entry.note.id] !== entry { return }
        selectedNoteID = entry?.note.id
        if let entry { store.recordNoteUse(entry.note.id) }
        updateOpacities()
    }

    private func handleShortcut(_ event: NSEvent, in entry: Entry) -> Bool {
        guard event.type == .keyDown, entries[entry.note.id] === entry,
              entry.panel.isKeyWindow, entry.panel.isVisible, entry.note.isVisible,
              !store.isRecordingShortcut, NSApp.modalWindow == nil, entry.panel.attachedSheet == nil,
              !hasMarkedText(entry) else { return false }
        let shortcuts = store.keyboardShortcuts
        let action: (Entry) -> Void
        if shortcuts.toggleKeepOpen?.matches(event) == true { action = toggleKeepExpanded }
        else if shortcuts.hideNote?.matches(event) == true { action = { [weak self] in self?.hide(note: $0.note) } }
        else if shortcuts.deleteNote?.matches(event) == true { action = requestDelete }
        else { return false }
        // Holding a shortcut should not repeat its action, or send its repeated
        // keys into the text editor after the first successful press.
        guard !event.isARepeat else { return true }
        action(entry)
        return true
    }

    private func toggleKeepExpanded(_ entry: Entry) {
        store.keepNotesExpanded.toggle()
        let notice = "Keep Notes Expanded: \(store.keepNotesExpanded ? "On" : "Off")"
        clearShortcutNotice(entry)
        entry.note.shortcutNotice = notice
        NSAccessibility.post(element: entry.panel, notification: .announcementRequested,
                             userInfo: [.announcement: notice, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        let work = DispatchWorkItem { [weak entry] in entry?.note.shortcutNotice = nil }
        entry.shortcutNoticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    private func clearShortcutNotice(_ entry: Entry) {
        entry.shortcutNoticeWork?.cancel()
        entry.shortcutNoticeWork = nil
        entry.note.shortcutNotice = nil
    }

    private func updateOpacities(inactiveOpacity: Double? = nil) {
        for entry in entries.values { updateOpacity(entry, inactiveOpacity: inactiveOpacity) }
    }

    private func updateOpacity(_ entry: Entry, inactiveOpacity: Double? = nil) {
        // The status menu protects collapse for every note; it does not select all notes.
        let interacting = !entry.interactions.subtracting(["statusMenu"]).isEmpty
        let fullOpacity = entry.note.isExpanded || selectedNoteID == entry.note.id || interacting
        entry.panel.alphaValue = fullOpacity ? 1 : (inactiveOpacity ?? store.inactiveNoteOpacity)
    }

    private func finishTitleEditing(_ entry: Entry, force: Bool = false) {
        guard entry.interactions.contains("titleEditing"), force || !hasMarkedText(entry) else { return }
        // Resigning the window alone need not end an NSTextField's editing session.
        if entry.panel.makeFirstResponder(nil) {
            setInteraction(entry, name: "titleEditing", active: false)
        }
    }

    private func dragHover(_ entry: Entry, active: Bool) {
        guard entry.compactResizeSession == nil else { return }
        if active {
            restoreHeader(entry)
            entry.interactions.insert("drag")
            entry.collapseWork?.cancel()
            if !entry.note.isExpanded {
                entry.dragAttachmentCount = entry.note.attachments.count
                entry.temporaryDragExpansion = true
                expand(entry, focus: false)
            }
        } else {
            entry.interactions.remove("drag")
            // NSItemProvider can complete after isTargeted becomes false.
            scheduleCollapse(entry, delay: 0.8)
        }
        updateOpacity(entry)
    }

    private func shouldAutomaticallyCollapse(_ entry: Entry) -> Bool {
        // A cancelled drop still restores a note that was only opened for its preview.
        !store.keepNotesExpanded || entry.temporaryDragExpansion
    }

    fileprivate func scheduleCollapse(_ entry: Entry, delay: Double = 0.18) {
        entry.collapseWork?.cancel()
        entry.collapseWork = nil
        guard shouldAutomaticallyCollapse(entry) else { return }
        let work = DispatchWorkItem { [weak self, weak entry] in
            guard let self, let entry, !entry.panel.isKeyWindow else { return }
            self.collapse(entry, automatic: true)
        }
        entry.collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scheduleUnfocusedCollapses() {
        for entry in entries.values {
            if !entry.panel.isKeyWindow { finishTitleEditing(entry) }
            scheduleCollapse(entry)
        }
    }

    private func hasMarkedText(_ entry: Entry) -> Bool {
        (entry.panel.firstResponder as? NSTextInputClient)?.hasMarkedText() ?? false
    }

    private func setSize(_ entry: Entry, expanded: Bool) {
        entry.adjustingFrame = true
        defer { entry.adjustingFrame = false }
        let note = entry.note
        let screen = preferredScreen(for: note)
        let area = screen.visibleFrame.insetBy(dx: 6, dy: 6)
        var compactSize = compactSize(for: note)
        compactSize.width = min(compactSize.width, area.width)
        compactSize.height = min(compactSize.height, area.height)
        note.compactWidth = compactSize.width
        note.compactHeight = compactSize.height
        let compactLeft = max(area.minX, min(note.compactX.map { CGFloat($0) } ?? area.minX, area.maxX - compactSize.width))
        let compactBottom = max(area.minY, min(note.compactY.map { CGFloat($0) } ?? area.maxY - compactSize.height, area.maxY - compactSize.height))
        note.compactX = Double(compactLeft)
        note.compactY = Double(compactBottom)
        let size = expanded
            ? NSSize(width: min(max(CGFloat(note.expandedWidth), 360), area.width), height: min(max(CGFloat(note.expandedHeight), 420), area.height))
            : compactSize
        // The compact top-left corner is the anchor, so expansion grows down.
        var frame = NSRect(x: compactLeft, y: compactBottom + compactSize.height - size.height, width: size.width, height: size.height)
        frame.origin.x = max(area.minX, min(frame.minX, area.maxX - frame.width))
        frame.origin.y = max(area.minY, min(frame.minY, area.maxY - frame.height))
        entry.panel.minSize = expanded ? NSSize(width: min(360, area.width), height: min(420, area.height)) :
            NSSize(width: min(CompactResizeGeometry.minimumSize.width, area.width), height: min(CompactResizeGeometry.minimumSize.height, area.height))
        entry.panel.maxSize = expanded ? area.size :
            NSSize(width: min(CompactResizeGeometry.maximumSize.width, area.width), height: min(CompactResizeGeometry.maximumSize.height, area.height))
        entry.panel.setFrame(frame, display: true)
        // Expansion may need to shift to fit the display. Preserve the compact
        // anchor so closing it does not permanently move the user's sticky note.
        entry.expansionOffset = NSPoint(x: compactLeft - frame.minX, y: compactBottom + compactSize.height - frame.maxY)
        note.displayID = displayID(screen)
    }

    fileprivate func saveFrame(_ entry: Entry, persist: Bool = true) {
        guard entries[entry.note.id] === entry, !entry.adjustingFrame, entry.compactResizeSession == nil else { return }
        let frame = entry.panel.frame
        if !entry.note.isExpanded {
            entry.note.compactWidth = frame.width
            entry.note.compactHeight = frame.height
        }
        let offset = entry.note.isExpanded ? entry.expansionOffset : .zero
        entry.note.compactX = Double(frame.minX + offset.x)
        entry.note.compactY = Double(frame.maxY - entry.note.compactHeight + offset.y)
        if entry.note.isExpanded && !entry.note.isHeaderOnly {
            entry.note.expandedWidth = frame.width
            entry.note.expandedHeight = frame.height
        }
        if let screen = entry.panel.screen { entry.note.displayID = displayID(screen) }
        if persist { store.persist() }
    }

    private func clampAllWindows() {
        for entry in entries.values {
            finishCompactResize(entry)
            if entry.isDraggingWindow {
                entry.needsScreenClamp = true
            } else if entry.note.isHeaderOnly {
                collapse(entry, force: true)
            } else {
                setSize(entry, expanded: entry.note.isExpanded)
            }
        }
        store.persist()
    }

    private func preferredScreen(for note: NoteState) -> NSScreen {
        if let id = note.displayID, let screen = NSScreen.screens.first(where: { displayID($0) == id }) { return screen }
        if let x = note.compactX, let y = note.compactY,
           let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(NSPoint(x: x + note.compactWidth / 2, y: y + note.compactHeight / 2)) }) { return screen }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    private func displayID(_ screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    fileprivate struct CompactResizeSession {
        let edges: CompactResizeEdges
        let originalFrame: NSRect
        let origin: NSPoint
        let area: NSRect
    }

    @MainActor fileprivate final class Entry: NSObject, NSWindowDelegate {
        let note: NoteState
        let panel: NotePanel
        weak var manager: NoteWindowManager?
        var interactions = Set<String>()
        var subscriptions = Set<AnyCancellable>()
        var collapseWork: DispatchWorkItem?
        var headerCollapseWork: DispatchWorkItem?
        var shortcutNoticeWork: DispatchWorkItem?
        var headerCollapseDeadline: DispatchTime?
        var headerCollapseToken: UUID?
        var isDraggingWindow = false
        var collapseAfterDrag = false
        var automaticCollapseAfterDrag = false
        var forceCollapseAfterDrag = false
        var needsScreenClamp = false
        var adjustingFrame = false
        var releasingCompactFocus = false
        var temporaryDragExpansion = false
        var dragAttachmentCount = 0
        var expansionOffset: NSPoint = .zero
        var compactResizeSession: CompactResizeSession?

        init(note: NoteState, panel: NotePanel, manager: NoteWindowManager) {
            self.note = note
            self.panel = panel
            self.manager = manager
        }
        func windowDidResignKey(_ notification: Notification) {
            // A deliberate compact/header transition already owns its timing;
            // scheduling the usual blur collapse would shorten double-click grace.
            guard !releasingCompactFocus else { return }
            if manager?.selectedNoteID == note.id { manager?.selectNote(nil) }
            manager?.finishTitleEditing(self)
            manager?.scheduleCollapse(self)
        }
        func windowDidBecomeKey(_ notification: Notification) { manager?.selectNote(self) }
        func windowDidMove(_ notification: Notification) { manager?.saveFrame(self) }
        func windowDidEndLiveResize(_ notification: Notification) { manager?.saveFrame(self) }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            manager?.hide(note: note)
            return false
        }
    }
}

@MainActor fileprivate final class NotePanel: NSPanel {
    var allowsKeyboardFocus = false
    var onEscape: (() -> Void)?
    var onWindowDrag: ((Bool) -> Void)?
    var onShortcut: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { allowsKeyboardFocus }
    override var canBecomeMain: Bool { false }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onShortcut?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onShortcut?(event) == true { return }
        super.sendEvent(event)
    }
    override func performDrag(with event: NSEvent) {
        onWindowDrag?(true)
        defer { onWindowDrag?(false) }
        super.performDrag(with: event)
    }
    override func cancelOperation(_ sender: Any?) {
        guard !((firstResponder as? NSTextInputClient)?.hasMarkedText() ?? false) else { return }
        onEscape?()
    }
}

private final class NoteHostingView<Content: View>: NSHostingView<Content> {
    private let titleContextMenu = NoteTitleContextMenu()
    var titleHeight: (() -> CGFloat)?
    var configureTitleMenu: ((NoteTitleContextMenu) -> Void)?
    override var mouseDownCanMoveWindow: Bool { true }
    override func rightMouseDown(with event: NSEvent) {
        // Foreground SwiftUI buttons can forward their context click here.
        // Native title editors keep their normal text-editing context menu.
        let point = convert(event.locationInWindow, from: nil)
        let height = titleHeight?() ?? 0
        let inTitle = isFlipped ? point.y <= bounds.minY + height : point.y >= bounds.maxY - height
        guard bounds.contains(point), inTitle, let configureTitleMenu else {
            super.rightMouseDown(with: event)
            return
        }
        configureTitleMenu(titleContextMenu)
        titleContextMenu.popUp(with: event, for: self)
    }
}
