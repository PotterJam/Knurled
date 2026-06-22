import SwiftUI

struct SettingsHomeView: View {
    @Environment(AppModel.self) private var app

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
                    } else {
                        Text("No repository connected.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("GitHub") {
                    Button {
                    } label: {
                        Label("Connect GitHub", systemImage: "person.crop.circle.badge.plus")
                    }
                    .disabled(true)
                    Text("GitHub sign-in arrives in an upcoming build step.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Engine") {
                    LabeledContent("knurled-core", value: app.engineVersion ?? "—")
                }

                Section("App") {
                    LabeledContent("Version", value: Bundle.main.shortVersion)
                }
            }
            .navigationTitle("Settings")
        }
    }
}
