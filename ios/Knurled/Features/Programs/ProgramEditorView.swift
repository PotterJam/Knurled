import SwiftUI

/// Mobile program editing stays guided and typed. Raw FitSpec/patch authoring remains a workbench
/// concern; this surface delegates every write to `PlanEdit.quick` through the existing editor.
struct ProgramEditorView: View {
    let repo: ActiveRepo
    let plan: PlanIR

    @Environment(AppModel.self) private var app
    @State private var suggestions: [ProgramAdjustmentSuggestion] = []

    var body: some View {
        List {
            Section {
                NavigationLink {
                    QuickPlanEditView(repo: repo, plan: plan)
                } label: {
                    Label("Schedule, equipment, rest, and session work", systemImage: "slider.horizontal.3")
                }
            } header: {
                Text("Guided edits")
            } footer: {
                Text("Exercise swaps are available directly on workout cards. Raw patches remain available to CLI/workbench clients for compatibility.")
            }

            if !suggestions.isEmpty {
                Section("Engine suggestions") {
                    ForEach(suggestions) { suggestion in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(suggestion.lane).font(.headline)
                            Text(suggestion.displayText).font(.footnote).foregroundStyle(.secondary)
                            if let value = suggestion.proposedValue {
                                Text("Current: \(value)").font(.caption.monospaced())
                            }
                        }
                    }
                }
            }

            if let session = repo.nextWorkout {
                Section("Available swaps") {
                    ForEach(session.items.filter { $0.exerciseOptions?.alternatives.isEmpty == false }) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.display.title)
                            Text(item.exerciseOptions?.alternatives.map(\.label).joined(separator: ", ") ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Edit program")
        .task {
            suggestions = (try? await app.engine.suggestProgramAdjustments(dir: repo.url)) ?? []
        }
    }
}
