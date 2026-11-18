import HealthKit
import XCTest
@testable import Journal

@MainActor
final class FakeRemote: EntryRemote {
    var server: [UUID: Entry] = [:]
    var revision = 0
    var offline = false
    var puts = 0
    var onPut: (() -> Void)?

    func put(_ entry: Entry) async throws -> Entry {
        if offline { throw APIError.offline }
        puts += 1
        onPut?()
        if let existing = server[entry.id], existing.deleted { return existing }
        revision += 1
        var stored = entry
        stored.revision = revision
        server[entry.id] = stored
        return stored
    }

    func delete(_ id: UUID) async throws -> Entry {
        if offline { throw APIError.offline }
        revision += 1
        var stored = server[id] ?? Entry(id: id, entryDate: "2026-11-10", createdAt: Date(), updatedAt: Date(),
                                         source: .text, isPrivate: false, text: "", mood: nil, tags: [])
        stored.deleted = true
        stored.text = ""
        stored.revision = revision
        server[id] = stored
        return stored
    }

    func changes(after: Int) async throws -> ChangesPage {
        if offline { throw APIError.offline }
        let entries = server.values.filter { ($0.revision ?? 0) > after }.sorted { ($0.revision ?? 0) < ($1.revision ?? 0) }
        return ChangesPage(entries: entries, revision: entries.last?.revision ?? after, more: false)
    }
}

@MainActor
final class EntryStoreTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() async throws {
        fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("journal-test-\(UUID()).json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func entry(_ text: String, day: String = "2026-11-10", isPrivate: Bool = false) -> Entry {
        Entry(entryDate: day, createdAt: Date(), updatedAt: Date(), source: .text, isPrivate: isPrivate,
              text: text, mood: 3, tags: ["work"])
    }

    func testSaveIsPersistedAndQueued() async throws {
        let store = EntryStore(fileURL: fileURL)
        store.save(entry("hello"))
        XCTAssertEqual(store.pendingCount, 1)
        let reloaded = EntryStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.visibleEntries.map(\.text), ["hello"])
        XCTAssertEqual(reloaded.pendingCount, 1)
        let values = try fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testSyncPushesThenPulls() async {
        let store = EntryStore(fileURL: fileURL)
        let remote = FakeRemote()
        let other = entry("from another device")
        remote.revision = 1
        var stored = other
        stored.revision = 1
        remote.server[other.id] = stored

        store.save(entry("local"))
        await store.sync(with: remote)

        XCTAssertEqual(store.pendingCount, 0)
        XCTAssertEqual(Set(store.visibleEntries.map(\.text)), ["local", "from another device"])
        XCTAssertNil(store.syncError)
    }

    func testOfflineKeepsOutboxWithoutError() async {
        let store = EntryStore(fileURL: fileURL)
        let remote = FakeRemote()
        remote.offline = true
        store.save(entry("waiting"))
        await store.sync(with: remote)
        XCTAssertEqual(store.pendingCount, 1)
        XCTAssertNil(store.syncError)

        remote.offline = false
        await store.sync(with: remote)
        XCTAssertEqual(store.pendingCount, 0)
        XCTAssertEqual(remote.server.count, 1)
    }

    func testEditDuringPushStaysQueued() async {
        let store = EntryStore(fileURL: fileURL)
        let remote = FakeRemote()
        var e = entry("v1")
        store.save(e)
        remote.onPut = { [weak store] in
            remote.onPut = nil
            e.text = "v2"
            store?.save(e, now: Date().addingTimeInterval(1))
        }
        await store.sync(with: remote)
        // The v2 edit happened mid-request, so it must still be queued, then sent on the next sync.
        XCTAssertEqual(store.visibleEntries.first?.text, "v2")
        await store.sync(with: remote)
        XCTAssertEqual(store.pendingCount, 0)
        XCTAssertEqual(remote.server[e.id]?.text, "v2")
    }

