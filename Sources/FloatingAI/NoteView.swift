import AppKit
import FloatingAICore
import SwiftUI
import UniformTypeIdentifiers

@MainActor struct NoteView: View {
    @ObservedObject var note: NoteState
    @ObservedObject var store: AppStore
    var actions: NoteWindowActions
    @State private var dropTargeted = false
    @State private var isComposing = false
    @State private var followsLatest = true
    @State private var transcriptHeight: CGFloat = 0
    @State private var isResizingComposer = false
    @State private var showsFiles = false

    private var selectedModel: ChatModel? { store.model(for: note) }
    private var compactFrame: NSRect? {
        guard let x = note.compactX, let y = note.compactY else { return nil }
        return NSRect(x: x, y: y, width: note.compactWidth, height: note.compactHeight)
    }
    private var canSend: Bool {
        !note.isImportingFiles && !note.isDeleting && !note.deletionPending && !note.isBusy && !note.needsReconciliation && note.pendingSubmission == nil && !isComposing && store.isReady(for: note) &&
        (!note.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !note.attachments.isEmpty) &&
        store.availableModels(for: note).contains(where: { $0.id == note.modelSelectionID }) &&
        selectedModel?.supportedReasoningEfforts.contains(where: { $0.reasoningEffort == note.effort }) == true
    }

