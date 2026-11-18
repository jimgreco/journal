import SwiftUI

struct ComposeView: View {
    @Environment(EntryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

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
                        if text.isEmpty && !dictation.isRecording {
                            Text("What's on your mind?")
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                        }
                        TextEditor(text: $text)
                            .frame(minHeight: 220)
                            .focused($editorFocused)
                            .disabled(dictation.isRecording)
                    }
                    dictationControls
                }

                Section {
                    DatePicker("Day", selection: $day, in: ...Date(), displayedComponents: .date)
                    Picker("Mood", selection: $mood) {
                        Text("None").tag(Int?.none)
                        ForEach(Mood.allCases) { m in
                            Label(m.label, systemImage: m.symbol).tag(Int?.some(m.rawValue))
                        }
                    }
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
                    Button("Save", action: save).disabled(trimmed.isEmpty || dictation.isRecording)
                }
            }
            .confirmationDialog("Discard this entry?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { close() }
            }
            .interactiveDismissDisabled(hasChanges || dictation.isRecording)
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
            // Leaving the app stops listening; the entry stays open with its text.
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { dictation.stop() }
            }
        }
    }

    @ViewBuilder private var dictationControls: some View {
        HStack {
            if dictation.isRecording {
                Button {
                    dictation.stop()
                } label: {
                    Label("Stop", systemImage: "stop.circle.fill")
                }
                .tint(.red)
                ProgressView(value: Double(dictation.level))
                    .progressViewStyle(.linear)
                    .tint(.red)
                    .accessibilityLabel("Listening")
            } else {
                Button {
                    Task { await beginDictation() }
                } label: {
                    Label(text.isEmpty ? "Speak" : "Keep talking", systemImage: "mic.fill")
                }
                Spacer()
                Text("Transcribed on this iPhone").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.borderless)
        if let error = dictation.error {
            Text(error).font(.footnote).foregroundStyle(.orange)
        }
    }

    private func beginDictation() async {
        editorFocused = false
        textBeforeDictation = text
        await dictation.start()
    }

    private func save() {
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
        dictation.stop()
        dismiss()
    }
}
