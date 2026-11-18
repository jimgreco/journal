import GoogleSignIn
import SwiftUI

@main
struct JournalApp: App {
    @State private var session = Session()
    @State private var store = EntryStore()
    @State private var lock = AppLock()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        if let clientID = GoogleConfig.clientID {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(store)
                .environment(lock)
                .onOpenURL { url in GIDSignIn.sharedInstance.handle(url) }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    if phase == .background { lock.lock() }
                    guard phase == .active, session.isSignedIn else { return }
                    if lock.isLocked {
                        Task { await lock.unlockAutomaticallyIfNeeded() }
                    } else {
                        Task { await store.sync(with: SessionRemote(session: session)) }
                    }
                }
        }
    }
}

enum GoogleConfig {
    /// The iOS OAuth client id, or nil while project.yml still has its placeholder.
    static var clientID: String? {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String,
              !id.isEmpty, !id.hasPrefix("YOUR_") else { return nil }
        return id
    }
}

struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.background)
            Image(systemName: "book.closed.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
        }
        .ignoresSafeArea()
    }
}

struct RootView: View {
    @Environment(Session.self) private var session
    @Environment(EntryStore.self) private var store
    @Environment(AppLock.self) private var lock
    @Environment(\.scenePhase) private var scenePhase
    @State private var shield = ShieldWindow()

    /// The list and any open entry stay in place underneath the shield, so
    /// unlocking returns to exactly where you were.
    private var shieldVisible: Bool {
        scenePhase != .active || (session.isSignedIn && lock.isLocked)
    }

    var body: some View {
        Group {
            if session.isSignedIn {
                EntryListView()
            } else {
                SignInView()
            }
        }
        .animation(.default, value: session.isSignedIn)
        .onChange(of: shieldVisible, initial: true) { _, visible in
            shield.setVisible(visible) {
                ShieldView().environment(session).environment(lock)
            }
        }
        .onChange(of: lock.isLocked) { _, locked in
            if !locked, session.isSignedIn {
                Task { await store.sync(with: SessionRemote(session: session)) }
            }
        }
        .onChange(of: session.isSignedIn) { _, signedIn in
            if signedIn {
                Task { await store.sync(with: SessionRemote(session: session)) }
            } else {
                store.reset()
            }
        }
    }
}
