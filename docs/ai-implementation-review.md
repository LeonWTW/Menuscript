# AI Implementation Review

This document is a plain account of how I used AI (Claude Code) to build Menuscript, what an AI-driven engineering review of my own prototype turned up, which of its suggestions I accepted or rejected, and how I verified the result by hand afterward.

## AI Implementation Assistance

My working style for this project is AI-assisted engineering: Claude Code writes the majority of the actual Swift code, and I act as the engineer directing it — I set the milestone scope, write or approve the requirements, decide the acceptance criteria for each step, and review/approve every milestone before moving to the next one. Concretely, the app was built in a sequence of milestones (M1 scaffold, M2 models/services, M3 capture flow, M4 menu UI, M5 bill/explain/history, M6 review fixes + polish), plus a follow-up bilingual UI milestone, each landed as its own commit (`167a013` through `249dd5f`), and Sprint 1's project-definition docs were written the same way (`1ee3893`, `fee488d`).

For each milestone I gave Claude Code a scoped brief (what to build, what the acceptance test was, which files were in/out of scope), let it produce the implementation and tests, and then reviewed the diff and ran the app/tests myself before accepting the milestone. AI did not choose the feature slice, the architecture direction, or when something was "done" — those were my calls. What AI did well: turning a written spec into working SwiftUI/SwiftData code quickly, keeping test coverage alongside new features (currently 46 tests across 12 suites), and handling repetitive/mechanical work like the bilingual string catalog entries.

## AI Engineering Review

After the core prototype (through the bilingual milestone) was in a working state on `sprint-2-prototype`, I ran an AI-assisted engineering review pass over the implementation, specifically looking for correctness and UX gaps that a normal feature-complete pass could plausibly miss. It surfaced four issues:

1. **ExplainSheet dead-end error state** — when the "explain this dish" LLM call fails because no API key is configured (mock provider off), the sheet's error view only offered a "Try again" button, which would just fail the same way again. There was no path out of the sheet into Settings to actually fix the problem.
2. **Wrong default target language under English UI** — when the app's UI language was set to English, the translation target-language default shown in the picker was still hard-coded to Traditional Chinese, which is backwards for an English-UI user (and doesn't respect the System-locale case correctly either).
3. **Dynamic Type overflow at AX3+** — the dish chips and quantity steppers were not verified to reflow at the largest accessibility text sizes (AX3 and above), meaning at those sizes they could visually collide or get clipped.
4. **FX rate source not shown in UI** — the app tracks whether a currency conversion rate came from a live fetch, a cached value, or a manual override, but none of that provenance was surfaced anywhere in the UI, so a user has no way to tell how stale/trustworthy a shown conversion is.

## Accepted Suggestions

I accepted and fixed issues (1) and (2) on `sprint-2-prototype`, because both are small, localized, user-facing correctness bugs in the feature slice I'm already shipping — not new scope.