    func testDeleteSyncsAndRemoves() async {
        let store = EntryStore(fileURL: fileURL)
        let remote = FakeRemote()
        let e = entry("bye")
        store.save(e)
        await store.sync(with: remote)
        store.delete(e.id)
        XCTAssertTrue(store.visibleEntries.isEmpty)
        await store.sync(with: remote)
        XCTAssertEqual(store.pendingCount, 0)
        XCTAssertEqual(remote.server[e.id]?.deleted, true)
        XCTAssertNil(store.state.entries[e.id])
    }

    func testRemoteDeletionRemovesLocalCopy() async {
        let store = EntryStore(fileURL: fileURL)
        let remote = FakeRemote()
        let e = entry("gone elsewhere")
        store.save(e)
        await store.sync(with: remote)
        _ = try? await remote.delete(e.id)
        await store.sync(with: remote)
        XCTAssertTrue(store.visibleEntries.isEmpty)
    }

    func testResetWipesDevice() async {
        let store = EntryStore(fileURL: fileURL)
        store.save(entry("secret"))
        store.reset()
        XCTAssertTrue(store.visibleEntries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testDaysGroupingAndSearch() {
        let store = EntryStore(fileURL: fileURL)
        store.save(entry("morning run felt great", day: "2026-11-10"))
        store.save(entry("hard meeting", day: "2026-11-11"))
        XCTAssertEqual(store.days().map(\.day), ["2026-11-11", "2026-11-10"])
        XCTAssertEqual(store.days(matching: "RUN").flatMap(\.entries).map(\.text), ["morning run felt great"])
        XCTAssertEqual(store.days(matching: "work").flatMap(\.entries).count, 2, "search matches tags")
    }
}

final class ModelTests: XCTestCase {
    func testTagParsing() {
        XCTAssertEqual(Tags.parse("work, running ,  Work, #sleep"), ["work", "running", "sleep"])
        XCTAssertEqual(Tags.parse(String(repeating: "a,", count: 20)).count, 1)
        XCTAssertEqual(Tags.parse((1...20).map(String.init).joined(separator: ",")).count, Entry.maxTags)
    }

    func testUploadBodyMatchesServerContract() throws {
        let e = Entry(entryDate: "2026-11-10", createdAt: Date(timeIntervalSince1970: 0),
                      updatedAt: Date(timeIntervalSince1970: 1), source: .voice, isPrivate: true,
                      text: "hi", mood: nil, tags: [])
        let json = try JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(e.uploadBody)) as! [String: Any]
        XCTAssertEqual(json["private"] as? Bool, true)
        XCTAssertEqual(json["source"] as? String, "voice")
        XCTAssertEqual(json["createdAt"] as? String, "1970-01-01T00:00:00.000Z")
        XCTAssertTrue(json["mood"] is NSNull, "mood is sent as an explicit null")
        XCTAssertNil(json["deleted"])
    }

    func testDecodesServerEntry() throws {
        let json = """
        {"id":"d20decc1-2c5d-41a0-8551-72623f720451","entryDate":"2026-11-10","createdAt":"2026-11-10T12:00:00.000Z",
         "updatedAt":"2026-11-10T12:00:00.000Z","source":"voice","private":false,"revision":1,"deleted":false,
         "text":"hello","mood":3,"tags":["test"]}
        """
        let e = try JSONCoding.decoder.decode(Entry.self, from: Data(json.utf8))
        XCTAssertEqual(e.text, "hello")
        XCTAssertEqual(e.revision, 1)
        XCTAssertEqual(e.source, .voice)
        let tombstone = try JSONCoding.decoder.decode(Entry.self, from: Data(json.replacingOccurrences(
            of: "\"text\":\"hello\"", with: "\"text\":null").utf8))
        XCTAssertEqual(tombstone.text, "")
    }

    func testDayKeyUsesLocalCalendarDay() {
        let tz = TimeZone(identifier: "America/New_York")!
        // 02:30 UTC on Nov 11 is still Nov 10 in New York.
        let date = JSONCoding.isoFormatter.date(from: "2026-11-11T02:30:00.000Z")!
        XCTAssertEqual(DayKey.key(for: date, timeZone: tz), "2026-11-10")
    }
}

@MainActor
final class HealthMoodTests: XCTestCase {
    private func entry(day: String, created: Date, mood: Int?, isPrivate: Bool = false, deleted: Bool = false) -> Entry {
        Entry(entryDate: day, createdAt: created, updatedAt: created, source: .text, isPrivate: isPrivate,
              text: "never sent", mood: mood, tags: [], deleted: deleted)
    }

