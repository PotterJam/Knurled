import Foundation

extension AppModel {
    @discardableResult
    func amendRecord(
        _ record: TrainingRecord,
        amendment: RecordAmendment,
        in repo: ActiveRepo,
        timestamp: String = LiveWorkout.timestamp()
    ) async throws -> AmendRecordOutcome {
        let outcome = try await engine.amendRecord(
            dir: repo.url,
            request: AmendRecordRequest(
                recordId: record.id,
                expectedRevision: record.revision,
                updatedAt: timestamp,
                amendment: amendment
            )
        )
        await repo.refresh(engine: engine)
        await pushIfConnected(
            repo: repo,
            message: "Amend workout - \(record.date)",
            files: outcome.changedFiles
        )
        return outcome
    }
}
