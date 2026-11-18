import Foundation
import Observation

struct ChangesPage: Decodable {
    let entries: [Entry]
    let revision: Int
    let more: Bool
}

/// What the store needs from the server. `SessionRemote` is the real one; tests use a fake.
@MainActor
protocol EntryRemote {
    func put(_ entry: Entry) async throws -> Entry
    func delete(_ id: UUID) async throws -> Entry
    func changes(after revision: Int) async throws -> ChangesPage
}

@MainActor
struct SessionRemote: EntryRemote {
    let session: Session

    func put(_ entry: Entry) async throws -> Entry {
        try await session.request("PUT", "/api/entries/\(entry.id.uuidString.lowercased())", body: entry.uploadBody)
    }

    func delete(_ id: UUID) async throws -> Entry {
        try await session.request("DELETE", "/api/entries/\(id.uuidString.lowercased())")
    }

    func changes(after revision: Int) async throws -> ChangesPage {
        try await session.request("GET", "/api/entries?after=\(revision)")
    }
}

/// Entries on this iPhone, plus an outbox of changes not yet on the server.
///
/// The file is written with complete file protection (unreadable while the
/// phone is locked) and excluded from iCloud/iTunes backups.
@MainActor
@Observable
final class EntryStore {
    struct State: Codable {
        var entries: [UUID: Entry] = [:]
        var pending: [UUID: Pending] = [:]
        var revision = 0
    }

    enum Pending: Codable, Equatable {
        case upsert(Date)
        case delete
    }

    private(set) var state = State()
    private(set) var isSyncing = false
    var syncError: String?

    private let fileURL: URL
    private var syncAgain = false

    /// Called after every local save or delete (Apple Health mirroring).
    var onLocalChange: ((Entry) -> Void)?

    init(fileURL: URL = EntryStore.defaultFileURL) {
        self.fileURL = fileURL
        load()
    }

    nonisolated static var defaultFileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("journal-state.json")
    }

    // MARK: Reading

    /// Live entries, newest day first, newest entry first within a day.
    var visibleEntries: [Entry] {
        state.entries.values
            .filter { !$0.deleted }
            .sorted { ($0.entryDate, $0.createdAt) > ($1.entryDate, $1.createdAt) }
    }

    func days(matching query: String = "") -> [(day: String, entries: [Entry])] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = q.isEmpty ? visibleEntries : visibleEntries.filter {
            $0.text.lowercased().contains(q) || $0.tags.contains { $0.lowercased().contains(q) }
        }
        var order: [String] = []
        var groups: [String: [Entry]] = [:]
        for entry in filtered {
            if groups[entry.entryDate] == nil { order.append(entry.entryDate) }
            groups[entry.entryDate, default: []].append(entry)
        }
        return order.map { ($0, groups[$0]!) }
    }

    var pendingCount: Int { state.pending.count }

    // MARK: Writing

    func save(_ entry: Entry, now: Date = Date()) {
        var entry = entry
        entry.text = String(entry.text.prefix(Entry.maxTextLength))
        entry.updatedAt = now
        entry.deleted = false
        state.entries[entry.id] = entry
        state.pending[entry.id] = .upsert(now)
        persist()
        onLocalChange?(entry)
    }

    func delete(_ id: UUID) {
        guard var entry = state.entries[id] else { return }
        entry.deleted = true
        entry.text = ""
        entry.tags = []
        entry.mood = nil
        state.entries[id] = entry
        state.pending[id] = .delete
        persist()
        onLocalChange?(entry)
    }

    /// Wipes everything on this device (sign out, account deletion).
    func reset() {
        state = State()
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: Sync

    func sync(with remote: EntryRemote) async {
        if isSyncing {
            syncAgain = true
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            syncAgain = false
            do {
                try await push(remote)
                try await pull(remote)
                syncError = nil
            } catch APIError.offline {
                syncError = nil // offline is normal; the outbox waits
                return
            } catch {
                syncError = error.localizedDescription
                return
            }
        } while syncAgain
    }

    private func push(_ remote: EntryRemote) async throws {
        for (id, op) in state.pending {
            switch op {
            case .upsert(let stamp):
                guard let entry = state.entries[id] else {
                    state.pending[id] = nil
                    continue
                }
                let stored = try await remote.put(entry)
                // Only clear the outbox if nothing changed locally while the request was in flight.
                if state.pending[id] == .upsert(stamp) {
                    state.pending[id] = nil
                    if stored.deleted {
                        state.entries[id] = stored // deleted elsewhere: deletion wins
                    } else {
                        state.entries[id]?.revision = stored.revision
                    }
                }
            case .delete:
                _ = try await remote.delete(id)
                if state.pending[id] == .delete {
                    state.pending[id] = nil
                    state.entries[id] = nil
                }
            }
            persist()
        }
    }

    private func pull(_ remote: EntryRemote) async throws {
        var more = true
        while more {
            let page = try await remote.changes(after: state.revision)
            for incoming in page.entries where state.pending[incoming.id] == nil {
                state.entries[incoming.id] = incoming.deleted ? nil : incoming
            }
            state.revision = max(state.revision, page.revision)
            more = page.more && !page.entries.isEmpty
            persist()
        }
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONCoding.decoder.decode(State.self, from: data) else { return }
        state = decoded
    }

    private func persist() {
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONCoding.encoder.encode(state)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
            var url = fileURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch {
            syncError = "Couldn't save on this iPhone: \(error.localizedDescription)"
        }
    }
}
