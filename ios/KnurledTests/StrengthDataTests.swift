import Testing
import Foundation
@testable import Knurled

@Suite struct StrengthDataTests {
    // MARK: - Estimated 1RM (Epley)

    @Test func epleyReturnsLoadAtOneRep() {
        #expect(OneRepMax.epley(loadKg: 100, reps: 1) == 100)
    }

    @Test func epleyScalesWithReps() {
        // 100 * (1 + 5/30) = 116.666…
        #expect(abs(OneRepMax.epley(loadKg: 100, reps: 5) - 116.6667) < 0.001)
    }

    // MARK: - Load parsing

    @Test func parsesKgAndLbSuffixes() {
        #expect(OneRepMax.kilograms(fromLoad: "55kg", defaultUnit: .kg) == 55)
        #expect(abs((OneRepMax.kilograms(fromLoad: "100lb", defaultUnit: .kg) ?? 0) - 45.359237) < 0.0001)
    }

    @Test func bareNumberUsesDefaultUnit() {
        #expect(OneRepMax.kilograms(fromLoad: "80", defaultUnit: .kg) == 80)
        #expect(abs((OneRepMax.kilograms(fromLoad: "80", defaultUnit: .lb) ?? 0) - 36.287) < 0.001)
    }

    @Test func rejectsGarbage() {
        #expect(OneRepMax.kilograms(fromLoad: "heavy", defaultUnit: .kg) == nil)
        #expect(OneRepMax.kilograms(fromLoad: "", defaultUnit: .kg) == nil)
    }

    // MARK: - Level mapping

