import Foundation

/// Shortens tab titles for a narrow sidebar: unread-count prefixes, account e-mail addresses, boilerplate suffixes.
/// (Arc ships a remote list of per-site rules for this; Cosmos keeps a compact built-in rule table.)
public enum TidyTitles {
    struct Rule {
        let host: String           // matches the host or any subdomain
        let pattern: String        // regular expression on the title
        let template: String       // replacement ($1...)
    }

    private static let rules: [Rule] = [
        Rule(host: "youtube.com", pattern: #"^\(\d+\+?\)\s*"#, template: ""),
        Rule(host: "youtube.com", pattern: #"\s+-\s+YouTube$"#, template: ""),
        Rule(host: "x.com", pattern: #"^\(\d+\+?\)\s*"#, template: ""),
        Rule(host: "twitter.com", pattern: #"^\(\d+\+?\)\s*"#, template: ""),
        Rule(host: "reddit.com", pattern: #"^\(\d+\+?\)\s*"#, template: ""),
        Rule(host: "facebook.com", pattern: #"^\(\d+\+?\)\s*"#, template: ""),
        Rule(host: "linkedin.com", pattern: #"^\(\d+\+?\)\s*"#, template: ""),
        Rule(host: "github.com", pattern: #"^GitHub\s+-\s+([^:]+):.*$"#, template: "$1"),
        Rule(host: "github.com", pattern: #"\s+·\s+GitHub$"#, template: ""),
        Rule(host: "mail.google.com", pattern: #"^(.*?)\s+-\s+[\w.+-]+@[\w.-]+\s+-\s+Gmail$"#, template: "$1 · Gmail"),
        Rule(host: "outlook.live.com", pattern: #"\s+-\s+[\w.+-]+@[\w.-]+\s+-\s+Outlook$"#, template: " · Outlook"),
        Rule(host: "app.slack.com", pattern: #"^(?:\*\s*)?(.*?)\s+\|\s+(.*?)\s+\|\s+Slack$"#, template: "$1 · $2"),
        Rule(host: "notion.so", pattern: #"\s+\|\s+Notion$"#, template: ""),
        Rule(host: "docs.google.com", pattern: #"\s+-\s+Google\s+(Docs|Sheets|Slides)$"#, template: " · $1"),
        Rule(host: "wikipedia.org", pattern: #"\s+-\s+Wikipedia$"#, template: ""),
        Rule(host: "stackoverflow.com", pattern: #"\s+-\s+Stack Overflow$"#, template: ""),
    ]

    /// Anything shaped like "name@host.tld" in a title is account detail the sidebar doesn't need.
    private static let emailTail = try! NSRegularExpression(pattern: #"\s+[-–|·]\s+[\w.+-]+@[\w-]+(\.[\w-]+)+"#)

    public static func tidy(title: String, url: URL?) -> String {
        var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return t }
        if let host = url?.host?.lowercased() {
            for r in rules where host == r.host || host.hasSuffix("." + r.host) {
                guard let re = try? NSRegularExpression(pattern: r.pattern) else { continue }
                let range = NSRange(t.startIndex..., in: t)
                if re.firstMatch(in: t, range: range) != nil {
                    t = re.stringByReplacingMatches(in: t, range: range, withTemplate: r.template)
                    break
                }
            }
        }
        let range = NSRange(t.startIndex..., in: t)
        t = emailTail.stringByReplacingMatches(in: t, range: range, withTemplate: "")
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? title : t
    }
}
