import SwiftUI

struct SettingsView: View {
    @Environment(Session.self) private var session
    @Environment(EntryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var exportURL: URL?
    @State private var exporting = false
    @State private var confirmDelete = false
    @State private var message: String?
    @State private var reminder = Reminder.shared

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    LabeledContent("Signed in as", value: session.email ?? "—")
                    LabeledContent("Entries", value: "\(store.visibleEntries.count)")
                    if store.pendingCount > 0 {
                        LabeledContent("Waiting to sync", value: "\(store.pendingCount)")
                    }
                }

                Section {
                    Label("Face ID locks Journal whenever you leave it.", systemImage: "faceid")
                    Label("Voice is transcribed on this iPhone. Audio is never saved or uploaded.", systemImage: "waveform")
                    Label("Entries are encrypted on the server. Private entries never leave it.", systemImage: "lock.shield")
                } header: {
                    Text("Privacy")
                }
                .font(.footnote)

                Section {
                    Toggle("Daily reminder", isOn: Binding(
                        get: { reminder.isOn },
                        set: { on in
                            if on { Task { await reminder.turnOn() } } else { reminder.turnOff() }
                        }
                    ))
                    if reminder.isOn {
                        DatePicker("Time", selection: Binding(
                            get: { reminder.time },
                            set: { date in Task { await reminder.setTime(date) } }
                        ), displayedComponents: .hourAndMinute)
                    }
                    if let note = reminder.message {
                        Text(note).font(.footnote).foregroundStyle(.orange)
                    }
                } header: {
                    Text("Reminder")
                } footer: {
                    Text("Tap it to start speaking an entry. The notification never shows anything you wrote. "
                         + "You can also put Speak Entry on the Action Button or ask Siri.")
                }

                Section {
                    if let exportURL {
                        ShareLink(item: exportURL) { Label("Share export", systemImage: "square.and.arrow.up") }
                    } else {
                        Button {
                            Task { await export() }
                        } label: {
                            Label(exporting ? "Preparing…" : "Export all entries", systemImage: "arrow.down.doc")
                        }
                        .disabled(exporting)
                    }
                } footer: {
                    Text("A JSON file of every entry, including private ones.")
                }

                Section {
                    Button("Sign Out") {
                        Task {
                            await session.signOut()
                            dismiss()
                        }
                    }
                    Button("Delete Account and All Entries", role: .destructive) { confirmDelete = true }
                }

                if let message {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
                if let commit = Bundle.main.object(forInfoDictionaryKey: "GitCommitHash") as? String, !commit.isEmpty {
                    Text("Build \(commit)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Delete your journal?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete Everything", role: .destructive) { Task { await deleteAccount() } }
            } message: {
                Text("Every entry is removed from the server and this iPhone. This can't be undone.")
            }
            .onDisappear { removeExport() }
        }
    }

    private func export() async {
        exporting = true
        defer { exporting = false }
        do {
            let data = try await session.data("/api/export")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("journal-export.json")
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            exportURL = url
        } catch {
            message = error.localizedDescription
        }
    }

    private func removeExport() {
        if let exportURL { try? FileManager.default.removeItem(at: exportURL) }
        exportURL = nil
    }

    private func deleteAccount() async {
        do {
            let _: EmptyResponse = try await session.request("DELETE", "/api/account")
            session.clearTokens()
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }
}
