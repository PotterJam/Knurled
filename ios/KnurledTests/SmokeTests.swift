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
