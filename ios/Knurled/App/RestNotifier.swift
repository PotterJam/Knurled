import Foundation
import UserNotifications

/// Schedules the local notification that fires when a rest countdown elapses, so the user gets a
/// buzz and banner even when Knurled is backgrounded and only the Live Activity is on screen.
/// There is at most one pending rest notification at a time — scheduling a new one replaces it.
enum RestNotifier {
    private static let identifier = "knurled.rest.complete"

    /// Ask once for permission to post the rest-complete alert. Safe to call repeatedly; the
    /// system only prompts the first time.
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// (Re)schedule the rest-complete notification to fire at `date`. No-op if the date is already
    /// in the past (e.g. a sub-second rest), which keeps a stale notification from lingering.
    static func schedule(at date: Date, nextUp: String) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])

        let interval = date.timeIntervalSinceNow
        guard interval > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = "Rest complete"
        content.body = nextUp.isEmpty ? "Time for your next set." : "Next up: \(nextUp)"
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        center.add(request)
    }

    /// Drop any pending rest-complete notification — rest was skipped, the timer was turned off,
    /// or the workout ended. A notification that has already been delivered is left untouched.
    static func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}
