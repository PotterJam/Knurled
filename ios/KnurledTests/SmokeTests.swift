import Testing
@testable import Knurled

@Suite struct SmokeTests {
    @Test func appTabsAreDistinct() {
        #expect(AppTab.workout != AppTab.history)
    }

    @Test func historyBuilderKeepsWorkoutRecordForDetailNavigation() {
        let record = DayRecord(
            date: "2026-06-24",
            lifts: [
                LiftRecord(exercise: "squat", weight: "80kg", sets: [5, 5, 7]),
                LiftRecord(exercise: "bench_press", weight: "55kg", sets: [10, 10, 10]),
            ]
        )

        let item = HistoryBuilder.items(from: [record]).first

        #expect(item?.id == "2026-06-24")
        #expect(item?.kind == .workout)
        #expect(item?.record == record)
        #expect(item?.title == "2 lifts")
    }

    @Test func historyBuilderLabelsContinuablePartial() {
        let record = DayRecord(
            date: "2026-06-24",
            status: ExecutionStatus.partial,
            sessionId: "a1",
            lifts: [
                LiftRecord(itemId: "a1.t1", exercise: "squat", weight: "80kg", sets: [5]),
            ]
        )

        let item = HistoryBuilder.items(from: [record]).first

        #expect(item?.status == "Partial")
        #expect(item?.canContinue == true)
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
