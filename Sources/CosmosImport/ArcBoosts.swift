import Foundation
import CosmosCore

/// Boosts (`StorableBoostsData.json`).
///
/// TODO: Boost import. The sample Arc profiles have no `StorableBoostsData.json` and the teardown documents no
/// schema for it (only the file name and the `BoostsImageCache/` folder), so there is nothing to map yet. When
/// the format is known, parse the file here into `[Boost]` (host patterns, CSS, JS, zaps, colour filter, font,
/// zoom) and drop the warning below. Until then a profile that has the file is reported rather than ignored.
enum ArcBoosts {
    static func load(directory: URL, notes: ImportNotes) -> [Boost] {
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("StorableBoostsData.json").path) {
            notes.warn("Arc Boosts were found but Boost import is not implemented yet; none were imported")
            notes.skip("boostsFile")
        }
        return []
    }
}
