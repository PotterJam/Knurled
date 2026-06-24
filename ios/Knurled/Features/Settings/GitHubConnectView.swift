import SwiftUI

struct GitHubConnectView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var connectingRepo: GitHubRepo?
    @State private var selectedRepoID: GitHubRepo.ID?
    @State private var creatingRepo = false
    @State private var newRepoName = "my-training"
    @State private var newRepoTemplate: StarterTemplate?
    @State private var newRepoPrivate = true
    @State private var emptyRepoToInitialize: GitHubRepo?

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
            .sheet(item: $emptyRepoToInitialize) { repo in
                InitializeEmptyRepoView(repo: repo) { template in
                    try await app.initializeRepository(githubRepo: repo, template: template)
                    dismiss()
                }
            }
            .task {
                await app.loadStarterTemplates()
                if newRepoTemplate == nil { newRepoTemplate = app.starterTemplates.first }
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
                    Text("No repositories found.")
                        .foregroundStyle(.secondary)
                    Button("Reload repositories") { Task { await app.github.loadRepos() } }
                } else {
                    Picker("Repository", selection: selectedRepoBinding) {
                        ForEach(app.github.repos) { repo in
                            Text(repoLabel(repo))
                                .tag(Optional(repo.id))
                        }
                    }
                    .pickerStyle(.menu)

                    Button {
                        if let repo = selectedRepo { connect(repo) }
                    } label: {
                        HStack {
                            Label(connectButtonTitle, systemImage: "checkmark.circle")
                            if connectingRepo != nil { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(connectingRepo != nil || selectedRepo == nil)
                }
            }
            Section("Create starter repository") {
                TextField("Repository name", text: $newRepoName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Picker("Template", selection: $newRepoTemplate) {
                    ForEach(app.starterTemplates) { template in
                        VStack(alignment: .leading) {
                            Text(template.title)
                            Text(template.reference)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(Optional(template))
                    }
                }

                Toggle("Private repository", isOn: $newRepoPrivate)

                if let subtitle = newRepoTemplate?.subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Button {
                    if let template = newRepoTemplate { createStarterRepo(template) }
                } label: {
                    HStack {
                        Label("Create and connect", systemImage: "plus.circle")
                        if creatingRepo { Spacer(); ProgressView() }
                    }
                }
                .disabled(creatingRepo || newRepoTemplate == nil || newRepoName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            errorSection
        }
    }

    private var selectedRepo: GitHubRepo? {
        app.github.repos.first { $0.id == selectedRepoID } ?? app.github.repos.first
    }

    private var connectButtonTitle: String {
        (selectedRepo?.isEmpty ?? false) ? "Initialize selected repository" : "Connect selected repository"
    }

    private func repoLabel(_ repo: GitHubRepo) -> String {
        var tags: [String] = []
        if repo.private { tags.append("Private") }
        if repo.isEmpty { tags.append("Empty") }
        return tags.isEmpty ? repo.fullName : "\(repo.fullName) · \(tags.joined(separator: " · "))"
    }

    private var selectedRepoBinding: Binding<GitHubRepo.ID?> {
        Binding(
            get: { selectedRepo?.id },
            set: { selectedRepoID = $0 }
        )
    }

    @ViewBuilder private var errorSection: some View {
        if let message = app.github.errorMessage {
            Section {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private func connect(_ repo: GitHubRepo) {
        // An empty repo can't be pulled — offer to seed it instead of attempting a connect
        // that would 409. The catch below is a fallback if `size` was stale.
        if repo.isEmpty {
            emptyRepoToInitialize = repo
            return
        }
        connectingRepo = repo
        Task {
            do {
                try await app.connect(repo: repo)
                dismiss()
            } catch GitHubError.emptyRepository {
                emptyRepoToInitialize = repo
            } catch {
                app.github.errorMessage = error.localizedDescription
            }
            connectingRepo = nil
        }
    }

    private func createStarterRepo(_ template: StarterTemplate) {
        creatingRepo = true
        Task {
            do {
                try await app.createStarterRepository(
                    name: newRepoName,
                    template: template,
                    isPrivate: newRepoPrivate
                )
                dismiss()
            } catch {
                app.github.errorMessage = error.localizedDescription
            }
            creatingRepo = false
        }
    }
}

/// Sheet shown when the user connects to an existing GitHub repo that has no commits yet.
/// Lets them pick a starter template and seed the empty repository from the app.
private struct InitializeEmptyRepoView: View {
    let repo: GitHubRepo
    let initialize: (StarterTemplate) async throws -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var template: StarterTemplate?
    @State private var isInitializing = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("\(repo.fullName) is empty. Choose a starter template and Knurled will build it and make the first commit.")
                        .font(.subheadline)
                }
                Section("Template") {
                    Picker("Template", selection: $template) {
                        ForEach(app.starterTemplates) { template in
                            VStack(alignment: .leading) {
                                Text(template.title)
                                Text(template.reference)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(Optional(template))
                        }
                    }

                    if let subtitle = template?.subtitle {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        if let template { initializeRepo(template) }
                    } label: {
                        HStack {
                            Label("Initialize repository", systemImage: "plus.circle")
                            if isInitializing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(isInitializing || template == nil)
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Begin repository")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isInitializing)
                }
            }
            .task {
                await app.loadStarterTemplates()
                if template == nil { template = app.starterTemplates.first }
            }
        }
    }

    private func initializeRepo(_ template: StarterTemplate) {
        isInitializing = true
        errorMessage = nil
        Task {
            do {
                try await initialize(template)
            } catch {
                errorMessage = error.localizedDescription
            }
            isInitializing = false
        }
    }
}
