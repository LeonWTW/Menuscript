# Bug Scan & Fixes — 2026-07-12

Record of a full-repo bug scan and the fixes applied afterwards, so future development knows what was found, what changed and why, and what is still open.

**Scan method.** Four parallel reviewer agents scanned the repo through four lenses (money/domain logic, concurrency & state, security/trust boundaries, future-development friction), findings were deduplicated, and each finding was then independently adversarially verified against the actual code before being accepted. Baseline before any change: `xcodebuild test` green (46 Swift Testing tests / 12 suites + 24 XCTest tests). Scan result: 15 confirmed findings (9 medium / 6 low), 1 refuted, 5 low-severity left unverified.

**Fix round.** All 9 medium findings were fixed the same day. After the fixes: `xcodebuild test` exit 0 — **59 Swift Testing tests / 13 suites + 25 XCTest tests, all passing** (14 new tests). The 6 low and 5 unverified findings are recorded in the backlog section below and remain unfixed.

---

## Fixed (9 medium findings)

### 1. Same-currency sessions rendered a duplicated "≈" self-conversion everywhere

- **Root cause:** `FXService.rate(from:to:)` returns `FXRate(rate: 1.0)` when the two currencies are equal, `CaptureViewModel` stored it into `session.fxRate`, and every conversion display (menu card, cart bar, bill total hero, bill per-person hero, FX status line) keyed only on `fxRate != nil`. A menu in the user's own home currency showed every amount twice.
- **Fix:** new computed `MenuSession.effectiveFXRate` returns `nil` whenever `menuCurrency == homeCurrency` (trimmed, case-insensitive) — this also neutralizes legacy rows that already persisted `1.0`. All display surfaces now key on `effectiveFXRate`. `CaptureViewModel.recognize()` skips the FX fetch entirely for same-currency menus, and `BillView.refreshFXRate()` early-returns for same-currency sessions.
- **Files:** `MenuSession.swift`, `CaptureViewModel.swift`, `BillView.swift`, `MenuView.swift` (card + cart bar call sites).
- **Tests:** `BillViewLogicTests` — `effectiveFXRate` nil for same-currency even with stored legacy 1.0; passthrough for differing currencies.

### 2. Forgotten manual FX override masqueraded as a fresh live rate

- **Root cause:** a manual override short-circuited the live fetch and was returned with `date: Date()` (read time), and `FXRate.source` was discarded on persist — so a months-old user-set rate rendered on the bill with today's date, indistinguishable from a live ECB rate, and the bill's refresh button silently re-returned the same override.
- **Fix:** `FXService.setManualOverride` now stores a set-date alongside the override value (`fx.override.date.<FROM>.<TO>` in the same defaults suite); `rate()` returns that stored date (legacy overrides without a stored date fall back to now). New persisted `MenuSession.fxSource: String?` (`"live"` / `"cached"` / `"manual"`, optional so SwiftData lightweight migration covers existing stores) is written by both `CaptureViewModel.recognize()` and `BillView.refreshFXRate()`. The bill status line labels manual-sourced rates as manually set (with the set date) instead of formatting them like a live dated rate.
- **Files:** `FXService.swift`, `MenuSession.swift`, `CaptureViewModel.swift`, `BillView.swift`, `Localizable.xcstrings` (2 new keys, en + explicit zh-Hant).
- **Tests:** `FXServiceTests` — manual override surfaces the stored set date, not read time; legacy override without a timestamp falls back to now.

### 3. Photo-load task raced recognition; late-arriving photos were excluded then destroyed

- **Root cause:** `CaptureView`'s `.onChange(of: pickerSelection)` spawned an untracked load task; iCloud-offloaded originals can take seconds to download with no loading UI; `pickerSelection` was only reset after all loads (so a mid-load re-pick duplicated items); failed loads were silently dropped by `try?`; and `recognize()` snapshotted the photo array, then on success called `photos.removeAll()` — wiping photos appended after the snapshot that were never recognized.
- **Fix:** `loadPickedPhotos` resets `pickerSelection` immediately (before any `await`), tracks an `isLoadingPhotos` state that shows a small loading row and disables the recognize button while loads are in flight, and counts failed loads into a visible footnote. `CaptureViewModel.recognize()` now removes exactly the recognized snapshot by object identity instead of `removeAll()`, so photos appended mid-recognition survive in the staging grid.
- **Files:** `CaptureView.swift`, `CaptureViewModel.swift`, `Localizable.xcstrings` (2 new keys).
- **Tests:** `CaptureViewModelTests` — a photo appended after recognition starts survives; the recognized snapshot is removed.

