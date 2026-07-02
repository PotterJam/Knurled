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
        #expect(repo.state?.lanes["squat.t1"]?.load == "85kg")

        let records = try await app.engine.records(dir: dir)
        #expect(records.first?.lifts.first?.exercise == "squat")
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

    @Test func shorterWorkoutIsFinalizedWithoutProgressingIncompleteExercise() async throws {
        let (dir, repo, app, session, _) = try await Self.fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try #require(session.items.first)
        let beforeLoad = repo.state?.lanes["squat.t1"]?.load
        let input = ExecutionInput(
            renderedSessionHash: session.renderedSessionHash,
            startedAt: "2026-06-24T10:00:00Z",
            completedAt: "2026-06-24T10:45:00Z",
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
        #expect(outcome.record.completedAt == "2026-06-24T10:45:00Z")
        #expect(outcome.record.sessionId == session.sessionId)
        #expect(outcome.record.lifts.first?.itemId == first.itemId)
        #expect(repo.state?.lanes["squat.t1"]?.load == beforeLoad)
        #expect(repo.state?.cursor.nextSession != session.sessionId)
    }

    @Test func sameDaySubmissionsProduceDistinctHistoryRows() async throws {
        let (dir, repo, app, session, input) = try await Self.fixture()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try await app.submit(
            session: session,
            input: input,
            mode: .advance,
            in: repo,
            timestamp: "2026-06-24T11:00:00Z"
        )
        let next = try #require(repo.nextWorkout)
        let second = ExecutionInput(
            renderedSessionHash: next.renderedSessionHash,
            startedAt: "2026-06-24T14:00:00Z",
            completedAt: "2026-06-24T15:00:00Z",
            inputs: next.items.map(Self.passingInput)
        )
        _ = try await app.submit(
            session: next,
            input: second,
            mode: .advance,
            in: repo,
            timestamp: "2026-06-24T15:00:00Z"
        )

        #expect(repo.records.count == 2)
        #expect(Set(repo.records.map(\.id)).count == 2)
        #expect(HistoryBuilder.items(from: repo.records).count == 2)
    }

    @Test func amendmentChangesHistoryWithoutChangingState() async throws {
        let (dir, repo, app, session, input) = try await Self.fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await app.submit(
            session: session,
            input: input,
            mode: .advance,
            in: repo,
            timestamp: "2026-06-24T11:00:00Z"
        )
        let record = try #require(repo.records.first)
        let lift = try #require(record.lifts.first)
        let stateBefore = try Data(contentsOf: dir.appending(path: "state/current.json"))

        let outcome = try await app.amendRecord(
            record,
            amendment: .addSet(liftId: lift.liftId, load: lift.weight, reps: 8, metrics: ["rpe": "9"]),
            in: repo,
            timestamp: "2026-06-24T18:00:00Z"
        )

        #expect(outcome.record.revision == 2)
        #expect(repo.records.first?.revision == 2)
        #expect(try Data(contentsOf: dir.appending(path: "state/current.json")) == stateBefore)

        let addedExercise = try await app.amendRecord(
            outcome.record,
            amendment: .addExercise(
                exercise: "curl",
                weight: "20kg",
                note: nil,
                sets: [ActualSet(set: 1, load: "20kg", reps: 12)]
            ),
            in: repo,
            timestamp: "2026-06-24T18:05:00Z"
        )
        #expect(addedExercise.record.revision == 3)
        #expect(addedExercise.record.lifts.last?.exercise == "curl")
        #expect(try Data(contentsOf: dir.appending(path: "state/current.json")) == stateBefore)
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
        let repo = ActiveRepo(displayName: "sample", url: dir)
        await repo.refresh(engine: app.engine)
        let session = try #require(repo.nextWorkout)
        let input = ExecutionInput(
            renderedSessionHash: session.renderedSessionHash,
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
