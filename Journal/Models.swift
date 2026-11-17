import Foundation

enum EntrySource: String, Codable, Sendable {
    case text
    case voice
}

struct Entry: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    /// The local calendar day the entry belongs to, `YYYY-MM-DD`.
    var entryDate: String
    var createdAt: Date
    var updatedAt: Date
    var source: EntrySource
    var isPrivate: Bool
    var text: String
    var mood: Int?
    var tags: [String]
    var deleted: Bool = false
    var revision: Int?

    enum CodingKeys: String, CodingKey {
        case id, entryDate, createdAt, updatedAt, source, text, mood, tags, deleted, revision
        case isPrivate = "private"
    }

    init(id: UUID = UUID(), entryDate: String, createdAt: Date, updatedAt: Date, source: EntrySource,
         isPrivate: Bool, text: String, mood: Int?, tags: [String], deleted: Bool = false, revision: Int? = nil) {
        self.id = id
        self.entryDate = entryDate
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.source = source
        self.isPrivate = isPrivate
        self.text = text
        self.mood = mood
        self.tags = tags
        self.deleted = deleted
        self.revision = revision
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        entryDate = try c.decode(String.self, forKey: .entryDate)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        source = try c.decode(EntrySource.self, forKey: .source)
        isPrivate = try c.decode(Bool.self, forKey: .isPrivate)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        mood = try c.decodeIfPresent(Int.self, forKey: .mood)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        revision = try c.decodeIfPresent(Int.self, forKey: .revision)
    }

    static let maxTextLength = 20_000
    static let maxTags = 10
    static let maxTagLength = 32

    /// The body sent with `PUT /api/entries/:id`.
    var uploadBody: UploadBody {
        UploadBody(entryDate: entryDate, createdAt: createdAt, updatedAt: updatedAt, source: source,
                   isPrivate: isPrivate, text: text, mood: mood, tags: tags)
    }

    struct UploadBody: Encodable {
        let entryDate: String
        let createdAt: Date
        let updatedAt: Date
        let source: EntrySource
        let isPrivate: Bool
        let text: String
        let mood: Int?
        let tags: [String]

        enum CodingKeys: String, CodingKey {
            case entryDate, createdAt, updatedAt, source, text, mood, tags
            case isPrivate = "private"
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(entryDate, forKey: .entryDate)
            try c.encode(createdAt, forKey: .createdAt)
            try c.encode(updatedAt, forKey: .updatedAt)
            try c.encode(source, forKey: .source)
            try c.encode(isPrivate, forKey: .isPrivate)
            try c.encode(text, forKey: .text)
            try c.encode(mood, forKey: .mood) // explicit null
            try c.encode(tags, forKey: .tags)
        }
    }
}

enum Mood: Int, CaseIterable, Identifiable {
    case rough = 1, low, okay, good, great
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .rough: "Rough"
        case .low: "Low"
        case .okay: "Okay"
        case .good: "Good"
        case .great: "Great"
        }
    }
    var symbol: String {
        switch self {
        case .rough: "cloud.rain"
        case .low: "cloud"
        case .okay: "cloud.sun"
        case .good: "sun.max"
        case .great: "sparkles"
        }
    }
}

enum DayKey {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// The local calendar day of `date`, in the device's current time zone.
    static func key(for date: Date, timeZone: TimeZone = .current) -> String {
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    static func date(from key: String, timeZone: TimeZone = .current) -> Date? {
        formatter.timeZone = timeZone
        return formatter.date(from: key)
    }

    static func title(for key: String, now: Date = Date()) -> String {
        guard let date = date(from: key) else { return key }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return date.formatted(sameYear
            ? .dateTime.weekday(.wide).month(.wide).day()
            : .dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
    }
}

enum Tags {
    /// Splits "work, running ,  sleep" into ["work", "running", "sleep"], deduplicated, within the server's limits.
    static func parse(_ text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in text.split(whereSeparator: { $0 == "," || $0 == "#" }) {
            let tag = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Entry.maxTagLength))
            guard !tag.isEmpty, seen.insert(tag.lowercased()).inserted else { continue }
            result.append(tag)
            if result.count == Entry.maxTags { break }
        }
        return result
    }
}

enum JSONCoding {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(isoFormatter.string(from: date))
        }
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = isoFormatter.date(from: s) ?? plainISOFormatter.date(from: s) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad date \(s)")
        }
        return d
    }()

    nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) static let plainISOFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
