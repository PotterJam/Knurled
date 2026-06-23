import SwiftUI

struct GitHubConnectView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var connectingRepo: GitHubRepo?

    var body: some View {
        NavigationStack {
            Group {
                switch app.github.phase {
                case .signedOut:
                    signedOut
                case .awaitingAuthorization(let code):
                    awaitingAuthorization(code)
                case .signedIn(let login):
                    signedIn(login)
                }
            }
            .navigationTitle("GitHub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Signed out

    private var signedOut: some View {
        Form {
            Section {
                Text("Connect a GitHub account to sync training to your own repository. Knurled commits one signed commit per session straight to the Git Data API — no servers in between.")
                    .font(.subheadline)
            }
            if app.github.isConfigured {
                Section {
                    Button {
                        app.github.signIn()
                    } label: {
                        Label("Connect GitHub", systemImage: "person.crop.circle.badge.plus")
                    }
                }
            } else {
                Section("Setup required") {
                    Text("No OAuth client ID is configured. Register a GitHub OAuth App with Device Flow enabled, then add its Client ID to `Config/Secrets.xcconfig` as `GITHUB_CLIENT_ID`.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            errorSection
        }
    }

    // MARK: - Awaiting authorization

    private func awaitingAuthorization(_ code: DeviceCodeResponse) -> some View {
        Form {
            Section("Enter this code at GitHub") {
                HStack {
                    Text(code.userCode)
                        .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                    Spacer()
                    Button {
                        UIPasteboard.general.string = code.userCode
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                }
                Link(destination: URL(string: code.verificationUri) ?? URL(string: "https://github.com/login/device")!) {
                    Label("Open \(code.verificationUri)", systemImage: "safari")
                }
            }
            Section {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Waiting for you to authorize…")
                        .foregroundStyle(.secondary)
                }
                Button("Cancel", role: .cancel) { app.github.cancelSignIn() }
            }
            errorSection
        }
    }

    // MARK: - Signed in

    private func signedIn(_ login: String) -> some View {
        Form {
            Section("Account") {
                LabeledContent("Signed in", value: "@\(login)")
                Button("Sign out", role: .destructive) { app.github.signOut() }
            }
            Section("Choose a repository") {
                if app.github.isLoadingRepos {
                    HStack { ProgressView(); Text("Loading repositories…").foregroundStyle(.secondary) }
                } else if app.github.repos.isEmpty {
                    Button("Reload repositories") { Task { await app.github.loadRepos() } }
                } else {
                    ForEach(app.github.repos) { repo in
                        Button {
                            connect(repo)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(repo.fullName)
                                    if repo.private {
                                        Text("Private").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if connectingRepo == repo {
                                    ProgressView()
                                } else if app.activeRepo?.displayName == repo.fullName {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .disabled(connectingRepo != nil)
                    }
                }
            }
            errorSection
        }
    }

    @ViewBuilder private var errorSection: some View {
        if let message = app.github.errorMessage {
            Section {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private func connect(_ repo: GitHubRepo) {
        connectingRepo = repo
        Task {
            do {
                try await app.connect(repo: repo)
                dismiss()
            } catch {
                app.github.errorMessage = error.localizedDescription
            }
            connectingRepo = nil
        }
    }
}