### 4. Changing app language mid-capture destroyed gathered photos, bypassing the discard confirmation

- **Root cause:** `MenuscriptApp` applies `.id(appLanguageRaw)` to `RootView` to rebuild the UI on language change — but that also destroyed all `@State` beneath it, including the `CaptureViewModel` holding captured photos and the `fullScreenCover` presentation state. Reachable mid-capture via the no-API-key alert → Settings sheet → language picker.
- **Fix:** ownership of `captureViewModel` moved above the `.id` boundary — `MenuscriptApp` now holds it as `@State` and passes a `@Binding` into `RootView`. A language switch still rebuilds the whole UI in the new language, but the VM (photos) and the cover presentation survive, and the existing discard-confirmation flow keeps its authority.
- **Files:** `MenuscriptApp.swift`, `RootView.swift`.
- **Tests:** none feasible at unit level (SwiftUI identity semantics); verified by build + full existing suite + code review.

### 5. FX fetch had no timeout while sitting in the recognition critical path

- **Root cause:** `FXService` defaulted to `URLSession.shared` (60 s request timeout). The FX call runs *after* a successful (paid) Gemini extraction and before the session is persisted, so a blackholed FX host held the recognition spinner up to a minute; a user cancel at that point discarded the paid extraction — for a rate that is only a nice-to-have (`fxRate = nil` is a supported state).
- **Fix:** `FXService.makeDefaultSession()` — ephemeral configuration with `timeoutIntervalForRequest = 10`, `timeoutIntervalForResource = 15` — is the new default; the injectable session parameter for tests is unchanged. (`GeminiProvider` already set its own 120 s request timeout.)
- **Files:** `FXService.swift`.
- **Tests:** `FXServiceTests` — default session enforces the 10 s / 15 s timeouts.

### 6. Price parser accepted negative LLM prices, silently reducing bill totals

- **Root cause:** `wirePriceDecimal`'s strict-parse regex allowed a leading `-?`, so a malformed Gemini reply like `{"price": "-500"}` became a real negative `Decimal` that flowed unguarded into cart subtotal, bill total, and per-person splits. Menu prices are never negative.
- **Fix:** regex tightened to `^[0-9]+(\.[0-9]+)?$`; a negative string now fails strict parse and falls through to the existing `priceNote` path like any other non-price text.
- **Files:** `GeminiProvider.swift`.
- **Tests:** `ExtractedMenuDecodeTests.testNegativePriceFallsThroughToPriceNote`.

### 7. Capture flow kept unbounded full-resolution photos in memory (jetsam risk)

- **Root cause:** picked photos were fully decoded at original resolution and up to six full-res `UIImage`s stayed alive for the whole flow; the thumbnail grid and `ImagePrep.jpegData` each forced full-bitmap decodes. Six 48 MP / panorama picks could exceed the foreground memory limit on 3–4 GB devices, killing the app mid-recognition.
- **Fix:** `ImagePrep.downsampledImage(from:maxPixelSize:)` decodes via ImageIO's thumbnail generator (`CGImageSourceCreateThumbnailAtIndex`, EXIF transform baked in) so the full bitmap is never materialized; `ImagePrep.captureMaxPixelSize = 2560` — comfortably above `jpegData`'s 1600 pt upload target, so recognition quality is unaffected. Picker loads go through the new helper; camera captures are capped by `ImagePrep.resized(_:maxLongEdge:)` inside `CameraPicker`.
- **Files:** `ImagePrep.swift`, `CaptureView.swift`, `CameraPicker.swift`.
- **Tests:** `ImagePrepTests` — 5000×4000 source decodes within the cap, aspect ratio preserved.

### 8 + 9. Cleared free-text Settings fields persisted `""`, defeating every `?? default` fallback

