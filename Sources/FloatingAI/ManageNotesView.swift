import SwiftUI

@MainActor struct ManageNotesView: View {
    @ObservedObject var store: AppStore
    let onShow: (NoteState) -> Void
    let onHide: (NoteState) -> Void
    @State private var selectedIDs: Set<UUID>
    @State private var search = ""

    init(store: AppStore, selectedIDs: Set<UUID> = [],
         onShow: @escaping (NoteState) -> Void, onHide: @escaping (NoteState) -> Void) {
        self.store = store
        self.onShow = onShow
        self.onHide = onHide
        _selectedIDs = State(initialValue: selectedIDs)
    }

    private var selectedNotes: [NoteState] { store.notes.filter { selectedIDs.contains($0.id) } }
    private var filteredNotes: [NoteState] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.notes }
        return store.notes.filter {
            [$0.title, $0.provider.displayName, store.model(for: $0)?.displayName ?? $0.model]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }
    private var deletionReason: String? { store.deletionUnavailableReason(for: selectedNotes) }
    private var canDeleteSelection: Bool {
        !selectedNotes.isEmpty && !store.isDeletingNotes && deletionReason == nil &&
            selectedNotes.allSatisfy { store.canDeleteNote($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("Search notes", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search notes")
                Button("Select All") { selectedIDs.formUnion(filteredNotes.map(\.id)) }
                    .disabled(filteredNotes.isEmpty || store.isDeletingNotes)
                Button("Deselect All") { selectedIDs.removeAll() }
                    .disabled(selectedIDs.isEmpty || store.isDeletingNotes)
            }
            .padding(16)

            Divider()
            if store.notes.isEmpty {
                emptyList(title: "No notes", detail: "Create a note from the menu bar to get started.")
            } else if filteredNotes.isEmpty {
                emptyList(title: "No matching notes", detail: "Try a different search.")
            } else {
                List {
                    ForEach(filteredNotes) { note in
                        ManageNoteRow(note: note, store: store, isSelected: Binding(
                            get: { selectedIDs.contains(note.id) },
                            set: { selected in
                                if selected { selectedIDs.insert(note.id) }
                                else { selectedIDs.remove(note.id) }
                            }))
                    }
                }
                .listStyle(.inset)
            }
            Divider()

            VStack(alignment: .leading, spacing: 10) {
                if let summary = store.noteDeletionSummary {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(summary)
                }
                if let reason = deletionReason, !selectedNotes.isEmpty {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    Text("\(selectedNotes.count) selected")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Show") { for note in selectedNotes { onShow(note) } }
                        .disabled(selectedNotes.isEmpty || store.isDeletingNotes)
                        .help("Show the selected notes")
                    Button("Hide") { for note in selectedNotes { onHide(note) } }
                        .disabled(selectedNotes.isEmpty || store.isDeletingNotes)
                        .help("Hide the selected notes and keep their conversations")
                    Button("Delete Selected…", role: .destructive) { store.requestDeleteNotes(selectedNotes) }
                        .disabled(!canDeleteSelection)
                        .help("Permanently delete the selected notes and their local conversation histories")
                }
            }
            .padding(16)
        }
        .frame(minWidth: 560, minHeight: 360)
        .onChange(of: store.notes.map(\.id)) { ids in selectedIDs.formIntersection(ids) }
    }

    private func emptyList(title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "note.text").font(.title).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

@MainActor private struct ManageNoteRow: View {
    @ObservedObject var note: NoteState
    @ObservedObject var store: AppStore
    @Binding var isSelected: Bool

    private var title: String { note.title.isEmpty ? "Ask Me Anything" : note.title }
    private var state: String? {
        if note.isDeleting { return "Deleting…" }
        if note.deletionPending { return "Deletion incomplete" }
        if note.isBusy { return "Generating…" }
        if note.error != nil { return "Needs attention" }
        return nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("Select \(title)", isOn: $isSelected)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("Select \(title)")
                .disabled(store.isDeletingNotes || note.isDeleting)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fontWeight(.medium).lineLimit(1)
                Text("\(note.provider.displayName) · \(store.model(for: note)?.displayName ?? note.model)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let error = note.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 6) {
                Label(note.isVisible ? "Visible" : "Hidden", systemImage: note.isVisible ? "eye" : "eye.slash")
                    .foregroundStyle(.secondary)
                if let state {
                    HStack(spacing: 5) {
                        if note.isBusy || note.isDeleting { ProgressView().controlSize(.mini) }
                        Text(state)
                    }
                    .foregroundStyle(note.deletionPending || note.error != nil ? Color.orange : Color.secondary)
                }
            }
            .font(.caption)
            .frame(minWidth: 88, alignment: .trailing)
        }
        .padding(.vertical, 7)
    }
}