    var body: some View {
        GeometryReader { geometry in
            // Keep the transcript and native editor mounted while the panel is compact.
            // This preserves the reading position, selection, undo stack, and marked text.
            expanded
                .frame(width: note.isExpanded ? geometry.size.width : note.expandedWidth,
                       height: note.isExpanded && !note.isHeaderOnly ? geometry.size.height : note.expandedHeight)
                .opacity(note.isExpanded ? 1 : 0)
                .allowsHitTesting(note.isExpanded)
                .accessibilityHidden(!note.isExpanded)
            if !note.isExpanded { compact }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: note.isExpanded ? 14 : 12))
        .overlay {
            RoundedRectangle(cornerRadius: note.isExpanded ? 14 : 12)
                .strokeBorder(dropTargeted ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: dropTargeted ? 2 : 0.5)
                .allowsHitTesting(false)
        }
        .onDrop(of: [UTType.fileURL.identifier, UTType.image.identifier], isTargeted: $dropTargeted, perform: receiveDrop)
        .onChange(of: dropTargeted) { actions.dragHover($0) }
        .overlay {
            CompactResizeView(active: note.isVisible && !note.isExpanded,
                              onBegin: actions.beginCompactResize, onUpdate: actions.updateCompactResize, onEnd: actions.endCompactResize)
        }
        .overlay(alignment: .top) {
            if let notice = note.shortcutNotice {
                Text(notice)
                    .font(.caption.weight(.medium))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 8)
                    .padding(.top, note.isExpanded && !note.isHeaderOnly ? 52 : 4)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: showsFiles) { actions.interaction("noteFiles", $0) }
    }

    private var compact: some View {
        HStack(spacing: 9) {
            Image(systemName: "text.bubble.fill").foregroundStyle(.tint).font(.system(size: 13))
                .frame(width: 20, height: 30)
                .overlay { titleDragHandle(expanded: false, onClick: actions.expand) }
            titleView(expanded: false).frame(maxWidth: .infinity).frame(height: 30)
            Group {
                if note.isBusy || note.isDeleting {
                    ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                } else if note.error != nil {
                    Image(systemName: "exclamationmark.circle.fill").font(.system(size: 11)).foregroundStyle(.orange)
                } else if note.hasUnreadReply {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                } else {
                    Image(systemName: "chevron.up").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                }
            }.frame(width: 14, height: 30)
                .overlay { titleDragHandle(expanded: false, onClick: actions.expand) }
        }
        .padding(.horizontal, 12).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { titleDragHandle(expanded: false, onClick: actions.expand) }
        .accessibilityElement(children: .contain)
    }

    private var expanded: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(note.isHeaderOnly ? 0 : 1)
            GeometryReader { available in
                // The header is outside this region. Reserve room for the transcript,
                // toolbar, resize grip and (when present) the attachment strip.
                let maximum = max(44, min(320, available.size.height - 170 - (note.attachments.isEmpty ? 0 : 73)))
                let height = min(CGFloat(note.composerHeight), maximum)
                VStack(spacing: 0) {
                    transcript.frame(minHeight: 96, maxHeight: .infinity)
                    ComposerResizeHandle(height: height, maximumHeight: maximum,
                                         onChange: { note.composerHeight = Double($0) },
                                         onInteraction: {
                                             isResizingComposer = $0
                                             actions.interaction("composerResize", $0)
                                         })
                        .frame(height: 12)
                    composer(height: height)
                }
            }
            .opacity(note.isHeaderOnly ? 0 : 1)
            .allowsHitTesting(!note.isHeaderOnly)
            .accessibilityHidden(note.isHeaderOnly)
        }
    }

    // Keep notices scrollable so a small window or tall editor cannot push controls offscreen.
    private var conversationNotices: some View {
        VStack(spacing: 8) {
            if note.deletionPending {
                HStack(spacing: 8) {
                    if note.isDeleting { ProgressView().controlSize(.small) }
                    Text(note.isDeleting ? "Deleting note and conversation history…" : "Deletion is incomplete. Retry to finish removing this note and its history.")
                        .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                    if !note.isDeleting {
                        Button("Retry Delete", action: actions.delete)
                            .controlSize(.small).disabled(!store.canDeleteNote(note))
                    }
                }.padding(10).background(Color.orange.opacity(0.08))
            }
            if let error = note.error {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text(error).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Button { note.error = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).help("Dismiss")
                }
                .font(.caption).padding(10).background(Color.orange.opacity(0.08))
            }
            if !note.isBusy, !note.deletionPending, let pending = note.pendingSubmission {
                pendingRequest(pending)
            }
        }
    }

    private func pendingRequest(_ pending: PendingSubmission) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Delivery of the last message is unconfirmed. Check the history before retrying.", systemImage: "exclamationmark.circle")
                .font(.caption).foregroundStyle(.orange)
            if !pending.text.isEmpty {
                Text(pending.text).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).textSelection(.enabled)
            }
            HStack {
                if !pending.attachments.isEmpty {
                    Label("\(pending.attachments.count) images", systemImage: "photo")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Restore Draft") { store.recoverPending(note) }.controlSize(.small)
                Button("Dismiss Request") { store.discardPending(note) }.controlSize(.small)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.05))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.bubble.fill").foregroundStyle(.tint)
                .frame(width: 20, height: 22)
                .overlay { titleDragHandle(expanded: true, onClick: {}) }
            titleView(expanded: true).frame(maxWidth: .infinity).frame(height: 22)
            HStack(spacing: 2) {
                headerButton("chevron.down", label: "Collapse Note", help: "Collapse Note (Esc)", action: actions.collapse)
                headerButton("minus", label: "Hide Note", help: "Hide Note", action: actions.hide)
                headerButton("xmark", label: "Delete Note", help: "Delete Note and Conversation History…",
                             enabled: store.canDeleteNote(note), action: actions.delete)
            }
        }.padding(.horizontal, 14).frame(height: 46)
            .background { titleDragHandle(expanded: true, onClick: {}) }
    }

    private func headerButton(_ symbol: String, label: String, help: String, enabled: Bool = true,
                              action: @escaping () -> Void) -> some View {
        NoteHeaderButton(symbol: symbol, label: label, help: help, enabled: enabled, action: action,
                         canDelete: store.canDeleteNote(note), onHide: actions.hide, onDelete: actions.delete,
                         onMenuInteraction: { actions.interaction("titleMenu", $0) })
            .frame(width: 28, height: 28)
    }

    private func titleDragHandle(expanded: Bool, onClick: @escaping () -> Void) -> some View {
        WindowDragHandle(active: note.isVisible && note.isExpanded == expanded,
                         onClick: onClick, canDelete: store.canDeleteNote(note), onHide: actions.hide,
                         onResetSize: expanded ? nil : actions.resetSize, onDelete: actions.delete,
                         onMenuInteraction: { actions.interaction("titleMenu", $0) })
    }

    private func titleView(expanded: Bool) -> some View {
        NoteTitleView(title: note.title, fontSize: expanded ? 14 : 13, weight: expanded ? .semibold : .medium,
                      active: note.isVisible && note.isExpanded == expanded,
                      compactFrame: expanded ? compactFrame : nil,
                      onSingleClick: { if expanded { actions.collapse() } else { actions.expand() } },
                      onCommit: { if !note.isDeleting && !note.deletionPending { note.title = $0; store.persist() } },
                      onEditing: { actions.interaction("titleEditing", $0) },
                      onSingleClickPreservingHeader: expanded ? actions.collapseTitle : nil,
                      canRename: !note.isDeleting && !note.deletionPending,
                      canDelete: store.canDeleteNote(note), onHide: actions.hide,
                      onResetSize: expanded ? nil : actions.resetSize, onDelete: actions.delete,
                      onMenuInteraction: { actions.interaction("titleMenu", $0) })
            .help(expanded ? "Drag to move; click to collapse; double-click to rename" : "Drag to move; click to expand; double-click to rename")
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if note.messages.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Make room for an idea.")
                                .font(.title3.weight(.medium)).foregroundStyle(.primary)
                            Text(store.keepNotesExpanded
                                 ? "Type a message, or add images and files.\nClick the title or press Esc to collapse this note."
                                 : "Type a message, or add images and files.\nClick elsewhere to collapse this note.")
                                .font(.callout).foregroundStyle(.secondary).lineSpacing(4)
                        }.padding(.top, 18).padding(.bottom, 12)
                    }
                    ForEach(note.messages) { message in
                        MessageView(message: message, assistantName: note.provider.displayName,
                                    onLayoutChange: {
                            // WebKit reports its height after the streaming text changes.
                            // Preserve the current reading intent across that layout pass.
                            if followsLatest, !isResizingComposer {
                                DispatchQueue.main.async {
                                    proxy.scrollTo("transcript-bottom", anchor: .bottom)
                                }
                            }
                        }).equatable()
                    }
                    if note.isBusy {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(note.isStopping ? "Stopping…" : "\(note.provider.displayName) is replying…")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 2)
                    }
                    conversationNotices
                    Color.clear.frame(height: 1).id("transcript-bottom")
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(key: TranscriptBottomPreference.self,
                                                       value: geometry.frame(in: .named("transcript")).maxY)
                            }
                        }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            .coordinateSpace(name: "transcript")
            .background {
                GeometryReader { geometry in
                    Color.clear.onAppear { transcriptHeight = geometry.size.height }
                        .onChange(of: geometry.size.height) { transcriptHeight = $0 }
                }
            }
            .onPreferenceChange(TranscriptBottomPreference.self) { bottom in
                if !isResizingComposer, transcriptHeight > 0 {
                    // LazyVStack removes the bottom marker while reading older
                    // messages. A missing marker must not retain follow mode.
                    followsLatest = bottom.map { $0 <= transcriptHeight + 50 && $0 >= 0 } ?? false
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !followsLatest {
                    Button {
                        followsLatest = true
                        proxy.scrollTo("transcript-bottom", anchor: .bottom)
                    } label: { Label("Latest", systemImage: "arrow.down") }
                        .buttonStyle(.bordered).controlSize(.small).padding(10)
                }
            }
            .onAppear { proxy.scrollTo("transcript-bottom", anchor: .bottom) }
            .onChange(of: transcriptHeight) { _ in
                if followsLatest { proxy.scrollTo("transcript-bottom", anchor: .bottom) }
            }
            .onChange(of: note.messages) { _ in
                if followsLatest { proxy.scrollTo("transcript-bottom", anchor: .bottom) }
            }
            .onChange(of: note.isBusy) { _ in
                if followsLatest { proxy.scrollTo("transcript-bottom", anchor: .bottom) }
            }
        }
    }

    private func composer(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !note.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(note.attachments) { attachment in
                            AttachmentThumbnail(attachment: attachment) { store.removeAttachment(attachment, from: note) }
                        }
                    }.padding(.top, 4).padding(.trailing, 4)
                }.frame(height: 65)
            }
            ZStack(alignment: .topLeading) {
                if note.draft.isEmpty {
                    Text("Message…").font(.system(size: 14)).foregroundStyle(.tertiary)
                        .padding(.leading, 13).padding(.top, 9).allowsHitTesting(false)
                }
                ComposerView(text: $note.draft, focusRequest: note.focusRequest,
                             onSend: sendDraft, onEscape: actions.collapse,
                             onImage: { store.attachImage($0, to: note) },
                             onFiles: { store.attachFiles($0, to: note) },
                             onComposition: { active in
                                 if isComposing != active { isComposing = active }
                                 actions.interaction("composition", active)
                             },
                             canFocus: { note.isVisible && note.isExpanded && !note.isHeaderOnly && !note.isDeleting && !note.deletionPending },
                             onImageData: { store.attachImageData($0, to: note) })
            }
            .frame(height: height).background(Color.primary.opacity(0.035))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            HStack(spacing: 6) {
                Button(action: chooseFiles) { Image(systemName: "paperclip") }
                    .buttonStyle(.plain).font(.system(size: 16)).help("Add Files…").accessibilityLabel("Add Files")
                    .disabled(note.isImportingFiles)
                    .frame(width: 22, height: 24)
                Button {
                    if !showsFiles { actions.interaction("noteFiles", true) }
                    showsFiles.toggle()
                } label: { Image(systemName: "folder") }
                    .buttonStyle(.plain).font(.system(size: 15)).help("Note Files").accessibilityLabel("Note Files")
                    .frame(width: 24, height: 24)
                    .popover(isPresented: $showsFiles, arrowEdge: .bottom) {
                        NoteFilesView(note: note, store: store, onClose: { showsFiles = false })
                    }
                if note.isImportingFiles { ProgressView().controlSize(.mini).help("Adding files…") }
                NativePopup(options: store.availableModels(for: note).map { .init(id: $0.id, title: $0.displayName) },
                            selection: note.modelSelectionID, unavailableTitle: note.model,
                            enabled: !note.isBusy && !note.isDeleting && !note.deletionPending && store.hasConnectedProvider, borderless: true,
                            accessibilityLabel: "Model", onSelect: { store.selectModel($0, for: note) },
                            onInteraction: { actions.interaction("modelMenu", $0) })
                    .frame(height: 24)
                    .help("Model: \(selectedModel?.displayName ?? note.model)")
                NativePopup(options: selectedModel?.supportedReasoningEfforts.map { .init(id: $0.reasoningEffort, title: $0.reasoningEffort.capitalized) } ?? [],
                            selection: note.effort, enabled: !note.isBusy && !note.isDeleting && !note.deletionPending && store.isReady(for: note), borderless: true,
                            accessibilityLabel: "Effort", onSelect: { store.selectEffort($0, for: note) },
                            onInteraction: { actions.interaction("effortMenu", $0) })
                    .frame(height: 24).layoutPriority(1).help("Effort: \(note.effort.capitalized)")
                if !store.isReady(for: note) {
                    Image(systemName: "wifi.slash").font(.system(size: 11)).foregroundStyle(.secondary)
                        .help(store.connectionStatus(for: note)).accessibilityLabel(store.connectionStatus(for: note))
                }
                Spacer(minLength: 0)
                if note.isBusy {
                    Button { store.stop(note) } label: {
                        Image(systemName: "stop.fill").font(.system(size: 11)).frame(width: 15, height: 18)
                    }.controlSize(.small).disabled(note.isStopping)
                        .help("Stop Generating").accessibilityLabel("Stop Generating")
                } else {
                    Button(action: sendDraft) { Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .semibold)).frame(width: 15, height: 18) }
                        .buttonStyle(.borderedProminent).controlSize(.small).disabled(!canSend)
                        .help("Send (Enter); Shift + Enter for a new line").accessibilityLabel("Send")
                }
            }.padding(.horizontal, 2)
        }.padding(12).disabled(note.isDeleting || note.deletionPending)
    }

    private func sendDraft() {
        guard canSend else { return }
        followsLatest = true
        store.send(note)
    }

    private func chooseFiles() {
        actions.interaction("imagePicker", true)
        let panel = NSOpenPanel()
        panel.title = "Add Files"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK { store.attachFiles(panel.urls, to: note) }
            actions.interaction("imagePicker", false)
            note.focusRequest = UUID()
        }
        if let owner = NSApp.keyWindow { panel.beginSheetModal(for: owner, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }

    private func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !note.isDeleting, !note.deletionPending else { return false }
        let accepted = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) ||
            $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) || $0.canLoadObject(ofClass: NSImage.self)
        }
        guard !accepted.isEmpty else { return false }
        actions.expand()
        for provider in accepted {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url: URL?
                    if let value = item as? URL { url = value }
                    else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                    else { url = nil }
                    if let url { DispatchQueue.main.async { store.attachFiles([url], to: note) } }
                }
            } else {
                AttachmentImageCodec.importedData(from: provider) { data, failure in
                    DispatchQueue.main.async {
                        if let data { store.attachImageData(data, to: note) }
                        else if !note.isDeleting, !note.deletionPending { note.error = failure ?? "This image could not be read." }
                    }
                }
            }
        }
        return true
    }
}

