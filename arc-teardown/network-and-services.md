# Network endpoints and services

Hosts referenced by the main executable (**observed** in strings). Presence in the binary does not prove a request is made on every launch; many are feature- or flag-gated. Keys, tokens, DSNs and the Firebase project configuration are intentionally not reproduced.

## The Browser Company — Arc

| Host | Use |
|---|---|
| `arc.net` | Marketing and deep links: `/welcome-to-arc`, `/get-started-with-arc`, `/boosts`, `/easel`, `/note`, `/object`, `/gift/`, `/max/tutorial`, `/privacy`, `/release-notes`, `/farewell`, `/wemightnotmakeit`, `/api/redirect-links/image?url=` |
| `start.arc.net` | Terms, privacy-rights-by-region, release notes |
| `resources.arc.net` | Help centre (Zendesk; `thebrowsercompany.zendesk.com`) |
| `releases.arc.net` | Sparkle appcast `updates.xml` and downloads |
| `content.arc.net` | Remotely updated behaviour configs: `web_content_behavior.json`, `command_bar_behavior.json`, `memory_behavior.json` |

`arc.net` is also the app's associated domain for web credentials (`webcredentials:arc.net` entitlement), used for passwords/passkeys.

## The Browser Company — Dia infrastructure used by Arc

| Host | Use |
|---|---|
| `aiproxy.diabrowser.engineering` | LLM streaming proxy (`/api/dia-claude-stream`) |
| `ai-service.diabrowser.engineering`, `ai-service.staging…`, `ai-service-eval…` | AI proxy (`/aiproxy`, `/eval/aiproxy`) |
| `websearch.diabrowser.engineering`, `webresultproxy.diabrowser.engineering` | Web search and result fetching for Browse for Me |
| `dia-blocklists-release.diabrowser.engineering` | Ad/tracker block-list manifest and mirrored lists |
| `artifactcdn.diabrowser.engineering` | AI artifact assets |
| `auth.diabrowser.com` | Shared account auth domain |
| `releases.diabrowser.com`, `www.diabrowser.com`, `help.diabrowser.com`, `status.diabrowser.com` | Dia downloads (for *Send to Dia*), help and status |

## Backend platforms

| Service | Evidence | Use |
|---|---|---|
| **Firebase** (Auth, Firestore, Functions, Storage) | `GoogleService-Info.plist`, `googleapis.com`, Firestore gRPC methods (`/google.firestore.v1.Firestore/Listen`, `Write`, `Commit`, `BatchGetDocuments`, `RunAggregationQuery`) | Accounts (incl. MFA), sidebar sync, easels, sharing, boosts |
| **CloudKit** | container `iCloud.net.arc.sidebar` | Original sidebar sync |
| **Apple Push** | `aps-environment` production | Remote notifications (e.g. sync/collaboration) |
| **Sparkle** | `SUFeedURL`, `SUPublicEDKey` | Updates (EdDSA-verified) |

## Feature flags, analytics, telemetry

| Service | Hosts | Use |
|---|---|---|
| **LaunchDarkly** | `clientstream.launchdarkly.com`, `mobile.launchdarkly.com`, `app.launchdarkly.com` | Feature flags (streaming) — see [appendix/feature-flags.txt](appendix/feature-flags.txt) |
| **Segment** | `api.segment.io`, `cdn-settings.segment.com`, `state.sync/update.segment.com` | Product analytics (`AnalyticsClient` emits `SegmentEncodable` events) |
| **Datadog** | `browser-intake-*datadoghq.*` | Logs, traces, RUM (`DatadogCore`, `DatadogLogs`, `DatadogTrace`; the AI service has `EnableDataDogTracing`) |
| **OpenTelemetry** | API linked | Tracing abstraction feeding Datadog (`TelemetryClient.RemoteTracingBackend`) |
| **Sentry** | `thebrowsercompany.sentry.io`, `*.ingest.sentry.io` | Crash and error reporting |

## Third-party sites with special handling

`app.slack.com`, `notion.so` / `app.notion.com`, `mail.google.com`, `calendar.google.com`, `docs.google.com`, `github.com`, `figma.com`, `linear.app`, `youtube.com`, `twitch.tv`, `meet.google.com`, `graph.microsoft.com` / `login.microsoftonline.com` / `outlook.live.com` (calendar/mail previews), `id.atlassian.com`, `chat.openai.com` — via tidy titles, keep-alive, PiP rules, live data clients, previews and the internal extension (see [web-behaviors-and-boosts.md](web-behaviors-and-boosts.md)).
