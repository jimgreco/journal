import SwiftUI

struct EntryListView: View {
    @Environment(Session.self) private var session
    @Environment(EntryStore.self) private var store
    @Environment(AppLock.self) private var lock
    @State private var search = ""
    @State private var editing: Entry?
    @State private var composing: ComposeMode?
    @State private var showingSettings = false

    enum ComposeMode: Identifiable {
        case text, voice
        var id: Self { self }
    }

    var body: some View {
        NavigationStack {
            List {
                if let error = store.syncError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                let days = store.days(matching: search)
                if days.isEmpty {
                    ContentUnavailableView(
                        search.isEmpty ? "No entries yet" : "No matches",
                        systemImage: search.isEmpty ? "square.and.pencil" : "magnifyingglass",
                        description: Text(search.isEmpty ? "Write or speak your first thought." : "Try a different word or tag.")
                    )
                    .listRowBackground(Color.clear)
                }
                ForEach(days, id: \.day) { group in
                    Section(DayKey.title(for: group.day)) {
                        ForEach(group.entries) { entry in
                            Button { editing = entry } label: { EntryRow(entry: entry) }
                                .buttonStyle(.plain)
                                .swipeActions {
                                    Button("Delete", systemImage: "trash", role: .destructive) {
                                        store.delete(entry.id)
                                        syncSoon()
                                    }
                                }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $search, prompt: "Search entries and tags")
            .refreshable { await store.sync(with: SessionRemote(session: session)) }
            .navigationTitle("Journal")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingSettings = true } label: { Image(systemName: "person.crop.circle") }
                        .accessibilityLabel("Account")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if store.pendingCount > 0 {
                        Image(systemName: "icloud.and.arrow.up")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("\(store.pendingCount) entries waiting to sync")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button { composing = .text } label: {
                        Label("Write", systemImage: "square.and.pencil").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button { composing = .voice } label: {
                        Label("Speak", systemImage: "mic.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
            .sheet(item: $composing) { mode in
                ComposeView(entry: nil, startRecording: mode == .voice) { syncSoon() }
            }
            .sheet(item: $editing) { entry in
                ComposeView(entry: entry, startRecording: false) { syncSoon() }
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            // Fetch the better speech model before the first voice entry needs it.
            .task { SpeechModel.shared.prepare() }
            .onChange(of: CaptureRequest.shared.pending, initial: true) { _, _ in openPendingCapture() }
            .onChange(of: lock.isLocked) { _, _ in openPendingCapture() }
        }
    }

    /// Starts the entry asked for by the Action Button, Siri, a shortcut or the reminder.
    private func openPendingCapture() {
        // This list sits under the lock shield, so wait for Face ID first.
        guard !lock.isLocked, let kind = CaptureRequest.shared.take() else { return }
        // Already writing: keep that entry rather than replacing it.
        guard composing == nil, editing == nil else { return }
        showingSettings = false
        composing = kind == .voice ? .voice : .text
    }

    private func syncSoon() {
        Task { await store.sync(with: SessionRemote(session: session)) }
    }
}

struct EntryRow: View {
    let entry: Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(entry.createdAt, format: .dateTime.hour().minute())
                if entry.source == .voice { Image(systemName: "waveform") }
                if let mood = entry.mood.flatMap(Mood.init(rawValue:)) { Image(systemName: mood.symbol) }
                if entry.isPrivate {
                    Label("Private", systemImage: "eye.slash").labelStyle(.titleAndIcon)
                }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(entry.text)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !entry.tags.isEmpty {
                Text(entry.tags.map { "#\($0)" }.joined(separator: " "))
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
