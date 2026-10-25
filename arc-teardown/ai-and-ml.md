# AI and on-device ML

Arc has two separate AI stacks:

1. **Cloud LLM features ("Arc Max")** — Swift code in the main app calling LLM providers through The Browser Company's proxy.
2. **An on-device AI service inside Chromium** — `ArcAIService`, which runs embedding models, small local LLMs, a text classifier and a learned command-bar ranker.

## 1. Arc Max (cloud)

**Features (observed from UI strings, menu items and flags):**

| Feature | Evidence |
|---|---|
| Ask Arc / Browse for Me — searches, reads several pages and writes an answer page ("Reading %d web pages", "Top Search Results", "Dive Deeper") | `AskArc` (`AskArcSessionImpl`, `AskArcStore`, `AskArcPersistentCacheImpl`), `AskArcComparisonTool`, `WebSearch`; flags `browse-for-me-enabled`, `browse-for-me-pip-enabled` |
| Ask on Page — chat about the current page | `AskInPage`; `Arc.AskInPageHostingView`; flag `ask-in-page-enabled` |
| Tidy Tab Titles — LLM-shortened tab titles | `TidyTabTitlesClient`, `TidyTitleConfiguration`, "Tidy Tab Title Feedback" |
| Tidy Tabs — groups today's tabs | `TidyTabsButtonImageView`, `TidyTabsPreview` |
| Tidy Downloads — renames downloaded files from their source page | few-shot rename examples embedded in the binary |
| 5-second previews / summaries on hover | "Second Preview" strings, `HoverCards`, "Summarize" |
| ChatGPT in the Command Bar — send a query to ChatGPT | "New ChatGPT Message…" ⌥⌘G (hidden); keys `gpt-command-bar-integration-*` |
| AI artifacts — "Making a website for you" | `arc::ArtifactHost`, `artifactcdn.diabrowser.engineering`, `setArtifactAllowedScriptSources:` |

Arc Max is opt-in ("Arc Max requires that we send data to our AI partners…").

**Clients (observed).** The `LLM` module defines `LLMClient`, `ChatGPTClient`, `ClaudeClient` and `UniversalLLMClient` protocols, with a `UniversalClient` that accumulates streamed messages and token usage (`MessageAccumulatorBox`, `TokenUsageBox`). `PromptGeneration` builds prompts using **Mustache** templates. `Scraping` (`HTMLFetchClientImpl`, `WebViewHTMLFetcher`, `HTMLScrapingRulesProviderImpl`) fetches page HTML through a hidden web view, then HTML is converted to Markdown by the on-device content-conversion service (below). Token counting uses OpenAI's public tiktoken encodings (`cl100k_base`, `o200k_base`, `p50k_base`, `r50k_base`).

**Endpoints (observed).** Requests go through The Browser Company's proxy rather than straight to providers: `https://aiproxy.diabrowser.engineering/api/dia-claude-stream`, `https://ai-service.diabrowser.engineering/aiproxy` (plus `…staging…` and `ai-service-eval…/eval/aiproxy`). Web search for Browse for Me uses `websearch.diabrowser.engineering` and `webresultproxy.diabrowser.engineering`.

**Model identifiers in the binary (observed)** — Anthropic `claude-instant-1` through `claude-opus-5-5` / `claude-sonnet-5-5` / `claude-haiku-5-5`; OpenAI `gpt-3.5-turbo` … `gpt-4o`, `gpt-4.1`, `o1`/`o3`/`o4-mini`, `gpt-5.x`, `gpt-6-*`; Google `gemini-2.0-flash`, `gemini-3-flash`, `gemini-3-pro`; embeddings `text-embedding-3-small/large`, `text-embedding-ada-002`. Which model serves which feature is chosen remotely (LaunchDarkly / remote config), so the list is a menu rather than a fixed mapping.

## 2. On-device AI service (inside Chromium)

