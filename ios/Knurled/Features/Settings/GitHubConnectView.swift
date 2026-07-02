import SwiftUI

struct GitHubConnectView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var connectingRepo: GitHubRepo?
    @State private var selectedRepoID: GitHubRepo.ID?
    @State private var creatingRepo = false
    @State private var newRepoName = "my-training"
    @State private var newRepoTemplate: StarterTemplate?
    @State private var newRepoUnits: Units = .kg
    @State private var newRepoInitialValues: [String: String] = InitialTrainingNumbers.emptyValues(
        for: InitialTrainingNumbers.spec(for: nil)
    )
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
                InitializeEmptyRepoView(repo: repo) { template, initialNumbers in
                    try await app.initializeRepository(
                        githubRepo: repo,
                        template: template,
                        initialNumbers: initialNumbers
                    )
                    dismiss()
                }
            }
            .task {
                await app.loadStarterTemplates()
                if newRepoTemplate == nil {
                    newRepoTemplate = app.starterTemplates.first
                    resetNewRepoInitialValues(for: newRepoTemplate)
                }
                // A restored session arrives signed in but with no repos fetched yet.
                if app.github.login != nil, app.github.repos.isEmpty {
                    await app.github.loadRepos()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                // Coming back from Safari after (de)selecting repositories on GitHub:
                // pick up the new grant without making the user hunt for a refresh button.
                if phase == .active, app.github.login != nil {
                    Task { await app.github.loadRepos() }
                }
            }
        }
    }

    // MARK: - Signed out

    private var signedOut: some View {
        Form {
            Section {
                Text("Connect a GitHub account to sync training to your own repository. You sign in with a device code, then choose exactly which repositories the app can access — Knurled commits straight to the GitHub API, no servers in between.")
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
                    Text("No GitHub App client ID is configured. Register a GitHub App with Device Flow enabled, then add its Client ID to `Config/Secrets.xcconfig` as `GITHUB_APP_CLIENT_ID`.")
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
            Section {
                if app.github.isLoadingRepos && app.github.repos.isEmpty {
                    HStack { ProgressView(); Text("Loading repositories…").foregroundStyle(.secondary) }
                } else if app.github.repos.isEmpty {
                    Text(
                        app.github.hasInstallations
                            ? "The app is installed, but no repositories are selected yet."
                            : "Install the app on your GitHub account and pick which repositories it can access. Only those repositories are visible to Knurled."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    selectRepositoriesLink
                    Button {
                        Task { await app.github.loadRepos() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
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
                            Label("Connect selected repository", systemImage: "checkmark.circle")
                            if connectingRepo != nil { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(connectingRepo != nil || selectedRepo == nil)

                    selectRepositoriesLink
                }
            } header: {
                Text("Choose a repository")
            } footer: {
                if !app.github.repos.isEmpty {
                    Text("Only repositories you've granted to the app appear here. The list refreshes when you return from GitHub.")
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
            }

            InitialTrainingNumbersEditor(
                spec: newRepoInitialSpec,
                units: $newRepoUnits,
                values: $newRepoInitialValues
            )
            .onChange(of: newRepoTemplate) { _, template in
                resetNewRepoInitialValues(for: template)
            }

            Section {
                Button {
                    if let template = newRepoTemplate { createStarterRepo(template) }
                } label: {
                    HStack {
                        Label("Create and connect", systemImage: "plus.circle")
                        if creatingRepo { Spacer(); ProgressView() }
                    }
                }
                .disabled(
                    creatingRepo ||
                    newRepoTemplate == nil ||
                    newRepoName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    !newRepoInitialNumbersComplete
                )
            }
            errorSection
        }
    }

    private var newRepoInitialSpec: InitialTrainingNumbers.Spec {
        InitialTrainingNumbers.spec(for: newRepoTemplate)
    }

    private var newRepoInitialNumbersComplete: Bool {
        InitialTrainingNumbers.isComplete(values: newRepoInitialValues, for: newRepoInitialSpec)
    }

    private var selectRepositoriesLink: some View {
        Link(destination: GitHubConfig.installURL) {
            Label(
                app.github.repos.isEmpty && !app.github.hasInstallations
                    ? "Select repositories on GitHub"
                    : "Manage repository access",
                systemImage: "arrow.up.forward.app"
            )
        }
    }

    private var selectedRepo: GitHubRepo? {
        app.github.repos.first { $0.id == selectedRepoID } ?? app.github.repos.first
    }

    private func repoLabel(_ repo: GitHubRepo) -> String {
        var tags: [String] = []
        if repo.private { tags.append("Private") }
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
        // The repository list's size field is not a reliable emptiness signal. Attempt the
        // pull and let GitHub's empty-repo 409 route the user into the initializer.
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
        let initialNumbers = InitialTrainingNumbers(
            spec: newRepoInitialSpec,
            units: newRepoUnits,
            values: newRepoInitialValues
        )
        Task {
            do {
                try await app.createStarterRepository(
                    name: newRepoName,
                    template: template,
                    initialNumbers: initialNumbers,
                    isPrivate: newRepoPrivate
                )
                dismiss()
            } catch {
                app.github.errorMessage = error.localizedDescription
            }
            creatingRepo = false
        }
    }

    private func resetNewRepoInitialValues(for template: StarterTemplate?) {
        let spec = InitialTrainingNumbers.spec(for: template)
        newRepoInitialValues = InitialTrainingNumbers.emptyValues(for: spec)
    }
}

/// Sheet shown when the user connects to an existing GitHub repo that has no commits yet.
/// Lets them pick a starter template and seed the empty repository from the app.
private struct InitializeEmptyRepoView: View {
    let repo: GitHubRepo
    let initialize: (StarterTemplate, InitialTrainingNumbers) async throws -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var template: StarterTemplate?
    @State private var units: Units = .kg
    @State private var initialValues: [String: String] = InitialTrainingNumbers.emptyValues(
        for: InitialTrainingNumbers.spec(for: nil)
    )
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
                }
                InitialTrainingNumbersEditor(
                    spec: initialSpec,
                    units: $units,
                    values: $initialValues
                )
                .onChange(of: template) { _, template in
                    resetInitialValues(for: template)
                }
                Section {
                    Button {
                        if let template { initializeRepo(template) }
                    } label: {
                        HStack {
                            Label("Initialize repository", systemImage: "plus.circle")
                            if isInitializing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(isInitializing || template == nil || !initialNumbersComplete)
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
                if template == nil {
                    template = app.starterTemplates.first
                    resetInitialValues(for: template)
                }
            }
        }
    }

    private var initialSpec: InitialTrainingNumbers.Spec {
        InitialTrainingNumbers.spec(for: template)
    }

    private var initialNumbersComplete: Bool {
        InitialTrainingNumbers.isComplete(values: initialValues, for: initialSpec)
    }

    private func initializeRepo(_ template: StarterTemplate) {
        isInitializing = true
        errorMessage = nil
        let initialNumbers = InitialTrainingNumbers(
            spec: initialSpec,
            units: units,
            values: initialValues
        )
        Task {
            do {
                try await initialize(template, initialNumbers)
            } catch {
                errorMessage = error.localizedDescription
            }
            isInitializing = false
        }
    }

    private func resetInitialValues(for template: StarterTemplate?) {
        let spec = InitialTrainingNumbers.spec(for: template)
        initialValues = InitialTrainingNumbers.emptyValues(for: spec)
    }
}
