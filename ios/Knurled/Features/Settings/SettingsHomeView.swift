import SwiftUI

struct SettingsHomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(ThemeStore.self) private var theme
    @State private var showConnect = false
    @State private var isSyncing = false

    var body: some View {
        @Bindable var theme = theme
        NavigationStack {
            List {
                Section("Appearance") {
                    Picker("Colour scheme", selection: $theme.scheme) {
                        ForEach(KnurledColorScheme.allCases) { scheme in
                            SchemeRow(scheme: scheme).tag(scheme)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }

                Section("Repository") {
                    if let repo = app.activeRepo {
                        LabeledContent("Active", value: repo.displayName)
                        if repo.isSample {
                            Text("Running on the bundled sample repo. Connect GitHub to use your own training repository.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        if repo.pendingPush {
                            Label("Changes saved locally — not yet pushed", systemImage: "arrow.up.circle.dotted")
                                .font(.footnote)
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
                            Label("Manage / switch repository", systemImage: "arrow.left.arrow.right")
                        }
                    } else {
                        Button {
                            showConnect = true
                        } label: {
                            Label("Connect GitHub", systemImage: "person.crop.circle.badge.plus")
                        }
                    }
                }

                if let repo = app.activeRepo {
                    Section("Custom Exercises") {
                        NavigationLink {
                            CustomExercisesView(repo: repo)
                        } label: {
                            Label("Manage custom exercises", systemImage: "figure.strengthtraining.traditional")
                        }
                    }
                }

                Section("Engine") {
                    LabeledContent("knurled-core", value: app.engineVersion ?? "—")
                }

                Section("App") {
                    LabeledContent("Version", value: Bundle.main.shortVersion)
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showConnect) {
                GitHubConnectView()
            }
        }
    }
}

/// A single colour-scheme option: name, accent/danger description and a pair
/// of swatches previewing the two colours.
private struct SchemeRow: View {
    let scheme: KnurledColorScheme

    var body: some View {
        HStack(spacing: KnurledTheme.Spacing.s) {
            HStack(spacing: 4) {
                swatch(scheme.palette.accent)
                swatch(scheme.palette.danger)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(scheme.title)
                Text(scheme.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func swatch(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 16, height: 16)
            .overlay(Circle().strokeBorder(Color(uiColor: .separator).opacity(0.5), lineWidth: 0.5))
    }
}
