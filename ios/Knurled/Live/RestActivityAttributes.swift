import ActivityKit
import Foundation

/// Shared between the app (which starts/updates the activity) and the
/// KnurledRestActivity widget extension (which renders it).
struct RestActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var endDate: Date
        var exerciseTitle: String
    }

    var workoutName: String
}