- **Root cause:** Settings `TextField`s bind directly to `@AppStorage`, so clearing a field persists an empty string — and every read site used `defaults.string(forKey:) ?? default`, which only fires on `nil`. An emptied model-name field made every recognition upload all photos and fail with an unexplained HTTP 404 (the empty model produces `/models/:generateContent`), with the error blaming the server. Same trap for target language and home currency.
- **Fix:** one shared helper, `SettingsKeys.nonEmptyString(_:from:default:)` — trims whitespace/newlines and falls back when the stored value is missing or empty. Applied at every read site of the free-text keys: `ProviderFactory` (model), `CaptureViewModel.recognize()` (target language, home currency), and `ExplainSheet` (target-language fallback, which also removes the old raw `?? "繁體中文"` double-fallback). Grep confirms no remaining raw `string(forKey:) ?? …` reads of these keys.
- **Files:** `SettingsKeys.swift`, `ProviderFactory.swift`, `CaptureViewModel.swift`, `ExplainSheet.swift`.
- **Tests:** `SettingsKeysTests` (new suite: missing / empty / whitespace-only / trimming / passthrough); `ProviderFactoryTests` — empty model key still yields a provider whose request URL uses the default model id.

---

## Verification

- Command: `xcodebuild test -project Menuscript.xcodeproj -scheme Menuscript -destination 'platform=iOS Simulator,name=iPhone 17'`
- Result after all fixes: exit 0, `Test run with 59 tests in 13 suites passed` (Swift Testing) plus 25 XCTest tests, 0 failures. Baseline before fixes: 46 + 24.
- Each fix stage was also gated: stage A (fixes 1, 2, 4, 5, 6) verified centrally; stage B (fixes 3, 7, 8+9) ran the full suite after each change set.
- All new `Localizable.xcstrings` keys carry both `en` and explicit `zh-Hant` entries (gated by `LocalizationTests`).

## Backlog — confirmed but not fixed (6 low)

1. `BillView` FX status line formats the rate with `%.4f` — VND-class rates display as `0.0000` next to correct conversions.
2. `BillView.refreshFXRate()` gives zero feedback when no rate can be resolved (offline with no cached pair) — spinner flashes, nothing changes.
3. `BillMath.fractionDigits` treats TWD (and IDR) as 2-decimal; by the app's own JPY precedent they should be 0-decimal for payable per-person amounts.
4. FX cache never expires — `CachedPayload.fetchedAt` is written but never read, so on network failure an arbitrarily old cached rate is served (the quote date is disclosed only in the bill footnote).
5. Photo grid uses `ForEach(…enumerated(), id: \.offset)` with render-time indices captured in delete closures — near-simultaneous taps can delete the wrong photo, and offset identity will break planned reorder/animation work.
6. `CaptureViewModelTests` writes to `UserDefaults.standard` inside the real-app test host and never restores — running the suite wipes the developer's in-app settings (the suspected parallel-test race half of this finding was refuted: the suite is fully `@MainActor`).

## Backlog — plausible but unverified (5 low)

1. `SettingsView.clearAPIKey` swallows Keychain delete errors via `try?` (a failed secret removal shows as success); `saveAPIKey` clears the input field even when the save threw.
2. `GeminiProvider`'s corrective retry re-uploads the full image payload for failures the corrective suffix cannot fix (MAX_TOKENS truncation, SAFETY empty responses) — doubled cost/latency for deterministic failures; `finishReason` is decoded but never consulted.
3. `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` in `project.yml` are dead: the XcodeGen-written `Info.plist` hardcodes `1.0`/`1` instead of referencing them — a future TestFlight version bump will silently not apply.
4. The default Gemini model id `gemini-2.5-flash` is duplicated in three code sites (`SettingsView` @AppStorage default, `ProviderFactory` fallback, `GeminiProvider` init default) with no shared constant or parity test.
5. No guard against code→catalog localization drift: a newly added UI string that never lands in `Localizable.xcstrings` still renders fine in zh-Hant (key == source text) and ships raw Chinese in the English UI; `LocalizationTests` only validates keys already in the catalog.

## Refuted during verification (for the record)

- `KeychainStore.get` mapping every failure `OSStatus` to `nil` ("no key stored") is real behavior but currently unreachable as a defect: all three call sites are foreground-unlocked UI paths. It becomes a genuine trap only if a share extension, background task, or App Intent entry point is added — revisit then.
