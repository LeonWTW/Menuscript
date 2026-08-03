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
