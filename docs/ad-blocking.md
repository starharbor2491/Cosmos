# Ad, tracker and cookie-banner blocking

Cosmos blocks ads, trackers and cookie banners with **WebKit content rule lists**, the same mechanism Safari content
blockers use. WebKit evaluates them inside the networking and rendering stack, so no page script is involved and pages
cannot detect or bypass them. The module is `CosmosBlocking`; it is pure Foundation and never imports WebKit. The
browser target owns the one call that needs WebKit (`WKContentRuleListStore`).

Arc ships EasyList, EasyPrivacy, AdGuard, uBlock and cookie-banner lists inside Chromium (see
`arc-teardown/web-behaviors-and-boosts.md`). Cosmos offers the same coverage by compiling the same public lists.

```
 public filter lists (ABP / uBO syntax)
        │  download: URLSession, ETag / If-Modified-Since, 24 h freshness   FilterListManager
        ▼
   FilterParser ──► [Filter]  (network / cosmetic AST, skipped lines counted by reason)
        ▼
   ContentRuleCompiler ──► ordered, de-duplicated WebKit rules, split into lists ≤ 40,000 rules
        ▼
   [CompiledRuleList]  name, json, ruleCount, kind, digest, storeIdentifier        + CompileReport
        ▼
   app: WKContentRuleListStore.compileContentRuleList → WKUserContentController.add
```

## What is blocked, and how

| Filter | Becomes | Notes |
| --- | --- | --- |
| Network filter (`||ads.example.com^`, `/banner/*.gif`, `\|http://…\|`) | `block` rule with a `url-filter` regex | `\|\|` → `^[^:]+://+([^:/]+\.)?host`, `^` → `[^a-zA-Z0-9_.%-]`, `*` → `.*`, `\|` → `^` / `$` |
| Type options (`$script,image,xhr,subdocument,…`) | `resource-type` | `xhr` is `raw` + `fetch`; `subdocument` is `document` + `load-context: child-frame` |
| `$third-party` / `$~third-party` | `load-type: third-party` / `first-party` | |
| `$domain=a.com\|~b.com` | `if-domain: ["*a.com"]` or `unless-domain` | `*` makes WebKit match subdomains too. A mix of both becomes a block plus an `ignore-previous-rules` rule for the excluded hosts |
| `$match-case` | `url-filter-is-case-sensitive` | everything else is case-insensitive, as in ABP |
| `@@` exception | `ignore-previous-rules` | same trigger as the block it cancels |
| `$important` | `block` ordered after exceptions | beats normal exceptions, as in uBlock Origin |
| `@@\|\|site^$document` | `ignore-previous-rules` with `if-domain: ["*site"]` | switches the site off entirely |
| `$popup` | `resource-type: popup` | |
| `##.selector`, `site.com##.selector` | `css-display-none` | selectors are batched (250 per rule); domain rules sharing the same selectors share one rule |
| `~site.com##.sel`, `site.com#@#.sel` | `css-display-none` with `unless-domain` | exceptions are applied per selector, never as a blanket `ignore-previous-rules` |
| `@@\|\|site^$generichide` / `$elemhide` / `$specifichide` | adds the site to the `unless-domain` list of generic rules / removes it from site-specific rules | |
| `0.0.0.0 ads.example.com` (hosts file) | same as `\|\|ads.example.com^` | so hosts-format lists work as custom lists |

Network rules and cosmetic rules go to **separate WebKit lists** (`<id>.network.N`, `<id>.cosmetic.N`), so an
`ignore-previous-rules` rule in a network list can never switch off element hiding, and the other way round.

### Ordering and the guard rules

WebKit applies every matching rule of a list in order, and `ignore-previous-rules` only cancels *earlier* rules **of the
same list**. Each network list is therefore laid out as

1. normal blocks
2. two **guard rules** (`ignore-previous-rules` for top-level `document` loads and for `popup` loads)
3. explicit `$popup` / `$document` blocks
4. exceptions (`@@`)
5. `$important` blocks
6. `$document` whole-site exceptions

Why the guards: in Adblock Plus a filter without type options never applies to the page itself, but a bare WebKit
`block` rule would block *navigation*: clicking an ad-network redirect, or opening a URL that merely contains `/ads/`,
would show an error page. The guards restore the ABP meaning. Verified in a live web view
(`WebKitBehaviorTests`): without them `/ads/landing` blocks the main document, with them it loads while the page's
`/ads/` images are still blocked.

When a list is split at 40,000 rules every part repeats the guards and all exceptions, so each part is self-contained.

## Syntax support

