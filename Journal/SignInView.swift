import AuthenticationServices
import SwiftUI

struct SignInView: View {
    @Environment(Session.self) private var session
    @Environment(AppLock.self) private var lock

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "book.closed.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            VStack(spacing: 8) {
                Text("Journal").font(.largeTitle.bold())
                Text("A private place for your thoughts. Type or talk; voice is transcribed on this iPhone and the audio is never kept.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.email]
            } onCompletion: { result in
                switch result {
                case .success(let authorization):
                    guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else { return }
                    Task {
                        await session.signIn(with: credential)
                        if session.isSignedIn { await lock.unlock() }
                    }
                case .failure(let error):
                    if (error as? ASAuthorizationError)?.code != .canceled {
                        session.lastError = error.localizedDescription
                    }
                }
            }
            .signInWithAppleButtonStyle(.whiteOutline)
            .frame(height: 50)

            #if DEBUG
            Button("Local dev sign in") {
                Task {
                    await session.devSignIn()
                    if session.isSignedIn { await lock.unlock() }
                }
            }
            .font(.footnote)
            #endif

            if let error = session.lastError {
                Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }
        }
        .padding(32)
    }
}

struct LockView: View {
    @Environment(AppLock.self) private var lock

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "lock.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Journal is locked").font(.title2.bold())
            if let message = lock.message {
                Text(message).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Button {
                Task { await lock.unlock() }
            } label: {
                Label("Unlock", systemImage: "faceid")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(lock.isAuthenticating)
            Spacer()
        }
        .padding(32)
        .task { await lock.unlock() }
    }
}
