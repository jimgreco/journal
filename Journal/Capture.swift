import AppIntents
import Observation

enum CaptureKind: String, Sendable {
    case text
    case voice
}

/// A request to start a new entry that came from outside the app's own
/// buttons: the Action Button, Siri, Spotlight, Shortcuts or the daily
/// reminder. It waits here until the journal is signed in and unlocked, so
/// Face ID still comes first.
@MainActor
@Observable
final class CaptureRequest {
    static let shared = CaptureRequest()

    private(set) var pending: CaptureKind?

    func request(_ kind: CaptureKind) {
        pending = kind
    }

    /// Returns the waiting request, if any, and clears it.
    func take() -> CaptureKind? {
        defer { pending = nil }
        return pending
    }

    func clear() {
        pending = nil
    }
}

struct SpeakEntryIntent: AppIntent {
    static let title: LocalizedStringResource = "Speak an Entry"
    static let description = IntentDescription("Opens Private Notes and starts listening for a new entry.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        CaptureRequest.shared.request(.voice)
        return .result()
    }
}

struct WriteEntryIntent: AppIntent {
    static let title: LocalizedStringResource = "Write an Entry"
    static let description = IntentDescription("Opens Private Notes on a new, empty entry.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        CaptureRequest.shared.request(.text)
        return .result()
    }
}

/// Makes both actions available to the Action Button, Siri, Spotlight and
/// Shortcuts without any setup in the Shortcuts app.
struct JournalShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SpeakEntryIntent(),
            phrases: [
                "Speak an entry in \(.applicationName)",
                "New voice entry in \(.applicationName)"
            ],
            shortTitle: "Speak Entry",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: WriteEntryIntent(),
            phrases: [
                "Write an entry in \(.applicationName)",
                "New entry in \(.applicationName)"
            ],
            shortTitle: "Write Entry",
            systemImageName: "square.and.pencil"
        )
    }
}