private struct TranscriptBottomPreference: PreferenceKey {
    static var defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { value = nextValue() ?? value }
}

/// A native button owns its entire 28-point box, including clear space around
/// the symbol. Background dragging must never consume these action clicks.
struct NoteHeaderButton: NSViewRepresentable {
    var symbol: String
    var label: String
    var help: String
    var enabled: Bool
    var action: () -> Void
    var canDelete: Bool
    var onHide: () -> Void
    var onDelete: () -> Void
    var onMenuInteraction: (Bool) -> Void

    func makeNSView(context: Context) -> Button {
        let button = Button()
        button.isBordered = false
        button.setButtonType(.momentaryPushIn)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.focusRingType = .none
        button.target = button
        button.action = #selector(Button.clicked(_:))
        configure(button)
        return button
    }

    func updateNSView(_ button: Button, context: Context) { configure(button) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Button, context: Context) -> NSSize? {
        NSSize(width: 28, height: 28)
    }

    @MainActor private func configure(_ button: Button) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = help
        button.setAccessibilityLabel(label)
        button.isEnabled = enabled
        button.onClick = action
        button.titleContextMenu.canDelete = canDelete
        button.titleContextMenu.onHide = onHide
        button.titleContextMenu.onDelete = onDelete
        button.titleContextMenu.onInteraction = onMenuInteraction
    }

    final class Button: NSButton {
        var onClick: (() -> Void)?
        let titleContextMenu = NoteTitleContextMenu()
        override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 28) }
        override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }
        override var mouseDownCanMoveWindow: Bool { false }
        override var needsPanelToBecomeKey: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        @objc func clicked(_ sender: Any?) { if isEnabled { onClick?() } }
        override func rightMouseDown(with event: NSEvent) { titleContextMenu.popUp(with: event, for: self) }
        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { rightMouseDown(with: event) }
            else { super.mouseDown(with: event) }
        }
    }
}

