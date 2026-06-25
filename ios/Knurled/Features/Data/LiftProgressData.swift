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
        records: [DayRecord],
        state: StateProjection?,
        units: Units,
        calendar: Calendar = .current,
        workoutLimit: Int = 12
    ) -> LiftProgressData {
        var workouts: [WorkoutSample] = []

        for (recordOrder, record) in records.enumerated() {
            guard !record.lifts.isEmpty, let date = parseDate(record.date) else { continue }

            var e1RMsByLift: [CoreLift: Double] = [:]

            for liftRecord in record.lifts {
                guard let lift = CoreLift.from(exercise: liftRecord.exercise),
                      let top = topSet(liftRecord, units: units) else { continue }
                let e1rm = OneRepMax.epley(loadKg: top.loadKg, reps: top.reps)
                e1RMsByLift[lift] = max(e1RMsByLift[lift] ?? 0, e1rm)
            }

            guard !e1RMsByLift.isEmpty else { continue }
            workouts.append(WorkoutSample(date: date, recordOrder: recordOrder, e1RMsByLift: e1RMsByLift))
        }

        let sortedWorkouts = workouts
            .sorted { lhs, rhs in
                if lhs.date == rhs.date { return lhs.recordOrder < rhs.recordOrder }
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
        let recordOrder: Int
        let e1RMsByLift: [CoreLift: Double]
    }

    /// The heaviest logged set (by load), with its reps. Sets without a parseable
    /// load are ignored.
    private static func topSet(_ lift: LiftRecord, units: Units) -> (loadKg: Double, reps: Int)? {
        guard let load = lift.weight,
              let kg = OneRepMax.kilograms(fromLoad: load, defaultUnit: units)
        else { return nil }
        return lift.sets
            .map { (loadKg: kg, reps: $0) }
            .max { $0.reps < $1.reps }
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
        if iso.count == 10 {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: iso)
        }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: iso) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: iso)
    }
}
