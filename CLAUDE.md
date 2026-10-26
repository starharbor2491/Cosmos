# CLAUDE.md

Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.

---

# Cosmos project rules

The guidelines above come from [forrestchang/andrej-karpathy-skills](https://github.com/forrestchang/andrej-karpathy-skills) (MIT, as declared in its skill file); the same text is installed as a project skill in `.claude/skills/karpathy-guidelines/`. The rules below are this project's own.

- **Build and test with the scripts.** `scripts/test.sh` (not bare `swift test`, which flakes with "plugin for module 'TestingMacros' not found" on the Command Line Tools) and `scripts/build-app.sh`. There is no Xcode.
- **`@State` does not compile here.** Use `@Local` (`Sources/CosmosKit/UI/Local.swift`). Same for `@Entry` and `@Previewable`.
- **Bug fix = failing test first.** Model logic belongs in `CosmosCore` where it can be tested without UI. WebKit tests are `@MainActor`.
- **Look at UI changes.** Run the app with `--demo --automation script.json` and read the PNG snapshots (`docs/development.md`). Do not claim a UI change works from compiling alone.
- **Git.** No identity is configured: commit with `git -c user.name=starharbor2491 -c user.email=koioshong@hotmail.com commit ...`. Commit on `main`; never push.
- **Privacy.** The user's real Arc profile may be read, never written. Never put tab titles, addresses, extension names or other personal data from it in a commit, a doc or a report.
- **Arc.** Cosmos contains no Arc code, binaries, assets or strings.
