import AppKit
import SwiftUI
import FloatingAICore

/// A deterministic rendering mode for visual QA; it never connects to a CLI or reads user notes.
@MainActor enum PreviewRenderer {
    private static var retainedWindows: [NSWindow] = []
    static func run(outputDirectory: URL) {
        do { try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true) }
        catch { fputs("Preview directory failed: \(error)\n", stderr); exit(1) }
        let store = AppStore(directory: outputDirectory.appendingPathComponent("preview-data"),
                             previewAuthentication: (.codexSignIn, false))
        store.models = [CodexModel(id: "preview-model", displayName: "GPT-5.6 Codex Ultra", defaultReasoningEffort: "medium",
                                  supportedReasoningEfforts: [ReasoningEffortOption(reasoningEffort: "medium", description: "Balanced"),
                                                             ReasoningEffortOption(reasoningEffort: "high", description: "Deeper reasoning")], isDefault: true),
                        CodexModel(id: "preview-short", displayName: "GPT-5.6", defaultReasoningEffort: "low",
                                   supportedReasoningEfforts: [ReasoningEffortOption(reasoningEffort: "low", description: "Fast"),
                                                              ReasoningEffortOption(reasoningEffort: "medium", description: "Balanced")]),
                        CodexModel(id: "preview-long", displayName: "GPT-5.6 Codex Ultra Extended Preview", defaultReasoningEffort: "xhigh",
                                   supportedReasoningEfforts: [ReasoningEffortOption(reasoningEffort: "xhigh", description: "Extra high")])]
        store.defaultModelID = "preview-model"
        store.defaultEffort = "medium"
        store.isConnected = true
        store.isLoggedIn = true
        store.connectionStatus = "Connected · Preview"
        store.claudeModels = [CodexModel(id: "sonnet", displayName: "Claude Sonnet", defaultReasoningEffort: "medium",
                                       supportedReasoningEfforts: [ReasoningEffortOption(reasoningEffort: "low", description: "Fast"),
                                                                  ReasoningEffortOption(reasoningEffort: "medium", description: "Balanced"),
                                                                  ReasoningEffortOption(reasoningEffort: "high", description: "More reasoning")], isDefault: true)]
        store.claudeEnabled = true
        store.claudeIsConnected = true
        store.claudeIsLoggedIn = true
        store.claudeConnectionStatus = "Connected · Claude sign-in"
        let note = store.createNote(title: "Weekend reading", model: "codex:preview-model", effort: "medium")
        note.isExpanded = true
        note.messages = [ChatMessage(id: "1", role: "user", text: "How can I turn what I read into useful ideas?"),
                         ChatMessage(id: "2", role: "assistant", text: "Start with one small habit: **keep just one idea each time**.\n\n- Summarize it in your own words\n- Connect it to a problem you are working on\n- Write down one action to try tomorrow\n\n> A useful note is one you can return to.\n\n```python\nidea = {\n    \"question\": \"What could this solve?\",\n    \"next_step\": \"Try it once\"\n}\n``` ")]
        let actions = NoteWindowActions(expand: {}, collapse: {}, hide: {}, interaction: { _, _ in }, dragHover: { _ in })
        let compact = NoteState(title: "Weekend reading", model: "preview-model", effort: "medium")
        compact.hasUnreadReply = true
        func sizedNote(height: Double) -> NoteState {
            let result = NoteState(title: "Message box preview", model: "preview-model", effort: "medium")
            result.isExpanded = true
            result.composerHeight = height
            result.messages = note.messages
            result.draft = "Could you walk through an example?\nI would like to use this for my daily reading notes."
            return result
        }
        let smallComposer = sizedNote(height: 44)
        let largeComposer = sizedNote(height: 320)
        let narrowComposer = sizedNote(height: 320)
        narrowComposer.attachments = [StoredAttachment(path: "", name: "Example.png")]
        narrowComposer.error = "Connection interrupted. Your draft is saved. Reconnect to continue."
        narrowComposer.pendingSubmission = PendingMessage(text: "This message is awaiting confirmation.", attachments: [], model: "preview-model", effort: "medium")
        let shortToolbar = sizedNote(height: 64)
        shortToolbar.model = "preview-short"
        shortToolbar.effort = "low"
        let longToolbar = sizedNote(height: 64)
        longToolbar.model = "preview-long"
        longToolbar.effort = "xhigh"
        let claudeNote = sizedNote(height: 64)
        claudeNote.provider = .claude
        claudeNote.model = "sonnet"
        let fileNote = store.createNote(title: "Compare my research files", model: "codex:preview-short", effort: "medium")
        let narrowFileNote = store.createNote(title: "Files at minimum width", model: "codex:preview-long", effort: "xhigh")
        do {
            let attachments = AttachmentStore(directory: outputDirectory.appendingPathComponent("preview-data"))
            let image = NSImage(size: NSSize(width: 240, height: 150))
            image.lockFocus()
            NSColor(calibratedRed: 0.90, green: 0.95, blue: 1, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 240, height: 150)).fill()
            for (index, height) in [42, 69, 90, 110].enumerated() {
                NSColor(calibratedRed: 0.19, green: 0.48, blue: 0.81, alpha: 0.55 + Double(index) * 0.12).setFill()
                NSBezierPath(roundedRect: NSRect(x: 24 + index * 49, y: 20, width: 31, height: height), xRadius: 4, yRadius: 4).fill()
            }
            image.unlockFocus()
            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else { throw AttachmentError.storage }
            let source = outputDirectory.appendingPathComponent("preview-file-source.txt")
            try Data("Fictional fixture for visual QA only. No CLI is connected.\n".utf8).write(to: source)
            for fileFixture in [fileNote, narrowFileNote] {
                let picture = try attachments.storePNG(png, noteID: fileFixture.id, name: "Research summary chart.png")
                var document = try attachments.importFile(source, noteID: fileFixture.id,
                    name: "Quarterly_research_comparison_of_personal_notes_and_project_methods_final_review_2026.pdf")
                document.byteCount = 428_032
                var spreadsheet = try attachments.importFile(source, noteID: fileFixture.id, name: "Experiment results.xlsx")
                spreadsheet.byteCount = 86_016
                let memo = try attachments.importFile(source, noteID: fileFixture.id, name: "Meeting notes.txt")
                fileFixture.fileLibrary = [picture, document, spreadsheet, memo]
                fileFixture.attachments = [picture, document]
                fileFixture.isExpanded = true
                fileFixture.composerHeight = 64
                fileFixture.draft = "Compare the document with this chart."
                fileFixture.messages = [
                    ChatMessage(id: "file-user", role: "user", text: "Keep these files available for this note.",
                                fileAttachments: [document, spreadsheet]),
                    ChatMessage(id: "file-assistant", role: "assistant", text: "I can compare the findings once you tell me which question to focus on.")
                ]
            }
            try FileManager.default.removeItem(at: source)
        } catch {
            fputs("Preview file fixtures failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
        func resizedCompact(width: Double, height: Double) -> NoteState {
            let result = NoteState(title: "Research notes — questions and next steps for the next project review", model: "preview-short", effort: "medium")
            result.compactWidth = width
            result.compactHeight = height
            result.hasUnreadReply = true
            return result
        }
        let minimumCompact = resizedCompact(width: 160, height: 36)
        let wideCompact = resizedCompact(width: 640, height: 40)
        let tallCompact = resizedCompact(width: 320, height: 160)
        // These are display-only fixtures. No real key is supplied and the
        // preview initializer must never access Keychain or connect to Codex.
        let apiEmpty = AppStore(directory: outputDirectory.appendingPathComponent("preview-api-empty"),
                                previewAuthentication: (.openAIAPIKey, false))
        apiEmpty.connectionStatus = "OpenAI API Key · No key saved"
        let apiSaved = AppStore(directory: outputDirectory.appendingPathComponent("preview-api-saved"),
                                previewAuthentication: (.openAIAPIKey, true))
        apiSaved.isConnected = true
        apiSaved.isLoggedIn = true
        apiSaved.connectionStatus = "Connected · API key configured"
        let apiConnecting = AppStore(directory: outputDirectory.appendingPathComponent("preview-api-connecting"),
                                     previewAuthentication: (.openAIAPIKey, true))
        apiConnecting.isConnecting = true
        apiConnecting.connectionStatus = "Connecting to Codex…"
        let managed = AppStore(directory: outputDirectory.appendingPathComponent("preview-manage-notes"),
                               previewAuthentication: (.codexSignIn, false))
        managed.models = store.models
        managed.claudeModels = store.claudeModels
        managed.isConnected = true
        managed.isLoggedIn = true
        managed.claudeIsConnected = true
        managed.claudeIsLoggedIn = true
        let visibleNote = managed.createNote(title: "Weekend reading", model: "codex:preview-short", effort: "low")
        let hiddenNote = managed.createNote(title: "Research archive", model: "claude:sonnet", effort: "medium")
        hiddenNote.isVisible = false
        let generatingNote = managed.createNote(title: "Live web research", model: "codex:preview-model", effort: "medium")
        generatingNote.isBusy = true
        let incompleteNote = managed.createNote(title: "Saved questions", model: "claude:sonnet", effort: "medium")
        incompleteNote.isVisible = false
        incompleteNote.deletionPending = true
        incompleteNote.error = "Deletion did not finish. Reconnect Claude Code in Settings, then retry. Your note has been kept."
        let deletingNote = managed.createNote(title: "Old project notes", model: "codex:preview-short", effort: "low")
        deletingNote.isVisible = false
        deletingNote.isDeleting = true
        let views: [(String, AnyView, NSSize)] = [
            ("expanded", AnyView(NoteView(note: note, store: store, actions: actions)), NSSize(width: 500, height: 640)),
            ("composer-small", AnyView(NoteView(note: smallComposer, store: store, actions: actions)), NSSize(width: 500, height: 640)),
            ("composer-large", AnyView(NoteView(note: largeComposer, store: store, actions: actions)), NSSize(width: 500, height: 640)),
            ("composer-narrow", AnyView(NoteView(note: narrowComposer, store: store, actions: actions)), NSSize(width: 360, height: 420)),
            ("toolbar-short", AnyView(NoteView(note: shortToolbar, store: store, actions: actions)), NSSize(width: 500, height: 640)),
            ("toolbar-long-narrow", AnyView(NoteView(note: longToolbar, store: store, actions: actions)), NSSize(width: 360, height: 420)),
            ("claude-note", AnyView(NoteView(note: claudeNote, store: store, actions: actions)), NSSize(width: 500, height: 640)),
            ("files-expanded", AnyView(NoteView(note: fileNote, store: store, actions: actions)), NSSize(width: 500, height: 640)),
            ("files-minimum-width", AnyView(NoteView(note: narrowFileNote, store: store, actions: actions)), NSSize(width: 360, height: 420)),
            ("note-files-library", AnyView(NoteFilesView(note: fileNote, store: store, onClose: {})), NSSize(width: 350, height: 360)),
            ("compact", AnyView(NoteView(note: compact, store: store, actions: actions)), NSSize(width: 220, height: 40)),
            ("compact-minimum", AnyView(NoteView(note: minimumCompact, store: store, actions: actions)), NSSize(width: 160, height: 36)),
            ("compact-wide", AnyView(NoteView(note: wideCompact, store: store, actions: actions)), NSSize(width: 640, height: 40)),
            ("compact-tall", AnyView(NoteView(note: tallCompact, store: store, actions: actions)), NSSize(width: 320, height: 160)),
            ("new-note", AnyView(NewNoteView(store: store, onCreated: { _ in }, onCancel: {})), NSSize(width: 450, height: 400)),
            ("settings", AnyView(SettingsView(store: store)), NSSize(width: 540, height: 650)),
            ("settings-api-empty", AnyView(SettingsView(store: apiEmpty)), NSSize(width: 540, height: 650)),
            ("settings-api-saved", AnyView(SettingsView(store: apiSaved)), NSSize(width: 540, height: 650)),
            ("settings-api-connecting", AnyView(SettingsView(store: apiConnecting)), NSSize(width: 540, height: 650)),
            ("manage-notes", AnyView(ManageNotesView(store: managed, selectedIDs: [visibleNote.id, hiddenNote.id],
                                                   onShow: { _ in }, onHide: { _ in })), NSSize(width: 640, height: 480)),
            ("manage-notes-busy", AnyView(ManageNotesView(store: managed, selectedIDs: [generatingNote.id],
                                                        onShow: { _ in }, onHide: { _ in })), NSSize(width: 640, height: 480))
        ]
        for (_, view, size) in views {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
            window.appearance = NSAppearance(named: .aqua)
            window.isReleasedWhenClosed = false
            retainedWindows.append(window)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            var failed = false
            for (index, entry) in views.enumerated() {
                guard let view = retainedWindows[index].contentView else { continue }
                view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { failed = true; continue }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { failed = true; continue }
                do { try png.write(to: outputDirectory.appendingPathComponent(entry.0 + ".png")) }
                catch { failed = true }
            }
            fputs(failed ? "Preview failed\n" : "Preview rendered\n", stderr)
            exit(failed ? 1 : 0)
        }
    }
}
