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

## 2026-07-15 — Privacy, Offline Mock, and Completed-History Contract

This section defines the hands-on pass for the hardened lifecycle, provider, FX, and privacy behavior. It was written before execution and deliberately claimed no manual results at that point; the "Observed result" column was filled in afterwards, as each case was actually run — case 9 on 2026-07-22 (§ below), cases 3–8 on 2026-07-26 (§ below). Cases 1 and 2 remain pending: both require a live Gemini key in the app, and are the last outstanding items of this pass.

### Current Contract

- Recognition creates an unfinished draft. Tapping Done on a non-empty bill atomically saves a versioned immutable snapshot and returns to History; completed quantities, surcharge, people count, FX values, and totals are read-only.
- History separates unfinished and completed sessions. A session with saved photos exposes a photo-stack toolbar button; pages stay in capture order and support count, VoiceOver, pinch/double-tap zoom, and corrupt-data fallback.
- Mock mode resolves mock vision and mock FX together. The core Capture → Menu → Bill → History flow must work with networking blocked and without reading a Gemini key. Dish photo search remains an explicit Google Images browser action.
- Live mode discloses the direct Google Gemini transfer before its first request. Camera and photo-library permission prompts also distinguish live Google transfer from on-device mock processing.
- Live FX uses Frankfurter v2 blended reference rates, supports TWD, and accepts a cached quote only through its seven-day lifetime.
- The app privacy manifest declares no tracking/domains; it conservatively declares linked Photos/Videos, Other User Content, and Health for App Functionality and UserDefaults reason `CA92.1`.

### Manual Test Cases

