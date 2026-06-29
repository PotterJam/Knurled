import Testing
import Foundation
@testable import Knurled

@Suite struct ProgramAuthoringTests {
    @Test func forksBuiltinAndRendersBackToAnEquivalentTemplate() async throws {
        let engine = RustWorkoutEngine()

        // A built-in reference is vendored + parsed into the editable model.
        let dsl = try await engine.parseTemplate(text: "gzcl.gzclp@1.0.0")
        #expect(dsl.lanes.count == 9)
        #expect(dsl.rotation == ["a1", "b1", "a2", "b2"])

        // Rendering the model back to text and re-parsing is a fixed point.
        let text = try await engine.renderTemplate(dsl: dsl)
        let reparsed = try await engine.parseTemplate(text: text)
        #expect(reparsed == dsl)
    }

    @Test func dslTemplateJsonRoundTripsThroughTheSharedCoders() throws {
        let dsl = DslTemplate(
            name: "Mini",
            rotation: ["day"],
            restSeconds: 90,
            sessionDisplayNames: ["day": "Day"],
            sessions: ["day": [DslSessionItem(lane: "squat.main", slotId: "day.squat")]],
            lanes: [
                "squat.main": DslLane(
                    exercise: "squat",
                    tier: "main",
                    basis: .trainingMax,
                    initial: .percent(80),
                    sequence: .waves,
                    stages: [DslStage(id: "w1", groups: [DslSetGroup(count: 1, reps: 5, intensity: 85, amrap: true)])],
                    rules: [DslRule(trigger: .amrapGte(reps: 5), effects: [.increaseLoad(amount: "2.5"), .advanceStage])]
                )
            ]
        )
        let data = try KnurledCoding.encoder().encode(dsl)
        let decoded = try KnurledCoding.decoder().decode(DslTemplate.self, from: data)
        #expect(decoded == dsl)
    }

    @Test func previewSurfacesValidationAndAFirstWorkout() async throws {
        let engine = RustWorkoutEngine()
        let dsl = try await engine.parseTemplate(text: "gzcl.gzclp@1.0.0")

        // Without starting numbers the candidate is invalid and previews nothing.
        let missing = try await engine.previewTemplate(request: PreviewTemplateRequest(dsl: dsl))
        #expect(missing.validation.status == .invalid)
        #expect(missing.preview == nil)

        // With them, the engine returns a valid first session.
        let request = PreviewTemplateRequest(
            dsl: dsl,
            units: .kg,
            initialNumbers: ["squat": "100kg", "bench": "60kg", "press": "40kg", "deadlift": "140kg"]
        )
        let preview = try await engine.previewTemplate(request: request)
        #expect(preview.validation.status == .valid)
        let session = try #require(preview.preview)
        #expect(session.sessionId == "a1")
        #expect(!session.items.isEmpty)
    }

    @Test func blankStarterModelRendersAndPreviews() async throws {
        let engine = RustWorkoutEngine()
        let model = await ProgramAuthoringModel.blank(engine: engine, name: "Fresh")
        await MainActor.run { model.initialNumbers["squat"] = "100" }
        await model.refreshPreview()
        let valid = await model.isValid
        #expect(valid)
    }
}
