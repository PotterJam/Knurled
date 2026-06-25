import Foundation

extension AppModel {
    @discardableResult
    func submit(
        session: RenderedSession,
        input: ExecutionInput,
        mode: SubmitMode,
        in repo: ActiveRepo,
        timestamp: String
    ) async throws -> SubmitOutcome {
        let date = String(timestamp.prefix(10))
        let outcome = try await engine.submit(
            dir: repo.url,
            session: session,
            input: input,
            mode: mode,
            date: date
        )
        guard outcome.validation.isValid else { return outcome }

        await repo.refresh(engine: engine)
        await pushIfConnected(
            repo: repo,
            message: Self.commitMessage(session: session, mode: mode, date: date)
        )
        persistSelection()
        return outcome
    }

    static func commitMessage(session: RenderedSession, mode: SubmitMode, date: String) -> String {
        "\(mode.commitVerb) \(session.sessionId.uppercased()) - \(date)"
    }
}
