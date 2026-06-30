import AppIntents

// These LiveActivityIntents are compiled into both the app and the widget extension so the
// widget can construct the buttons. Their `perform()` runs in the app process, where the
// shared WorkoutLiveController lives — guarded by KNURLED_APP so the extension build (which
// has no access to app-only types) still compiles.

struct LogSetIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Log set"

    func perform() async throws -> some IntentResult {
        #if KNURLED_APP
        await WorkoutLiveController.shared.logCurrentSet()
        #endif
        return .result()
    }
}

struct SkipRestIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Skip rest"

    func perform() async throws -> some IntentResult {
        #if KNURLED_APP
        await WorkoutLiveController.shared.skipRest()
        #endif
        return .result()
    }
}

struct AddRestIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Add 30 seconds"

    func perform() async throws -> some IntentResult {
        #if KNURLED_APP
        await WorkoutLiveController.shared.addRest(30)
        #endif
        return .result()
    }
}

/// Opens the app and asks the workout screen to bring up the reps editor on the current set, so
/// the set is logged by dialling reps on the wheel in the app. Raised by tapping the reps readout
/// on the Live Activity, and by the "Log" action for sets that can't be logged at a fixed number
/// (AMRAP, or a weighted set still missing its load).
struct EditRepsIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Edit reps"
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        #if KNURLED_APP
        await WorkoutLiveController.shared.requestRepsEdit()
        #endif
        return .result()
    }
}

struct SkipWarmupIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Skip warm-up"

    func perform() async throws -> some IntentResult {
        #if KNURLED_APP
        await WorkoutLiveController.shared.skipWarmup()
        #endif
        return .result()
    }
}
