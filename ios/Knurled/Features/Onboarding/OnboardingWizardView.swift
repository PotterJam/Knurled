import SwiftUI

/// First-run wizard, shown whenever no training repo exists yet. Two paths:
///
/// - **Start fresh**: pick a built-in program → enter first-workout numbers → optionally
///   attach a GitHub backup → the repo is created in primary storage (iCloud Drive when
///   available, this device otherwise).
/// - **Restore**: sign in to GitHub and pull an existing backup down as the active repo.
///
/// GitHub is never required — it is an optional backup of the iCloud/local working copy.
struct OnboardingWizardView: View {
    private enum Step: Hashable {
        case welcome
        case program
        case numbers
        case backup
    }

    @Environment(AppModel.self) private var app

    @State private var path: [Step] = []
    @State private var template: StarterTemplate?
    @State private var units: Units = .kg
    @State private var values: [String: String] = InitialTrainingNumbers.emptyValues(
        for: InitialTrainingNumbers.spec(for: nil)
    )
    @State private var wantsBackup = false
    @State private var backupRepoName = "my-training"
    @State private var backupPrivate = true
    @State private var isCreating = false
    @State private var showRestore = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack(path: $path) {
            welcome
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case .welcome: welcome
                    case .program: programStep
                    case .numbers: numbersStep
                    case .backup: backupStep
                    }
                }
        }
        .sheet(isPresented: $showRestore) {
            RestoreFromBackupView()
        }
        .task {
            await app.loadStarterTemplates()
            if template == nil {
                template = app.starterTemplates.first
                resetValues(for: template)
            }
        }
    }

    // MARK: - Welcome

    private var welcome: some View {
        VStack(spacing: KnurledTheme.Spacing.l) {
            Spacer()

            Image(systemName: "dumbbell.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Knurled")
                .font(.largeTitle.bold())
            Text("Progression-driven strength training. Your plan and every workout live in files you own — stored in iCloud, optionally backed up to GitHub.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            storageBadge

            Spacer()

            VStack(spacing: KnurledTheme.Spacing.s) {
                Button {
                    path.append(.program)
                } label: {
                    Label("Set up a new program", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    showRestore = true
                } label: {
                    Label("Restore from GitHub backup", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
            .padding(.horizontal)
            .padding(.bottom, KnurledTheme.Spacing.l)
        }
    }

    private var storageBadge: some View {
        Label(
            app.storageLocation == .iCloud
                ? "Training data syncs with iCloud Drive"
                : "iCloud is off — data stays on this device",
            systemImage: app.storageLocation == .iCloud ? "icloud.fill" : "iphone"
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    // MARK: - Program

    private var programStep: some View {
        List {
            Section {
                Text("Pick the program to start with. You can add, fork, or author programs later.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Section("Programs") {
                ForEach(app.starterTemplates) { starter in
                    Button {
                        if template != starter {
                            template = starter
                            resetValues(for: starter)
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(starter.title)
                                    .foregroundStyle(.primary)
                                Text(starter.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if template == starter {
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .accessibilityAddTraits(template == starter ? .isSelected : [])
                }
            }
        }
        .navigationTitle("Choose a program")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            continueBar(disabled: template == nil) { path.append(.numbers) }
        }
    }

    // MARK: - Numbers

    private var numbersStep: some View {
        Form {
            InitialTrainingNumbersEditor(
                spec: spec,
                units: $units,
                values: $values
            )
        }
        .navigationTitle("Starting numbers")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            continueBar(disabled: !numbersComplete) { path.append(.backup) }
        }
    }

    // MARK: - Backup

    private var backupStep: some View {
        Form {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.storageLocation == .iCloud ? "Stored in iCloud Drive" : "Stored on this device")
                        Text(app.storageLocation == .iCloud
                             ? "Your plan and training log sync across your devices automatically."
                             : "Turn on iCloud Drive for Knurled in Settings to sync across devices.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: app.storageLocation == .iCloud ? "icloud.fill" : "iphone")
                }
            } header: {
                Text("Storage")
            }

            Section {
                switch app.github.phase {
                case .signedOut:
                    Text("Optional: mirror every training commit to a GitHub repository you own.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if app.github.isConfigured {
                        Button {
                            app.github.signIn()
                        } label: {
                            Label("Connect GitHub", systemImage: "person.crop.circle.badge.plus")
                        }
                    } else {
                        Text("No GitHub OAuth client ID is configured in this build, so backup can be set up later.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                case .awaitingAuthorization(let code):
                    GitHubDeviceCodeSection(code: code) { app.github.cancelSignIn() }
                case .signedIn(let login):
                    LabeledContent("Account", value: "@\(login)")
                    Toggle("Create backup repository", isOn: $wantsBackup)
                    if wantsBackup {
                        TextField("Repository name", text: $backupRepoName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Toggle("Private repository", isOn: $backupPrivate)
                    }
                }
            } header: {
                Text("GitHub backup")
            } footer: {
                Text("You can add, change, or remove the GitHub backup any time in Settings.")
            }

            if let message = errorMessage ?? app.github.errorMessage {
                Section {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Storage & backup")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: app.github.login) { _, login in
            // Signing in mid-wizard is a strong signal the user wants the backup.
            if login != nil { wantsBackup = true }
        }
        .safeAreaInset(edge: .bottom) {
            continueBar(
                title: "Start training",
                systemImage: "flag.checkered",
                disabled: isCreating || (wantsBackup && app.github.login != nil && backupRepoName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
                inProgress: isCreating
            ) { create() }
        }
    }

    // MARK: - Actions

    private var spec: InitialTrainingNumbers.Spec {
        InitialTrainingNumbers.spec(for: template)
    }

    private var numbersComplete: Bool {
        InitialTrainingNumbers.isComplete(values: values, for: spec)
    }

    private func resetValues(for template: StarterTemplate?) {
        values = InitialTrainingNumbers.emptyValues(for: InitialTrainingNumbers.spec(for: template))
    }

    private func create() {
        guard let template else { return }
        isCreating = true
        errorMessage = nil
        let initialNumbers = InitialTrainingNumbers(spec: spec, units: units, values: values)
        Task {
            do {
                let repo = try await app.createTrainingRepository(
                    template: template,
                    initialNumbers: initialNumbers
                )
                // The app is usable from here — a backup failure must not undo onboarding,
                // so it surfaces as a repo banner instead of blocking the wizard.
                if wantsBackup, app.github.login != nil {
                    do {
                        try await app.createBackupRepository(name: backupRepoName, isPrivate: backupPrivate)
                    } catch {
                        repo.loadError = "Backup repository wasn't created: \(error.localizedDescription). You can retry from Settings."
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isCreating = false
        }
    }

    private func continueBar(
        title: String = "Continue",
        systemImage: String = "arrow.right",
        disabled: Bool,
        inProgress: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 0) {
            Button(action: action) {
                HStack {
                    Label(title, systemImage: systemImage)
                    if inProgress { ProgressView().padding(.leading, 4) }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(disabled)
            .padding()
        }
        .background(.bar)
    }
}

/// Shared device-flow UI: the one-time code the user enters at github.com/login/device.
struct GitHubDeviceCodeSection: View {
    let code: DeviceCodeResponse
    let cancel: () -> Void

    var body: some View {
        HStack {
            Text(code.userCode)
                .font(.system(.title2, design: .monospaced).weight(.bold))
            Spacer()
            Button {
                UIPasteboard.general.string = code.userCode
            } label: {
                Image(systemName: "doc.on.doc")
            }
        }
        Link(destination: URL(string: code.verificationUri) ?? URL(string: "https://github.com/login/device")!) {
            Label("Enter it at \(code.verificationUri)", systemImage: "safari")
        }
        HStack(spacing: 10) {
            ProgressView()
            Text("Waiting for you to authorize…")
                .foregroundStyle(.secondary)
        }
        Button("Cancel", role: .cancel) { cancel() }
    }
}

/// Restore path: sign in to GitHub, pick the backup repository, and pull it down as the
/// active training repo. Also reachable from Settings when replacing the local copy.
struct RestoreFromBackupView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var selectedRepoID: GitHubRepo.ID?
    @State private var isRestoring = false
    @State private var errorMessage: String?
    /// Set when a restore attempt hit GitHub's empty-repo 409 while a training repo is
    /// active: instead of restoring, we can back the active repo up into it.
    @State private var emptyRepoCandidate: GitHubRepo?

    var body: some View {
        NavigationStack {
            Form {
                switch app.github.phase {
                case .signedOut:
                    Section {
                        Text("Sign in to the GitHub account that holds your Knurled backup.")
                            .font(.subheadline)
                        if app.github.isConfigured {
                            Button {
                                app.github.signIn()
                            } label: {
                                Label("Connect GitHub", systemImage: "person.crop.circle.badge.plus")
                            }
                        } else {
                            Text("No GitHub OAuth client ID is configured. Add GITHUB_CLIENT_ID to Config/Secrets.xcconfig.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                case .awaitingAuthorization(let code):
                    Section("Enter this code at GitHub") {
                        GitHubDeviceCodeSection(code: code) { app.github.cancelSignIn() }
                    }
                case .signedIn(let login):
                    Section("Account") {
                        LabeledContent("Signed in", value: "@\(login)")
                    }
                    Section("Backup repository") {
                        if app.github.isLoadingRepos {
                            HStack { ProgressView(); Text("Loading repositories…").foregroundStyle(.secondary) }
                        } else if app.github.repos.isEmpty {
                            Text("No repositories found.")
                                .foregroundStyle(.secondary)
                            Button("Reload repositories") { Task { await app.github.loadRepos() } }
                        } else {
                            Picker("Repository", selection: selectedRepoBinding) {
                                ForEach(app.github.repos) { repo in
                                    Text(repo.fullName).tag(Optional(repo.id))
                                }
                            }
                            .pickerStyle(.menu)

                            Button {
                                if let repo = selectedRepo { restore(repo) }
                            } label: {
                                HStack {
                                    Label("Restore this backup", systemImage: "arrow.down.circle")
                                    if isRestoring { Spacer(); ProgressView() }
                                }
                            }
                            .disabled(isRestoring || selectedRepo == nil)
                        }
                    }
                }

                if let message = errorMessage ?? app.github.errorMessage {
                    Section {
                        Text(message).font(.footnote).foregroundStyle(.red)
                        if let candidate = emptyRepoCandidate {
                            Button {
                                backUpInto(candidate)
                            } label: {
                                HStack {
                                    Label("Back up into \(candidate.fullName) instead", systemImage: "arrow.up.circle")
                                    if isRestoring { Spacer(); ProgressView() }
                                }
                            }
                            .disabled(isRestoring)
                        }
                    }
                }
            }
            .navigationTitle("Restore backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isRestoring)
                }
            }
            .task {
                if app.github.login != nil, app.github.repos.isEmpty {
                    await app.github.loadRepos()
                }
            }
        }
    }

    private var selectedRepo: GitHubRepo? {
        app.github.repos.first { $0.id == selectedRepoID } ?? app.github.repos.first
    }

    private var selectedRepoBinding: Binding<GitHubRepo.ID?> {
        Binding(
            get: { selectedRepo?.id },
            set: { selectedRepoID = $0 }
        )
    }

    private func restore(_ repo: GitHubRepo) {
        isRestoring = true
        errorMessage = nil
        emptyRepoCandidate = nil
        Task {
            do {
                try await app.restoreFromBackup(repo: repo)
                dismiss()
            } catch GitHubError.emptyRepository {
                errorMessage = "\(repo.fullName) has no commits, so there is nothing to restore."
                if app.activeRepo != nil { emptyRepoCandidate = repo }
            } catch {
                errorMessage = error.localizedDescription
            }
            isRestoring = false
        }
    }

    private func backUpInto(_ repo: GitHubRepo) {
        isRestoring = true
        errorMessage = nil
        Task {
            do {
                try await app.backUpToExistingRepository(repo)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isRestoring = false
        }
    }
}
