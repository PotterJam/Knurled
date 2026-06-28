import SwiftUI

struct SettingsHomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(ThemeStore.self) private var theme
    @Environment(WorkoutSettings.self) private var workoutSettings
    @Environment(BodyMetricsStore.self) private var metrics

    var body: some View {
        @Bindable var theme = theme
        @Bindable var workoutSettings = workoutSettings
        NavigationStack {
            List {
                if let repo = app.activeRepo {
                    Section {
                        ActiveRepoSummaryRow(repo: repo)
                    }
                }

                Section("Profile") {
                    NavigationLink {
                        BodyMetricsSettingsView()
                    } label: {
                        SettingsNavigationRow(
                            title: "Body metrics",
                            subtitle: profileSubtitle,
                            systemImage: "figure"
                        )
                    }
                }

                Section("Workout") {
                    Toggle(isOn: $workoutSettings.restTimersEnabled) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Rest timers")
                                Text("Start a countdown after working sets")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "timer")
                        }
                    }
                }

                Section("Manage") {
                    NavigationLink {
                        GitSettingsView()
                    } label: {
                        SettingsNavigationRow(
                            title: "Git & Sync",
                            subtitle: gitSummary,
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }

                    if let repo = app.activeRepo {
                        NavigationLink {
                            CustomExercisesView(repo: repo)
                        } label: {
                            SettingsNavigationRow(
                                title: "Custom Exercises",
                                subtitle: "\(repo.plan?.exercises.count ?? 0) saved",
                                systemImage: "figure.strengthtraining.traditional"
                            )
                        }
                    }

                    NavigationLink {
                        AboutSettingsView(engineVersion: app.engineVersion)
                    } label: {
                        SettingsNavigationRow(
                            title: "About",
                            subtitle: "App and engine versions",
                            systemImage: "info.circle"
                        )
                    }
                }

                Section("Appearance") {
                    NavigationLink {
                        ColourSchemeSelectionView(selection: $theme.scheme)
                    } label: {
                        HStack {
                            Label("Colour scheme", systemImage: "paintpalette")
                            Spacer()
                            Text(theme.scheme.title)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }

    private var profileSubtitle: String {
        guard let weight = metrics.bodyWeight, weight > 0 else { return "Not set" }
        let formatted = weight.formatted(.number.precision(.fractionLength(0...1)))
        return "\(formatted) \(metrics.unit.rawValue) · \(metrics.sex.title)"
    }

    private var gitSummary: String {
        if let login = app.github.login {
            return app.activeRepo?.remote == nil ? "@\(login), no remote repo" : "@\(login)"
        }
        return app.activeRepo?.isSample == true ? "Sample repo" : "Not connected"
    }
}

private struct ActiveRepoSummaryRow: View {
    let repo: ActiveRepo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(repo.displayName)
                    .font(.headline)
                Spacer()
                StatusChip(text: repo.isValid ? "valid" : "invalid", style: repo.isValid ? .ok : .bad)
            }

            HStack(spacing: KnurledTheme.Spacing.s) {
                if let remote = repo.remote {
                    Label("\(remote.owner)/\(remote.name)", systemImage: "shippingbox")
                } else if repo.isSample {
                    Label("Sample repository", systemImage: "tray")
                } else {
                    Label("Local repository", systemImage: "folder")
                }

                if repo.pendingPush {
                    Label("Pending push", systemImage: "arrow.up.circle.dotted")
                        .foregroundStyle(.orange)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct BodyMetricsSettingsView: View {
    @Environment(BodyMetricsStore.self) private var metrics
    @State private var weightText = ""
    @FocusState private var weightFocused: Bool

    var body: some View {
        @Bindable var metrics = metrics
        List {
            Section("Body weight") {
                HStack(spacing: KnurledTheme.Spacing.s) {
                    TextField("Weight", text: $weightText)
                        .keyboardType(.decimalPad)
                        .focused($weightFocused)
                        .onChange(of: weightText) { _, new in
                            metrics.bodyWeight = Double(new.replacingOccurrences(of: ",", with: "."))
                        }

                    Picker("Unit", selection: $metrics.unit) {
                        Text("kg").tag(Units.kg)
                        Text("lb").tag(Units.lb)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 110)
                }
            }

            Section {
                Picker("Sex", selection: $metrics.sex) {
                    ForEach(Sex.allCases) { sex in
                        Text(sex.title).tag(sex)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Sex")
            } footer: {
                Text("Body weight and sex normalise each lift against strength standards. They stay on this device and are never written to your repo or training log.")
            }
        }
        .navigationTitle("Body metrics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { weightFocused = false }
            }
        }
        .onAppear {
            if weightText.isEmpty, let bodyWeight = metrics.bodyWeight {
                weightText = bodyWeight.formatted(.number.precision(.fractionLength(0...1)))
            }
        }
    }
}

private struct ColourSchemeSelectionView: View {
    @Binding var selection: KnurledColorScheme

    var body: some View {
        List {
            ForEach(KnurledColorScheme.allCases) { scheme in
                Button {
                    selection = scheme
                } label: {
                    HStack(spacing: KnurledTheme.Spacing.m) {
                        SchemeSwatchBox(scheme: scheme, isSelected: selection == scheme)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(scheme.title)
                                .foregroundStyle(.primary)
                            Text(scheme.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if selection == scheme {
                            Image(systemName: "checkmark")
                                .fontWeight(.semibold)
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(scheme.title)
                .accessibilityAddTraits(selection == scheme ? .isSelected : [])
            }
        }
        .navigationTitle("Colour scheme")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SchemeSwatchBox: View {
    let scheme: KnurledColorScheme
    let isSelected: Bool

    var body: some View {
        let borderColor = isSelected ? Color.accentColor : Color(uiColor: .separator).opacity(0.4)
        let borderWidth = isSelected ? 2.0 : 0.5

        HStack(spacing: 5) {
            swatch(scheme.palette.accent)
            swatch(scheme.palette.danger)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(borderColor, lineWidth: borderWidth)
        )
    }

    private func swatch(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 14, height: 14)
            .overlay(Circle().strokeBorder(Color(uiColor: .separator).opacity(0.5), lineWidth: 0.5))
    }
}

private struct SettingsNavigationRow: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
        }
        .padding(.vertical, 3)
    }
}

private struct GitSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var showConnect = false
    @State private var isSyncing = false

    var body: some View {
        List {
            Section("Repository") {
                if let repo = app.activeRepo {
                    LabeledContent("Active", value: repo.displayName)
                    if let remote = repo.remote {
                        LabeledContent("Remote", value: "\(remote.owner)/\(remote.name)")
                        LabeledContent("Branch", value: remote.branch)
                    } else if repo.isSample {
                        Text("Sample repository")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No remote repository")
                            .foregroundStyle(.secondary)
                    }

                    if repo.pendingPush {
                        Label("Changes saved locally, not yet pushed", systemImage: "arrow.up.circle.dotted")
                            .foregroundStyle(.orange)
                    }

                    if repo.remote != nil {
                        Button {
                            Task { isSyncing = true; await app.sync(); isSyncing = false }
                        } label: {
                            HStack {
                                Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                                if isSyncing { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(isSyncing)
                    }
                } else {
                    Text("No repository connected.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("GitHub") {
                if let login = app.github.login {
                    LabeledContent("Signed in", value: "@\(login)")
                    Button {
                        showConnect = true
                    } label: {
                        Label("Manage repository", systemImage: "arrow.left.arrow.right")
                    }
                } else {
                    Button {
                        showConnect = true
                    } label: {
                        Label("Connect GitHub", systemImage: "person.crop.circle.badge.plus")
                    }
                }
            }
        }
        .navigationTitle("Git & Sync")
        .sheet(isPresented: $showConnect) {
            GitHubConnectView()
        }
    }
}

private struct AboutSettingsView: View {
    let engineVersion: String?

    var body: some View {
        List {
            Section("App") {
                LabeledContent("Version", value: Bundle.main.shortVersion)
            }

            Section("Engine") {
                LabeledContent("knurled-core", value: engineVersion ?? "—")
            }
        }
        .navigationTitle("About")
    }
}
