import Foundation

/// One plotted point: a lift's estimated 1RM on a given day.
struct LiftSample: Identifiable, Hashable {
    let id = UUID()
    let lift: CoreLift
    let date: Date
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

    static func build(
        events: [TrainingEvent],
        state: StateProjection?,
        units: Units
    ) -> LiftProgressData {
        // lift -> day -> best e1RM that day (dedupes save+complete on the same date).
        var byLiftDay: [CoreLift: [Date: Double]] = [:]

        for event in events {
            guard event.type == "session_completed"
                || event.type == "session_continued"
                || event.type == "session_saved" else { continue }
            guard let date = parseDate(
                event.completedAt ?? event.savedAt ?? event.startedAt
            ) else { continue }
            let day = Calendar.current.startOfDay(for: date)

            for result in event.results {
                guard let lane = result.progressionLane,
                      lane.hasSuffix(".t1"),
                      let lift = CoreLift.from(lane: lane),
                      let top = topSet(result.actual, units: units) else { continue }
                let e1rm = OneRepMax.epley(loadKg: top.loadKg, reps: top.reps)
                byLiftDay[lift, default: [:]][day] = max(byLiftDay[lift]?[day] ?? 0, e1rm)
            }
        }

        var samples = byLiftDay.flatMap { lift, days in
            days.map { LiftSample(lift: lift, date: $0.key, e1RMkg: $0.value, estimated: true) }
        }

        // Fallback: lifts with no logged history get a single "today" point from the
        // current working load so the chart isn't empty for a fresh repo.
        if let lanes = state?.lanes {
            let today = Calendar.current.startOfDay(for: Date())
            for lift in CoreLift.allCases where byLiftDay[lift] == nil {
                guard let load = lanes["\(lift.rawValue).t1"]?.load,
                      let kg = OneRepMax.kilograms(fromLoad: load, defaultUnit: units)
                else { continue }
                samples.append(LiftSample(lift: lift, date: today, e1RMkg: kg, estimated: false))
            }
        }

        return LiftProgressData(samples: samples.sorted { $0.date < $1.date })
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
