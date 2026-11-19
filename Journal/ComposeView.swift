import SwiftUI

struct ComposeView: View {
    @Environment(EntryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppLock.self) private var lock

    let original: Entry?
    let startRecording: Bool
    let onSave: () -> Void

    @State private var text: String
    @State private var day: Date
    @State private var mood: Int?
    @State private var tagsText: String
    @State private var isPrivate: Bool
    @State private var usedVoice: Bool
    @State private var dictation = Dictation()
    @State private var textBeforeDictation = ""
    @State private var confirmDiscard = false
    @State private var resumeDictation = false
    @FocusState private var editorFocused: Bool

    init(entry: Entry?, startRecording: Bool, onSave: @escaping () -> Void) {
        original = entry
        self.startRecording = startRecording
        self.onSave = onSave
        _text = State(initialValue: entry?.text ?? "")
        _day = State(initialValue: entry.flatMap { DayKey.date(from: $0.entryDate) } ?? Date())
        _mood = State(initialValue: entry?.mood)
        _tagsText = State(initialValue: entry?.tags.joined(separator: ", ") ?? "")
        _isPrivate = State(initialValue: entry?.isPrivate ?? false)
        _usedVoice = State(initialValue: entry?.source == .voice)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasChanges: Bool {
        guard let original else { return !trimmed.isEmpty }
        return text != original.text || mood != original.mood || Tags.parse(tagsText) != original.tags
            || isPrivate != original.isPrivate || DayKey.key(for: day) != original.entryDate
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ZStack(alignment: .topLeading) {
                        if text.isEmpty && !dictation.isBusy {
                            Text("What's on your mind?")
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                        }
                        TextEditor(text: $text)
                            .frame(minHeight: 220)
                            .focused($editorFocused)
                            .disabled(dictation.isBusy)
                    }
                    dictationControls
                }

                Section {
                    DatePicker("Day", selection: $day, in: ...Date(), displayedComponents: .date)
                    moodRow
                    TextField("Tags, separated by commas", text: $tagsText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    Toggle(isOn: $isPrivate) {
                        Label("Private", systemImage: "eye.slash")
                    }
                } footer: {
                    Text(isPrivate
                         ? "Kept out of your weekly review. Only you can read it here."
                         : "Included in your Sunday weekly review, which Claude reads to find patterns.")
                }

                if let original {
                    Section {
                        Button("Delete Entry", role: .destructive) {
                            store.delete(original.id)
                            onSave()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(original == nil ? "New Entry" : "Edit Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if hasChanges { confirmDiscard = true } else { close() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(trimmed.isEmpty || dictation.isBusy)
                }
            }
            .confirmationDialog("Discard this entry?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { close() }
            }
            .interactiveDismissDisabled(hasChanges || dictation.isBusy)
            .onChange(of: dictation.transcript) { _, transcript in
                guard !transcript.isEmpty else { return }
                let separator = textBeforeDictation.isEmpty || textBeforeDictation.hasSuffix("\n") ? "" : " "
                text = textBeforeDictation + separator + transcript
                usedVoice = true
            }
            .task {
                if startRecording { await beginDictation() } else if original == nil { editorFocused = true }
            }
            .onDisappear { dictation.stop() }
            // Leaving the app pauses listening (the app locks, and audio isn't
            // recorded in the background). Once you're back and unlocked, it
            // picks up again, adding to the text so far.
            .onChange(of: scenePhase) { _, phase in
                if phase == .background, dictation.isRecording {
                    resumeDictation = true
                    dictation.stop()
                }
            }
            .onChange(of: scenePhase == .active && !lock.isLocked) { _, ready in
                guard ready, resumeDictation else { return }
                resumeDictation = false
                Task {
                    // Let the paused session's last words land in the text first.
                    try? await Task.sleep(for: .milliseconds(400))
                    await beginDictation()
                }
            }
        }
    }

    /// One tap sets the mood; tapping the selected one clears it.
    private var moodRow: some View {
        HStack(spacing: 4) {
            Text("Mood")
            Spacer()
            ForEach(Mood.allCases) { m in
                let selected = mood == m.rawValue
                Button {
                    mood = selected ? nil : m.rawValue
                } label: {
                    Image(systemName: m.symbol)
                        .frame(width: 36, height: 36)
                        .background(selected ? Color.accentColor.opacity(0.18) : Color.clear, in: Circle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .accessibilityLabel(m.label)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    @ViewBuilder private var dictationControls: some View {
        HStack {
            if dictation.isRecording {
                Button {
                    resumeDictation = false
                    dictation.stop()
                } label: {
                    Label("Stop", systemImage: "stop.circle.fill")
                }
                .tint(.red)
                ProgressView(value: Double(dictation.level))
                    .progressViewStyle(.linear)
                    .tint(.red)
                    .accessibilityLabel("Listening")
            } else if dictation.isPreparing || dictation.isFinishing {
                ProgressView()
                Text(dictation.isPreparing ? "Getting ready…" : "Finishing your last words…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                Button {
                    Task { await beginDictation() }
                } label: {
                    Label(text.isEmpty ? "Speak" : "Keep talking", systemImage: "mic.fill")
                }
                Spacer()
                Text(speechModelNote).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.borderless)
        if dictation.isRecording, dictation.isUsingOlderRecognizer {
            Text("Using the basic speech model for this entry. The better one isn't ready yet.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        if let error = dictation.error {
            Text(error).font(.footnote).foregroundStyle(.orange)
        }
    }

    private var speechModelNote: String {
        switch SpeechModel.shared.state {
        case .downloading: "Better speech model downloading…"
        case .failed: "Better speech model not downloaded yet"
        case .unsupported: "Basic speech model · on this iPhone"
        case .ready: "Better speech model · on this iPhone"
        case .unknown: "Transcribed on this iPhone"
        }
    }

    private func beginDictation() async {
        editorFocused = false
        textBeforeDictation = text
        await dictation.start()
    }

    private func save() {
        resumeDictation = false
        dictation.stop()
        let now = Date()
        let entry = Entry(
            id: original?.id ?? UUID(),
            entryDate: DayKey.key(for: day),
            createdAt: original?.createdAt ?? now,
            updatedAt: now,
            source: usedVoice ? .voice : .text,
            isPrivate: isPrivate,
            text: trimmed,
            mood: mood,
            tags: Tags.parse(tagsText),
            revision: original?.revision
        )
        store.save(entry, now: now)
        onSave()
        dismiss()
    }

    private func close() {
        resumeDictation = false
        dictation.stop()
        dismiss()
    }
}
