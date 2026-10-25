import Foundation

/// Result of compiling one or more filter lists.
public struct CompileResult: Sendable {
    /// Ready-to-install rule lists, in input order (network lists before cosmetic lists of the same source).
    public var lists: [CompiledRuleList]
    /// Totals over all inputs.
    public var report: CompileReport
    /// Per input list, keyed by the name given to `compile`.
    public var reports: [String: CompileReport]
}

/// Entry point of the content-blocking engine: filter list text in, WebKit content-rule-list JSON out.
///
/// Every input list compiles on its own. WebKit applies `ignore-previous-rules` only within one list, so exceptions,
/// `$badfilter` and `$generichide` entries affect the list that contains them.
public enum ContentBlocker {
    /// Bump when the compiler's output for the same input changes; it is part of the compiled-list cache key.
    public static let compilerVersion = 3

    public static func compile(lists: [(name: String, text: String)], options: ContentRuleCompiler.Options = .init()) -> CompileResult {
        var all: [CompiledRuleList] = []
        var total = CompileReport()
        var perList: [String: CompileReport] = [:]
        for input in lists {
            let one = compile(name: input.name, text: input.text, options: options)
            all.append(contentsOf: one.lists)
            total.merge(one.report)
            perList[input.name] = one.report
        }
        return CompileResult(lists: all, report: total, reports: perList)
    }

    /// Compiles a single list. Output lists are named `<name>.network.<n>` and `<name>.cosmetic.<n>` (n from 1).
    public static func compile(name: String, text: String, options: ContentRuleCompiler.Options = .init()) -> (lists: [CompiledRuleList], report: CompileReport) {
        let parsed = FilterParser.parse(text)
        let output = ContentRuleCompiler(options: options).compile(parsed)
        var lists: [CompiledRuleList] = []
        for (i, rules) in output.networkLists.enumerated() {
            lists.append(CompiledRuleList(name: "\(name).network.\(i + 1)", json: assemble(rules), ruleCount: rules.count, kind: .network))
        }
        for (i, rules) in output.cosmeticLists.enumerated() {
            lists.append(CompiledRuleList(name: "\(name).cosmetic.\(i + 1)", json: assemble(rules), ruleCount: rules.count, kind: .cosmetic))
        }
        return (lists, output.report)
    }

    static func assemble(_ rules: [String]) -> String {
        "[\n" + rules.joined(separator: ",\n") + "\n]"
    }

    /// The small list shipped inside the app, used until real lists have been downloaded.
    public static var fallbackListText: String {
        guard let url = Bundle.module.url(forResource: "fallback-rules", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }
}
