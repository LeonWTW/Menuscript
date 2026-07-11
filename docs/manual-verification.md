# Manual Verification

This document records a hands-on run of the app in the iOS Simulator, on top of the automated test suite, covering the Sprint 2 feature slice (Capture → Menu → Bill → History) plus the two AI-review fixes described in `docs/ai-implementation-review.md`.

## Scope & Environment

- **Date:** 2026-07-11
- **Branch:** `sprint-2-prototype`
- **Simulator:** iPhone 17, iOS 26.3 (runtime build 23D8133)
- **Xcode:** 26.3 (build 17C529)
- **Bundle ID:** `com.leonwong.menutranslate`
- **Build:** `xcodegen generate` → `xcodebuild build -project MenuTranslate.xcodeproj -scheme MenuTranslate -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug` — **BUILD SUCCEEDED**
- **Mock provider:** toggled per action below via the `-settings.useMockProvider YES|NO` launch argument (no live Gemini API key was entered into Keychain for this pass — the Settings screen's API key field showed only its empty placeholder throughout)
- **Automation channel used:** the app's existing `#if DEBUG` auto-demo scaffolding (`RootView.swift`, `MenuView.swift`) driven entirely by launch arguments — `-autoDemo YES [-autoDemoScreen bill|explain|settings] [-settings.appLanguage en|zh-Hant] [-settings.useMockProvider YES|NO]`. This does not exist to fake results; it lets the mock-provider path (deterministic sample menu, no network) be exercised head-lessly via `simctl`, without hand-driving the camera/photo-picker UI that `simctl` cannot script.
- **Automated test baseline (cited, not re-run by this pass):** 46 tests across 12 suites, all passing — `Test run with 46 tests in 12 suites passed after 2.347 seconds` (`xcodebuild test`, same destination). Full run included the new `SettingsKeysTests` suite (4 tests, fix 2) and `CaptureViewModelTests`/`FXServiceTests` unaffected by either fix. `** TEST SUCCEEDED **`.
- All screenshots referenced below were saved to a local scratchpad directory during this session, not committed to the repository.

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

1. **`README.md` test count was stale.** At the time of this verification pass, line 21 still read "42 tests across 11 suites, all passing," while the actual current suite (confirmed by this session's cited full run) is 46 tests across 12 suites — the new `SettingsKeysTests` suite (4 tests) added for fix 2 had not been reflected back into that line. *Corrected during the final review of this branch: README.md now reads 46 tests across 12 suites.*
2. **`ExplainSheet.swift`: no auto-refetch after dismissing Settings from the config-error state.** `.sheet(isPresented: $showSettings) { NavigationStack { SettingsView() } }` has no `onDismiss` handler, so a user who taps "去 Settings," enters a key, and dismisses Settings lands back on the same error view — they must notice and tap the toolbar's regenerate (arrow.clockwise) icon to actually retry. Not a dead end (there is a path forward), but a rough edge; not independently reproduced via UI in this pass because of the same tap-automation gap noted above — this is a direct code read (`ExplainSheet.swift`, the `.sheet(isPresented: $showSettings)` block around line 54), not a runtime observation.
3. **`ExplainSheet.swift:23` still has a hardcoded `?? "繁體中文"` fallback** in `targetLanguage`, bypassing `SettingsKeys.defaultTargetLanguage()`. It's only reached when `item.session` is `nil` (an edge case, not the normal Capture → Menu → Explain flow used in this verification pass), which is why none of the actions above surfaced it — every item opened here had a live `session`.
4. **`SettingsView.swift`'s `saveAPIKey()` clears `apiKeyInput` on both the success and the Keychain-write-failure path** (`apiKeyInput = ""` runs unconditionally after the `do`/`catch`, confirmed by reading lines 176–186). A user who hits a Keychain write error sees the correct error label but loses the key they just typed and must re-enter it in full. Not exercised in this pass (requires forcing a Keychain failure, which the mock/demo channel has no hook for).

None of items 1–4 block the feature slice from running end to end; they are documented here as known rough edges consistent with `docs/ai-implementation-review.md`'s postponed-issues framing.

## Engineering Conclusion

The Sprint 2 feature slice (Capture → Menu → Bill → History) runs correctly end to end on iPhone 17 / iOS 26.3 with the mock provider, including FX conversion against a live rate, bill math (surcharge, AA split), and persistence across process relaunches. Both AI-review fixes hold up under direct UI observation as far as the simulator's scriptable surface allows: fix 2 (English-UI default target language) is fully confirmed by screenshot; fix 1 (ExplainSheet config-error escape hatch) is confirmed on its happy path and confirmed by code + the existing `ProviderFactoryTests` suite on its error branch, but not by a direct screenshot of the error UI itself, because reaching it requires a UI tap that `simctl` cannot script and this sandboxed session's automation tools (`osascript`, `cliclick`) both lack the Accessibility permission needed to drive the Simulator window. This is a verification-tooling limitation, not a discovered app defect. The four issues above are all pre-existing minor rough edges independently re-confirmed by reading the current diff, not new regressions introduced by this verification pass, and none of them prevent the feature slice from being run, explained, or reviewed.

## Pending Verification

- **Real device + real Gemini API key end-to-end test: not done.** Everything in this document was run against the mock provider (or, for the config-error check, with no provider configured at all) on the iOS Simulator. No live Gemini `generateContent` call, no physical camera capture, and no physical-device run have been exercised in this pass. *(Leon: paste your real-device + live-key run results here.)*

  ```
  [Leon to fill in: device model, iOS version, date, API key source, screenshots/notes from the real Gemini recognition + explain flow]
  ```

- **`ExplainSheet`'s config-error UI (fix 1's error branch) was not directly screenshotted.** Two tooling approaches were tried and both failed for the same root cause (no Accessibility permission for host-side UI automation in this sandboxed session): `osascript`/System Events (`-1719 not allowed assistive access`) and `cliclick` (`Accessibility privileges not enabled`, confirmed by a before/after screenshot showing no change). This is covered instead by: (a) direct code inspection of `ExplainSheet.fetchExplanation()`, which deterministically sets `isConfigError = true` when `ProviderFactory.resolve()` returns `nil`; (b) `MenuTranslateTests/ProviderFactoryTests.swift`'s `"Mock toggle off with no stored key resolves to nil"` test, which is exactly that precondition; and (c) action 8 above, which confirms the app does not crash or hang when mock is off and no key is stored. A screenshot of the actual "去 Settings" button rendering under this condition is still outstanding — either grant Accessibility permission to the automation host and re-run action 9, or manually tap through History → a session → a dish's info icon with mock off and no key on a real simulator/device session.
- **Dynamic Type at AX3+ and FX-rate-source-in-UI** (`docs/ai-implementation-review.md`'s postponed issues 3 and 4) were out of scope for this pass and remain unverified, consistent with that document.
