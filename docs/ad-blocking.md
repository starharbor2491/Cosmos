# Ad, tracker and cookie-banner blocking

Cosmos blocks ads, trackers and cookie banners with Chromium's own **`declarativeNetRequest`** rules, the mechanism
Manifest V3 ad blockers use. Chromium matches every request against them in its network process, so no page script is
involved and pages cannot detect or bypass them. The compiler is `CosmosBlocking`, pure Foundation with no engine code;
`CosmosChromium/BlockerExtension.swift` packages its output as a small extension ("Cosmos Blocker") that Cosmos writes
into each profile and loads over the debugging pipe.

Arc ships EasyList, EasyPrivacy, AdGuard, uBlock and cookie-banner lists inside Chromium (see
`arc-teardown/web-behaviors-and-boosts.md`). Cosmos offers the same coverage by compiling the same public lists.

```
 public filter lists (ABP / uBO syntax)
        │  download: URLSession, ETag / If-Modified-Since, 24 h freshness   FilterListManager
        ▼
   FilterParser ──► [Filter]  (network / cosmetic AST, skipped lines counted by reason)
        ▼
   DNRCompiler ──► declarativeNetRequest rules in rulesets of ≤ 10,000, and element-hiding data per site
        ▼
   [CompiledRuleList]  name, json, ruleCount, kind, digest                         + CompileReport
        ▼
   BlockerExtension: rules-N.json rulesets, allow.json (sites switched off), hiding style sheets as content scripts
        ▼
   Chromium: Extensions.loadUnpacked into the profile
```

## What is blocked, and how

| Filter | Becomes | Notes |
| --- | --- | --- |
| Network filter (`\|\|ads.example.com^`, `/banner/*.gif`, `\|http://…\|`) | `block` rule with that `urlFilter` | Adblock Plus patterns are already `declarativeNetRequest` URL filters, so they carry over unchanged |
| `/regex/` filter | `regexFilter` | only expressions RE2 accepts (see below); at most 300 per list |
| Type options (`$script,image,xhr,subdocument,…`) | `resourceTypes` | `subdocument` is `sub_frame`, `document` is `main_frame` |
| `$third-party` / `$~third-party` | `domainType: thirdParty` / `firstParty` | |
| `$domain=a.com\|~b.com` | `initiatorDomains` / `excludedInitiatorDomains` | both can be given on one rule; subdomains match too |
| `$match-case` | `isUrlFilterCaseSensitive` | everything else is case-insensitive, as in ABP |
| `@@` exception | `allow` rule, priority 2 | beats a normal block (priority 1) |
| `$important` | `block`, priority 3 | beats normal exceptions, as in uBlock Origin |
| `@@\|\|site^$document` | `allowAllRequests` on `main_frame` / `sub_frame`, priority 4 | switches the site off entirely |
| Site Controls' per-site switch | `allowAllRequests`, priority 100, in its own `allow.json` ruleset | wins over every list rule |
| `##.selector`, `site.com##.selector` | a style sheet with `display: none !important` | generic selectors in one content-script style sheet for all sites; site selectors in a script that applies those of the site and its parent domains |
| `~site.com##.sel`, `site.com#@#.sel` | the site's exceptions | exceptions to generic selectors undo the hiding on that site; the others keep a site rule from applying |
| `@@\|\|site^$generichide` / `$elemhide` | the site is left out of the generic style sheet / out of all hiding | |
| `0.0.0.0 ads.example.com` (hosts file) | same as `\|\|ads.example.com^` | so hosts-format lists work as custom lists |

Top-level navigations are not special-cased: a filter without type options applies to every request type except
`main_frame`, because that is what `declarativeNetRequest` does when `resourceTypes` is left out. Clicking an
ad-network redirect, or opening an address that merely contains `/ads/`, therefore still loads, as in Adblock Plus.

