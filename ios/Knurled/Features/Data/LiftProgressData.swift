import Foundation

/// One plotted point: a lift's estimated 1RM in one workout.
struct LiftSample: Identifiable, Hashable {
    let id = UUID()
    let lift: CoreLift
    let date: Date
    let workoutIndex: Int
    let e1RMkg: Double
    /// `true` when derived from logged sets (load + reps via Epley); `false` when
    /// falling back to the current working load (no rep data, treated as e1RM floor).
    let estimated: Bool
}

/// Reconstructs per-lift estimated-1RM history for the Data tab from the training
/// log, falling back to the current state's working loads so a freshly connected
/// repo (no logs yet) still renders.
struct LiftProgressData {
    let samples: [LiftSample]

    var isEmpty: Bool { samples.isEmpty }

    /// Lifts that actually have data, in canonical `CoreLift` order.
    var lifts: [CoreLift] {
        let present = Set(samples.map(\.lift))
        return CoreLift.allCases.filter(present.contains)
    }

    var workoutIndexes: [Int] {
        Array(Set(samples.map(\.workoutIndex))).sorted()
    }

    static func build(
        events: [TrainingEvent],
        state: StateProjection?,
        units: Units,
        calendar: Calendar = .current,
        workoutLimit: Int = 12
    ) -> LiftProgressData {
        var workouts: [WorkoutSample] = []

        for (eventOrder, event) in events.enumerated() {
            guard isWorkoutEvent(event) else { continue }
            guard let date = parseDate(
                event.completedAt ?? event.savedAt ?? event.startedAt
            ) else { continue }

            var e1RMsByLift: [CoreLift: Double] = [:]

            for result in event.workoutResults {
                guard let lift = lift(from: result),
                      let top = topSet(result.actual, units: units) else { continue }
                let e1rm = OneRepMax.epley(loadKg: top.loadKg, reps: top.reps)
                e1RMsByLift[lift] = max(e1RMsByLift[lift] ?? 0, e1rm)
            }

            guard !e1RMsByLift.isEmpty else { continue }
            workouts.append(WorkoutSample(date: date, eventOrder: eventOrder, e1RMsByLift: e1RMsByLift))
        }

        let sortedWorkouts = workouts
            .sorted { lhs, rhs in
                if lhs.date == rhs.date { return lhs.eventOrder < rhs.eventOrder }
                return lhs.date < rhs.date
            }

        let loggedSamples = CoreLift.allCases.flatMap { lift in
            sortedWorkouts
                .compactMap { workout -> (date: Date, e1RMkg: Double)? in
                    guard let e1RMkg = workout.e1RMsByLift[lift] else { return nil }
                    return (workout.date, e1RMkg)
                }
                .suffix(max(1, workoutLimit))
                .enumerated()
                .map { offset, sample in
                    LiftSample(
                        lift: lift,
                        date: calendar.startOfDay(for: sample.date),
                        workoutIndex: offset + 1,
                        e1RMkg: sample.e1RMkg,
                        estimated: true
                    )
                }
            }
        if !loggedSamples.isEmpty {
            return LiftProgressData(samples: loggedSamples.sorted(by: sampleComesBefore))
        }

        var samples: [LiftSample] = []

        // Fallback: if there is no logged workout data to chart, show current
        // working loads so a freshly connected repo still renders.
        if let lanes = state?.lanes {
            let today = calendar.startOfDay(for: Date())
            for lift in CoreLift.allCases {
                guard let load = lanes["\(lift.rawValue).t1"]?.load,
                      let kg = OneRepMax.kilograms(fromLoad: load, defaultUnit: units)
                else { continue }
                samples.append(LiftSample(lift: lift, date: today, workoutIndex: 1, e1RMkg: kg, estimated: false))
            }
        }

        return LiftProgressData(samples: samples.sorted(by: sampleComesBefore))
    }

    private struct WorkoutSample {
        let date: Date
        let eventOrder: Int
        let e1RMsByLift: [CoreLift: Double]
    }

    /// The heaviest logged set (by load), with its reps. Sets without a parseable
    /// load are ignored.
    private static func topSet(_ sets: [ActualSet], units: Units) -> (loadKg: Double, reps: Int)? {
        sets
            .compactMap { set -> (loadKg: Double, reps: Int)? in
                guard let load = set.load,
                      let kg = OneRepMax.kilograms(fromLoad: load, defaultUnit: units)
                else { return nil }
                return (kg, set.reps)
            }
            .max { $0.loadKg < $1.loadKg }
    }

    private static func isWorkoutEvent(_ event: TrainingEvent) -> Bool {
        event.type == "session_completed"
            || event.type == "session_continued"
            || event.type == "session_saved"
            || event.type == "session_imported"
    }

    private static func lift(from result: ExerciseResult) -> CoreLift? {
        if let lane = result.progressionLane {
            guard lane.hasSuffix(".t1") else { return nil }
            return CoreLift.from(lane: lane)
        }
        return CoreLift.from(exercise: result.performedExercise)
            ?? CoreLift.from(exercise: result.prescribedExercise)
    }

    private static func sampleComesBefore(_ lhs: LiftSample, _ rhs: LiftSample) -> Bool {
        if lhs.workoutIndex != rhs.workoutIndex {
            return lhs.workoutIndex < rhs.workoutIndex
        }
        let lhsLiftIndex = CoreLift.allCases.firstIndex(of: lhs.lift) ?? 0
        let rhsLiftIndex = CoreLift.allCases.firstIndex(of: rhs.lift) ?? 0
        return lhsLiftIndex < rhsLiftIndex
    }

    private static func parseDate(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: iso) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: iso)
    }
}
