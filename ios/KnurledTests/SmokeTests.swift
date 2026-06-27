import Testing
import Foundation
@testable import Knurled

@Suite struct SmokeTests {
    @Test func appTabsAreDistinct() {
        #expect(AppTab.workout != AppTab.history)
    }

    @Test func historyBuilderKeepsWorkoutRecordForDetailNavigation() {
        let record = TrainingRecord(
            id: "workout-1",
            date: "2026-06-24",
            sessionId: "a1",
            startedAt: "2026-06-24T10:00:00Z",
            completedAt: "2026-06-24T11:00:00Z",
            lifts: [
                LiftRecord(liftId: "squat-1", exercise: "squat", weight: "80kg", sets: [5, 5, 7]),
                LiftRecord(liftId: "bench-1", exercise: "bench_press", weight: "55kg", sets: [10, 10, 10]),
            ]
        )

        let item = HistoryBuilder.items(from: [record]).first

        #expect(item?.id == "workout-1")
        #expect(item?.kind == .workout)
        #expect(item?.record == record)
        #expect(item?.title == "A1")
    }

    @Test func historyBuilderLabelsContinuablePartial() {
        let record = TrainingRecord(
            id: "partial-1",
            date: "2026-06-24",
            status: ExecutionStatus.partial,
            sessionId: "a1",
            startedAt: "2026-06-24T10:00:00Z",
            savedAt: "2026-06-24T10:30:00Z",
            lifts: [
                LiftRecord(liftId: "squat-1", itemId: "a1.t1", exercise: "squat", weight: "80kg", sets: [5]),
            ]
        )

        let item = HistoryBuilder.items(from: [record]).first

        #expect(item?.status == "Partial")
        #expect(item?.canContinue == true)
    }

    @Test func programMarkerDecodesWithoutLifts() throws {
        let json = #"{"id":"program-1","revision":1,"kind":"program_marker","date":"2026-06-24","program":"gzcl.gzclp"}"#
        let record = try KnurledCoding.decoder().decode(TrainingRecord.self, from: Data(json.utf8))

        #expect(record.kind == .programMarker)
        #expect(record.lifts.isEmpty)
    }
}

@Suite struct LoadEditDraftTests {
    @Test func startsWithCapturedBaselineAndEmptyDestination() {
        let draft = LoadEditDraft(baselineText: "82.5kg")

        #expect(draft.baselineText == "82.5kg")
        #expect(draft.destinationText.isEmpty)
    }

    @Test func typingDestinationDoesNotReplaceBaseline() {
        var draft = LoadEditDraft(baselineText: "82.5kg")

        draft.destinationText = "85"

        #expect(draft.baselineText == "82.5kg")
        #expect(draft.destinationText == "85")
    }
}

@Suite struct RPEColorScaleTests {
    @Test func mapsEffortFromGreenThroughYellowToRed() {
        #expect(RPEColorScale.hex(for: 1) == 0x006837)
        #expect(RPEColorScale.hex(for: 5.5) == 0xFFFFBF)
        #expect(RPEColorScale.hex(for: 9) == 0xD73027)
        #expect(RPEColorScale.hex(for: 10) == 0xA50026)
    }

    @Test func clampsValuesToScaleEndpoints() {
        #expect(RPEColorScale.hex(for: -1) == RPEColorScale.hex(for: 1))
        #expect(RPEColorScale.hex(for: 12) == RPEColorScale.hex(for: 10))
    }
}
