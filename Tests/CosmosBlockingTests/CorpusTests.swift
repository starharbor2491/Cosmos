import Foundation
import Testing
@testable import CosmosBlocking

/// Runs the real EasyList and EasyPrivacy through the engine. Downloads them (nothing is stored in the repository);
/// the test is cancelled, not failed, when the network is unreachable.
@Suite struct CorpusTests {
    @Test func realEasyListAndEasyPrivacyCompile() async throws {
        guard let easylist = await CorpusCache.shared.text(Corpus.easylist),
              let easyprivacy = await CorpusCache.shared.text(Corpus.easyprivacy) else {
            try Test.cancel("EasyList could not be downloaded (offline?)")
        }

        // Parse speed
        let parseStart = Date()
        let parsed = FilterParser.parse(easylist)
        let parseSeconds = Date().timeIntervalSince(parseStart)
        #expect(parsed.lineCount > 50_000)
        #if DEBUG
        #expect(parseSeconds < 10, "parsing EasyList took \(parseSeconds)s")
        #else
        #expect(parseSeconds < 2, "parsing EasyList took \(parseSeconds)s")
        #endif

        // Full compile
        let compileStart = Date()
        let result = ContentBlocker.compile(lists: [("easylist", easylist), ("easyprivacy", easyprivacy)])
        let compileSeconds = Date().timeIntervalSince(compileStart)

        var validatorSeconds = 0.0
        var problems: [String] = []
        for list in result.lists {
            #expect(list.ruleCount <= 40_000, "\(list.name) has \(list.ruleCount) rules")
            #expect(list.ruleCount > 0)
            let t = Date()
            problems += RuleListValidator.validate(json: list.json).map { "\(list.name): \($0)" }
            validatorSeconds += Date().timeIntervalSince(t)
        }
        #expect(problems.isEmpty, "\(problems.prefix(10))")

        for (name, report) in result.reports.sorted(by: { $0.key < $1.key }) {
            #expect(report.networkCompileRatio >= 0.90, "\(name): only \(report.networkCompiled) of \(report.networkParsed) network filters compiled")
            #expect(report.parsed == report.compiled + report.skippedTotal, "\(name): every filter line must be accounted for")
        }
        #expect(result.report.networkCompileRatio >= 0.90)
        #expect(result.report.cosmeticCompiled > 10_000)

        let top = result.report.skipped.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        print("""
        [corpus] easylist: \(parsed.lineCount) lines, parse \(String(format: "%.3f", parseSeconds))s
        [corpus] easylist+easyprivacy compile \(String(format: "%.2f", compileSeconds))s, validate \(String(format: "%.2f", validatorSeconds))s
        [corpus] network \(result.report.networkCompiled)/\(result.report.networkParsed) (\(String(format: "%.1f", result.report.networkCompileRatio * 100))%), \
        cosmetic \(result.report.cosmeticCompiled)/\(result.report.cosmeticParsed), \(result.report.ruleCount) rules in \(result.lists.count) lists \
        (\(result.lists.map { "\($0.name)=\($0.ruleCount)" }.joined(separator: ", ")))
        [corpus] skipped \(result.report.skippedTotal): \(top)
        """)
    }

    @Test func compiledListsAreDeterministic() async throws {
        guard let easyprivacy = await CorpusCache.shared.text(Corpus.easyprivacy) else {
            try Test.cancel("EasyPrivacy could not be downloaded (offline?)")
        }
        let a = ContentBlocker.compile(name: "ep", text: easyprivacy).lists
        let b = ContentBlocker.compile(name: "ep", text: easyprivacy).lists
        #expect(a == b)
    }
}
