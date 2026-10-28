import Foundation
import UserNotifications
import CosmosEngine

/// Where Cosmos posts the notifications of sites and extensions. The engine runs headless and shows none itself.
@MainActor
protocol Notifying: AnyObject {
    /// Posts `note`; a later one with the same `key` replaces it. `onAction` hears the click, the button or the close.
    func show(_ note: EngineNotification, key: String, onAction: @escaping (NotificationAction) -> Void)
    func close(key: String)
}

/// macOS's Notification Center, as Cosmos: macOS asks the user once whether Cosmos may post.
@MainActor
final class SystemNotifier: NSObject, Notifying, UNUserNotificationCenterDelegate {
    static let shared = SystemNotifier()

    private var handlers: [String: (NotificationAction) -> Void] = [:]
    private var categories: Set<UNNotificationCategory> = []
    /// Only an app has a Notification Center (a test run does not).
    private var center: UNUserNotificationCenter? { Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current() }

    func show(_ note: EngineNotification, key: String, onAction: @escaping (NotificationAction) -> Void) {
        guard let center else { return }
        center.delegate = self
        handlers[key] = onAction
        let content = UNMutableNotificationContent()
        content.title = note.title
        content.subtitle = note.source
        content.body = note.body
        content.userInfo = ["key": key]
        content.categoryIdentifier = category(for: note.buttons, in: center)
        if let icon = note.icon, let file = Self.write(icon, key: key),
           let attachment = try? UNNotificationAttachment(identifier: "icon", url: file) {
            content.attachments = [attachment]
        }
        Task {
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            try? await center.add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
        }
    }

    func close(key: String) {
        center?.removeDeliveredNotifications(withIdentifiers: [key])
        handlers[key] = nil
    }

    /// One category per set of buttons; every one reports a dismissal, which is the notification's `close`.
    private func category(for buttons: [String], in center: UNUserNotificationCenter) -> String {
        let id = "cosmos." + buttons.joined(separator: "|")
        if !categories.contains(where: { $0.identifier == id }) {
            let actions = buttons.enumerated().map { UNNotificationAction(identifier: "button-\($0.offset)", title: $0.element) }
            categories.insert(UNNotificationCategory(identifier: id, actions: actions, intentIdentifiers: [], options: [.customDismissAction]))
            center.setNotificationCategories(categories)
        }
        return id
    }

    /// A copy of the icon for the notification to take (macOS moves the file it is given).
    private static func write(_ image: Data, key: String) -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Cosmos Notification Icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? UUID().uuidString
        let file = folder.appendingPathComponent(name + (image.starts(with: [0xFF, 0xD8]) ? ".jpg" : ".png"))
        return (try? image.write(to: file)) == nil ? nil : file
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let key = response.notification.request.identifier
        let action: NotificationAction = switch response.actionIdentifier {
        case UNNotificationDismissActionIdentifier: .closed
        case let id where id.hasPrefix("button-"): .button(Int(id.dropFirst("button-".count)) ?? 0)
        default: .clicked
        }
        Task { @MainActor in
            let handler = self.handlers[key]
            if action == .closed { self.handlers[key] = nil }
            handler?(action)
        }
        completionHandler()
    }

    /// Shown even while Cosmos is in front: the page that posted it may be in another window or tab.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