    @Test func strengthLevelLabelsKeepExistingThresholdValues() {
        #expect(StrengthLevel.allCases.map(\.title) == [
            "Beginner",
            "Novice",
            "Intermediate",
            "Advanced",
            "Elite",
        ])
        #expect(StrengthLevel.allCases.map(\.value) == [1, 2, 3, 4, 5])
    }

    @Test func beginnerThresholdLandsOnLevelOne() {
        // Male squat beginner multiple is 1.25 -> ratio 1.25 maps to level 1.0.
        let v = StrengthStandards.levelValue(ratio: 1.25, lift: .squat, sex: .male)
        #expect(abs(v - 1.0) < 0.0001)
    }

    @Test func advancedThresholdLandsOnLevelFour() {
        let v = StrengthStandards.levelValue(ratio: 2.75, lift: .squat, sex: .male)
        #expect(abs(v - 4.0) < 0.0001)
    }

    @Test func levelIsMonotonic() {
        let low = StrengthStandards.levelValue(ratio: 1.0, lift: .bench, sex: .male)
        let high = StrengthStandards.levelValue(ratio: 1.6, lift: .bench, sex: .male)
        #expect(high > low)
    }

    @Test func sexChangesLevelForSameRatio() {
        // Female standards are lower, so the same ratio reads as a higher level.
        let ratio = 1.0
        let male = StrengthStandards.levelValue(ratio: ratio, lift: .bench, sex: .male)
        let female = StrengthStandards.levelValue(ratio: ratio, lift: .bench, sex: .female)
        #expect(female > male)
        #expect(abs(female - male) > 0.1) // a substantial shift, not cosmetic
    }

    // MARK: - Lane → lift mapping

    @Test func mapsLanePrefixToLift() {
        #expect(CoreLift.from(lane: "squat.t1") == .squat)
        #expect(CoreLift.from(lane: "press.t2") == .press)
        #expect(CoreLift.from(lane: "barbell_row.t3") == nil)
    }

    @Test func mapsImportedExerciseNamesToLift() {
        #expect(CoreLift.from(exercise: "Bench Press") == .bench)
        #expect(CoreLift.from(exercise: "overhead_press") == .press)
        #expect(CoreLift.from(exercise: "barbell row") == nil)
    }

    // MARK: - Progress reconstruction

    @Test func emptyInputsProduceNoSamples() {
        let data = LiftProgressData.build(records: [], state: nil, units: .kg)
        #expect(data.isEmpty)
    }

    @Test func fallsBackToCurrentWorkingLoads() throws {
        let json = """
        {
          "type": "state_projection",
          "schema_version": "0.1",
          "engine_version": "0.1.0",
          "program_hash": "sha256:abc",
          "last_event_id": null,
          "cursor": { "next_session": "a1", "week": 1, "cycle": 1 },
          "lanes": {
            "squat.t1": { "load": "80kg", "stage": "5x3+" },
            "bench.t1": { "load": "55kg", "stage": "5x3+" }
          },
          "sessions": {}
        }
        """
        let state = try KnurledCoding.decoder().decode(StateProjection.self, from: Data(json.utf8))
        let data = LiftProgressData.build(records: [], state: state, units: .kg)

        #expect(Set(data.lifts) == [.squat, .bench])
        let squat = try #require(data.samples.first { $0.lift == .squat })
        #expect(squat.e1RMkg == 80)
        #expect(squat.estimated == false)
    }

    @Test func importedWorkoutsFeedLastTwelveSamplesEvenOnSameDay() throws {
        let records = (0..<13).map { index in
            Self.record(
                exercise: "Squat",
                load: "\(100 + index)kg",
                date: "2026-06-20"
            )
        }

        let data = LiftProgressData.build(
            records: records,
            state: nil,
            units: .kg,
            calendar: Self.utcCalendar
        )

        #expect(data.samples.count == 12)
        #expect(data.samples.allSatisfy { $0.estimated })
        #expect(data.workoutIndexes == Array(1...12))
        #expect(data.samples.allSatisfy { $0.lift == .squat })
        #expect(abs(data.samples[0].e1RMkg - 117.8333) < 0.001)
        #expect(abs(data.samples[11].e1RMkg - 130.6667) < 0.001)
    }

    @Test func importedHistoricalLiftIsNotDroppedByNewerOtherLiftWorkouts() throws {
        let importedSquat = Self.record(
            exercise: "Squat",
            load: "100kg",
            date: "2026-01-01"
        )
        let newerBenchRecords = (0..<12).map { index in
            Self.record(
                exercise: "Bench Press",
                load: "\(70 + index)kg",
                date: "2026-02-\(String(format: "%02d", index + 1))"
            )
        }

        let data = LiftProgressData.build(
            records: [importedSquat] + newerBenchRecords,
            state: nil,
            units: .kg,
            calendar: Self.utcCalendar
        )

        #expect(data.samples.contains { $0.lift == .squat })
        #expect(data.samples.filter { $0.lift == .bench }.count == 12)
    }

    @Test func recentLoggedSamplesSuppressCurrentLoadFallback() throws {
        let stateJSON = """
        {
          "type": "state_projection",
          "schema_version": "0.1",
          "engine_version": "0.1.0",
          "program_hash": "sha256:abc",
          "last_event_id": null,
          "cursor": { "next_session": "a1", "week": 1, "cycle": 1 },
          "lanes": {
            "squat.t1": { "load": "80kg", "stage": "5x3+" },
            "bench.t1": { "load": "55kg", "stage": "5x3+" }
          },
          "sessions": {}
        }
        """
        let state = try KnurledCoding.decoder().decode(StateProjection.self, from: Data(stateJSON.utf8))
        let record = Self.record(
            exercise: "Squat",
            load: "100kg",
            date: "2026-06-20"
        )

        let data = LiftProgressData.build(
            records: [record],
            state: state,
            units: .kg,
            calendar: Self.utcCalendar
        )

        #expect(data.samples.count == 1)
        #expect(data.samples.first?.lift == .squat)
        #expect(data.samples.first?.workoutIndex == 1)
        #expect(data.samples.first?.estimated == true)
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func record(
        exercise: String,
        load: String,
        date: String
    ) -> TrainingRecord {
        TrainingRecord(
            id: "\(date)-\(exercise)",
            date: date,
            sessionId: "history",
            startedAt: "\(date)T10:00:00Z",
            completedAt: "\(date)T11:00:00Z",
            program: nil,
            note: nil,
            lifts: [
                LiftRecord(
                    liftId: "\(date)-\(exercise)-lift",
                    exercise: exercise,
                    weight: load,
                    sets: [5],
                    metrics: [:],
                    note: nil
                ),
            ]
        )
    }
}
