import Testing
import Foundation
@testable import Knurled

@MainActor
@Suite struct SubmitTests {
    @Test func advanceSubmitWritesRecordAndProgressesState() async throws {
        let (dir, repo, app, session, input) = try await Self.fixture()
        defer { try? FileManager.default.removeItem(at: dir) }

        let outcome = try await app.submit(
            session: session,
            input: input,
            mode: SubmitMode.advance,
            in: repo,
            timestamp: "2026-06-24T11:00:00Z"
        )

        #expect(outcome.validation.isValid)
        #expect(repo.records.contains { $0.date == "2026-06-24" && !$0.lifts.isEmpty })
        #expect(repo.state?.lanes["squat.t1"]?.load == "82.5kg")

        let month = try KnurledCoding.decoder().decode(
            LogMonth.self,
            from: Data(contentsOf: dir.appending(path: "logs/2026/06.json"))
        )
        #expect(month.days.first?.lifts.first?.exercise == "squat")
    }

    @Test func offDaySubmitRecordsButLeavesLanesUntouched() async throws {
        let (dir, repo, app, session, input) = try await Self.fixture()
        defer { try? FileManager.default.removeItem(at: dir) }

        let before = repo.state?.lanes["squat.t1"]?.load
        let outcome = try await app.submit(
            session: session,
            input: input,
            mode: SubmitMode.offDay,
            in: repo,
            timestamp: "2026-06-24T11:00:00Z"
        )

        #expect(outcome.validation.isValid)
        #expect(repo.records.contains { $0.date == "2026-06-24" })
        #expect(repo.state?.lanes["squat.t1"]?.load == before)
        #expect(repo.state?.cursor.nextSession != "a1")
    }

    @Test func resetSubmitUsesPerformedLoadsAsBaseline() async throws {
        let (dir, repo, app, session, _) = try await Self.fixture()
        defer { try? FileManager.default.removeItem(at: dir) }

        let input = ExecutionInput(
            renderedSessionHash: session.renderedSessionHash,
            status: ExecutionStatus.complete,
            startedAt: "2026-06-24T10:00:00Z",
            completedAt: "2026-06-24T11:00:00Z",
            inputs: session.items.map { item in
                if item.itemId == "a1.t1" {
                    return ItemInput(
                        itemId: item.itemId,
                        mode: InputMode.amrapFinalSet,
                        finalSetReps: 5,
                        load: "70kg"
                    )
                }
                return Self.passingInput(for: item)
            }
        )

        let outcome = try await app.submit(
            session: session,
            input: input,
            mode: SubmitMode.reset,
            in: repo,
            timestamp: "2026-06-24T11:00:00Z"
        )

        #expect(outcome.validation.isValid)
        #expect(repo.state?.lanes["squat.t1"]?.load == "70kg")
        #expect(outcome.effects.contains { $0.op == "reset_load" && $0.to == "70kg" })
    }

    @Test func partialSubmitWritesResumeMetadataWithoutProgressingState() async throws {
        let (dir, repo, app, session, _) = try await Self.fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try #require(session.items.first)
        let beforeLoad = repo.state?.lanes["squat.t1"]?.load
        let input = ExecutionInput(
            renderedSessionHash: session.renderedSessionHash,
            status: ExecutionStatus.partial,
            startedAt: "2026-06-24T10:00:00Z",
            savedAt: "2026-06-24T10:45:00Z",
            inputs: [
                ItemInput(
                    itemId: first.itemId,
                    mode: InputMode.perSetReps,
                    sets: [
                        ActualSet(set: 1, load: first.prescription.sets.first?.load, reps: 5),
                    ]
                ),
            ]
        )

        let outcome = try await app.submit(
            session: session,
            input: input,
            mode: SubmitMode.advance,
            in: repo,
            timestamp: "2026-06-24T10:45:00Z"
        )

        #expect(outcome.validation.isValid)
        #expect(outcome.recordDay.status == ExecutionStatus.partial)
        #expect(outcome.recordDay.sessionId == session.sessionId)
        #expect(outcome.recordDay.lifts.first?.itemId == first.itemId)
        #expect(repo.state?.lanes["squat.t1"]?.load == beforeLoad)
        #expect(repo.state?.cursor.nextSession == session.sessionId)
    }

