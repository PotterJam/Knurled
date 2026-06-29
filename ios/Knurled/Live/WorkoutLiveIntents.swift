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
/// the set is logged by typing reps in the app rather than stepping values on the lock screen.
struct EditRepsIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Log set"
    static var openAppWhenRun: Bool = true

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