Arc ships the service's C API headers in `ArcCore.framework/Resources/arc/services/ai/public/mojom/` (`ai_service.mojom-c_api.h`, `…-bridge.h`), so the interface is documented by the vendor's own headers (**observed**). The service is a Chromium Mojo service (**inferred**: hosted in a utility process, as Chromium services normally are) and loads its ML runtime from a dynamic library (`AIServiceConfiguration.libraryPath`, errors `LibraryNotFound`, `LibraryMissingRequiredSymbols`). Swift reaches it through `ArcBrowserApplication createAIService:` → `ArcAIService`, wrapped by `AIInfraProtocols` (`LocalNomicEmbedTextProvider`, `LocalDistilBertClassifierProvider`, `LocalCommandBarRankingProvider`).

### Capabilities

| Service type | API | Models / runtimes |
|---|---|---|
| Embedding | `GetEmbeddingsFor(inputs, config)` | GTE small/base/large, Alibaba GTE base; via **ONNX Runtime, Core ML, MLX** or remote |
| Nomic embeddings | `LoadNomicEmbedText`, `NomicEmbed(items{text, task})` | `nomic-embed-text` with task prefixes |
| Inference (local LLM) | `LoadInferenceModel`, `GetStreamedInferenceFor(prompt, {maxTokens, streamAfterEveryNTokens})` | **Phi-3.5, Llama 3.2, Gemma 2B, Qwen2 0.5B, OpenELM 270M**, or any model directory |
| Classification | `LoadClassifier`, `GetClassificationFor` | **DistilBERT** with LoRA config and a classifier head (`numClasses`) |
| Command-bar ranking | `LoadCommandBarRanking`, `RankCommandBar`, `EvaluateCommandBarRanking`, `TrainCommandBarRanking` | Custom model, trained with **MLX** |

Plus housekeeping: `Initialize`, `SetUser(id, email)`, `UpdateFeatureFlags(json)`, `EnableDataDogTracing(sampling_rate)`, `WaitForDebuggerToAttach`, `Crash`.

### Learned command-bar ranking (federated-style training)

This is the most unusual piece. **Observed** from the header:

- Each candidate result carries `archetype`, `destination`, `title`, `url`, `lastNavSeconds`, `freqEver`, `typedCount`, `siteEngagement`, `isExactUrlMatch`, `isBaseDomainMatch`, `isTitlePrefix`, and a `titleEmbedding`; the query carries a `queryEmbedding`.
- `RankCommandBar` returns a score per candidate id.
- `TrainCommandBarRanking(examples)` trains on examples of *{query, candidates, selectedIndex}* — i.e. which result the user actually picked — and returns a `CommandBarRankingTrainingResult` with `delta` tensors, `lossesPerEpoch`, `gradientNormMean/Max`, `deltaNorm`, `deltaToWeightRatio`, `numSamples` and the model name/version. Outcomes include `Gated`; failures include `LossNaN` and `MlxError`.

**Inferred:** returning weight *deltas* plus norms (rather than a new model) is the shape of federated learning — each device trains locally on its own selections and only model updates (not browsing data) would be aggregated. The local selection history it learns from is `StorableCommandBarAdditionalRanking.json` (`queriesToSelectedArchetype`).

### Content conversion (HTML → Markdown)

`content_conversion_service.mojom-c_api.h` (**observed**): `ConvertHtmlToMarkdown(request)` with `html`, `url`, `linkStyle` (inline / reference), `strategy` (`MainContentFirst`, `MainContentOnly`, `AsIs`, `MetaTagsOnly`), `urlTransform` (`Remove`, `Noop`, `ResolveGoogleRedirects`), `skipNoscript`, `passThroughInputElements`, `metaTagsToCapture`, `deduplicateMetaTagContent`. The result has `body`, `title`, `references[]`, `selectorsApplied[]`, `selectorsContentPct` and captured `metaTags`. This is what turns web pages into LLM-ready context for Ask Arc and previews. Chromium-side extraction also exists (`ArcBrowserContextPageContentExtraction`, `ArcExtractedPageContent`, `ArcAccessibilityTreeNode`).

### Agentic browsing hook

`ArcWebContentsAIAgent` exposes `sendTextInput:` and `sendKeyPress:` on a page — the low-level primitive for an AI agent typing into a web page (Dia-style "browse for me" actions). **Observed** (selectors); usage **inferred**.
