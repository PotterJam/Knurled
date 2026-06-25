import Testing
import Foundation
@testable import Knurled

@Suite struct ModelDecodingTests {
    private func fixture(_ relativePath: String) throws -> Data {
        let base = try #require(SampleRepo.bundledURL)
        return try Data(contentsOf: base.appending(path: relativePath))
    }

    @Test func decodesNextWorkout() throws {
        let session = try KnurledCoding.decoder()
            .decode(RenderedSession.self, from: fixture("build/next-workout.json"))
        #expect(session.type == "rendered_session")
        #expect(session.sessionId == "a1")
        #expect(session.items.count == 3)

        let t1 = try #require(session.items.first)
        #expect(t1.display.title == "Squat T1")
        #expect(t1.progressionLane == "squat.t1")
        #expect(t1.prescription.sets.count == 5)
        #expect(t1.prescription.sets.last?.amrap == true)
        #expect(t1.executionContract.recommendedInput == "amrap_final_set")
        #expect(t1.effectPreview.pass.first?.op == "increase_load")
        #expect(t1.effectPreview.pass.first?.to == "82.5kg")
    }

    @Test func decodesState() throws {
        let state = try KnurledCoding.decoder()
            .decode(StateProjection.self, from: fixture("state/current.json"))
        #expect(state.type == "state_projection")
        #expect(state.cursor.nextSession == "a1")
        #expect(state.lanes["squat.t1"]?.load == "80kg")
        #expect(state.lanes["barbell_row.t3"]?.stage == "3x15+")
    }

    @Test func decodesValidation() throws {
        let report = try KnurledCoding.decoder()
            .decode(ValidationReport.self, from: fixture("build/validation.json"))
        #expect(report.isValid)
        #expect(report.errors.isEmpty)
    }

    @Test func executionInputRoundTripsThroughSnakeCase() throws {
        let input = ExecutionInput(
            renderedSessionHash: "sha256:abc",
            status: ExecutionStatus.complete,
            startedAt: "2026-06-24T10:10:00+01:00",
            inputs: [ItemInput(itemId: "a1.t1", mode: InputMode.amrapFinalSet, finalSetReps: 7)]
        )
        let data = try KnurledCoding.encoder().encode(input)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"rendered_session_hash\""))
        #expect(text.contains("\"final_set_reps\""))
        #expect(text.contains("\"execution_input\""))

        let decoded = try KnurledCoding.decoder().decode(ExecutionInput.self, from: data)
        #expect(decoded == input)
    }
}
