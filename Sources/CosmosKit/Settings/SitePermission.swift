import Foundation

/// A remembered answer to "may this site use your camera, microphone or location?". Stored as `host|kind` in
/// `Settings.permissionDecisions`.
struct SitePermission: Identifiable, Equatable {
    let key: String
    let host: String
    let kind: String
    let allowed: Bool

    var id: String { key }

    init?(key: String, allowed: Bool) {
        let parts = key.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        self.key = key
        host = String(parts[0])
        kind = String(parts[1])
        self.allowed = allowed
    }

    var name: String {
        switch kind {
        case "camera": "Camera"
        case "microphone": "Microphone"
        case "cameraAndMicrophone": "Camera & microphone"
        case "location": "Location"
        default: kind.capitalized
        }
    }

    var symbol: String {
        switch kind {
        case "camera", "cameraAndMicrophone": "video.fill"
        case "microphone": "mic.fill"
        case "location": "location.fill"
        default: "hand.raised.fill"
        }
    }

    /// Every valid decision, by site and then by kind. Keys that don't parse are left out.
    static func list(from decisions: [String: Bool]) -> [SitePermission] {
        decisions.compactMap { SitePermission(key: $0.key, allowed: $0.value) }
            .sorted { ($0.host, $0.kind) < ($1.host, $1.kind) }
    }
}