/// Covers header gaps and decorations without intercepting foreground title fields or buttons.
private struct WindowDragHandle: NSViewRepresentable {
    var active: Bool
    var onClick: () -> Void
    var canDelete: Bool
    var onHide: () -> Void
    var onResetSize: (() -> Void)? = nil
    var onDelete: () -> Void
    var onMenuInteraction: (Bool) -> Void
    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.toolTip = "Drag Note"
        view.active = active
        view.onClick = onClick
        configureMenu(view)
        return view
    }
    func updateNSView(_ nsView: DragView, context: Context) {
        nsView.active = active
        nsView.onClick = onClick
        configureMenu(nsView)
    }

    @MainActor private func configureMenu(_ view: DragView) {
        view.titleContextMenu.canDelete = canDelete
        view.titleContextMenu.onHide = onHide
        view.titleContextMenu.onResetSize = onResetSize
        view.titleContextMenu.onDelete = onDelete
        view.titleContextMenu.onInteraction = onMenuInteraction
    }

    final class DragView: NSView {
        var active = true {
            didSet {
                if !active { downEvent = nil; dragged = false }
            }
        }
        var onClick: () -> Void = {}
        let titleContextMenu = NoteTitleContextMenu()
        private var downEvent: NSEvent?
        private var dragged = false
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { active ? super.hitTest(point) : nil }
        // Keep normal hover cursors, including the title field's I-beam while editing.
        // A background or inactive header must not install a cursor over foreground views.
        override func mouseDown(with event: NSEvent) {
            guard active else { return }
            if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
            downEvent = event
            dragged = false
        }
        override func rightMouseDown(with event: NSEvent) {
            guard active else { return }
            downEvent = nil
            dragged = false
            titleContextMenu.popUp(with: event, for: self)
        }
        override func mouseDragged(with event: NSEvent) {
            guard active, !dragged, let downEvent else { return }
            let delta = hypot(event.locationInWindow.x - downEvent.locationInWindow.x,
                              event.locationInWindow.y - downEvent.locationInWindow.y)
            if delta >= 3 {
                guard let window else { return }
                dragged = true
                NSCursor.closedHand.push()
                defer { NSCursor.pop() }
                window.performDrag(with: downEvent)
            }
        }
        override func mouseUp(with event: NSEvent) {
            if active, !dragged, downEvent != nil { onClick() }
            downEvent = nil
        }
    }
}

