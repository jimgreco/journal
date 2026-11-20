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
    func uploadPhoto(_ id: UUID, entryId: UUID, data: Data) async throws
    func downloadPhoto(_ id: UUID) async throws -> Data
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

    func uploadPhoto(_ id: UUID, entryId: UUID, data: Data) async throws {
        let path = "/api/photos/\(id.uuidString.lowercased())?entry=\(entryId.uuidString.lowercased())"
        _ = try await session.upload("PUT", path, data: data, contentType: "image/jpeg")
    }

    func downloadPhoto(_ id: UUID) async throws -> Data {
        try await session.data("/api/photos/\(id.uuidString.lowercased())")
    }
}

/// Entries on this iPhone, plus an outbox of changes not yet on the server.
///
/// The file is written with complete file protection (unreadable while the
/// phone is locked) and excluded from iCloud/iTunes backups. Photos sit next
/// to it in `PhotoFiles`, with the same protection.
@MainActor
@Observable
final class EntryStore {
    struct State: Codable {
        var entries: [UUID: Entry] = [:]
        var pending: [UUID: Pending] = [:]
        var revision = 0
        /// Photos taken or picked here and not yet uploaded: photo id -> entry id.
        var photoUploads: [UUID: UUID] = [:]

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            entries = try c.decode([UUID: Entry].self, forKey: .entries)
            pending = try c.decode([UUID: Pending].self, forKey: .pending)
            revision = try c.decode(Int.self, forKey: .revision)
            photoUploads = try c.decodeIfPresent([UUID: UUID].self, forKey: .photoUploads) ?? [:]
        }
    }

    enum Pending: Codable, Equatable {
        case upsert(Date)
        case delete
    }

    private(set) var state = State()
    private(set) var isSyncing = false
    var syncError: String?

    private let fileURL: URL
    let photoFiles: PhotoFiles
    private var syncAgain = false
    private var downloads: [UUID: Task<Data?, Never>] = [:]

    /// Called after every local save or delete (Apple Health mirroring).
    var onLocalChange: ((Entry) -> Void)?

    init(fileURL: URL = EntryStore.defaultFileURL) {
        self.fileURL = fileURL
        photoFiles = PhotoFiles(directory: fileURL.deletingLastPathComponent()
            .appendingPathComponent(fileURL.deletingPathExtension().lastPathComponent + "-photos", isDirectory: true))
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

    /// Saves an entry. `newPhotos` holds the JPEG for each photo id in
    /// `entry.photos` that was added in this edit.
    @discardableResult
    func save(_ entry: Entry, newPhotos: [UUID: Data] = [:], now: Date = Date()) -> Bool {
        var entry = entry
        entry.text = String(entry.text.prefix(Entry.maxTextLength))
        entry.photos = Array(entry.photos.prefix(Entry.maxPhotos))
        entry.updatedAt = now
        entry.deleted = false
        do {
            for id in entry.photos {
                guard let data = newPhotos[id] else { continue }
                try photoFiles.write(data, for: id)
                state.photoUploads[id] = entry.id
            }
        } catch {
            syncError = "Couldn't save the photo on this iPhone: \(error.localizedDescription)"
            return false
        }
        forgetPhotos(of: state.entries[entry.id], keeping: entry.photos)
        state.entries[entry.id] = entry
        state.pending[entry.id] = .upsert(now)
        persist()
        onLocalChange?(entry)
        return true
    }

    func delete(_ id: UUID) {
        guard var entry = state.entries[id] else { return }
        forgetPhotos(of: entry, keeping: [])
        entry.deleted = true
        entry.text = ""
        entry.tags = []
        entry.mood = nil
        entry.photos = []
        state.entries[id] = entry
        state.pending[id] = .delete
        persist()
        onLocalChange?(entry)
    }

    /// Removes this iPhone's copies of an entry's photos that are no longer attached.
    private func forgetPhotos(of entry: Entry?, keeping kept: [UUID]) {
        for id in entry?.photos ?? [] where !kept.contains(id) {
            photoFiles.remove(id)
            state.photoUploads[id] = nil
        }
    }

    /// Wipes everything on this device (sign out, account deletion).
    func reset() {
        state = State()
        try? FileManager.default.removeItem(at: fileURL)
        photoFiles.removeAll()
        PhotoCache.removeAll()
    }

    // MARK: Photos

    /// A photo's JPEG: from this iPhone, or downloaded from the server and kept here.
    func photoData(_ id: UUID, remote: EntryRemote) async -> Data? {
        if let data = photoFiles.data(for: id) { return data }
        if let running = downloads[id] { return await running.value }
        let files = photoFiles
        let task = Task<Data?, Never> { @MainActor in
            defer { self.downloads[id] = nil }
            guard let data = try? await remote.downloadPhoto(id) else { return nil }
            // Keep it only while an entry still shows it.
            if self.state.entries.values.contains(where: { $0.photos.contains(id) }) {
                try? files.write(data, for: id)
            }
            return data
        }
        downloads[id] = task
        return await task.value
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
                // Photos go up first, so the entry never lists a photo the server lacks.
                for photo in entry.photos where state.photoUploads[photo] != nil {
                    if let data = photoFiles.data(for: photo) {
                        try await remote.uploadPhoto(photo, entryId: id, data: data)
                    }
                    state.photoUploads[photo] = nil
                    persist()
                }
                let stored = try await remote.put(entry)
                // Only clear the outbox if nothing changed locally while the request was in flight.
                if state.pending[id] == .upsert(stamp) {
                    state.pending[id] = nil
                    if stored.deleted {
                        forgetPhotos(of: state.entries[id], keeping: [])
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
                forgetPhotos(of: state.entries[incoming.id], keeping: incoming.deleted ? [] : incoming.photos)
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
