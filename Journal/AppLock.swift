import Foundation
import LocalAuthentication
import Observation

/// Face ID / passcode lock. The app starts locked and locks again whenever it
/// goes to the background.
@MainActor
@Observable
final class AppLock {
    #if DEBUG
    /// Simulator UI checks only: `-JournalSkipLock` starts unlocked. Never in release builds.
    private(set) var isLocked = !ProcessInfo.processInfo.arguments.contains("-JournalSkipLock")
    #else
    private(set) var isLocked = true
    #endif
    private(set) var isAuthenticating = false
    var message: String?

    func lock() {
        isLocked = true
    }

    func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No passcode on this device: there is nothing to check against.
            if (error as? LAError)?.code == .passcodeNotSet {
                message = "Set a passcode on this iPhone to lock your journal."
                isLocked = false
            } else {
                message = error?.localizedDescription
            }
            return
        }
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your journal")
            isLocked = false
            message = nil
        } catch {
            message = nil // cancelled; the lock screen offers to try again
        }
    }
}