private struct AttachmentThumbnail: View {
    let attachment: Attachment
    var remove: () -> Void
    var body: some View {
        ZStack(alignment: .topTrailing) {
            if attachment.isImage, let image = NSImage(contentsOfFile: attachment.path) {
                Image(nsImage: image).resizable().scaledToFill().frame(width: 64, height: 56)
                    .clipped().clipShape(RoundedRectangle(cornerRadius: 6)).help(attachment.name)
            } else { FileAttachmentLabel(attachment: attachment).frame(width: 168, height: 56) }
            Button(action: remove) { Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette).foregroundStyle(.white, Color.black.opacity(0.7)) }
                .buttonStyle(.plain).offset(x: 4, y: -3).help("Remove \(attachment.name)")
        }.frame(width: attachment.isImage ? 64 : 168, height: 56)
    }
}

private struct MessageView: View, Equatable {
    let message: ChatMessage
    let assistantName: String
    var onLayoutChange: () -> Void = {}

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message && lhs.assistantName == rhs.assistantName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message.role == "user" ? "👤" : assistantName)
                .font(.system(size: message.role == "user" ? 14 : 11, weight: .semibold)).foregroundStyle(.secondary)
                .accessibilityLabel(message.role == "user" ? "You" : assistantName)
            if !message.imagePaths.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Array(message.imagePaths.enumerated()), id: \.offset) { _, path in
                            if let image = NSImage(contentsOfFile: path) {
                                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 210, maxHeight: 150)
                                    .clipShape(RoundedRectangle(cornerRadius: 7))
                            }
                        }
                    }
                }
            }
            if !message.fileAttachments.isEmpty {
                ForEach(message.fileAttachments) { file in
                    FileAttachmentLabel(attachment: file).frame(maxWidth: 280, alignment: .leading)
                }
            }
            if !message.text.isEmpty {
                if MathMessageView.shouldRender(message.text) {
                    MathMessageView(text: message.text, onLayoutChange: onLayoutChange)
                } else {
                    MarkdownMessage(text: message.text)
                }
            }
        }
        .padding(message.role == "user" ? 12 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(message.role == "user" ? Color.accentColor.opacity(0.07) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct MarkdownMessage: View {
    let text: String

    private var segments: [Segment] {
        var result: [Segment] = []
        var buffer: [String] = []
        var inCode = false
        var language = ""
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if !buffer.isEmpty {
                    result.append(Segment(code: inCode, language: language, text: buffer.joined(separator: "\n")))
                    buffer.removeAll()
                }
                if !inCode { language = String(line.trimmingCharacters(in: .whitespaces).dropFirst(3)) }
                inCode.toggle()
            } else { buffer.append(line) }
        }
        if !buffer.isEmpty { result.append(Segment(code: inCode, language: language, text: buffer.joined(separator: "\n"))) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                if segment.code {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(segment.language.isEmpty ? "Code" : segment.language).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(segment.text, forType: .string)
                            } label: { Label("Copy", systemImage: "doc.on.doc") }
                                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                        }
                        ScrollView(.horizontal) {
                            Text(segment.text).font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled).fixedSize(horizontal: true, vertical: false)
                        }
                    }.padding(10).background(Color.primary.opacity(0.055)).clipShape(RoundedRectangle(cornerRadius: 7))
                } else {
                    MarkdownProse(text: segment.text)
                }
            }
        }
    }

    private struct Segment {
        var code: Bool
        var language: String
        var text: String
    }
}

