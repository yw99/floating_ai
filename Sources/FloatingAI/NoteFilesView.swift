import AppKit
import SwiftUI
import FloatingAICore

struct FileAttachmentLabel: View {
    let attachment: Attachment
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: attachment.isImage ? "photo" : "doc.text").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(attachment.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    .help(attachment.name)
                if let bytes = attachment.byteCount {
                    Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(9).background(Color.primary.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius: 7))
            .accessibilityElement(children: .combine)
    }
}

@MainActor struct NoteFilesView: View {
    @ObservedObject var note: NoteState
    @ObservedObject var store: AppStore
    let onClose: () -> Void
    @State private var search = ""
    @State private var selected: Set<UUID> = []
    private var files: [Attachment] {
        store.files(for: note).filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Note Files").font(.headline)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(.plain).help("Close")
            }
            TextField("Search files", text: $search).textFieldStyle(.roundedBorder)
            if files.isEmpty {
                Text(search.isEmpty ? "Files added to this note will appear here." : "No matching files.")
                    .foregroundStyle(.secondary).font(.callout).frame(maxWidth: .infinity, minHeight: 100)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(files) { file in
                            let inDraft = note.attachments.contains { $0.id == file.id }
                            let exists = FileManager.default.fileExists(atPath: file.path)
                            Button {
                                if selected.contains(file.id) { selected.remove(file.id) } else { selected.insert(file.id) }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: inDraft || selected.contains(file.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(inDraft ? Color.secondary : Color.accentColor)
                                    if file.isImage, let image = NSImage(contentsOfFile: file.path) {
                                        Image(nsImage: image).resizable().scaledToFill().frame(width: 38, height: 38).clipped()
                                            .clipShape(RoundedRectangle(cornerRadius: 5))
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(file.name).lineLimit(1).truncationMode(.middle).help(file.name)
                                        if !exists { Text("File missing").font(.caption).foregroundStyle(.orange) }
                                        else if inDraft { Text("In current message").font(.caption).foregroundStyle(.secondary) }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.padding(6).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(inDraft || !exists)
                        }
                    }
                }.frame(maxHeight: 280)
            }
            HStack {
                Text("Only files from this note").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Add to Message") {
                    store.referenceFiles(selected, in: note)
                    onClose()
                }.disabled(selected.isEmpty || note.isDeleting || note.deletionPending)
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(16).frame(width: 350)
    }
}
