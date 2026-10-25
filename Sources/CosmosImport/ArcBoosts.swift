import Foundation
import CosmosCore

/// Boosts.
///
/// Not imported. A real, long-used Arc profile checked while building Cosmos has a `BoostsImageCache/` folder but no
/// Boost definition file anywhere in it (no `StorableBoostsData.json`; no other file mentions Boosts beyond ids), so
/// Boosts appear to live in the Arc account, not on disk, and there is nothing local to read. When a profile does
/// have `StorableBoostsData.json`, or a Boost image cache, the report says so instead of staying silent; recreating
/// a Boost in Cosmos takes a minute (Site Controls ▸ Boost this site).
enum ArcBoosts {
    static func load(directory: URL, notes: ImportNotes) -> [Boost] {
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("StorableBoostsData.json").path) {
            notes.warn("Arc Boosts were found but Boost import is not implemented yet; none were imported")
            notes.skip("boostsFile")
        }
        let cache = directory.appendingPathComponent("BoostsImageCache", isDirectory: true)
        if ((try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []).contains(where: { !$0.hasPrefix(".") }) {
            notes.warn("Arc keeps Boost definitions in your Arc account, not in this folder, so they were not imported; recreate them from Boost this site")
        }
        return []
    }
}