    @Test func twoSessionsOnSameDateAreKeptAsSeparateRecords() async throws {
        let (dir, repo, app, sessionA, inputA) = try await Self.fixture()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Complete the first session on 2026-06-24.
        _ = try await app.submit(
            session: sessionA, input: inputA, mode: SubmitMode.advance,
            in: repo, timestamp: "2026-06-24T11:00:00Z"
        )

        // Complete the next session on the *same* date.
        let sessionB = try #require(repo.nextWorkout)
        #expect(sessionB.sessionId != sessionA.sessionId)
        let inputB = ExecutionInput(
            renderedSessionHash: sessionB.renderedSessionHash,
            status: ExecutionStatus.complete,
            startedAt: "2026-06-24T17:00:00Z",
            completedAt: "2026-06-24T18:00:00Z",
            inputs: sessionB.items.map(Self.passingInput)
        )
        _ = try await app.submit(
            session: sessionB, input: inputB, mode: SubmitMode.advance,
            in: repo, timestamp: "2026-06-24T18:00:00Z"
        )

        // Both sessions survive: the second must not overwrite the first.
        let onDate = repo.records.filter { $0.date == "2026-06-24" }
        #expect(onDate.count == 2)
        #expect(Set(onDate.compactMap(\.sessionId)) == [sessionA.sessionId, sessionB.sessionId])
    }

    @Test func continuingPartialReplacesItInPlaceAndProgresses() async throws {
        let (dir, repo, app, session, _) = try await Self.fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try #require(session.items.first)

        // Save a partial of the current session.
        let partial = ExecutionInput(
            renderedSessionHash: session.renderedSessionHash,
            status: ExecutionStatus.partial,
            startedAt: "2026-06-24T10:00:00Z",
            savedAt: "2026-06-24T10:45:00Z",
            inputs: [
                ItemInput(
                    itemId: first.itemId,
                    mode: InputMode.perSetReps,
                    sets: [ActualSet(set: 1, load: first.prescription.sets.first?.load, reps: 5)]
                ),
            ]
        )
        _ = try await app.submit(
            session: session, input: partial, mode: SubmitMode.advance,
            in: repo, timestamp: "2026-06-24T10:45:00Z"
        )
        #expect(repo.records.filter { $0.sessionId == session.sessionId }.count == 1)
        #expect(repo.state?.cursor.nextSession == session.sessionId)

        // Continue from history: re-render that session and complete it, landing
        // on the partial's date (as LiveWorkout does for a restored workout).
        let resumed = try await app.engine.renderSession(dir: repo.url, sessionId: session.sessionId)
        let complete = ExecutionInput(
            renderedSessionHash: resumed.renderedSessionHash,
            status: ExecutionStatus.complete,
            startedAt: "2026-06-24T10:45:00Z",
            completedAt: "2026-06-24T11:30:00Z",
            inputs: resumed.items.map(Self.passingInput)
        )
        _ = try await app.submit(
            session: resumed, input: complete, mode: SubmitMode.advance,
            in: repo, timestamp: "2026-06-24T11:30:00Z"
        )

        // The partial became a single completed record — not a duplicate — and
        // the cursor advanced to the next workout.
        let forSession = repo.records.filter { $0.sessionId == session.sessionId }
        #expect(forSession.count == 1)
        #expect(forSession.first?.status == nil)
        #expect(repo.state?.cursor.nextSession != session.sessionId)
    }

    private static func fixture() async throws -> (
        dir: URL,
        repo: ActiveRepo,
        app: AppModel,
        session: RenderedSession,
        input: ExecutionInput
    ) {
        let dir = try SampleRepo.makeWorkingCopy()
        let app = AppModel()
        let repo = ActiveRepo(displayName: "sample", url: dir, isSample: true)
        await repo.refresh(engine: app.engine)
        let session = try #require(repo.nextWorkout)
        let input = ExecutionInput(
            renderedSessionHash: session.renderedSessionHash,
            status: ExecutionStatus.complete,
            startedAt: "2026-06-24T10:00:00Z",
            completedAt: "2026-06-24T11:00:00Z",
            inputs: session.items.map(passingInput)
        )
        return (dir, repo, app, session, input)
    }

    private static func passingInput(for item: RenderedItem) -> ItemInput {
        if item.executionContract.recommendedInput == InputMode.amrapFinalSet {
            let target = item.prescription.sets.last?.targetReps ?? 1
            return ItemInput(itemId: item.itemId, mode: InputMode.amrapFinalSet, finalSetReps: target)
        }
        let sets = item.prescription.sets.map { ActualSet(set: $0.set, load: $0.load, reps: $0.targetReps) }
        return ItemInput(itemId: item.itemId, mode: InputMode.perSetReps, sets: sets)
    }
}
