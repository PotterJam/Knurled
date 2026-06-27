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
        let date = String((input.startedAt ?? timestamp).prefix(10))
        let outcome = try await engine.submit(
            dir: repo.url,
            session: session,
            input: input,
            mode: mode,
            date: date
        )
        guard outcome.validation.isValid else { return outcome }

        await repo.refresh(engine: engine)
        if !outcome.changedFiles.isEmpty {
            await pushIfConnected(
                repo: repo,
                message: Self.commitMessage(session: session, mode: mode, status: input.status, date: date),
                files: outcome.changedFiles
            )
        }
        persistSelection()
        return outcome
    }

    static func commitMessage(
        session: RenderedSession,
        mode: SubmitMode,
        status: String = ExecutionStatus.complete,
        date: String
    ) -> String {
        let verb = status == ExecutionStatus.partial ? "Save progress" : mode.commitVerb
        return "\(verb) \(session.sessionId.uppercased()) - \(date)"
    }
}
