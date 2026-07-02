import SwiftUI

/// Manages the optional GitHub backup of the active training repo. The iCloud/local working
/// copy is the source of truth; this view links a remote mirror (a new repository pushed from
/// the working copy), offers restore from an existing backup, and can unlink the mirror
/// without touching any data.
struct GitHubBackupView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var newRepoName = "my-training"
    @State private var newRepoPrivate = true
    @State private var isCreating = false
    @State private var showRestore = false
    @State private var showUnlinkConfirm = false
    @State private var errorMessage: String?

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
            .navigationTitle("GitHub backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showRestore) {
                RestoreFromBackupView()
            }
        }
    }

    // MARK: - Signed out

    private var signedOut: some View {
        Form {
            Section {
                Text("Your training repo lives in \(app.storageLocation.title). Connect a GitHub account to also mirror every training commit to a repository you own — no servers in between.")
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
                GitHubDeviceCodeSection(code: code) { app.github.cancelSignIn() }
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

            if let repo = app.activeRepo {
                if let remote = repo.remote {
                    linkedSection(repo: repo, remote: remote)
                } else {
                    createBackupSection
                }
            } else {
                Section {
                    Text("No active training repo yet — finish onboarding first.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button {
                    showRestore = true
                } label: {
                    Label("Restore from another backup", systemImage: "arrow.down.circle")
                }
            } footer: {
                Text("Restoring pulls a backup repository down and makes it the active training repo.")
            }

            errorSection
        }
    }

    private func linkedSection(repo: ActiveRepo, remote: GitHubRemote) -> some View {
        Section {
            LabeledContent("Repository", value: "\(remote.owner)/\(remote.name)")
            LabeledContent("Branch", value: remote.branch)
            if repo.pendingPush {
                Label("Changes saved locally, not yet pushed", systemImage: "arrow.up.circle.dotted")
                    .foregroundStyle(.orange)
            }
            Button(role: .destructive) {
                showUnlinkConfirm = true
            } label: {
                Label("Stop backing up", systemImage: "xmark.circle")
            }
            .confirmationDialog(
                "Stop backing up to \(remote.owner)/\(remote.name)?",
                isPresented: $showUnlinkConfirm,
                titleVisibility: .visible
            ) {
                Button("Stop backing up", role: .destructive) { app.unlinkBackup() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your training data stays in \(app.storageLocation.title) and the GitHub repository keeps its history — Knurled just stops pushing new commits.")
            }
        } header: {
            Text("Backup")
        }
    }

    private var createBackupSection: some View {
        Section {
            TextField("Repository name", text: $newRepoName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Toggle("Private repository", isOn: $newRepoPrivate)
            Button {
                createBackup()
            } label: {
                HStack {
                    Label("Create backup repository", systemImage: "plus.circle")
                    if isCreating { Spacer(); ProgressView() }
                }
            }
            .disabled(isCreating || newRepoName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } header: {
            Text("Backup")
        } footer: {
            Text("Creates the repository on GitHub and pushes your entire training repo as its first commit.")
        }
    }

    @ViewBuilder private var errorSection: some View {
        if let message = errorMessage ?? app.github.errorMessage {
            Section {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private func createBackup() {
        isCreating = true
        errorMessage = nil
        Task {
            do {
                try await app.createBackupRepository(name: newRepoName, isPrivate: newRepoPrivate)
            } catch {
                errorMessage = error.localizedDescription
            }
            isCreating = false
        }
    }
}