    func testValenceRunsFromUnpleasantToPleasant() {
        XCTAssertEqual(Mood.allCases.map(HealthMood.valence(for:)), [-1, -0.5, 0, 0.5, 1])
    }

    func testOnlyPublicLiveEntriesWithAMoodGoToHealth() {
        let now = Date()
        let today = DayKey.key(for: now)
        XCTAssertNotNil(HealthMood.sample(for: entry(day: today, created: now, mood: 4)))
        XCTAssertNil(HealthMood.sample(for: entry(day: today, created: now, mood: nil)))
        XCTAssertNil(HealthMood.sample(for: entry(day: today, created: now, mood: 4, isPrivate: true)))
        XCTAssertNil(HealthMood.sample(for: entry(day: today, created: now, mood: 4, deleted: true)))
    }

    func testSampleCarriesOnlyTheMoodAndASyncIdentifier() throws {
        let now = Date()
        let e = entry(day: DayKey.key(for: now), created: now, mood: 5)
        let sample = try XCTUnwrap(HealthMood.sample(for: e))
        XCTAssertEqual(sample.valence, 1)
        XCTAssertEqual(sample.kind, .dailyMood)
        XCTAssertEqual(sample.metadata?[HKMetadataKeySyncIdentifier] as? String, HealthMood.syncIdentifier(e.id))
        XCTAssertFalse(sample.metadata?.values.contains { "\($0)".contains("never sent") } ?? false)
    }

    func testBackdatedEntryIsPlacedAtMiddayOfItsDay() {
        let calendar = Calendar.current
        let now = Date()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let e = entry(day: DayKey.key(for: yesterday), created: now, mood: 3)
        let date = HealthMood.date(for: e, calendar: calendar)
        XCTAssertTrue(calendar.isDate(date, inSameDayAs: yesterday))
        XCTAssertEqual(calendar.component(.hour, from: date), 12)
        let sameDay = entry(day: DayKey.key(for: now), created: now, mood: 3)
        XCTAssertEqual(HealthMood.date(for: sameDay, calendar: calendar), now)
    }
}

final class TranscriptSegmentsTests: XCTestCase {
    func testRevisionsOfOneUtteranceReplaceEachOther() {
        var t = TranscriptSegments()
        t.update("I went", utteranceEnded: false)
        t.update("I went to the", utteranceEnded: false)
        t.update("I went to the store.", utteranceEnded: false)
        XCTAssertEqual(t.text, "I went to the store.")
    }

    func testUtteranceEndKeepsTextWhenTheNextStarts() {
        var t = TranscriptSegments()
        t.update("I went to the store.", utteranceEnded: false)
        t.update("I went to the store.", utteranceEnded: true)
        t.update("Then", utteranceEnded: false)
        t.update("Then I came home.", utteranceEnded: false)
        XCTAssertEqual(t.text, "I went to the store. Then I came home.")
    }

    func testRestartWithoutMetadataIsStillKept() {
        var t = TranscriptSegments()
        t.update("It was a long day at work and I was tired.", utteranceEnded: false)
        t.update("Dinner", utteranceEnded: false)
        t.update("Dinner was good.", utteranceEnded: false)
        XCTAssertEqual(t.text, "It was a long day at work and I was tired. Dinner was good.")
    }

    func testShorterRevisionWithTheSameStartIsNotARestart() {
        var t = TranscriptSegments()
        t.update("I think that that is", utteranceEnded: false)
        t.update("I think that is", utteranceEnded: false)
        XCTAssertEqual(t.text, "I think that is")
    }
}
