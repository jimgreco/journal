import SwiftUI
import UIKit

/// A window above the rest of the app, open sheets included, that shows the
/// lock screen or the app-switcher cover. Covering only the root view would
/// leave an open entry visible, and swapping the root view for the lock screen
/// would close the entry you were writing.
@MainActor
final class ShieldWindow {
    private var window: UIWindow?
    private weak var previousKeyWindow: UIWindow?

    func setVisible(_ visible: Bool, content: () -> some View) {
        if visible {
            guard window?.isHidden != false else { return }
            if window == nil {
                guard let scene = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene }).first else { return }
                let window = UIWindow(windowScene: scene)
                window.windowLevel = .alert + 1
                let host = UIHostingController(rootView: content())
                host.view.backgroundColor = .systemBackground
                window.rootViewController = host
                self.window = window
            }
            previousKeyWindow = window?.windowScene?.windows.first(where: \.isKeyWindow)
            window?.makeKeyAndVisible()
        } else if let window, !window.isHidden {
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
    }
}

struct ShieldView: View {
    @Environment(Session.self) private var session
    @Environment(AppLock.self) private var lock

    var body: some View {
        if session.isSignedIn && lock.isLocked {
            LockView()
        } else {
            PrivacyCover()
        }
    }
}