| Syntax | Status |
| --- | --- |
| `\|\|host^`, `\|` start and end anchors, `*`, `^`, plain substrings | supported |
| Options `third-party` (`3p`), `first-party` (`1p`), `script`, `image`, `stylesheet` (`css`), `font`, `media`, `xmlhttprequest` (`xhr`), `subdocument` (`frame`), `document` (`doc`), `ping`, `websocket`, `other`, `popup`, `all`, `domain=` (`from=`), `match-case`, `important`, `badfilter` | supported |
| `~type` negations (`$~script`) | supported (default types minus the negated ones); `~object` and similar are ignored |
| `@@` exceptions, `@@…$document`, `@@…$generichide`, `$elemhide`, `$specifichide` | supported |
| `/regex/` filters | supported when they only use literals, `.` `*` `+` `?`, `[...]`, `(...)`, `^`, `$`, `\d`, `\w` and escaped punctuation; otherwise skipped (`regex-not-representable`) |
| `##selector`, `domain##selector`, `~domain##selector`, `#@#` | supported for standard CSS: type/class/id/attribute selectors, combinators, `:not` `:is` `:where` `:has` (not nested), `:nth-*`, `:first-child`… |
| `!#if env_safari && !ext_ublock` … `!#else` / `!#endif` | evaluated (`env_safari` is true; `ext_ublock`, `env_chromium`, `env_mobile`… are false) |
| hosts-file lines | supported |
| `$redirect`, `$redirect-rule`, `$rewrite` | skipped: WebKit cannot substitute a neutral resource, and blocking instead would break pages |
| `$csp`, `$replace`, `$removeparam`, `$queryprune`, `$urlskip`, `$uritransform`, `$header`, `$permissions`, `$cname` | skipped: no WebKit rule can rewrite requests or responses |
| `$denyallow`, `$to`, `$method`, `$ipaddress`, `$strict1p`, `$strict3p` | skipped: no equivalent trigger |
| `#?#`, `:has-text()`, `:contains()`, `:xpath()`, `:matches-css()`, `:-abp-*`, `:upward()`, `:nth-ancestor()`, `:style()`, `:remove()` | skipped (`extended-selector`): needs a script engine |
| `##+js(…)` scriptlets, `#%#`, `#$#`, `##^` HTML filtering, `$$` | skipped |
| `selector {property: value}` style injection | skipped (`css-injection`) |
| `site.*` entity domains | dropped from include lists; the filter is skipped when nothing is left or an exclusion cannot be honoured |
| Non-ASCII patterns, filters that would match (almost) everything | skipped (`non-ascii`, `too-broad`) |
| `@@…$document` for a pattern that is not a whole site | skipped (`document-exception`) |

Everything skipped is counted by reason in `CompileReport.skipped`, so nothing is silently mis-compiled. On the real
lists (release build, Apple silicon):

| List | Lines | Network filters compiled | Cosmetic filters compiled | Rules (lists) | Parse | Parse + compile |
| --- | --- | --- | --- | --- | --- | --- |
| EasyList | 86,191 | 61,159 / 61,209 (99.9 %) | 24,133 / 24,706 | 67,334 (3) | 0.03 s | 0.73 s |
| EasyPrivacy | 57,179 | 56,325 / 56,369 (99.9 %) | 2 / 37 | 57,218 (3) | 0.01 s | 0.12 s |
| Cookie banners (Fanboy) | 26,146 | 2,109 / 2,110 | 23,122 / 23,198 | 9,119 (2) | 0.01 s | 0.05 s |
| Fanboy Annoyances | 56,395 | 4,156 / 4,157 | 46,062 / 49,922 | 17,907 (2) | 0.01 s | 0.14 s |
| AdGuard Base + EasyList | 155,542 | 82,060 / 83,203 (98.6 %) | 47,889 / 56,383 | 103,065 (4) | 0.04 s | 2.4 s |
| uBlock filters | 10,835 | 1,297 / 1,739 (74.6 %) | 1,282 / 4,264 | 1,566 (2) | < 0.01 s | 0.01 s |
| uBlock privacy | 3,383 | 917 / 1,433 (64.0 %) | 6 / 313 | 919 (2) | < 0.01 s | < 0.01 s |
| uBlock badware | 7,189 | 4,541 / 4,855 (93.5 %) | 101 / 139 | 4,581 (2) | < 0.01 s | 0.01 s |

The uBlock lists lean on `$redirect`, `$removeparam`, scriptlets and `$to`, which WebKit rules cannot express, hence
the lower ratios. In a debug build parsing EasyList takes about 0.2 s.

## WebKit constraints the compiler works around

Checked against the real `WKContentRuleListStore` (see "Verification"):

- **Hard limit of 150,000 rules per list.** Output is split into lists of at most 40,000 rules (`Options.maxRulesPerList`),
  which also compile faster and fail independently. An empty rule list is *invalid*, so empty lists are never emitted.