private struct MarkdownProse: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.parse(text).enumerated()), id: \.offset) { _, block in
                switch block.kind {
                case .paragraph:
                    inline(block.text)
                case .heading(let level):
                    inline(block.text)
                        .font(.system(size: level == 1 ? 21 : level == 2 ? 18 : level == 3 ? 16 : 14, weight: .semibold))
                        .padding(.top, 3)
                case .list(let marker, let indentation):
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(marker).foregroundStyle(.secondary).frame(minWidth: 14, alignment: .trailing)
                        inline(block.text).frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.leading, CGFloat(min(indentation, 16)) * 4)
                case .quote:
                    inline(block.text)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 12).padding(.vertical, 3)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1).fill(Color.accentColor.opacity(0.5)).frame(width: 3)
                        }
                }
            }
        }
        .font(.system(size: 14)).lineSpacing(4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ value: String) -> some View {
        Text((try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value))
            .textSelection(.enabled)
    }

    private struct Block {
        enum Kind {
            case paragraph
            case heading(Int)
            case list(marker: String, indentation: Int)
            case quote
        }
        var kind: Kind
        var text: String
    }

    private static func parse(_ text: String) -> [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        var listCanContinue = false
        var quoteCanContinue = false
        func flushParagraph() {
            if !paragraph.isEmpty {
                result.append(Block(kind: .paragraph, text: paragraph.joined(separator: "\n")))
                paragraph.removeAll()
            }
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indentation = line.prefix(while: { $0 == " " || $0 == "\t" }).count
            if trimmed.isEmpty {
                flushParagraph()
                listCanContinue = false
                quoteCanContinue = false
                continue
            }
            let headingLevel = trimmed.prefix(while: { $0 == "#" }).count
            if (1...6).contains(headingLevel), trimmed.dropFirst(headingLevel).first == " " {
                flushParagraph()
                result.append(Block(kind: .heading(headingLevel), text: String(trimmed.dropFirst(headingLevel)).trimmingCharacters(in: .whitespaces)))
                listCanContinue = false
                quoteCanContinue = false
            } else if ["- ", "* ", "+ "].contains(where: trimmed.hasPrefix) {
                flushParagraph()
                result.append(Block(kind: .list(marker: "•", indentation: indentation), text: String(trimmed.dropFirst(2))))
                listCanContinue = true
                quoteCanContinue = false
            } else if let range = trimmed.range(of: #"^[0-9]+[.)]\s+"#, options: .regularExpression) {
                flushParagraph()
                let marker = String(trimmed[range]).trimmingCharacters(in: .whitespaces)
                result.append(Block(kind: .list(marker: marker, indentation: indentation), text: String(trimmed[range.upperBound...])))
                listCanContinue = true
                quoteCanContinue = false
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                let quote = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                if quoteCanContinue, !result.isEmpty { result[result.count - 1].text += "\n" + quote }
                else { result.append(Block(kind: .quote, text: quote)) }
                quoteCanContinue = true
                listCanContinue = false
            } else if listCanContinue, indentation > 0, !result.isEmpty {
                result[result.count - 1].text += "\n" + trimmed
            } else {
                paragraph.append(line)
                listCanContinue = false
                quoteCanContinue = false
            }
        }
        flushParagraph()
        return result
    }
}
