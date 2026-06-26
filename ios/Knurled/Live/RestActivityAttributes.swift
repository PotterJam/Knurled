import ActivityKit
import Foundation

/// Shared between the app (which starts/updates/advances the activity through
/// `WorkoutLiveController`) and the KnurledRestActivity widget extension (which renders it
/// and fires the interactive intents).
struct RestActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// What the activity is currently asking the user to do.
        enum Phase: Int, Codable, Hashable {
            case ready     // a set is staged, waiting to be logged
            case resting   // counting down between sets
            case finished  // every set logged
        }

        var phase: Phase
        var exerciseTitle: String
        var exerciseIndex: Int   // 1-based position of the current exercise
        var totalExercises: Int
        var setNumber: Int       // 1-based set within the exercise (warmup or working)
        var totalSets: Int
        var targetReps: Int
        var loadText: String?
        var isWarmup: Bool       // the current set is a ramp-up rather than a working set
        var isAmrap: Bool
        var amrapReps: Int       // staged rep count for an AMRAP final set
        var restEndDate: Date    // meaningful while `phase == .resting`

        var exerciseProgress: String { "Exercise \(exerciseIndex) of \(totalExercises)" }
        var loadReps: String {
            let reps = isAmrap ? "\(targetReps)+" : "\(targetReps)"
            guard let loadText else { return "x \(reps)" }
            return "\(loadText) x \(reps)"
        }
        var compactSetLine: String {
            let prefix = isWarmup ? "W " : ""
            return "\(prefix)\(loadReps)"
        }
    }

    var workoutName: String
}