- **`url-filter` is a small regex dialect.** Supported: literals, `.`, `[...]`, `(...)`, `*` `+` `?`, `^` first, `$`
  last. Rejected: alternation `|`, `{n,m}`, `\d \w \s \b`, lookaround, `^`/`$` in the middle, non-ASCII, empty
  strings. `RuleListValidator` enforces exactly this.
- **A trailing `^` also matches the end of the URL.** WebKit has no alternation, so `/path^` becomes
  `/path([^a-zA-Z0-9_.%-].*)?$`. A host-only `||host^` needs no such tail because a URL always has a `/` after the host.
- **Selectors are validated by WebKit, silently.** One invalid selector in a comma-joined list makes WebKit drop the
  *whole rule* without an error (the list only fails when nothing valid remains). `CSSSelectorValidator` mirrors WebKit's
  parser: all 68,681 selectors it accepted from the eight lists above compiled in WebKit, and all 378 it rejected were
  also rejected by WebKit. Typical rejections: nested `:has`, unknown pseudo-classes, ids starting with a digit.
- **`if-domain` and `unless-domain` cannot be combined**, and domains must be lowercase ASCII (punycode for IDNs).
  Apple documents a 250-entry cap; WebKit accepted 5,000 in testing, but `if-domain` arrays are still split at 250.
- **Exceptions only reach rules in their own list**, so an EasyList exception does not cancel an EasyPrivacy block.
  `$badfilter` and `$generichide` likewise apply within the list that contains them.
- WebKit is the reference, but it targets one OS version: development used the WebKit shipped with the macOS 27 SDK,
  the deployment floor is macOS 14. If a list ever fails to compile on an older system, the first suspects are the
  `fetch` / `ping` / `websocket` / `other` resource types and `load-context`.

## Lists, updates and offline behaviour

