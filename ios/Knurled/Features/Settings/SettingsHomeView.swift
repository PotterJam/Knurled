import SwiftUI

struct SettingsHomeView: View {
    @Environment(AppModel.self) private var app
    @State private var showConnect = false
    @State private var isSyncing = false

    var body: some View {
        NavigationStack {
            List {
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
