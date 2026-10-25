# Web behaviours, Boosts and blocking

## Boosts

**How they're applied (observed from the ArcCore bridge).** `ArcBrowserContextEffects` — one per profile — exposes:

```
registerStylesheet:withIdentifier:forHostPattern:
registerScript:withIdentifier:forHostPattern:
registerColorFilter:forHostPattern:
registerColorScheme:forHostPattern:
registerZoomFactor:forHostPattern:
unregisterStylesheet: / unregisterScript: / unregisterColorFilter: / unregisterColorScheme: / unregisterZoomFactor:
```

So a Boost is a bundle of per-host effects that Chromium injects itself, at the engine level, rather than a Chrome extension. Colour filters are expressed with `ArcHSLAMatrix` (hue/saturation/lightness/alpha matrices) — the Boost colour wheel. The internal URL pattern `arc://effect/%s` and `arc://boost/v2/css/`, `arc://boost/v2/js/` show effects and Boost v2 files are served from internal URLs.

**Editor.** `BoostsEditor` ships `SelectorPicker.js`, which builds a CSS selector for the element under the cursor (tag, id, classes, `:nth-child` position) — this is *Zap*, which hides elements. Boosts v2 adds a code editor (flag `boosts-v2-monaco-enabled`, i.e. Monaco) wired to Chromium through `ArcWebContentsBoostIDE` (`sendEvent:jsonString:`, `sendResponse:jsonString:`, `sendErrorResponse:jsonString:`), a JSON message channel between the editor page and native code. Boosts sync via the Firestore `boosts` collection and can be shared (flag `boost-sharing-enabled`). The legacy editor is still reachable as *New Legacy Boost (Advanced)*.

## Per-site behaviour config

`ARC_WebContentBehaviorConfigurationClient.bundle/web_content_behavior.json` (also refreshed remotely from `content.arc.net/web_content_behavior.json`) has five sections (**observed**):

| Key | Entries | Purpose |
|---|---|---|
| `tidyTitles` | 52 hosts | Rewrite tab titles. Each host has `siteName` and `rules[]` of `{match, title}`; matchers include `fragmentEquals` and title rules like `always`. Example: on `mail.google.com`, fragment `inbox` → title "Gmail", `starred` → "Starred" |
| `keepaliveAllowList` | 21 URL regexes | Never suspend these (Twitter/X, Slack, Gmail, Google Calendar, Notion …) |
| `tabSuspensionBlocklist` | 2 | Additional suspension exclusions |
| `pipSiteConfigs` | 5 | Per-site PiP tweaks, e.g. Twitch → `disablePlayButton`, `disableScrubButton`, `disableSkipButton` |
| `pipDisallowList` | 3 | Sites where auto-PiP is off (e.g. Slack) |

Two sibling configs are fetched remotely: `content.arc.net/command_bar_behavior.json` (bundled copy: `dedupByTitleAndHostList` of 10 hosts) and `content.arc.net/memory_behavior.json`.

## Ad, tracker and cookie-banner blocking

- `ARCClients_BlockListClient.bundle/manifest.json` declares `manifest_url` `https://dia-blocklists-release.diabrowser.engineering` and 46 known lists: EasyList, EasyPrivacy, EasyList Social, AdGuard (Ads, Cookies, Spyware, Social), uBlock filters, Fanboy third-party, a cookie-banner list ("CookieMonster"), ~35 regional lists, and The Browser Company's own `BCNYBlocklists`. Lists are mirrored on Dia's CDN rather than fetched from upstream.
- EasyList and EasyPrivacy are bundled as fallbacks (`EasyList.txt`, `EasyPrivacy.txt`).
- Lists are handed to Chromium with `ArcBrowserApplication setBlockLists:`, so network blocking happens inside the engine.
- `ADK_ADK.bundle/selectors.css` (≈240 KB) is a generic cosmetic-filter stylesheet (element-hiding rules).
- UI: `AdBlocking` module (`ManageAdBlockersDialogContext`), flag `multiple-ad-blockers-sidebar-banner-enabled` (nudges users who also run an ad-block extension).

## The internal extension

`resources.pak` contains a Manifest V3 component extension, *"&lt;APP_NAME&gt; Internal Extension"* v0.0.10, with `scripting` and `tabs` permissions on `app.slack.com`, `www.notion.so` and `chromewebstore.google.com`. Its background service worker (**observed**, summarised):

- **Slack and Notion**: watches the page's dark/light class and forces a solid page background colour, so the site matches Arc's themed window chrome and the top-bar colour sampler (`TopBarColorClient`) gets a clean colour.
- **Chrome Web Store**: replaces the word "Chrome" in install buttons with the browser's name (from the extension manifest), and hides the "switch to Chrome" dialogs and info banners via injected CSS.

## Other injected scripts

- `ARC_EaselUI.bundle/DisableInlineLinks.js` — disables in-page link navigation inside Easel captures (walks up to the nearest anchor and neutralises it).
- `YouTubePlayerKit_YouTubePlayerKit.bundle/YouTubePlayer.html` — the third-party YouTube embed used for video previews.
- `ArcBrowserApplication setArtifactAllowedScriptSources:` plus `arc::ArtifactHost` / `ArtifactDownloadBlock` in ArcCore — sandboxed AI "artifacts" (generated mini web apps, cf. Ask Arc's "Making a website for you") with a restricted script allow-list. **Inferred.**