**(1) ExplainSheet dead-end fixed.** `ExplainSheet.swift` now tracks a new `@State isConfigError` alongside the existing `@State showSettings`. `fetchExplanation` sets `isConfigError = true` specifically when `ProviderFactory.resolve()` returns `nil` (no API key configured / mock mode off) and when the call throws `VisionProviderError.missingAPIKey` (covers a timing edge case in `GeminiProvider`'s key check). The error view (`errorState(_:)`) now branches on that flag: if it's a config problem, the button reads "去 Settings" / "Open Settings" and opens Settings via a new `.sheet(isPresented: $showSettings) { NavigationStack { SettingsView() } }`, mirroring the exact same sheet pattern `CaptureView.swift`/`RootView.swift` already use elsewhere; if it's any other error, the existing "再試一次" retry button stays. No new localization keys were needed — the catalog already had bilingual entries for both strings, and `StringCatalogTests` passed unchanged, confirming that.

**(2) English-UI default target language fixed.** I added a single source of truth, `SettingsKeys.defaultTargetLanguage(appLanguage:systemLocale:)`, in `SettingsKeys.swift`: if the app language is explicitly English it returns "English", if explicitly Traditional Chinese it returns "繁體中文", and if set to "System" it checks the system locale's language code and picks accordingly. Both real call sites now use this as a fallback-only default (it never overwrites a value the user already saved): `SettingsView.swift`'s `@AppStorage` default expression, and `CaptureViewModel.swift`'s `defaults.string(forKey:) ?? SettingsKeys.defaultTargetLanguage()`. I deliberately left the two `#Preview` blocks in `BillView.swift` and `MenuView.swift` untouched since they're demo/preview data, not runtime behavior. I also found — but did not fix, since it wasn't in the original two named call sites — a third latent occurrence in `ExplainSheet.swift` (`?? "繁體中文"`, reached only when `item.session` is nil, an edge case not the normal flow). I'm noting it here as a follow-up rather than pretending it's already covered. I added `MenuscriptTests/SettingsKeysTests.swift` covering all branches (explicit English, explicit Traditional Chinese, System+English-locale, System+non-English-locale).

## Rejected or Postponed Suggestions

I postponed issues (3) (Dynamic Type overflow at AX3+) and (4) (FX rate source not shown in UI). Both are legitimate findings, not excuses to skip work, but I made a deliberate scoping call: (4) in particular would require adding a new field to the data model to actually persist/display rate provenance, and (3) would mean auditing and likely reworking layout across multiple views for an accessibility tier I haven't otherwise budgeted time to test properly. The Sprint 2 brief is explicit that large architecture or persistence changes should wait until Sprint 3, and my priority right now is making sure the feature slice I already have is fully documented and verified rather than expanding its surface area. Both are recorded here so they aren't lost, and (4) is the more likely candidate to pick up first in Sprint 3 since it's additive rather than a rework.

## Manual Verification After AI Review

I did not just trust the AI's fixes — I re-ran the full automated test suite and did a manual pass through the app in the simulator with the mock provider (documented in detail in `docs/manual-verification.md`). The relevant excerpt from the post-review full test run:

```
✔ Test "Network failure with an existing cache falls back to the cached rate" passed after 0.080 seconds.
✔ Test "Manual override wins over live and cache" passed after 0.006 seconds.
✔ Test "Same currency short-circuits to 1.0 without hitting the network" passed after 0.001 seconds.
✔ Suite FXServiceTests passed after 1.650 seconds.
✔ Test "Successful recognition persists a session with 10 ordered items" passed after 1.715 seconds.
✔ Suite "CaptureViewModel" passed after 2.346 seconds.
✔ Test run with 46 tests in 12 suites passed after 2.347 seconds.
** TEST SUCCEEDED **
```

All 46 tests across 12 suites pass, including the new `SettingsKeysTests` suite added for fix (2) and the unchanged `StringCatalogTests` I relied on to confirm fix (1) didn't need new localization keys. Beyond the automated suite, I manually switched the app language to English and confirmed by screenshot that the target-language default now shows "English" instead of "繁體中文" on a fresh install. The ExplainSheet config-error branch itself could not be driven to a screenshot in this pass — reaching it requires a simulator tap that can't be scripted without an Accessibility permission the verification session didn't have (details in `docs/manual-verification.md`). It is covered instead by direct code inspection of `fetchExplanation()` and the existing `ProviderFactoryTests` precondition test, and a hands-on tap-through of that error screen is still on my list. Real-API (live Gemini) end-to-end testing is still pending on my side — the mock-provider flow is what's verified so far.

## Engineering Responsibility Statement

To be precise about the division of labor: AI (Claude Code) wrote the large majority of the code in this repository, generated the fixes for issues (1) and (2), and ran the AI engineering review that identified all four issues in the first place. That is a real and substantial contribution, and I'm not going to describe it as "just helping out." But every engineering judgment call in this project was mine: defining the feature slice and milestone scope, writing the acceptance criteria for each milestone, deciding which of the four review findings to fix now versus postpone (and why), reviewing the actual diffs before accepting them rather than accepting them blind, running the test suite and manually exercising the fixed flows myself rather than taking a "tests passed" report at face value, and making the final call on what ships in this Sprint 2 submission. AI did not decide what "done" means for this project, did not choose to defer issues (3) and (4), and did not verify its own work — I did.