| Id | List | Category | Default |
| --- | --- | --- | --- |
| `easylist` | [EasyList](https://easylist.to/easylist/easylist.txt) | ads | on |
| `easyprivacy` | [EasyPrivacy](https://easylist.to/easylist/easyprivacy.txt) | privacy | on |
| `fanboy-cookiemonster` | [Cookie banners](https://secure.fanboy.co.nz/fanboy-cookiemonster.txt) (the EasyList Cookie List) | cookies | on |
| `ublock-filters` | [uBlock Origin filters](https://ublockorigin.github.io/uAssets/filters/filters.txt) | ads | off |
| `ublock-privacy` | [uBlock Origin privacy](https://ublockorigin.github.io/uAssets/filters/privacy.txt) | privacy | off |
| `ublock-badware` | [uBlock Origin badware](https://ublockorigin.github.io/uAssets/filters/badware.txt) | security | off |
| `fanboy-annoyance` | [Fanboy Annoyances](https://secure.fanboy.co.nz/fanboy-annoyance.txt) | annoyances | off |
| `adguard-base` | [AdGuard Base + EasyList](https://filters.adtidy.org/extension/ublock/filters/2.txt) (large; replaces EasyList) | ads | off |

All URLs were checked with `curl` when the catalog was written. `FilterListManager` (an actor) keeps them fresh:

- `refresh(force:)` downloads every enabled list in parallel. A list younger than **24 hours** is not contacted
  (`force: true` overrides). Older lists are revalidated with `If-None-Match` / `If-Modified-Since`; a `304` renews the
  timestamp and costs no recompile.
- Downloads are validated (non-empty, not an HTML error page, ≤ 64 MB) and written atomically.
- Compiled JSON is cached under a key of **SHA-256(list text + `ContentBlocker.compilerVersion`)**: an unchanged list is
  never recompiled, and changing the compiler (bump the version) invalidates every cache.
- **Offline**: a failed download falls back to the cached copy. With no copy at all, the bundled
  `Resources/fallback-rules.txt` (~90 dedicated third-party ad/tracker endpoints and a few generic ad-container
  selectors, nothing that touches first-party logins or checkouts) stands in, so the first launch is protected too.
- `cachedRuleLists()` never touches the network: use it at launch for instant protection, then call `refresh()` and every
  ~24 hours. (If the compiled cache is missing it compiles from the cached text, about 1 s for EasyList in a release build.)

Files, under `CosmosPaths.dataDirectory` (`~/Library/Application Support/Cosmos`, or `COSMOS_DATA_DIR`):

```
blocking.json                      enabled list ids and custom lists
FilterLists/<id>.txt               downloaded list text
FilterLists/<id>.meta.json         URL, ETag, Last-Modified, last check
FilterLists/compiled/<id>.manifest.json, <name>.<key>.json   compiled cache
```

### Using it from the browser

```swift
let blocking = FilterListManager()

@MainActor func installBlockLists(_ lists: [CompiledRuleList], into store: WKContentRuleListStore) async -> [WKContentRuleList] {
    var installed: [WKContentRuleList] = []
    for list in lists {
        // The digest is part of the identifier: a hit means the stored rules are current, so nothing is recompiled.
        if let existing = try? await store.contentRuleList(forIdentifier: list.storeIdentifier) {
            installed.append(existing)
        } else if let compiled = try? await store.compileContentRuleList(forIdentifier: list.storeIdentifier, encodedContentRuleList: list.json) {
            installed.append(compiled)
        }
    }
    let wanted = Set(lists.map(\.storeIdentifier))
    for id in await store.availableIdentifiers() ?? [] where id.hasPrefix("cosmos.") && !wanted.contains(id) {
        try? await store.removeContentRuleList(forIdentifier: id)
    }
    return installed
}
// configuration.userContentController.add(list) for every returned list, on every WKWebViewConfiguration.

let cached = await blocking.cachedRuleLists()      // launch: instant
// … install, then in the background:
let fresh = await blocking.refresh()               // and again about every 24 h
```

Per-site "blocking off" is an app concern: leave the lists out of that site's configuration, or add an
`@@||site.com^$document` rule through a custom list. Enabling or disabling a list: `try await blocking.setEnabled("fanboy-annoyance", true)`, then `refresh()`.
`status()` returns per-list check times, rule counts and the `CompileReport` for a settings screen.

## Adding a custom list

Any `http(s)://` or `file://` URL that serves Adblock Plus / uBlock Origin syntax (or a hosts file) works:

```swift
let info = try await blocking.addCustomList(name: "My list", url: URL(string: "https://example.com/my-filters.txt")!)
// enabled immediately, same 24 h refresh and caching as the built-in lists
try await blocking.removeCustomList(id: info.id)
```

For a one-off list, put the rules in a file and use its `file://` URL. To compile text directly (for example the
user's own rules from a settings field), call `ContentBlocker.compile(lists: [("my-rules", text)])`; the result carries
the rule lists and a `CompileReport` that tells the user which lines were not understood.

## Licensing and attribution

Cosmos does **not** bundle or redistribute third-party lists. They are downloaded to the user's machine at run time
from their official locations, and the compiled JSON is a local cache. The settings screen should show each list's name
and licence (`FilterListInfo.license`) with a link to its homepage.

- **EasyList and EasyPrivacy**: dual-licensed GPLv3+ and CC BY-SA 3.0 (<https://easylist.to/pages/licence.html>).
- **EasyList Cookie List / Fanboy Annoyances**: CC BY 3.0 (<https://easylist.to/>), attribution required.
- **uBlock Origin lists** (uAssets): GPLv3 (<https://github.com/uBlockOrigin/uAssets>).
- **AdGuard Base**: GPLv3 (<https://github.com/AdguardTeam/AdguardFilters>).
- `Resources/fallback-rules.txt` is original content written for Cosmos.

Test runs download EasyList and EasyPrivacy into memory only; nothing downloaded is committed to the repository.

## Verification

```
scripts/test.sh --filter CosmosBlockingTests                          # unit, manager (injected fetcher) and corpus tests
COSMOS_VERIFY_WEBKIT=1 scripts/test.sh --filter CosmosBlockingTests   # + real WKContentRuleListStore and WKWebView checks
```

- **Parser tables**, **exact JSON for ~35 filters**, **semantic match tables** (generated expressions evaluated with ICU
  regexes against URLs), validator accept/reject tables and chunking/ordering tests.
- **Corpus test**: real EasyList and EasyPrivacy are downloaded (the test is cancelled when offline), compiled, and must
  compile ≥ 90 % of network filters, pass `RuleListValidator` with zero problems, and stay at ≤ 40,000 rules per list.
- **`WebKitCompileTests`** (opt-in): every output list, including the full real lists, is compiled by the real
  `WKContentRuleListStore`. This works headless, from `swift test`, with no window server.
- **`WebKitBehaviorTests`** (opt-in): 50 scenarios load real pages in a `WKWebView` from an in-process HTTP server and
  check which requests are blocked and which elements are hidden: host anchors, separators, types, third-party,
  `*domain` subdomain matching, exceptions, `$important`, popups, top-level navigation, cosmetic exceptions and
  `$generichide`.

## Known limits

- No redirects/neutered stubs, request rewriting, scriptlets or procedural cosmetics (see the table). Pages that rely on
  a stub (`$redirect=noop.js`) keep working only because those filters are skipped rather than turned into plain blocks.
- Exceptions, `$badfilter` and hide exemptions work within one list, not across lists.
- `site.*` filters are not expanded to every TLD; they are dropped.
- Generic `:has()` selectors are accepted because WebKit supports them, but they cost style-recalculation time on large
  pages; a future option could drop them.
