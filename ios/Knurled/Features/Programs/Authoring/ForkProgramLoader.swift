import SwiftUI

/// Loads a built-in template into the structured editor by parsing it through the
/// engine (`knurled_parse_template` vendors a built-in reference), so "Customise
/// GZCLP / 5-3-1 / SS" dogfoods the very documents the engine ships.
struct ForkProgramLoader: View {
    let repo: ActiveRepo
    let reference: String
    let name: String
    let units: Units

    @Environment(AppModel.self) private var app
    @State private var model: ProgramAuthoringModel?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let model {
                ProgramAuthoringView(repo: repo, model: model)
            } else if let loadError {
                ContentUnavailableView("Couldn't load template", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else {
                ProgressView("Loading template…")
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard model == nil else { return }
        do {
            let dsl = try await app.engine.parseTemplate(text: reference)
            model = ProgramAuthoringModel(
                engine: app.engine,
                name: name,
                template: dsl,
                units: units
            )
        } catch {
            loadError = error.localizedDescription
        }
    }
}
