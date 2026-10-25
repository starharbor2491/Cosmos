import Foundation
import WebKit
import CosmosCore

/// Connects the filter-list engine (`CosmosBlocking`) to WebKit: compiles rule lists with `WKContentRuleListStore` and
/// attaches them to every profile's content controller. Filled in once the blocking engine lands.
@MainActor
final class ContentBlockerController {
    func attach(to environment: ProfileEnvironment) {}
    func settingsDidChange() {}
}
