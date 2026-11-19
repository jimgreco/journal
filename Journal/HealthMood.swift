import Foundation
import HealthKit
import Observation

/// Copies each entry's mood into Apple Health as a State of Mind sample.
///
/// Only the mood goes to Health: never the entry text or tags. Private
/// entries are left out, the same as the weekly review. Each sample carries
/// the entry's id as its sync identifier, so editing an entry replaces its
/// sample, and deleting it (or marking it private) removes the sample.
@MainActor
@Observable
final class HealthMood {
    static let enabledKey = "healthMoodEnabled"

    private(set) var isEnabled: Bool
    var error: String?

    private let health = HKHealthStore()
    private let defaults: UserDefaults
    private var type: HKStateOfMindType { HKObjectType.stateOfMindType() }

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.enabledKey)
    }

    /// Asks for permission to write State of Mind, then copies every existing
    /// mood across. Leaves it off, with a message, if access wasn't given.
    func enable(existing entries: [Entry]) async {
        error = nil
        guard Self.isAvailable else {
            error = "Apple Health isn't available on this device."
            return
        }
        do {
            try await health.requestAuthorization(toShare: [type], read: [])
        } catch {
            self.error = "Couldn't ask for Apple Health access: \(error.localizedDescription)"
            return
        }
        guard health.authorizationStatus(for: type) == .sharingAuthorized else {
            error = "Turn on State of Mind for Private Notes in the Health app (Sharing › Apps)."
            return
        }
        isEnabled = true
        defaults.set(true, forKey: Self.enabledKey)
        for entry in entries { await update(entry) }
    }

    /// Stops copying new moods. Moods already in Health stay there.
    func disable() {
        isEnabled = false
        defaults.set(false, forKey: Self.enabledKey)
    }

    /// Mirrors one entry into Health: saves, replaces or removes its sample.
    func update(_ entry: Entry) async {
        guard isEnabled, health.authorizationStatus(for: type) == .sharingAuthorized else { return }
        do {
            if let sample = Self.sample(for: entry) {
                try await health.save(sample)
            } else {
                let predicate = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier,
                                                            allowedValues: [Self.syncIdentifier(entry.id)])
                _ = try await health.deleteObjects(of: type, predicate: predicate)
            }
        } catch {
            self.error = "Couldn't update Apple Health: \(error.localizedDescription)"
        }
    }

    // MARK: Mapping (kept pure so it can be tested)

    static func syncIdentifier(_ id: UUID) -> String { "journal-mood-\(id.uuidString.lowercased())" }

    /// Rough … Great on Health's unpleasant-to-pleasant scale (-1 … 1).
    static func valence(for mood: Mood) -> Double {
        switch mood {
        case .rough: -1.0
        case .low: -0.5
        case .okay: 0.0
        case .good: 0.5
        case .great: 1.0
        }
    }

    /// When the mood happened: when the entry was written if that was on the
    /// entry's day, otherwise midday on the day it's filed under.
    static func date(for entry: Entry, calendar: Calendar = .current) -> Date {
        guard let day = DayKey.date(from: entry.entryDate, timeZone: calendar.timeZone) else { return entry.createdAt }
        if calendar.isDate(entry.createdAt, inSameDayAs: day) { return entry.createdAt }
        return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
    }

    /// The sample to store for an entry, or nil if it shouldn't be in Health.
    static func sample(for entry: Entry) -> HKStateOfMind? {
        guard !entry.deleted, !entry.isPrivate, let raw = entry.mood, let mood = Mood(rawValue: raw) else { return nil }
        return HKStateOfMind(
            date: date(for: entry),
            kind: .dailyMood,
            valence: valence(for: mood),
            labels: [],
            associations: [],
            metadata: [
                HKMetadataKeySyncIdentifier: syncIdentifier(entry.id),
                HKMetadataKeySyncVersion: NSNumber(value: Int64(entry.updatedAt.timeIntervalSince1970 * 1000)),
            ]
        )
    }
}
