import SwiftUI

/// Re-renders the session a draft belongs to (by its session id) and hands it to
/// `ActiveWorkoutView` to resume. Used when the saved draft is for a different session than
/// today's next workout, so the live view always builds against a freshly rendered session.
struct ResumeWorkoutView: View {
    let repo: ActiveRepo
    let draft: WorkoutDraft

    @Environment(AppModel.self) private var app
    @State private var phase: Phase = .loading

    private enum Phase {
        case loading
        case loaded(RenderedSession)
        case failed(String)
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView("Loading workout…")
            case .loaded(let session):
                ActiveWorkoutView(repo: repo, session: session, draft: draft)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't continue", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard case .loading = phase else { return }
        do {
            phase = .loaded(try await app.engine.renderSession(dir: repo.url, sessionId: draft.sessionId))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
