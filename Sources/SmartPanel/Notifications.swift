import Foundation
import UserNotifications

/// Where a device is in its cycle, as far as alerts are concerned.
enum CyclePhase {
    case idle, running, paused, finished, attention
}

/// Posts macOS notifications for finished cycles, cycles about to finish and devices that need attention.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Minutes before the end of a cycle for the "almost done" alert.
    static let soonMinutes = 5

    private var center: UNUserNotificationCenter { .current() }

    func start() {
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = id
        center.add(UNNotificationRequest(identifier: "\(id).\(UUID().uuidString)", content: content, trigger: nil))
    }

    func sendTest() {
        post("test", title: "SmartPanel", body: "Notifications are working.")
    }

    /// Menu bar apps count as frontmost while the panel is open; show banners anyway.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

extension Settings {
    static var notifyDone: Bool {
        get { UserDefaults.standard.object(forKey: "notify.done") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "notify.done") }
    }

    static var notifySoon: Bool {
        get { UserDefaults.standard.object(forKey: "notify.soon") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "notify.soon") }
    }
}

extension STDevice {
    /// Job states that mean the load is ready even though the machine still reports "run"
    /// (e.g. a dryer tumbling in wrinkle prevent after drying).
    private static let doneJobs: Set<String> = ["finish", "finished", "wrinklePrevent", "wrinkleprevent"]

    var phase: CyclePhase {
        if kind == .robotCleaner {
            return switch string("robotCleanerMovement", "robotCleanerMovement") {
            case "cleaning", "point", "after": .running
            case "pause": .paused
            case "alarm": .attention
            default: .idle
            }
        }
        guard kind.operatingCapability != nil else { return .idle }
        switch machineState {
        case "run":
            if let job = rawJobState, Self.doneJobs.contains(job) { return .finished }
            return .running
        case "pause": return .paused
        default: return .idle
        }
    }

    /// Compares the new status with the previous one and posts the matching alert.
    func notifyTransition(from old: CyclePhase?, alreadyWarned: inout Bool) {
        let now = phase
        defer { if now != .running { alreadyWarned = false } }
        guard let old else { return } // first status after launch: nothing to compare
        let notifier = Notifier.shared

        if now == .attention, old != .attention {
            notifier.post(id, title: "\(label) needs attention",
                          body: kind == .robotCleaner ? "The vacuum is stuck or has an error." : "Check the device.")
            return
        }
        if Settings.notifyDone, old == .running || old == .paused, now == .finished || (now == .idle && old == .running) {
            notifier.post(id, title: "\(label) finished", body: doneMessage)
            return
        }
        if Settings.notifySoon, now == .running, !alreadyWarned,
           let m = remainingMinutes, m > 0, m <= Notifier.soonMinutes {
            alreadyWarned = true
            notifier.post(id, title: "\(label) almost done", body: "About \(m) min left.")
        }
    }

    private var doneMessage: String {
        switch kind {
        case .washer: "Laundry is ready to move to the dryer."
        case .dryer: "Laundry is dry."
        case .dishwasher: "Dishes are clean."
        case .oven: "Cooking is done."
        case .robotCleaner: "Cleaning is done."
        default: "Done."
        }
    }
}
