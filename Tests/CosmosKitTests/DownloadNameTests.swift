import Foundation
import Testing
@testable import CosmosKit

@Suite struct DownloadNameTests {
    @Test(arguments: [("report.pdf", "report.pdf"), ("../../evil.txt", "evil.txt"), ("/etc/passwd", "passwd"), ("a/b/c.pdf", "c.pdf"),
                      ("..\\..\\evil.exe", "evil.exe"), ("..", "Download"), (".", "Download"), ("", "Download"), ("dir/", "dir"), ("日本語.txt", "日本語.txt")])
    func aSuggestedNameNeverChoosesAFolder(_ suggested: String, _ expected: String) {
        #expect(DownloadsManager.safeFilename(suggested) == expected)
    }
}