All rulesets of the blocker are matched together by priority, so an exception in one list cancels a block from
another (an EasyList `@@` rule reaches EasyPrivacy's blocks). `$badfilter` and
`$generichide` still apply within the list that contains them, because the compiler resolves them per list.

## Syntax support

| Syntax | Status |
| --- | --- |
| `\|\|host^`, `\|` start and end anchors, `*`, `^`, plain substrings | supported |
| Options `third-party` (`3p`), `first-party` (`1p`), `script`, `image`, `stylesheet` (`css`), `font`, `media`, `xmlhttprequest` (`xhr`), `subdocument` (`frame`), `document` (`doc`), `ping` (`beacon`), `websocket`, `other`, `all`, `domain=` (`from=`), `match-case`, `important`, `badfilter` | supported |
| `~type` negations (`$~script`) | supported (default types minus the negated ones); `~object` and similar are ignored |
| `@@` exceptions, `@@…$document`, `@@…$generichide`, `$elemhide`, `$specifichide` | supported |
| `/regex/` filters | supported when RE2 can compile them: no look-around, back-references, atomic groups or possessive repeats (otherwise `regex-not-representable`) |
| `##selector`, `domain##selector`, `~domain##selector`, `#@#` | supported for standard CSS; `CSSSelectorValidator` drops selectors a browser would reject (unknown pseudo-classes, nested `:has`, ids starting with a digit…) |
| `!#if env_chromium && !ext_ublock` … `!#else` / `!#endif` | evaluated (`env_chromium`, `env_mv3` and `cap_user_stylesheet` are true; `ext_ublock`, `env_safari`, `env_mobile`… are false); nesting is limited, deeper lines are rejected |
| hosts-file lines | supported |
| `$popup` | skipped (`option:popup`): `declarativeNetRequest` has no popup type, and blocking the opener's request instead would be wrong |
| `$redirect`, `$redirect-rule`, `$rewrite` | skipped: a neutral stub needs `redirect` rules with bundled resources, which Cosmos does not ship, and blocking instead would break pages |
| `$csp`, `$replace`, `$removeparam`, `$queryprune`, `$urlskip`, `$uritransform`, `$header`, `$permissions`, `$cname` | skipped |
| `$denyallow`, `$to`, `$method`, `$ipaddress`, `$strict1p`, `$strict3p` | skipped |
| `#?#`, `:has-text()`, `:contains()`, `:xpath()`, `:matches-css()`, `:-abp-*`, `:upward()`, `:nth-ancestor()`, `:style()`, `:remove()` | skipped (`extended-selector`): needs a script engine |
| `##+js(…)` scriptlets, `#%#`, `#$#`, `##^` HTML filtering, `$$` | skipped |
| `selector {property: value}` style injection | skipped (`css-injection`) |
| `site.*` entity domains | dropped from include lists; the filter is skipped when nothing is left or an exclusion cannot be honoured |
| Non-ASCII patterns, filters that would match (almost) everything | skipped (`non-ascii`, `too-broad`) |

Everything skipped is counted by reason in `CompileReport.skipped`, so nothing is silently mis-compiled. Each filter is
counted once, as compiled when any part of it took effect. The corpus test on the current EasyList and EasyPrivacy
(debug build, Apple silicon, October 2026):

| | |
| --- | --- |
| Network filters compiled | 103,934 of 106,958 (97.2 %) |
| Cosmetic filters compiled | 24,144 of 24,751 |
| Rules | 103,770 in 11 network rulesets plus one hiding list per source |
| Skipped, largest reasons | `option:popup` 2,962, `extended-selector` 298, `entity-domain` 236, `css-injection` 40, `scriptlet` 30, `option:redirect` 29 |
| Time | EasyList parse 0.2 s; both lists compile in 1.1 s |

Almost all of the gap is `$popup`. The uBlock lists lean on `$redirect`, `$removeparam` and scriptlets, so fewer of
their filters compile; for those, add uBlock Origin Lite as an extension.

## Chromium limits the compiler works around

- **The rule budget.** Chromium promises each extension 30,000 static rules and lends more from a pool of 300,000 that
  all extensions share; a ruleset that does not fit is switched off as a whole. Output is cut into rulesets of at most
  10,000 rules (`Options.maxRulesPerList`), so an overflow costs only the last rulesets. Checked live
  (`PageAgentTests.everyRulesetOfListsAsLargeAsTheRealOnesIsOn`): 110,000 rules in 11 rulesets all take effect, and
  the same test fails at 340,000, past the cap. Other extensions that use the pool (uBlock Origin Lite, for example)
  leave less for Cosmos.
- **1,000 regular-expression rules per extension**, shared by every list. Each list may use 300; further regex
  filters are skipped.
- **RE2, not JavaScript regexes.** Chromium drops a rule whose expression RE2 cannot compile. The compiler checks every
  `/regex/` filter (with ICU standing in for RE2) and skips look-around, back-references, atomic groups and possessive
  repeats.
- **Selectors.** One invalid selector in a comma-joined group makes the browser drop the whole group, so selectors go
  into small groups and `CSSSelectorValidator` drops the ones that would be rejected.
- **Domains** must be lowercase ASCII (punycode for IDNs).

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
- Compiled output is cached under a key of **SHA-256(list text + `ContentBlocker.compilerVersion`)**: an unchanged
  list is never recompiled, and changing the compiler (bump the version) invalidates every cache.
- **Offline**: a failed download falls back to the cached copy. With no copy at all, the bundled
  `Resources/fallback-rules.txt` (~90 dedicated third-party ad/tracker endpoints and a few generic ad-container
  selectors, nothing that touches first-party logins or checkouts) stands in, so the first launch is protected too.
- `cachedRuleLists()` never touches the network: it is used at launch for instant protection, then `refresh()` runs
  in the background and about every 24 hours.

Files, under `CosmosPaths.dataDirectory` (`~/Library/Application Support/Cosmos`, or `COSMOS_DATA_DIR`):

```
blocking.json                      enabled list ids and custom lists
FilterLists/<id>.txt               downloaded list text
FilterLists/<id>.meta.json         URL, ETag, Last-Modified, last check
FilterLists/compiled/…             compiled cache
Engine Profiles/<profile>/Cosmos Blocker/   the extension Chromium loads (rewritten when lists or the per-site switches change)
```

### How the browser uses it

`ContentBlockerController` (CosmosKit) asks the manager for the cached lists at launch and fresh ones afterwards, and
hands them to every profile with `EngineProfile.setContentBlocking(_:allowlist:)`. The Chromium profile writes the
blocker extension and reloads it; the same lists and switches a second time leave it as it is. The per-site switch in
Site Controls is the `allowlist`, so turning blocking off for a site takes effect on its next load without
recompiling anything. Enabling or disabling a list: `try await blocking.setEnabled("fanboy-annoyance", true)`, then
`refresh()`. `status()` returns per-list check times, rule counts and the `CompileReport` for the settings screen.

## Adding a custom list

Any `http(s)://` or `file://` URL that serves Adblock Plus / uBlock Origin syntax (or a hosts file) works:

```swift
let info = try await blocking.addCustomList(name: "My list", url: URL(string: "https://example.com/my-filters.txt")!)
// enabled immediately, same 24 h refresh and caching as the built-in lists
try await blocking.removeCustomList(id: info.id)
```

For a one-off list, put the rules in a file and use its `file://` URL. To compile text directly, call
`ContentBlocker.compile(lists: [("my-rules", text)])`; the result carries the rulesets and a `CompileReport` that tells
the user which lines were not understood.

## Licensing and attribution

Cosmos does **not** bundle or redistribute third-party lists. They are downloaded to the user's machine at run time
from their official locations, and the compiled output is a local cache. The settings screen shows each list's name
and licence (`FilterListInfo.license`) with a link to its homepage.

- **EasyList and EasyPrivacy**: dual-licensed GPLv3+ and CC BY-SA 3.0 (<https://easylist.to/pages/licence.html>).
- **EasyList Cookie List / Fanboy Annoyances**: CC BY 3.0 (<https://easylist.to/>), attribution required.
- **uBlock Origin lists** (uAssets): GPLv3 (<https://github.com/uBlockOrigin/uAssets>).
- **AdGuard Base**: GPLv3 (<https://github.com/AdguardTeam/AdguardFilters>).
- `Resources/fallback-rules.txt` is original content written for Cosmos.

Test runs download EasyList and EasyPrivacy into memory only; nothing downloaded is committed to the repository.

## Verification

```
scripts/test.sh --filter CosmosBlockingTests                       # parser, compiler, manager and corpus tests
COSMOS_TEST_CHROMIUM=/path/to/Chromium.app scripts/test.sh --filter PageAgentTests   # + live headless Chromium
```

- **`DNRCompilerTests`**: the exact rules for each kind of filter, priorities, ruleset cutting, the regex budget, RE2
  checks, cosmetic data and its exceptions.
- **`CorpusTests`**: real EasyList and EasyPrivacy are downloaded (cancelled when offline), compiled, and must compile
  ≥ 90 % of network filters, pass the `declarativeNetRequest` format checks in the test support with no problems, and
  keep every ruleset within its size.
- **`FuzzTests`**: mutated filter lines, random bytes and deeply nested `!#if` lines never crash the parser, and what
  compiles is valid.
- **`BlockerExtensionTests`** (CosmosChromium): the extension's manifest, numbered rulesets, the allowlist ruleset and
  the hiding scripts.
- **Live** (`PageAgentTests`, headless Chromium, no window): a page's script is blocked and an element hidden, and both
  come back on a site that was switched off; and the rule-budget check above.

## Known limits

- No redirects or neutered stubs, request rewriting, scriptlets or procedural cosmetics (see the table). Pages that
  rely on a stub (`$redirect=noop.js`) keep working only because those filters are skipped rather than turned into
  plain blocks.
- `$popup` filters are skipped.
- `$badfilter` and hide exemptions work within one list, not across lists.
- `site.*` filters are not expanded to every TLD; they are dropped.
