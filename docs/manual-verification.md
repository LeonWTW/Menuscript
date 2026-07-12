# Manual Verification

This document records a hands-on run of the app in the iOS Simulator, on top of the automated test suite, covering the Sprint 2 feature slice (Capture → Menu → Bill → History) plus the two AI-review fixes described in `docs/ai-implementation-review.md`.

## Scope & Environment

- **Date:** 2026-07-10
- **Branch:** `sprint-2-prototype`
- **Simulator:** iPhone 17, iOS 26.3 (runtime build 23D8133)
- **Xcode:** 26.3 (build 17C529)
- **Bundle ID:** `com.leonwong.menutranslate` *(historical — this pass ran before the project was renamed; the project, scheme, and bundle id are now `Menuscript` / `com.leonwong.menuscript`, so to reproduce today substitute those names in the commands below)*
- **Build:** `xcodegen generate` → `xcodebuild build -project MenuTranslate.xcodeproj -scheme MenuTranslate -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug` — **BUILD SUCCEEDED**
- **Mock provider:** toggled per action below via the `-settings.useMockProvider YES|NO` launch argument (no live Gemini API key was entered into Keychain for this pass — the Settings screen's API key field showed only its empty placeholder throughout)
- **Automation channel used:** the app's existing `#if DEBUG` auto-demo scaffolding (`RootView.swift`, `MenuView.swift`) driven entirely by launch arguments — `-autoDemo YES [-autoDemoScreen bill|explain|settings] [-settings.appLanguage en|zh-Hant] [-settings.useMockProvider YES|NO]`. This does not exist to fake results; it lets the mock-provider path (deterministic sample menu, no network) be exercised head-lessly via `simctl`, without hand-driving the camera/photo-picker UI that `simctl` cannot script.

## Actions Performed

| # | Action | Launch arguments |
|---|--------|-------------------|
| 1 | Fresh install; launch to History (empty state expected) | *(none)* |
| 2 | Auto-demo capture → lands on Menu | `-settings.useMockProvider YES -autoDemo YES` |
| 3 | Auto-demo capture → lands on Menu → auto-opens Bill sheet | `-settings.useMockProvider YES -autoDemo YES -autoDemoScreen bill` |
| 4 | Plain relaunch → History, to confirm persistence across process restarts | *(none)* |
| 5 | Auto-demo capture → lands on Menu → auto-opens Explain sheet for the first dish (mock explanation) | `-settings.useMockProvider YES -autoDemo YES -autoDemoScreen explain` |
| 6 | Auto-demo capture → Bill sheet, English UI | `-settings.useMockProvider YES -autoDemo YES -autoDemoScreen bill -settings.appLanguage en -AppleLanguages "(en)" -AppleLocale en_US` |
| 7 | Auto-demo → root Settings sheet, English UI, to check the new default-target-language fix | `-settings.useMockProvider YES -autoDemo YES -autoDemoScreen settings -settings.appLanguage en -AppleLanguages "(en)" -AppleLocale en_US` |
| 8 | Mock off, no stored key, land on History (populated from actions 2/3/5/6), attempt to reach the Explain sheet's config-error state | `-settings.useMockProvider NO -autoDemoScreen explain` |
| 9 | Two independent attempts at a scripted tap on the first History row to drive into Menu → Explain (needed to actually trigger action 8's fetch, since `-autoDemoScreen` only fires once `MenuView` is on screen) | `osascript`/System Events, then `cliclick`, targeting the Simulator window |

## Expected Results

1. First launch with no persisted data shows the "未有菜單記錄" (No menu records) empty state.
2. Mock-provider recognition returns a fixed sample menu ("鷹の目", 5 dishes visible + more below the fold) with live FX conversion (JPY → USD) applied to each line; the two lines the demo helper seeds with `quantity = 1` and `quantity = 2` show those exact stepper values.
3. `-autoDemoScreen bill` opens `BillView` as a `.large`-detent sheet over Menu, showing: order lines filtered to `quantity > 0` only, a surcharge/tax control (0/8/10%/custom), subtotal → surcharge → total (with FX line and rate/date), and an AA split section.
4. Sessions persist via SwiftData: relaunching without any demo flag lands on History showing the sessions captured by prior demo runs, newest first, each dated 2026-07-11.
5. `-autoDemoScreen explain` opens `ExplainSheet` for the session's first item; with the mock provider, `fetchExplanation` succeeds and renders the mock explanation text with no error state.
6. With `-settings.appLanguage en`, all UI strings render in English (verifies the pre-existing bilingual localization, not a Sprint 2 fix by itself).
7. **Fix 2 (`SettingsKeys.defaultTargetLanguage`):** with `appLanguage == .english` and no `settings.targetLanguage` ever explicitly saved, the Settings screen's "Translation" field should default to **"English"** — not the old hard-coded "繁體中文".
8. **Fix 1 (`ExplainSheet` config-error path):** with the mock provider off and no Gemini API key in Keychain, `ProviderFactory.resolve()` returns `nil`; `fetchExplanation` should set `isConfigError = true` and the sheet's error view should show a localized "去 Settings" / "Open Settings" button (instead of the old dead-end "再試一次" retry-only button), which opens `SettingsView` in a sheet.

## Observed Results

| # | Result |
|---|--------|
| 1 | Not separately screenshotted as its own step — implied by action 4 showing exactly the sessions created in this run (no stale data from a prior install on this simulator). |
| 2 | **Matches.** Menu screen rendered "鷹の目" with categorized dish rows (烤茄子/焼きなす ≈$3.09 ¥500 qty 1, 日式炸雞/唐揚げ ≈$4.02 ¥650 qty 2 with a low-confidence ⚠️ badge, 鹽烤雞翅, 串燒拼盤, and more below the fold), live FX conversion visible on every line, and a running checkout bar ("2 款 · 3 件 ≈$11.12 ¥1800"). |
| 3 | **Matches**, after one retry. The first screenshot (taken ~4s after launch) caught a transitional frame — the presenting Menu view's nav bar/category pills had already hidden but the Bill sheet content hadn't rendered yet. A second screenshot 3s later showed the fully settled Bill sheet: title "帳單" / Done ("完成"), order lines (烤茄子 ×1 ¥500, 日式炸雞 ×2 ¥1300), surcharge control (0% selected, explanatory note about Japan's 8%/10% consumption tax), 小計 ¥1800 / 附加費 ¥0 / 總數 ≈$11.12 (¥1800), exchange rate line "匯率 1 JPY ≈ 0.0062 USD (2026-07-09)" with a refresh icon, and an AA section (2 人 / 每人應付 ≈$5.57 with a rounding disclaimer). This confirms the live FX network call succeeded and a real (non-mock) rate was used, dated one day before this run. |
| 4 | **Matches.** History showed two "鷹の目" entries, both "7月11日 星期六 · 10 味菜 · 日文", newest first — one from action 2, one from action 3, confirming SwiftData persistence survives an app relaunch. |
| 5 | **Matches.** The Explain sheet opened over Menu for "烤茄子" (焼きなす), showing a multi-sentence mock explanation in Traditional Chinese and a regenerate ("重新生成") toolbar button. No error state, no config-error button — this is the pre-existing success path, unaffected by fix 1. |
| 6 | **Matches.** Bill screen in English: title "Bill" / "Done", order lines unchanged (dish names stay in their original/translated-name form, not re-translated), "Surcharge / Tax" section text and the Japan consumption-tax note fully translated, "Subtotal"/"Surcharge"/"Total", "Exchange rate: 1 JPY ≈ 0.0062 USD (2026-07-09)", "Split the Bill" / "People" / "2 people" / "Per Person" / rounding disclaimer — all in English. |
| 7 | **Matches — fix 2 confirmed.** Settings screen in English showed a "Translation" field with value **"English"**, with no `settings.targetLanguage` ever having been written by this run (all prior actions only read the key as a fallback, per `CaptureViewModel.recognize()`/`ExplainSheet`, never write it). This is a direct visual confirmation of `SettingsKeys.defaultTargetLanguage(appLanguage: .english, ...) == "English"` taking effect at the UI layer. The same screen also confirmed no Gemini API key was stored (empty placeholder field), which underpins action 8/9 below. |
| 8/9 | **Not directly observed — blocked by tooling, not by app behavior.** Launching with mock off and no stored key correctly lands on History without crashing or hanging (screenshotted; History showed 4 accumulated sessions from prior actions). But `-autoDemoScreen explain` alone doesn't trigger anything at the History screen — `MenuView`'s `applyAutoDemoScreenIfNeeded()` (the code that opens the Explain sheet) only runs once `MenuView` itself appears, which requires navigating into a session first. Two independent attempts were made to script that tap from the host Mac: (a) `osascript` targeting System Events, (b) `cliclick`. Both tools reported `-1719 osascript is not allowed assistive access` / `Accessibility privileges not enabled` respectively, and a follow-up screenshot after the `cliclick` attempt showed History completely unchanged — the tap was not delivered. Granting Accessibility permission to the automation host is outside this task's scope (it requires an interactive System Settings grant this sandboxed session cannot perform, and is not a code or config change belonging to this repository). See **Pending Verification** below for how this gap is covered instead. |

## Issues Found

None of the eight runtime flows above (actions 1–7) produced a mismatch between expected and observed behavior — both AI-review fixes are confirmed working at the UI layer where they could be directly observed (fix 2, fully; fix 1's happy path, via action 5; fix 1's error path could not be driven to a screenshot — see Pending Verification).

Independently verified by reading the current diff (not merely re-stating claims), the following pre-existing minor issues remain in the working tree and are called out here rather than silently left out of the record:

1. **`README.md` test count was stale.** At the time of this verification pass, line 21 still read "42 tests across 11 suites, all passing," while the actual current suite (confirmed by this session's cited full run) is 46 tests across 12 suites — the new `SettingsKeysTests` suite (4 tests) added for fix 2 had not been reflected back into that line. *Corrected during the final review of this branch: README.md was updated to 46 tests across 12 suites at that time (the line has since been refreshed again as the suite grew with later features).*
2. **`ExplainSheet.swift`: no auto-refetch after dismissing Settings from the config-error state.** `.sheet(isPresented: $showSettings) { NavigationStack { SettingsView() } }` has no `onDismiss` handler, so a user who taps "去 Settings," enters a key, and dismisses Settings lands back on the same error view — they must notice and tap the toolbar's regenerate (arrow.clockwise) icon to actually retry. Not a dead end (there is a path forward), but a rough edge; not independently reproduced via UI in this pass because of the same tap-automation gap noted above — this is a direct code read (`ExplainSheet.swift`, the `.sheet(isPresented: $showSettings)` block around line 54), not a runtime observation.
3. **`ExplainSheet.swift:23` still has a hardcoded `?? "繁體中文"` fallback** in `targetLanguage`, bypassing `SettingsKeys.defaultTargetLanguage()`. It's only reached when `item.session` is `nil` (an edge case, not the normal Capture → Menu → Explain flow used in this verification pass), which is why none of the actions above surfaced it — every item opened here had a live `session`.
4. **`SettingsView.swift`'s `saveAPIKey()` clears `apiKeyInput` on both the success and the Keychain-write-failure path** (`apiKeyInput = ""` runs unconditionally after the `do`/`catch`, confirmed by reading lines 176–186). A user who hits a Keychain write error sees the correct error label but loses the key they just typed and must re-enter it in full. Not exercised in this pass (requires forcing a Keychain failure, which the mock/demo channel has no hook for).

None of items 1–4 block the feature slice from running end to end; they are documented here as known rough edges consistent with `docs/ai-implementation-review.md`'s postponed-issues framing.

## Engineering Conclusion

The Sprint 2 feature slice (Capture → Menu → Bill → History) runs correctly end to end on iPhone 17 / iOS 26.3 with the mock provider, including FX conversion against a live rate, bill math (surcharge, AA split), and persistence across process relaunches. Both AI-review fixes hold up under direct UI observation as far as the simulator's scriptable surface allows: fix 2 (English-UI default target language) is fully confirmed by screenshot; fix 1 (ExplainSheet config-error escape hatch) is confirmed on its happy path and confirmed by code + the existing `ProviderFactoryTests` suite on its error branch, but not by a direct screenshot of the error UI itself, because reaching it requires a UI tap that `simctl` cannot script and this sandboxed session's automation tools (`osascript`, `cliclick`) both lack the Accessibility permission needed to drive the Simulator window. This is a verification-tooling limitation, not a discovered app defect. The four issues above are all pre-existing minor rough edges independently re-confirmed by reading the current diff, not new regressions introduced by this verification pass, and none of them prevent the feature slice from being run, explained, or reviewed.

## 2026-07-12 — Allergen Warnings + Photo Search

New feature pass covering the two Sprint 2 UX additions: per-dish allergen advisories (with an always-on one-line summary) and one-tap dish photo search.

### Scope & Environment

- **Date:** 2026-07-12
- **Branch:** `sprint-2-prototype`
- **Feature under test:** food-sensitivity allergen warnings + in-app photo search
- **Automated suite:** green — `xcodebuild test` exit 0, Swift Testing 82/18 suites + XCTest 33, 0 failures (this is the automated baseline; it includes the new `AllergenTests`, `PhotoSearchTests`, and `GeminiRequestTests` plus the extended `CaptureViewModelTests` / `ExtractedMenuDecodeTests`).
- **Manual pass status:** **PLANNED — not yet executed.** Every "Observed result" below is `pending — 待人手實測` and is to be filled in by a later hands-on run. No manual observation is claimed here. The intended manual environment mirrors the 2026-07-10 pass (iPhone simulator, mock provider driven by the `#if DEBUG` auto-demo launch arguments), plus one live-key run for the "all allergens off" case noted below.

### Test Cases

| # | Test case & expected behavior | Observed result |
|---|-------------------------------|-----------------|
| 1 | **Settings toggles persist.** In Settings → 食物敏感, toggling presets (e.g. 小麥, 大豆) and typing custom allergens (e.g. 香菜) writes `settings.allergenPresets` (comma-joined slugs) and `settings.allergenCustom`; the selections survive closing/reopening Settings and an app relaunch. | pending — 待人手實測 |
| 2 | **Summaries on every card (mock).** With the mock provider on, a scan renders the 鷹の目 sample menu with a one-line summary under the original name on all ten cards (e.g. 焼きなす → 「炭烤茄子淋薑蓉醬油，清爽開胃」). | pending — 待人手實測 |
| 3 | **Allergen warning icon (mock).** On the same mock scan, the 唐揚げ (日式炸雞) card shows the `allergens` warning icon beside the dish name — the mock seeds 唐揚げ with wheat/soy/egg; 焼き鳥盛り合わせ / 生ビール(小) / 豚汁 are likewise seeded. | pending — 待人手實測 |
| 4 | **Allergen alert content.** Tapping the 唐揚げ warning icon opens the 「可能含有敏感原」 alert listing 小麥、大豆、蛋 followed by the disclaimer 「AI 推測僅供參考，落單前請務必同餐廳確認。」. | pending — 待人手實測 |
| 5 | **Photo search opens in-app Safari.** Tapping a card's photo button opens an in-app `SFSafariViewController` showing Google Images results for the dish's original name (e.g. `www.google.com/search?q=唐揚げ&tbm=isch`); dismissing returns to the Menu without leaving the app. | pending — 待人手實測 |
| 6 | **No warning icon when all allergens off.** With every preset toggle off and the custom field cleared, a menu recognized via the real Gemini provider shows no warning icon on any card (the request omits the allergen rule and schema field — see `GeminiRequestTests`). Note: the mock provider hard-codes allergen hits regardless of this setting, so this case is checked with a live key, not the mock. | pending — 待人手實測 |
| 7 | **Old sessions unaffected.** A session captured before allergens were configured (empty `allergenProfile`, items with empty `possibleAllergens`) reopens from History with no warning icons and no advisory footnote, and does not crash — confirming the defaulted SwiftData fields migrate cleanly. | pending — 待人手實測 |

### Automated Smoke Evidence (2026-07-12, later the same day)

Before the hands-on pass, an automated simulator smoke run (driven via `simctl` and the `#if DEBUG` auto-demo launch arguments, with screenshots captured; no human interaction) verified a subset of the table above:

- **Migration — case 7's crash-freedom half: PASS.** The pre-feature build (commit `19b803f`) was installed on a cleaned simulator and auto-demo generated two sessions under the old schema; the feature build was then installed in place as an upgrade. The app launched, stayed alive past 5 seconds, and History listed both old sessions — no lightweight-migration crash. Build identity was verified by content anchors (`allergenPresets` present in the new build's dylib, absent from the old) after an earlier smoke attempt was invalidated for accidentally installing a stale DerivedData product. The "old sessions show no icons/footnote" half of case 7, and an on-device check on an actual iOS 17.x device, remain manual.
- **Summaries render — case 2, partial: PASS for all cards on screen.** On a fresh auto-demo scan with `-settings.allergenPresets "wheat,soy"`, every card visible in the screenshot (烤茄子, 日式炸雞, 鹽烤雞翅, 串燒拼盤, 日式炒飯) shows its one-line summary under the original name. Cards below the fold were not observed (no scroll automation).
- **Warning icons — case 3, partial: PASS for the seeded/unseeded split on screen.** 日式炸雞 and 串燒拼盤 (mock-seeded with hits) show the allergens icon; 烤茄子 and 鹽烤雞翅 (seeded empty) correctly show none. On 日式炸雞 the icon renders beside the low-confidence triangle with no layout breakage.
- Cases needing tap interaction or a live key (1, 4, 5, 6) were not exercised and stay with the manual pass.

### Status

Automated coverage for both features is in place and green (see Scope & Environment), and the same-day automated smoke run above additionally confirmed migration crash-freedom and the summary/icon render paths. The interactive cases (settings persistence, alert content, photo search) and the live-key case remain for the hands-on manual pass; the "Observed result" column is to be completed by that pass.