| # | Test case and expected result | Observed result |
|---|-------------------------------|-----------------|
| 1 | On a fresh install with live mode selected, start recognition. The Google disclosure names the menu images/context being sent and offers Continue/Cancel. Cancel sends no request; reopening shows the disclosure again. | pending — 待人手實測 |
| 2 | Continue once, complete recognition, then begin a second live recognition. The disclosure is not repeated after consent has been recorded. | pending — 待人手實測 |
| 3 | Trigger camera and photo-library permission prompts in both locales. English and Traditional Chinese prompts each mention Google Gemini in live mode and on-device processing in Demo Mode. | **PARTIAL — 2026-07-26.** Both locales' shipped strings verified in the built bundle: each names Google Gemini for live mode and on-device processing for Demo Mode. Neither OS prompt is triggerable, for two different reasons — the simulator has no capture device, so no camera TCC alert appears even after `simctl privacy reset camera`; and the app's photo picker is permissionless by design, so iOS will never present `NSPhotoLibraryUsageDescription` at all. The case wording is amended accordingly in § 2026-07-26. |
| 4 | Enable Demo Mode, remove any stored key, and block network access. Complete Capture → Menu → Bill → History with mock conversion; confirm no Gemini or Frankfurter request. Then tap dish photo search and confirm that this explicit action attempts to load Google Images. | **PARTIAL — 2026-07-26.** The Demo-Mode flow ran end to end and the bill showed the mock conversion explicitly (`1 JPY ≈ 0.0063 USD (demo rate, 2026-01-15)`, matching `MockFXService`); dish photo search opened Google Images for the dish's original name inside the in-app Safari view. The two preconditions — removing the stored key and blocking network access — were **not run**, so "no Gemini or Frankfurter request" rests on indirect evidence (unchanged FX cache bytes across the flow, persisted `providerMode`/`fxSource` of `mock`) rather than observed isolation. See § 2026-07-26. |
| 5 | Exit after recognition but before completing a bill. History shows the session under Unfinished. Reopen, complete it, and confirm it moves to Completed and returns to History. | **PASS — 2026-07-26.** Leaving before completion listed the session under Unfinished; reopening preserved its quantities exactly; tapping Done completed it, dismissed both the bill sheet and the menu screen on its own, and returned to History with the session under Completed. Store-level confirmation: `lifecycleStatusRaw = completed` with a 708-byte `billSnapshotData`. |
| 6 | Reopen a completed bill and attempt to change line quantity, surcharge, people, or refresh FX. No mutation control is available and displayed values match the completion snapshot. | **PASS — 2026-07-26.** On a reopened completed bill the quantity steppers, the 0/8/10% surcharge chips, the custom-surcharge stepper, the people stepper, and the FX refresh control are all absent; lines render as static `×2`/`×1`, and a zero-quantity line carries "Not included in the completed order". All nine displayed values — both lines, surcharge percent, subtotal, surcharge, total, people, per person, and the FX line — are identical to those shown at the moment of completion. |
| 7 | Open History photo galleries with one and six pages; verify order, counter, VoiceOver labels, pinch/double-tap zoom, and bounded memory while paging. A session with zero photos has no gallery button. | **PARTIAL — 2026-07-26.** Six numbered photos imported in the selected order and the gallery showed each page at its own index with the counter tracking 1/6 → 6/6 (notably in capture order, not the library's newest-first order); the one-page gallery showed 1/1; double-tap zoomed in and toggled back, and pinch-out zoomed; app RSS across 40 page flicks went 237 → 272 → 287 → 272 → 272 MB, i.e. bounded rather than a per-page leak; a zero-photo session had no gallery button and did not crash. **VoiceOver labels were read in source only, not heard** — enabling VoiceOver would have taken over the touch model used for the rest of the pass. |
| 8 | Exercise a TWD pair live, then disable network before and after the seven-day cache boundary. The fresh cached quote is accepted; the expired quote is not. Quote date stays unchanged across LA/Honolulu timezone changes. | **PARTIAL — 2026-07-26.** A live JPY→TWD refresh returned `1 JPY ≈ 0.1976 TWD (2026-07-27)`, matching an independent `curl` of Frankfurter v2 exactly on both rate (0.19755) and quote date. A cached quote inside its lifetime was accepted and displayed; the same key re-seeded eight days old was rejected with "Failed to Update Exchange Rate" while the bill kept the previously accepted value — deliberately distinguishable payloads (0.5000/2026-07-20 vs 0.7/2026-07-10) make the accept/reject unambiguous. Under both `America/Los_Angeles` and `Pacific/Honolulu` the quote date stayed 2026-07-27, while an ordinary local date on the same screen shifted Jul 22 → Jul 21, proving the timezone change took effect. The literal "disable network" step was **not run**; the same code branch was driven by a genuine live-fetch failure instead. See § 2026-07-26. |
| 9 | Inspect the archived app root for `PrivacyInfo.xcprivacy` and validate its collected-data and required-reason entries against the privacy labels prepared for distribution. | **PASS — 2026-07-22.** Archived via `xcodebuild archive` (generic/platform=iOS, `CODE_SIGNING_ALLOWED=NO`, ARCHIVE SUCCEEDED); `PrivacyInfo.xcprivacy` present at the app root and dumped with `plutil -p`. Contents match the declared contract exactly: `NSPrivacyTracking` false with no tracking-domains entry; collected data types are Photos/Videos, Other User Content, and Health — each linked, purpose App Functionality, tracking false; accessed-API types declare only UserDefaults with reason `CA92.1`. |

## 2026-07-22 — Live Gemini Spot-Check on a Real Handwritten Japanese Menu (informal)

An informal, single-menu accuracy spot-check of the live recognition path, run ahead of the formal nine-case pass above (which stays pending). It exists to answer one question early: does recognition/translation hold up on a real, difficult, handwritten menu? That was recorded at the Sprint 2 checkpoint as the project's biggest unknown, so it was worth testing as soon as a live key was available rather than waiting for the full pass.

### Scope & Environment

- **Date:** 2026-07-22
- **Simulator:** iPhone 17
- **Mode:** Demo Mode **off**, live Gemini via the user's own API key; live FX conversion shown per line (JPY → USD, consistent ≈0.00615 rate across all sampled lines)
- **Input:** one photo of a real izakaya menu, fully handwritten in Japanese brush calligraphy — deliberately chosen as a hard case: ~36–37 items across a sashimi list, appetizers, grilled dishes, an oden box, and two whisky highballs, with handwritten prices, prefecture-origin margin notes, orange highlighter strokes, and one item crossed out in red as sold out.
- **Method:** the same photo was also run through the Google Lens / Google Translate camera translation as a baseline, and results were compared dish-by-dish against a human reading of the original menu.
- **Process note:** a first attempt at this check was invalid — Demo Mode was still on, so the app returned its built-in 鷹の目 sample menu instead of a live result. The mismatch was caught by comparing the result's dishes and prices against the input photo before recording anything. Lesson kept here on purpose: live-path evidence must always be sanity-checked against its input.

### Observed Results — Menuscript (live Gemini)

- **Extraction coverage:** History records the session as **36 dishes · 日文, Completed** — essentially the full menu (the handwritten original has ~36–37 items, one of them struck through as sold out).
- **Dish-level sample** (all ten dishes visible across the captured screenshots, checked against the original):

| # | Handwritten item | App result (name / original / price) | Verdict |
|---|------------------|--------------------------------------|---------|
| 1 | カンパチ腹身刺し ¥1,280 | Amberjack Belly Sashimi · カンパチ腹刺 · ¥1280 | correct |
| 2 | ヒラメ刺し ¥1,380 | Flounder Sashimi · ヒラメ刺 · ¥1380 | correct |
| 3 | ヒラスズキ刺し ¥1,380 | Blackfin Seabass Sashimi · ヒラスズキ刺 · ¥1380 | correct — exact species (blackfin seabass), not a generic "sea bass" |
| 4 | ヒラメの肝和え ¥1,080 | Flounder Liver Aemono · ¥1080 | correct |
| 5 | 海鮮納豆 ¥880 | Seafood Natto · ¥880 | correct |
| 6 | 梅水晶 ¥580 | Ume Suisho · ¥580 · "Pickled plum with shark cartilage." | correct, including domain knowledge — the dish name alone does not say shark cartilage |
| 7 | 漬物盛り合わせ ¥580 | Assorted Pickles · ¥580 | correct |
| 8 | 骨付カルビの網焼 ¥1,280 | Grilled Bone-in Kalbi · ¥1280 | correct, "bone-in" preserved |
| 9 | 地鶏の塩焼 ¥880 | Local Chicken Salt Grill · ¥880 | correct |
| 10 | 胡麻カンパチ(?) ¥980 | Seasonal Fresh Amberjack · 旬鮮カンパチ · ¥980 | **one probable misread:** the brush-written modifier looks like 胡麻 (sesame — Google Lens read it the same way); Gemini transcribed 旬鮮 (seasonal fresh). Fish species and price are still correct. |

- **Sample tally: 9/10 fully correct, 1/10 with a probable modifier misread; prices 10/10 correct.** No fabricated dishes were observed in the sample, categories (Sashimi / Grilled Fish / Vegetables / Appetizer / Simmered Dish …) were assigned sensibly, and none of the sampled cards carried the low-confidence badge. Allergen advisory badges appeared on plausible dishes for the configured sensitivities (e.g. Seafood Natto, Assorted Pickles, Grilled Bone-in Kalbi), with the standing advisory-only footnote shown under the list.

### Baseline — Google Lens on the same photo

Roughly half of the Lens output on this menu was unusable, including outright fabrication. Representative failures against the same handwriting: 鰆の煮付け → "Boiled victory"; ワカサギの天ぷら → "Smelt heaven!"; 雲仙ハムカツ → "cloud muhamgan"; 白州ハイボール → "6 state highball"; タコぶつ → "Octopus hit"; an entire invented sentence ("Eightre-chan, here's a delicious shrimp treat.") where the menu lists a fried dish; and prices merged into dish text ("Dried 1803190 Hanpen"). Where both systems read the same dish, Gemini was consistently stronger: 梅水晶 came back as the literal "plum crystal" from Lens versus a correct shark-cartilage explanation from Menuscript, and ヒラスズキ as generic "Japanese sea bass" versus the exact species. Lens also has no notion of structure — no per-dish prices, categories, or summaries — which is the gap the app's structured extraction is designed to fill.

### Engineering Conclusion

On the strength of this spot-check, the Sprint 2 checkpoint's "biggest unknown" — whether recognition/translation would survive real, messy, handwritten menus — is retired as the project's top risk: structured extraction on a genuinely hard handwritten menu was essentially complete (36 items), the ten-dish sample contained no wrong dish or wrong price, and the one defect found was a modifier-level transcription slip. One menu is a spot-check, not a statistical claim, so formal accuracy evaluation stays future work; the project's top open risk now shifts to verifying the Sprint 3 persistence behavior — the nine-case manual pass above and a physical-device end-to-end run.

## 2026-07-26 — Hands-on Pass: Lifecycle, Read-only Completion, Photo Gallery, and FX Cache (cases 3–8)

Execution of the plan defined in § 2026-07-15. Cases 3–8 were run on the simulator and their verdicts are recorded in that table; this section carries the method, the detail behind each verdict, and the issues the pass surfaced. Cases 1 and 2 stay pending (they need a live Gemini key in the app); case 9 was completed on 2026-07-22.

### Scope & Environment

- **Date:** 2026-07-26
- **Branch:** `sprint-3-expansion` at `41df014`. **No source change was made for this pass** — the working tree was clean before and after, verified with `git status`.
- **Simulator:** iPhone 17 Pro, iOS 26.3
- **Build:** `xcodegen generate` then `xcodebuild build -project Menuscript.xcodeproj -scheme Menuscript -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` — **BUILD SUCCEEDED**, exit 0. The automated suite was not re-run for this pass; its most recent green run is the 211-test run recorded in `docs/ai-implementation-review.md`.
- **Automation channel:** the same `#if DEBUG` auto-demo launch arguments used in the 2026-07-10 pass, plus — new here — host-side tap automation (`cliclick`, with a calibrated simulator-pixel → host-point mapping re-confirmed after every reboot) and `xcrun simctl io … screenshot`. **A fresh screenshot was taken and read after every tap or tap group**, because a silently-missed tap is this channel's main failure mode. This is precisely the capability the 2026-07-10 pass lacked — `osascript` and `cliclick` were both denied Accessibility access then, which is why cases needing UI taps were deferred at that time. That permission is now granted, which is what made cases 3–8 executable.
- **Live requests:** no live Gemini request was made at any point in this pass. Every recognition ran with `-settings.useMockProvider YES`. The only live network traffic was the keyless Frankfurter FX endpoint in case 8.
- **Simulator data safety:** the device already contained pre-existing sessions, including the completed 36-dish live session cited in § 2026-07-22. It was **not** erased. The app container's store and preferences were backed up before any seeding; every seeded value and scratch-row edit was restored afterwards; and the cited session was then verified intact — 36 items, `completed`, `providerMode = live`, and its single 1200×1600 photo extracted and visually confirmed to still be the original handwritten-menu image.
- **Evidence retained:** 56 screenshots plus a per-case log holding the verbatim expected text and observed result for each case. Kept outside the repository because of size; not committed.

### Where seeding was required, and why

Three of these cases cannot be reached through the UI alone. Each shortcut is recorded here rather than left implicit, because it changes what the result proves:

1. **Zero-photo session (case 7's last clause).** Recognition always persists the prepared JPEGs (`Menuscript/Features/Capture/CaptureViewModel.swift:343`) and no photo-removal action exists for a saved session, so this state is unreachable in normal use. A **scratch** draft session's `photos` column was replaced with an archive of an empty array, the app terminated and backed up first, then reverted.
2. **FX cache boundary (case 8).** The cache value is `Data` under `fx.cache.<FROM>.<TO>` (`Menuscript/Services/FXService.swift:240-242`), and `NSArgumentDomain` cannot carry a `Data` value — so there is no launch-argument path to seed it. The container's preference plist was written directly with the simulator shut down (`cfprefsd` caches preferences while booted and would overwrite the edit).
3. **Reaching the real FX service at all (case 8).** `FXService`, the only cache-bearing provider, is selected only when a session's effective mode is `live` (`Menuscript/Features/Menu/MenuView.swift:63-82`). A scratch session's `providerModeRaw` was set to `NULL` — a legitimate legacy state — so the mode falls back to the preference, and the app was launched with `-settings.useMockProvider NO`. This exercises live FX with **no Gemini key read and no vision request**: the bill's FX refresh never constructs a vision provider.

### Issues discovered and resolutions

| # | Issue | Classification | Resolution |
|---|---|---|---|
| 1 | Case 3 as written cannot be satisfied for the photo library. The app selects photos with SwiftUI `PhotosPicker` (`Menuscript/Features/Capture/CaptureView.swift:236`), i.e. out-of-process PHPicker, which requires no photo-library authorization — so iOS never presents `NSPhotoLibraryUsageDescription`, even though the string ships correctly in both locales. After a `simctl privacy reset photos`, opening the picker showed an informational "Private Access to Photos" banner, not a permission alert. | Expectation defect in the test case, **not** an app defect — the permissionless picker is the privacy-preferable design. Low severity. | Case 3 is **amended**: verify that both locales' usage strings ship correctly and name the right data flow, and note that the library picker is permissionless by design so its string is unreachable at runtime. The string is kept because the App Store requires the key to be declared. The camera half stays open for a physical-device run. |
| 2 | The camera permission alert is not triggerable on the iOS 26 simulator: `UIImagePickerController` reports a camera as available and opens a placeholder capture UI with no TCC prompt, before and after `simctl privacy reset camera`, in both locales. | Tooling limitation (no capture device ⇒ no AVCapture TCC gate). | Deferred to the outstanding physical-device run, where it is a natural by-product of the first camera use. |
| 3 | No DEBUG hook exists to seed the FX cache, so the seven-day boundary cannot be tested without writing the container preference plist from outside the app. | Testability gap. | Worked around as described above. A DEBUG-only seeding hook would make this case reproducible from launch arguments alone; recorded as a candidate rather than added mid-deliverable, since it would mean changing shipping code purely for a test. |
| 4 | A zero-photo session and a Demo-Mode FX cache are both unreachable from the UI, so two clauses of the plan can only be exercised by seeding the store. | Testability limitation arising from the design, not defects. | Documented above so the corresponding results are read with the right scope. |
| 5 | Early in the pass, tap automation used too-short waits between clicks, so a picker dismissal went unnoticed and subsequent taps fell through to History. This opened the cited 36-dish session read-only and created one extra scratch draft session. | Harness error in the verification tooling, not in the app. | Fixed by adding an explicit mouse-move plus 400 ms/900 ms waits and verifying every tap against a fresh screenshot. No session data was altered — quantities re-checked at zero — and the stray session was removed by the final restore. Recorded because the lesson generalises: evidence from an automated UI channel is only as good as the per-step confirmation that each step landed. |

**No functional defect was found in the app across cases 3–8.** Every behaviour that could be observed matched the contract stated in § 2026-07-15.

### Not run / not observed

| Item | Case | Reason |
|---|---|---|
| The live Google disclosure on a first request, and its non-repetition after consent | 1, 2 | Require a live Gemini key configured in the app. Outstanding — the last two cases of this pass. |
| Triggering the OS camera permission alert | 3 | Not possible on the simulator; needs a physical device. |
| Triggering the OS photo-library permission alert | 3 | Architecturally impossible for this app (permissionless picker) — see issue 1. |
| "Remove any stored key" precondition | 4 | A key was present in the test device's Keychain and was deliberately left untouched; clearing it would have destroyed device state tied to the § 2026-07-22 evidence. Demo Mode's independence from the key is therefore shown by code path (`Menuscript/Services/RuntimeServiceResolver.swift` never reads the secret store on the mock branch), not by a key-absent device. |
| "Block network access", and confirming no request by observed isolation | 4, 8 | Host network state was deliberately not modified. Substituted evidence for case 4: the FX cache bytes were dumped before and after the whole Demo-Mode flow and were unchanged, and no new `fx.cache.*` key appeared, while `FXService` writes that key on every successful live fetch — so an unchanged cache is positive evidence that no Frankfurter request occurred. For case 8, the cache branch was driven by a genuine live-fetch failure on an unsupported currency pair, which takes the identical path (`fetchLive` throws → the cached-quote decision runs). Behaviour with the radio actually off remains unverified. |
| VoiceOver labels heard | 7 | VoiceOver was not enabled; it would have taken over the touch model driving the rest of the pass. The labels are present in source (`Menuscript/Features/Menu/HistoryPhotoGalleryView.swift:76,96-100,113`; `MenuView.swift:116`) and are reported as source evidence only. |
| Gallery corrupt-data fallback | 7 | Not required by the case; would need a deliberately corrupted photo blob. |

### Status

Seven of the nine cases in § 2026-07-15 now carry observed results: cases 5 and 6 as full passes, cases 3, 4, 7 and 8 as partials whose unmet portions are enumerated above, and case 9 from 2026-07-22. The two remaining cases, 1 and 2, are blocked only on running the app with a live Gemini key. The unmet portions cluster into three honest categories rather than scattered gaps — what the simulator cannot do (camera TCC), what was deliberately not touched (host network, the stored key), and what the design makes unreachable (the permissionless picker's usage string). None of them is an unverified claim about persistence behaviour, which was the direction this sprint actually expanded.

## 2026-08-02 — Sprint 4 Quality Verification

Sprint 4 verifies the Demo Mode offline guarantee and the seams that support it. The implementation work is recorded as three single-purpose commits on `sprint-4-quality`, based on `origin/main` `d5794d6`. The branch has not yet been merged; this section records verification evidence without claiming a completed merge.

### Automated verification — PASS

| Check | Command / scope | Observed result |
|---|---|---|
| Fresh project generation | `xcodegen generate` from the repository root | **PASS.** Completed independently before the test run. |
| Full suite | `xcodebuild test -project Menuscript.xcodeproj -scheme Menuscript -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` on iPhone 17 Pro / iOS 26.3.1 | **PASS.** Result `Passed`; `totalTestCount = 220`, `passedTests = 220`; device-dynamic runs passed = 245; 0 failed, 0 skipped, 0 expected failures. |
| F2 stress check | The two focused direct-photo preparation tests, repeated 10 times | **PASS.** All repetitions passed, covering off-main preparation and stable ordering. |
| Diff hygiene | `git diff --check` over the Sprint 4 documentation files | **PASS.** No whitespace errors. |

The suite includes the resolver precedence matrix; mock explanation/bill wiring with no secret or live-FX factory evaluation; explanation-cache provenance; direct-photo reservation, cap, off-main preparation, ordering, and failure blocking; permissive target-language fixtures; added FX cross-rates and copy; required `ExplainSheet` defaults / production wiring; and injected-vision FX hermeticity.

### Pending physical-device and network smoke checklist

No physical-device, airplane-mode, or live-key smoke test was performed in this environment. Each case below is deliberately **Pending**, not inferred from the simulator suite.

| ID | Steps | Expected result | Observed result |
|---|---|---|---|
| F1 | On a physical device, first create or reopen a session recorded as live with a valid Gemini key (the live-key smoke), then enable Demo Mode, remove/disable the usable key for the test device, enable airplane mode, request a dish explanation, and refresh the bill FX rate. Reopen the session after dismissing the sheet. | Explanation and supported mock FX succeed offline with no consent prompt; no live request can occur. The session's existing live explanation is not replaced by the Demo-Mode explanation. | **Pending — not performed in this environment.** |
| F2 | Use the physical camera to add several photos, including a quick multi-photo addition; also run the DEBUG demo path if available. Repeat while watching the camera-dismiss transition, ordering, capacity feedback, and recognition eligibility after deliberately causing a preparation failure in a DEBUG/test build. | JPEG preparation does not stall the main UI; accepted photos retain capture order; the cap is immediate; a failed preparation blocks recognition rather than submitting a partial batch; cancelled demo navigation does not continue recognition. | **Pending — not performed in this environment.** |
| F3 | In Demo Mode, recognize with target-language values `en`, `English (US)`, `廣東話`, `简体中文`, `日本語`, and an arbitrary string; open an explanation for at least one non-English fallback case. | `en` and text containing `english` use English fixture copy. Every other input succeeds deterministically with Traditional Chinese fixture copy; no unsupported-language alert is shown. | **Pending — not performed in this environment.** |
| F4 | In Demo Mode set home currency to PHP, then exercise a menu-to-bill conversion and refresh. Repeat with one other added currency (for example INR) and with an intentionally unsupported ISO-like code/pair. | Supported pairs show a deterministic mock conversion offline. An unsupported mock pair shows the Demo-Mode coverage message, not the live-network troubleshooting copy. | **Pending — not performed in this environment.** |
| F5 | In a debug/injected-defaults build, set Demo Mode only in the injected defaults and open a Menu dish explanation and Bill. Repeat with a live-mode injected setting and verify the disclosure/key path follows that same injected setting. | The explanation and bill read the same defaults scope and share the intended live-FX factory; no hidden fallback to `UserDefaults.standard` changes the selected mode. | **Pending — requires the injected-defaults smoke harness; not performed in this environment.** |
| F6 | In a debug/preview or test harness, inject a non-mock vision provider without an FX provider, run recognition with currencies that require conversion, then repeat with an explicit FX provider. | Omitted FX uses `MockFXService` regardless of inferred vision provenance; an explicit FX provider wins. The ordinary production resolver still chooses the live pair only when Demo Mode is off. | **Pending — requires the injection harness; not performed in this environment.** |

### Defects found during Sprint 4 review and resolution

The initial implementation passed its first full automated run, but a subsequent specification review found four correctness gaps before this verification record was written: a Demo-Mode explanation could overwrite a live-session cache; the target classifier did not honor strings containing `English`; the live-FX factory could be evaluated twice when constructing the Bill; and DEBUG auto-demo waited with a nondeterministic fixed count of 1,000 yields. The implementation now uses the cache provenance guard, `contains("english")` classifier, one `BillFXProviderSelection` resolution, and a cancellation-aware pending-photo wait described above. The final Sol/max specification gate and the independent standards/correctness gate both reported no blocker, P1, or P2 finding. The standards review's only earlier note was low-severity duplication of a test-only wait helper.

## 2026-08-16 — Sprint 5: Dynamic Type (AX3 / AX5) Verification

The peer review of 2026-08-02 (`docs/peer-review-1.txt`) noted that the app declares accessibility-size layout branches but carries no evidence that they were ever exercised, and asked for snapshot or UI tests. This section closes the *verification* half of that gap by hand: a simulator pass at two accessibility text sizes over the five screens a traveller actually uses, with a verdict for each screen at each size and every verdict traceable to a screenshot that was opened and read. It does not close the *automation* half — no snapshot or XCUITest coverage was added, and § Not run below says so.

### Scope & Environment

- **Date:** 2026-08-16. The run continued past midnight, so the retained evidence files carry host timestamps of both 2026-08-16 and 2026-08-17.
- **Branch:** `sprint-5-professional-completion` at `a41caf6` (`git rev-parse --short HEAD`). **The code under test was uncommitted working-tree state:** the Sprint 5 retention work (`Menuscript/Services/PhotoRetentionPolicy.swift`, `PhotoRetentionService.swift`, the Settings retention section, the MenuView pruned-photo notice) was present in the tree but not committed, so checking out `a41caf6` alone does not reproduce what was photographed here.
- **Simulator:** a **newly created** device, `Menuscript-AX-DT-20260816` (`EC32402C-8F1B-4D27-9BF8-9828BC6F5F8E`), device type iPhone 17, iOS 26.3 (26.3.1 – 23D8133). It was created for this pass precisely so that no existing device had to be booted, erased, or reset — in particular the device holding the § 2026-07-22 live-Gemini evidence was never named by any command in this pass. Every `simctl` invocation addressed the new UDID explicitly.
- **Build:** `xcodegen generate` (exit 0), then `xcodebuild build -project Menuscript.xcodeproj -scheme Menuscript -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath <scratch>/dd` → **BUILD SUCCEEDED**, exit 0. Debug configuration, because the `-autoDemo` deep links used to reach screens deterministically are `#if DEBUG`.
- **Automation channel:** `xcrun simctl ui <UDID> content_size <size>` to set the text size and, run bare, to read it back; `xcrun simctl launch` with the DEBUG launch arguments; `xcrun simctl io <UDID> screenshot` for every image; host-side `cliclick` for the few taps and drags that no launch argument can produce, always followed by a fresh screenshot. **No verdict below rests on an exit code — each one comes from a screenshot that was opened and read.**
- **Live requests:** none. Every launch passed `-settings.useMockProvider YES`; no Gemini call and no FX fetch was made at any point.
- **Evidence retained:** 132 screenshots in a scratch directory outside the repository (not committed, consistent with earlier passes); about thirty of them were read in full to produce the verdicts and findings below.
- **Text-size read-backs** (bare `content_size` prints the current value; taken before each capture group):

```
$ xcrun simctl ui EC32402C-8F1B-4D27-9BF8-9828BC6F5F8E content_size
large                                    # before the pass
accessibility-extra-large                # AX3, before every AX3 capture
accessibility-extra-extra-extra-large    # AX5, before every AX5 capture
large                                    # restored after the pass
```

- **How each screen was reached** (same arguments at both sizes): History — `-settings.useMockProvider YES`; Menu — `-autoDemo YES -settings.useMockProvider YES`; Bill — the same plus `-autoDemoScreen bill`; Settings — `-autoDemo YES -autoDemoScreen settings`; Capture ("Scan Menu") — launched into History, then the floating camera button tapped with `cliclick` and the resulting screen confirmed by screenshot. Long screens were scrolled with short host-side flick drags, one screenshot per flick.

### Verdict criteria (fixed before the pass, applied unchanged)

- **PASS** requires all of: no overlapping elements; every interactive control fully visible or scroll-reachable with a readable label; no text cut mid-glyph; content taller than the viewport is scroll-reachable; and, where an `isAccessibilitySize` branch exists in the source, the adapted layout actually rendered.
- **CLIPPING/FAIL:** an element partially off its container or off screen with no scroll path to it; overlapping interactive elements; or truncation that loses load-bearing information (price, total, currency code, button meaning).
- **NOTE, not failure:** a trailing `…` on decorative or repeated text; ugly-but-complete layouts, including hyphenated word wrapping that keeps every character.

### Verdict table

| Screen | How reached | AX3 | AX5 | Notes |
|---|---|---|---|---|
| History (Menus) | plain launch, mock provider | **PASS** | **CLIPPING (minor)** | AX5: the floating camera button overlays the last row's status label with no scroll path to clear it — finding D2. Row titles, dates, dish counts and status text are otherwise complete at both sizes. |
| Capture ("Scan Menu") | camera button tapped from History | **PASS (degraded)** | **PASS (degraded)** | The empty state and all four controls are complete and scroll-reachable at both sizes, but the two side-by-side add buttons wrap into hyphenated multi-line labels — at AX5 "Photo Library" becomes seven lines. Complete, so a note by the criteria above; recorded as finding D4. |
| Menu (dish list) | `-autoDemo YES` | **PASS** | **PASS (with D1)** | `MenuItemCard`'s accessibility branch (`MenuItemCard.swift:174`) and `CartBar`'s (`CartBar.swift:38,94`) both rendered: price above stepper, full-width Checkout. The last card scrolls clear of the cart bar at AX5, so the bottom `safeAreaInset` (`MenuView.swift:261`) is doing its job. AX5: the cart bar's converted total wraps mid-number — finding D1. |
| Bill | `-autoDemoScreen bill` | **PASS** | **PASS (with D3)** | All three `isAccessibilitySize` branches rendered — surcharge controls stacked (`BillView.swift:242`), total hero (`:455`) and per-person hero (`:544`) label-above-amount. Subtotal, surcharge, total, per-person, currency codes and the FX provenance line are complete at both sizes. AX5: the people stepper's value wraps between its − and + buttons — finding D3. |
| Settings | `-autoDemoScreen settings` | **PASS** | **PASS** | Scrolled end to end at both sizes, including the new **Menu Photo Retention** section: the "Keep photos for / 30 days" picker and its full footer render complete at AX5, as do "Clear All Menus" and the version line. AX5 note: the Language row's value truncates to `Follo…ystem` — the selection is still identifiable, so a note, not a failure. |

### Findings (documented, not fixed in this pass)

| # | Finding | Where | Severity | Judgment |
|---|---|---|---|---|
| D1 | At AX5 the cart bar's converted total wraps in the middle of the number, rendering as `$11.2` on one line and `5` on the next. Nothing is lost — the yen original `¥1800` and the dish/quantity summary are intact — but a split price is exactly the kind of number a user reads at speed. | `Menuscript/Features/Menu/Components/CartBar.swift` (the summary block inside the accessibility branch at `:38`) | Low, cosmetic | Note, not a failure: complete but degraded. A `minimumScaleFactor` or a line-break-mode on the amount would fix it. |
| D2 | At AX5 the History list's floating camera button sits on top of the last row's "Unfinished" status text, and the list has no compensating bottom inset, so the covered text cannot be scrolled clear. The row is still tappable outside the button and the same state is also carried by the clock icon and the section grouping. | `Menuscript/App/RootView.swift:60` — `.overlay(alignment: .bottomTrailing)` with no bottom `safeAreaInset`, in contrast with `MenuView.swift:261`, which does inset for its cart bar | Low | The only verdict in this pass recorded as clipping. The fix is the pattern the Menu screen already uses. |
| D3 | At AX5 the "Split the Bill" stepper's value wraps to two lines (`2` / `peo-ple`) and the wrapped text runs flush against the − and + controls. The controls remain distinct and tappable; the value is readable. | `Menuscript/Features/Bill/BillView.swift`, the people stepper row (the neighbouring hero blocks at `:455` and `:544` do reflow; this row does not) | Low | Note, not a failure. Worth reflowing for consistency with the two heroes directly below it. |
| D4 | The Capture screen's two add buttons are laid out in a fixed `HStack` that never reflows for accessibility sizes, so their labels hyphenate down to a few characters per line — "Photo Library" over five lines at AX3 and seven at AX5. Every character is present and all four controls stay scroll-reachable. | `Menuscript/Features/Capture/CaptureView.swift:250-278` (`addButtons`); this file has no `dynamicTypeSize` branch at all, unlike `BillView`, `MenuItemCard` and `CartBar` | Low–medium | Note by the fixed criteria (complete, reachable), but the worst-looking screen of the pass and the clearest candidate for the next accessibility change: stack the two buttons vertically when `dynamicTypeSize.isAccessibilitySize`. |

No layout code was changed in this pass. These are recorded as findings so that the next accessibility change starts from observed behaviour rather than a re-run of the same manual work.

### Harness limitations and artifacts

Recorded because each one changes what the evidence proves, and because the same automation channel misled an earlier pass (§ 2026-07-26, issue 5):

1. **The drag automation typed into the app.** During the first Settings scroll at AX3, a drag focused the Gemini model text field; the software keyboard then appeared under the next drag's start point, and three drags landed on the `g` key, inserting `ggg` into the model field. The app was uninstalled and reinstalled on the scratch device to reset all state, and the Settings pass was re-run from a clean install. No later screenshot in this record comes from the polluted state.
2. **A slow drag reads as a long press.** One Menu drag at AX5 produced the system Copy/Share text-selection callout instead of a scroll. Subsequent scrolling used quick flicks (short press dwell), and every flick was confirmed by a fresh screenshot.
3. **Right-edge horizontal drags trigger the system back affordance,** not the app. One attempt at scrolling the category chip row produced the OS "Back" HUD.
4. **Horizontal scrolling of the category chip row could not be demonstrated.** At both sizes the trailing category chip is cut off at the right edge. The source shows the row is a horizontal `ScrollView` (`Menuscript/Features/Menu/Components/CategoryChipsBar.swift:21`), so it should be reachable, but two further drag attempts moved it not at all, and synthetic scroll-wheel events (`CGEvent(scrollWheelEvent2Source:)` posted over the Simulator window) had no effect on the Simulator whatsoever. This is therefore recorded as **not observed** — neither a pass nor a defect.
5. **All later drags ran in the left margin of the screen,** outside the row cards, which is the only reliable way found to scroll a `Form` without focusing one of its text fields.

### Not run / not observed

| Item | Reason |
|---|---|
| Physical-device Dynamic Type | Not available in this environment. Simulator text-size rendering is a good proxy but not identical (fonts, safe areas, and the OS keyboard differ). |
| VoiceOver at accessibility sizes | Enabling VoiceOver would take over the touch model that drove every gesture in this pass. The accessibility labels themselves are covered by source evidence in § 2026-07-26 and by unit tests, not by this pass. |
| Horizontal scrolling of the category chip row | See harness limitation 4 — attempted, not achieved, not claimed. |
| The explanation sheet, the photo gallery, and the pruned-photo notice alert at AX sizes | Out of scope for this pass, which covered the five main screens; each needs a tap sequence that this channel can produce only unreliably. |
| The Camera and Photo Library flows themselves | The simulator has no capture device, and the library picker is out-of-process; only the buttons that open them were verified. |
| AX1, AX2, AX4 | Only the two ends of the accessibility range were exercised, on the assumption that AX3 and AX5 bracket the intermediate sizes. |
| The Sprint 4 physical-device and network smoke checklist (§ 2026-08-02) | Still **Pending**, unchanged by this pass. Nothing in this section alters those six cases. |

### Status

Dynamic Type is now **verified on the simulator at AX3 and AX5 for History, Capture, Menu, Bill and Settings**, with one minor clipping verdict (D2) and three complete-but-degraded layouts recorded (D1, D3, D4). The three screens that carry explicit `isAccessibilitySize` branches were confirmed to actually take those branches at both sizes, which is the specific claim the peer review said was unevidenced. What remains open is automation: this pass cost an engineer-hour-scale manual effort that a snapshot test at two text sizes would repeat for free, and that automation — not another manual pass — is the right next investment.

## 2026-08-16 — Sprint 5: Photo Retention Pruning Verification

This section verifies the behaviour the peer review of 2026-08-02 (`docs/peer-review-1.txt`) named its highest-priority recommendation: that original menu photos should not be kept indefinitely. The unit suite already proves the rules in isolation (`MenuscriptTests/Services/PhotoRetentionServiceTests.swift`, eleven tests). What this pass adds is the part a unit test cannot show — that a real session, finalized through the UI and then aged past the window, actually loses its photos on the next launch, keeps its settled bill byte-for-byte, and says so on screen.

It is a companion to the Dynamic Type section above, not a replacement: the two passes ran in the same Sprint 5 session on two separate, newly created simulators.

### Scope & Environment

- **Date:** 2026-08-16 session. The work itself ran in the early hours of **2026-08-17** host time, which is why every timestamp read out of the store below says `2026-08-17` and the seeded sessions are dated *Monday, Aug 17*.
- **Branch:** `sprint-5-professional-completion` at `a41caf6` (`git rev-parse --short HEAD`). **The code under test was uncommitted working-tree state** — `Menuscript/Services/PhotoRetentionPolicy.swift`, `PhotoRetentionService.swift`, `MenuSession.photosPrunedAt`, the Settings retention section and the `MenuView` pruned-photo notice were all present in the tree but not committed. Checking out `a41caf6` alone does not reproduce what is recorded here.
- **Simulator:** a **newly created** device, `Menuscript-Prune-20260816` (`C4AE78A5-1B47-4339-BDEF-0670449F5257`), device type iPhone 17, iOS 26.3 (26.3.1 – 23D8133). It was created for this pass so that no existing device had to be booted, erased, or reset; in particular the device holding the § 2026-07-22 live-Gemini evidence was never named in any command. Every `simctl` call addressed this UDID explicitly, and the device was left shut down (not deleted) so the seeded store stays inspectable.
- **Build:** `xcodegen generate` (exit 0), then `xcodebuild build -project Menuscript.xcodeproj -scheme Menuscript -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath <scratch>/dd` → **BUILD SUCCEEDED**, exit 0. Debug configuration, because the `-autoDemo` seeding path is `#if DEBUG`.
- **Automation channel:** `xcrun simctl launch` with DEBUG launch arguments to create sessions; host-side `cliclick` for the taps that reached the cart, the Bill and the Done button, with a fresh `xcrun simctl io … screenshot` after every tap; `sqlite3` against the app container's store, always with the simulator shut down, for the state that no screen shows. **No verdict below rests on an exit code** — each one comes from a screenshot that was opened and read, or from a pasted `SELECT`.
- **Live requests:** none. Every launch passed `-settings.useMockProvider YES`; no Gemini call and no FX fetch was made at any point.
- **Evidence retained:** 18 images in a scratch directory outside the repository (not committed, consistent with earlier passes) — 17 device screenshots plus one host-window capture used to calibrate the tap coordinates — together with the before/after hex dumps of the completed session's bill snapshot.

### Where seeding was required, and why

A 30-day retention window cannot be reached by waiting, and the app has no control that changes a session's creation date. Both shortcuts are recorded here because they change what the result proves:

1. **Ageing.** Three sessions were created through the DEBUG auto-demo path, one of them then completed through the UI (see P1 below). With the simulator **shut down** — a booted device caches the store and would overwrite an external edit — two rows were backdated by exactly 31 days:
   `UPDATE ZMENUSESSION SET ZCREATEDAT = ZCREATEDAT - (31*86400) WHERE Z_PK IN (1,3); PRAGMA wal_checkpoint(TRUNCATE);`
   Row 3 is the completed session (the case under test); row 1 is a draft (the do-no-harm case). Row 2 was left at today's date as the second control. Nothing else in the store was edited at any point — no lifecycle status was faked, and no snapshot was fabricated.
2. **Reading `photosPrunedAt` and the snapshot bytes.** Neither is visible in the UI, so both were read with `sqlite3` (`ZPHOTOSPRUNEDAT`, `ZBILLSNAPSHOTDATA`) before and after each run.

Store state **before** the launch that pruned (`Z_PK | status | createdAt | photosPrunedAt | length(photos) | length(billSnapshot)`):

```
1|draft|2026-07-17 07:38:55|0|1113|
2|draft|2026-08-17 07:39:04|0|1113|
3|completed|2026-07-17 07:39:13|0|1113|578
```

### Test Cases

| ID | Case | Verdict |
|---|---|---|
| P1 | A completed, aged session loses its photos and keeps its bill | **PASS** (with the notice *alert body* not observed — see below) |
| P2 | Do no harm: an aged draft and a same-day draft keep their photos | **PASS** |
| P3 | The prune is idempotent and survives a relaunch | **PASS** |

**P1 — a completed session aged past the window is pruned, and its settled bill is not.**

*Steps.* Three demo sessions were created (`-autoDemo YES -settings.useMockProvider YES`). One of them was then completed by hand: open the session, tap `+` twice on *Grilled eggplant* (cart shows `Dishes: 1 · Qty: 2`, `≈ $6.25 ¥1000`), tap **Checkout**, and tap **Done** on the Bill sheet. History moved that session into **Completed** and no error alert appeared — the post-finalize prune trigger (`RootView.swift:45-50`) therefore ran cleanly on a store with nothing yet eligible. Its Menu screen was screenshotted showing the ordinary **photo-stack** toolbar button. The session was then backdated 31 days as described above, and the app relaunched with `-settings.useMockProvider YES` only (no `-autoDemo`, so nothing new could shadow the seeded rows).

*Expected.* On next launch the session's photos are deleted, `photosPrunedAt` is stamped, the toolbar button becomes the pruned-photos notice, and the completed bill, its dishes and the session metadata are unchanged.

*Observed — all four.* Store state after the launch:

```
1|draft|2026-07-17 07:38:55||1113|
2|draft|2026-08-17 07:39:04||1113|
3|completed|2026-07-17 07:39:13|2026-08-17 07:43:16|219|578
```

Row 3's `ZPHOTOSPRUNEDAT` is now stamped and `length(ZPHOTOS)` fell from 1113 to 219 bytes — consistent with the archived form of the empty array that `session.photos = []` writes. The column is not zero-length afterwards, and this section does not claim it is. `length(ZBILLSNAPSHOTDATA)` is still 578, and a hex dump of those bytes taken before the prune and again afterwards is **byte-identical** (`shasum` of both dumps: `faab8d3d2ecc4dd34cf1cb8790ebbc8e361398e4`). The session still has its 10 `MenuItem` rows with the same total quantity of 2, and its title, people count and FX rate are unchanged (`鷹の目`, `2`, `0.00625`). On screen, the same session's toolbar button had changed from `photo.stack` to the `photo.badge.exclamationmark` notice button, while the completed order itself still read *Grilled eggplant ×2*, `≈ $6.25 / ¥1000`, with the untouched dishes still marked *Not included in the completed order*. No error alert appeared at any launch.

**P2 — do no harm.** The draft backdated by the same 31 days (row 1) and the same-day draft (row 2) both still show `length(ZPHOTOS) = 1113` and a `NULL` `photosPrunedAt` in the read-back above, and a draft's Menu screen still offers the ordinary photo-stack gallery button. Draft protection is therefore observed, not merely coded: the only difference between row 1 and row 3 was the lifecycle status and the presence of a bill snapshot.

**P3 — idempotent and durable.** The app was launched a second time and the store re-read after shutdown: `photosPrunedAt` still reads `2026-08-17 07:43:16` (the first prune's timestamp, not a fresh one), `length(ZPHOTOS)` is still 219, and the snapshot dump still hashes to `faab8d3d…`. The second pass therefore found nothing to do and wrote nothing, and the pruned state survived a relaunch.

### Harness limitations and artifacts

1. **The pruned-photos alert body was never displayed.** Three attempts (single click, repeated click, explicit press-and-release with a dwell) at the notice button's coordinates produced no alert. The same coordinates then failed to trigger *the existing photo-gallery button* on a draft session and the navigation **Back** button — both long-standing, working controls. Host taps in the top toolbar row simply did not register on this device, while taps lower on the screen (rows, steppers, Checkout, the Bill's Done button) all landed on the first or second try. This is therefore recorded as a limitation of the tap channel, **not** as evidence about the notice button, and the alert's title and message (`菜單相片已自動清理` / `原始菜單相片已按「保留期限」設定自動清理…`) remain source-only claims (`Menuscript/Features/Menu/MenuView.swift:178-182`). The *icon swap*, which is the part that tells a user their photos are gone, was observed.
2. **The demo photo data is small enough to be stored inline.** The container has no `_EXTERNAL_DATA` directory, so no on-disk file-size reclamation could be measured and none is claimed; the evidence for reclamation here is the `photos` column shrinking, plus the `@Attribute(.externalStorage)` declaration in the model. A real capture is the size class `externalStorage` exists for, but producing one needs the physical camera or a photo-library import that this channel cannot drive. Its magnitude was instead measured directly, on 2026-08-17, from the SwiftData stores of earlier simulators (copied out and read with `sqlite3` + `plistlib`; no device was booted or modified): the § 2026-07-22 live handwritten-menu session holds one **1200×1600 JPEG of 447,516 bytes (437 KB)**, and a second live session one 1188×1584 JPEG of 306,367 bytes. That is the persisted size class — note that 2,560 px (`Menuscript/Services/ImagePrep.swift:24`) is only the *decode* bound; what is saved is re-encoded at a 1,600 px long edge at quality 0.7 (`ImagePrep.swift:28`), which both measurements confirm.
3. **The window itself was not varied.** Everything above was observed with the default 30-day policy. The 90-day and keep-forever options, and the failure paths, were exercised only by the unit suite.

### Not run / not observed

| Item | Reason |
|---|---|
| The pruned-photos alert's title and message on screen | Harness limitation 1 — attempted three times, not achieved, not claimed. |
| The 90-day and keep-forever settings end to end | The same code path with a different constant: the window values are pinned by `PhotoRetentionPolicyTests` and `.forever` by the service's no-op test ("Keep forever performs no database work at all"). Repeating the pass at 91 days would re-exercise what was already observed here. |
| Changing the retention setting in Settings and watching a prune follow | The Settings picker itself was seen rendering (§ 2026-08-16 Dynamic Type, Settings row), but the setting was left at its default for this pass. |
| The failure paths (`PhotoRetentionError.fetchFailed` / `.saveFailed`) and their alert | Reachable only by injecting a throwing store; covered by two unit tests that assert the typed error and that every photo survives. |
| Storage actually reclaimed on disk | See harness limitation 2. |
| Physical-device behaviour | Unchanged from every earlier section: the app has still never run on hardware. |
| The Sprint 4 physical-device and network smoke checklist (§ 2026-08-02) | Still **Pending**, unchanged by this pass. |

### Status

Retention is **verified end to end on the simulator for the default 30-day policy**: an aged completed session is pruned, its immutable bill is byte-identical afterwards, aged drafts and same-day sessions are untouched, the prune is idempotent and durable across relaunch, and the UI distinguishes a pruned session from one that never had photos. Two gaps are named rather than glossed: the notice alert's text was not driven on screen, and no on-disk byte reclamation was measured because the demo photos are stored inline.

## 2026-08-18 — Sprint 5 Final Safety and Completion Addendum

This addendum records the frozen Sprint 5 state after an adversarial review found that the first retention implementation treated any non-`nil` snapshot bytes as sufficient evidence that the settled bill was recoverable. It also records the three small completion hardening items accepted before code freeze. Earlier dated sections remain historical evidence; the points below say exactly which evidence still applies and which behavior is new.

### Final automated verification — PASS

| Check | Evidence and observed result |
|---|---|
| Full frozen suite | **PASS — 2026-08-18.** 201 Swift Testing tests across 35 suites plus 41 XCTest tests = **242 total**, 0 failures. Exact `xcodebuild` result: `** TEST SUCCEEDED **`. The earlier 195 + 41 = 236 figure was the pre-safety checkpoint, not the final count. |
| Retention production fixtures | Every positive prune fixture now creates a deterministic selected-item session, captures it with `BillSnapshot.capture(from:completedAt:)`, and encodes it with `BillSnapshotCodec.encode`, matching production finalization. The old `Data("{\"v\":1}".utf8)` value remains only as deliberately corrupt negative input. |
| Retention invalid-state protection | Four new regression tests cover an expired corrupt snapshot, an expired unsupported-version snapshot, a mixed valid/corrupt batch, and an all-invalid batch. They assert that invalid records keep their photos and prune stamp unchanged; the mixed batch still prunes the valid record in one save, while the all-invalid batch saves nothing. |
| Completed-session FX write guard | A regression calls `SessionStore.updateFXRate` on a completed session and asserts exact `SessionStoreError.completedSessionCannotUpdateFXRate`, all five FX fields unchanged, zero save calls, and no pending context changes. The store throws before reading/mutating those fields. `BillView` retains its independent post-`await` completion recheck and suppresses only that expected typed race; generic persistence errors still alert. |
| Small-rate presentation | Parameterized coverage pins ordinary values, a small value, the exact `0.00000001` threshold, a positive value below it, and a value just above it. Output is POSIX fixed-decimal with at most eight fractional digits and trimmed trailing zeros; a positive value below the threshold is `<0.00000001`. |

### Why the 2026-08-16 retention pass remains applicable

The session in § *Sprint 5: Photo Retention Pruning Verification* was finalized through the production UI and held a real, readable v1 snapshot. The final safety change does not alter that eligible path: it strengthens the filter by requiring the stored snapshot to decode through the same production codec before `photos` is loaded and cleared. Its observations therefore remain valid for a readable completed bill — photo removal, `photosPrunedAt`, byte-identical bill data, draft protection, and relaunch durability.

That earlier pass does **not** prove the new invalid-snapshot behavior. Missing/corrupt/unsupported, mixed valid/corrupt, and all-invalid/no-save cases are automated unit evidence only. At the 2026-08-16 checkpoint the service suite had eleven tests; the four safety regressions above bring the final retention-service coverage to fifteen. This scope boundary is explicit so the earlier manual result is not silently stretched over behavior it never exercised.

### Draft-finalization confirmation — manual PASS

- **Date/environment:** 2026-08-18, iPhone 16e simulator, iOS 26.3, English UI, offline Demo Mode. No live Gemini or FX request was part of this pass.
- **Dialog:** On an editable draft Bill, tapping **Done** displayed the English finalization confirmation dialog.
- **Cancel/outside path:** Dismissing through the outside/cancel path left the draft on the editable Bill screen. The people count could still be changed from **2 → 3**, directly confirming that cancellation had not finalized the session.
- **Confirm path:** Opening the dialog again and choosing **Finish Bill** used the existing finalization path, returned to History, and showed the session under **Completed**.
- **Completed-session behavior:** The implementation retains the pre-existing direct-dismiss behavior for Done on an already completed bill; this pass specifically observed the two draft branches above.

### Still pending / not inferred

| Item | Final status |
|---|---|
| Physical-device smoke, including real camera and on-device performance | **Pending.** Menuscript has still not been run on physical hardware. |
| Airplane-mode device validation for the Sprint 4 offline guarantee | **Pending.** Simulator/unit evidence does not substitute for a radio-isolated device run. |
| Formal live-Gemini-key path, including first-use disclosure/cancel/accept cases | **Pending.** The informal 2026-07-22 simulator spot-check remains useful historical evidence, but it does not close the formal cases 1–2 or a current physical-device live-key smoke. |
| Pruned-photo notice alert body on screen | **Pending.** The icon swap was observed on 2026-08-16; the alert title/body still has source and localization coverage only because the toolbar tap did not land. |
| Actual external-storage disk reclamation | **Pending.** The demo payload's encoded column shrank, but no external file-size reduction was measured. |
| 90-day / keep-forever end-to-end behavior and injected retention failure alerts | **Pending at manual level.** These remain unit-covered only, as recorded in the 2026-08-16 section. |

The final 242-test pass, the narrow C2 simulator pass, and the earlier valid-snapshot retention evidence complete the frozen automated/simulator evidence claimed for Sprint 5. None of the pending device, live-key, alert-body, or storage-reclamation work is represented as passed.
