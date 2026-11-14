import SwiftUI

@main
struct JournalApp: App {
    @State private var session = Session()
    @State private var store = EntryStore()
    @State private var lock = AppLock()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(store)
                .environment(lock)
                // Hide entries in the app switcher and whenever the app isn't in front.
                .overlay {
                    if scenePhase != .active {
                        PrivacyCover()
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { lock.lock() }
                    if phase == .active, session.isSignedIn, !lock.isLocked {
                        Task { await store.sync(with: SessionRemote(session: session)) }
                    }
                }
        }
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

    var body: some View {
        Group {
            if !session.isSignedIn {
                SignInView()
            } else if lock.isLocked {
                LockView()
            } else {
                EntryListView()
            }
        }
        .animation(.default, value: session.isSignedIn)
        .animation(.default, value: lock.isLocked)
        .onChange(of: session.isSignedIn) { _, signedIn in
            if signedIn {
                Task { await store.sync(with: SessionRemote(session: session)) }
            } else {
                store.reset()
            }
        }
    }
}
