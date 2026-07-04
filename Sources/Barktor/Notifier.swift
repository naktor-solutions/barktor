import AppKit
import UserNotifications

// Completion/failure notifications for the background transcription queue.
// Injected as a protocol so unit tests can spy without touching
// UNUserNotificationCenter (which traps outside a real app bundle).
@MainActor
protocol Notifying: AnyObject {
    func requestPermissionIfNeeded()
    func notifyMeetingDone(title: String, revealURL: URL)
    func notifyFileDone(filename: String)
    func notifyFailure(message: String, revealURL: URL?, opensHistory: Bool)
}

// Default for an unwired queue (and a safe stand-in anywhere notifications
// must be off): swallows everything.
@MainActor
final class NullNotifier: Notifying {
    func requestPermissionIfNeeded() {}
    func notifyMeetingDone(title: String, revealURL: URL) {}
    func notifyFileDone(filename: String) {}
    func notifyFailure(message: String, revealURL: URL?, opensHistory: Bool) {}
}

// The real thing. Permission is requested lazily on the first enqueue —
// never at launch. A denial stays silent: the menu bar still tells the
// story, and nagging a user who said no is worse than no banner.
@MainActor
final class Notifier: NSObject, Notifying, UNUserNotificationCenterDelegate {
    // Opens the History window (file-job clicks). Wired by AppDelegate.
    var onOpenHistory: () -> Void = {}

    private var permissionRequested = false

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestPermissionIfNeeded() {
        guard !permissionRequested else { return }
        permissionRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
            _, _ in
        }
    }

    func notifyMeetingDone(title: String, revealURL: URL) {
        post(title: "Transcription ready", body: title, userInfo: ["reveal": revealURL.path])
    }

    func notifyFileDone(filename: String) {
        post(title: "Transcription ready", body: filename, userInfo: ["openHistory": true])
    }

    func notifyFailure(message: String, revealURL: URL?, opensHistory: Bool) {
        var info: [AnyHashable: Any] = [:]
        // revealURL wins if both are set: a concrete file to show beats a
        // generic "go look at History" landing spot.
        if let revealURL {
            info["reveal"] = revealURL.path
        } else if opensHistory {
            info["openHistory"] = true
        }
        post(title: "Transcription failed", body: message, userInfo: info)
    }

    private func post(title: String, body: String, userInfo: [AnyHashable: Any]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = userInfo
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // Click routing: meetings reveal the transcript/summary in Finder, file
    // jobs open the History window (their result IS a History entry).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        Task { @MainActor [weak self] in
            if let path = info["reveal"] as? String {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            } else if info["openHistory"] != nil {
                self?.onOpenHistory()
            }
            completionHandler()
        }
    }

    // Banners must show even while a Barktor window is frontmost (Settings /
    // History count as foreground for a menu-bar app). Also list it in
    // Notification Center: a background transcription can finish while the
    // user is away from their Mac, and a transient banner alone can be missed.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
