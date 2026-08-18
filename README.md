# Menuscript

## Overview

Travelers who can't read the local language often can't understand a restaurant menu — dish names, ingredients, prices in an unfamiliar currency. The hard case isn't a clean, printed menu with a photo next to each item; it's the handwritten, locally-styled one: no printed layout, stylized handwriting, regional shorthand, nothing to point at. Generic camera-translation tools like Google Translate cope reasonably well with printed menus but tend to fall apart on these, producing garbled, near-unreadable output — which is exactly the case that actually matters once you're somewhere off the beaten path.

Menuscript is an iOS app built around solving that harder case. Point the camera at a menu — printed or handwritten, one photo or several — and an LLM vision model, not plain OCR, recognizes dish names in context, translates them, and flags anything it isn't confident about. From there you browse the translated menu by category, tap any dish for a plain-language AI explanation, and build a shared order. When it's time to settle up, the app computes a subtotal with a configurable surcharge/tax, splits the bill evenly ("AA") across diners, and converts the total into your home currency. Recognized sessions are saved as drafts; completing a bill freezes an immutable copy of the order and all values used to calculate it.

A core design principle: recognition quality on hard, handwritten menus is the product — the cart, bill-splitting, and history exist to make that useful end-to-end, not the other way around.

## Current Status

Professional-completion candidate — the end-to-end core flow is implemented, documented, and verified at automated-test and simulator scope through Sprint 5 (see git history and the dated verification record):

- **Capture** — multi-photo menu capture from the camera or photo library, feeding directly into the recognition pipeline.
- **Menu** — categorized, translated dish cards with a one-line AI summary per dish, advisory allergen warning icons, quantity controls, and one-tap Google Images photo search in an in-app browser; an on-demand AI "explain this dish" sheet, cached per dish; builds the cart.
- **Bill** — subtotal, configurable surcharge/tax, even ("AA") split across diners, converted to the home currency via Frankfurter v2 rates with a seven-day cached fallback. Completing a bill stores an immutable, versioned snapshot.
- **Settings** — bring-your-own Gemini API key (Keychain-backed, never bundled with the app), model selection (default `gemini-2.5-flash`), target language, a food-allergy filter (11 common presets + free-text custom), home currency, a mock-provider toggle, menu-photo retention (30 days / 90 days / forever), and app UI language (Traditional Chinese / English).
- **History** (the root screen) — locally persisted sessions separated into unfinished and completed sections. Original menu photos can be reopened in an ordered, zoomable gallery while the selected retention policy keeps them; completed orders and bill inputs are read-only, and a notice replaces the gallery button after eligible photos are pruned.

The automated suite covers provider requests, capture limits, offline mock behavior, FX fallback, persistence, immutable bill snapshots, localization, and privacy-manifest structure. See Quickstart below to run it locally.

See [Intentionally Deferred Features](#intentionally-deferred-features) below for what's explicitly out of scope for this first version.

## Sprint 3 Expansion — Persistence

Sprint 3's expansion direction is **persistence**: a session that survives being abandoned, and a bill that can never silently change once it has been settled. It builds on the Sprint 2 feature slice rather than replacing any of it.

**What's new**

- **Draft/completed session lifecycle.** A recognized menu is persisted immediately as a *draft*. Leaving mid-order keeps it in History under 未完成 / *Unfinished*; completing the bill moves it to 已完成 / *Completed*. Sessions written before this field existed map to `legacyUnfinalized` — never to completed.
- **Immutable, versioned bill snapshots.** Confirming completion after tapping Done writes a `BillSnapshot` (version 1) holding every line and every input and output behind the totals: chosen lines, prices and market-price notes, quantities, currencies, the FX quote with its market date and source, surcharge, totals, people count, per-person values, and completion time. Completed screens render only from that snapshot and never recompute, so a later FX refresh or settings change cannot rewrite a bill the user has already paid.
- **History photo gallery.** While the selected retention policy keeps them, the menu photos captured for a session reopen in capture order in a paged, zoomable gallery with a page count.
- **A throwing persistence boundary.** `SessionStore` is the only writer of lifecycle state and snapshot bytes. `finalize` is idempotent — a second completion returns the persisted snapshot without writing — and restores the previous state if the save throws, so the UI can never show "completed" for something that was not saved. History deletion runs in an isolated, short-lived `ModelContext`, so a failed delete cannot damage what the UI is displaying.
- **Hardening that this direction forced into the open.** `RuntimeServiceResolver` resolves the vision and FX providers as a matched pair (live Gemini + live Frankfurter, or mock vision + mock FX — never a mix); the Gemini API key moved out of `UserDefaults` into Keychain behind a `SecretStore` protocol; the capture pipeline gained stable photo ordering, explicit limits, atomic saves, and cancellation; and `Resources/PrivacyInfo.xcprivacy` plus a one-time `GeminiDisclosureGate` now sit ahead of the first live Gemini request.
- **FX rate provenance is persisted and shown** (live / cached / manual / demo) and frozen into the snapshot, so a completed bill records which kind of rate produced its totals for the lifetime of that retained session. This closes a Sprint 2 AI-review finding that was deliberately postponed at the time.

**New dependencies: none.** The app still has zero third-party runtime dependencies — only Apple frameworks (SwiftUI, SwiftData, Security/Keychain, PhotosUI, SafariServices). `project.yml` declares no packages, and there is no `Package.swift`, `Podfile`, or `Cartfile`. XcodeGen, unchanged since Sprint 1, remains the only external tool and is build-time only.

**Run instructions: unchanged** — see [Quickstart](#quickstart) below. There is nothing new to configure: the expansion needs no API key and works fully offline with the demo provider.

**How to demonstrate it in about a minute.** Turn on **示範模式（Mock 數據）/ Demo Mode (Mock Data)** in Settings, recognize a menu, add a couple of dishes, open Bill — then leave *without* tapping Done: the session appears in History as *Unfinished*. Reopen it, tap Done, and choose **Finish Bill** in the confirmation dialog; it moves to *Completed*. Reopening it now shows the frozen order and bill with no quantity steppers, no surcharge control and no rate refresh, and the photo-stack button replays the original menu photos while the selected retention policy keeps them.

**Where to look.** `Menuscript/Models/BillSnapshot.swift`, `Menuscript/Models/MenuSession.swift`, `Menuscript/Services/SessionStore.swift`, `Menuscript/Services/RuntimeServiceResolver.swift`, `Menuscript/Features/Menu/HistoryPhotoGalleryView.swift`. The design rationale is in [docs/architecture.md](docs/architecture.md); the hands-on evidence is in [docs/manual-verification.md](docs/manual-verification.md).

## Sprint 4 — Demo-Mode Quality Hardening

Sprint 4 completes the important capability promised by Demo Mode: turning it on is an **offline guarantee**, even when a saved session records that it was originally created in live mode. The work was merged to `main` by PR #8 at merge commit `a740bc0`.

- **F1 — one runtime decision.** Demo Mode takes precedence over persisted session provenance for recognition, dish explanation, and bill FX. In the mock branch the app does not seek consent, read the API key, construct the live FX factory, or call Gemini/Frankfurter. A mock explanation fetched for a formerly live session is visible for that sheet only and cannot overwrite the session's persisted live explanation.
- **F2 — responsive direct photo capture.** Camera and DEBUG/direct additions reserve their capped slots immediately, then prepare JPEGs away from the main actor in submission order. Stable slots preserve photo order; preparation failure blocks recognition rather than sending a partial batch. The DEBUG auto-demo path waits for preparation deterministically and honors cancellation.
- **F3 — forgiving demo-language input.** The mock fixture selects English for exactly `en` or text containing `english`; every other target-language value deterministically uses its Traditional Chinese fixture projection without throwing.
- **F4 — broader offline FX.** `MockFXService` now supports 15 additional USD quote currencies — PHP, INR, IDR, MYR, NZD, DKK, NOK, SEK, PLN, CZK, TRY, AED, SAR, BRL, and ZAR — and derives all supported cross-rates from one internally consistent table. Unsupported pairs say that Demo Mode has finite coverage instead of blaming the network. The bill receives its provider and mode as one resolved selection.
- **F5/F6 — safer dependency seams.** `ExplainSheet` now requires explicit `UserDefaults`, and `MenuView` forwards its injected defaults and live-FX factory; previews supply defaults explicitly. Test/preview injection with a custom vision provider and no explicit FX provider defaults to `MockFXService`, while production resolution stays unchanged.

The quality suite exercises resolver precedence, explanation-cache provenance, capture ordering/failure behavior, mock-language fallback, deterministic FX cross-rates, mode-specific copy, production wiring, and hermetic test seams. At the historical Sprint 4 checkpoint, the automated simulator result was **PASS**: `xcodegen generate` succeeded independently, then `xcodebuild test` on iPhone 17 Pro / iOS 26.3.1 reported `Passed` with 220/220 tests passed (245 device-dynamic runs; 0 failed, 0 skipped, 0 expected failures). The two focused direct-photo tests also passed in a 10-iteration repetition. Physical-device, airplane-mode, and live-key smoke checks remain pending; see [manual verification](docs/manual-verification.md#2026-08-02--sprint-4-quality-verification) for the exact checklist.

## Sprint 5 — Professional Completion and Safety

Sprint 5 turns the completed first-version scope into a professional-completion candidate: it responds to external peer review, closes one irreversible-retention safety gap, adds focused finalization and FX hardening, and brings the requirements, architecture, verification, and AI-engineering record into line with the frozen implementation. Git/Canvas submission is a separate final workflow step and is not claimed here.

- **Recoverability before photo deletion.** The retention service considers cheap lifecycle, prior-prune, and age checks first; it then requires the completed bill snapshot to decode successfully as a version this app supports before it loads or deletes the original photos. Missing, malformed/corrupt, and future-version snapshots stay protected. Eligible pruning clears only `photos` and sets `photosPrunedAt`; the session, dishes, lifecycle, FX metadata, and frozen bill remain.
- **A deliberate irreversible step.** Tapping Done on an editable draft now presents a confirmation dialog. Cancel keeps the bill editable; Finish Bill uses the existing atomic finalization path. A completed bill's Done button still dismisses directly.
- **Completed-session FX integrity.** `SessionStore` rejects a late FX write with a typed error before touching any of the five quote fields, while `BillView` rechecks completion after its awaited fetch and treats that expected race as a quiet cancellation. Other persistence failures still surface an alert.
- **Readable small rates.** FX rates use a POSIX fixed-decimal representation with up to eight fractional digits and trimmed trailing zeros; a positive value below `0.00000001` displays as `<0.00000001` instead of rounding to zero.

The final frozen automated run on 2026-08-18 passed **201 Swift Testing tests across 35 suites plus 41 XCTest tests — 242 total, 0 failures** — and ended with `** TEST SUCCEEDED **`. This does not stand in for the still-pending physical-device, airplane-mode-device, or formal live-key validation listed in [manual verification](docs/manual-verification.md).

## Quickstart

Prerequisites: Xcode 16+ (iOS 17+ deployment target), [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
git clone git@github.com:LeonWTW/Menuscript.git
cd Menuscript
xcodegen generate
open Menuscript.xcodeproj
```

Build and run (`Cmd+R`) on an iOS 17+ simulator or device. On first launch, either:

- enter your own Gemini API key in Settings (stored in Keychain — nothing is bundled with the app), or
- turn on the mock-provider toggle in Settings to explore the core flow offline without a live key.

### Tests

```bash
xcodebuild test -project Menuscript.xcodeproj -scheme Menuscript \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

The final Sprint 5 run on 2026-08-18 passed 201 Swift Testing tests across 35 suites plus 41 XCTest tests: **242 total, 0 failures**, with the exact `xcodebuild` result `** TEST SUCCEEDED **`. The 220-test result above is retained as an explicitly historical Sprint 4 checkpoint.

## Expected Behavior

Running one full feature slice end to end, from a fresh launch:

1. **Launch** — the app opens on **History** (the root screen), showing past sessions if any exist, or an empty state on first run.
2. **Capture** — start a new session; take a photo of a menu with the camera, or pick one or more photos from the library. Multi-photo capture is supported for menus that span several pages.
3. **Recognition** — before the first live request, the app explains that the selected menu photos and recognition context will be sent directly to Google Gemini. The user can continue or cancel. Mock mode uses built-in menu and FX providers and keeps the core Capture → Menu → Bill → History flow on-device.
4. **Menu** — the recognized menu renders as categorized, translated dish cards (original name, translated name, price), each with a one-line AI summary of what the dish is shown under the original name. Tapping a dish opens an on-demand, plain-language AI explanation (cached after the first request, and kept separate from the always-on summary); quantity controls on each card build the order. Each card also has a **photo button** that opens an in-app Safari view (`SFSafariViewController`, without leaving the app) searching Google Images for the dish's original-language name, so you can see roughly what it looks like. If you have configured any food-sensitivity allergens (see below), a dish that may contain one of them shows an **allergen warning icon**; tapping it opens an alert listing the specific flagged allergens alongside an advisory-only disclaimer — the app never states that a dish is safe, and always tells you to confirm with the restaurant.
5. **Order → Bill** — proceeding from the built order computes a subtotal, applies the configurable surcharge/tax, splits the total evenly ("AA") across a chosen number of diners, and converts the home-currency total using Frankfurter v2 blended reference rates. TWD is supported; a cached quote is used only while it is no more than seven days old.
6. **Complete** — tapping Done on a draft presents a confirmation dialog before the irreversible step. Cancel leaves the draft editable; confirming saves a versioned snapshot of the chosen lines, prices and market-price notes, quantities, currencies, FX quote/date/source, surcharge, totals, people count, per-person values, and completion time through the existing atomic finalization path. Unpriced items remain visible but are explicitly excluded from totals. A repeated completion attempt is idempotent, and Done on an already completed bill dismisses directly.
7. **History** — recognized sessions exist as unfinished drafts until completion. History separates unfinished and completed sessions; reopening a completed session shows the frozen order and bill read-only. While original photos are retained, the photo-stack button opens them in capture order with page count and zoom. The photos of an eligible **completed** session are kept for 30 days by default — configurable in Settings → **菜單相片保留 / Menu Photo Retention** as 30 days, 90 days, or keep forever, measured from `createdAt` — and are pruned on the next app launch or immediately after a bill is finalized once the inclusive age boundary is reached. Eligibility additionally requires a stored bill snapshot that this app version can decode; unfinished and legacy menus and completed sessions with a missing, malformed/corrupt, or unsupported snapshot remain protected. For a pruned session the photo button becomes a pruned-photos notice; the completed bill, session, and dish records are unaffected. Extending retention later cannot restore deleted photos.

**Food sensitivities (Settings).** Settings includes a **食物敏感 (food-sensitivity)** section where you can toggle any of eleven preset allergens — the US "Big 9" (peanut, tree nuts, milk, egg, fish, crustacean shellfish, soy, wheat, sesame) plus gluten and molluscs — and add free-text custom allergens. When any are set, they are passed into the recognition prompt so the vision model can flag dishes that, by typical recipe, may contain them. These flags are advisory only and, by design, apply only to menus recognized *after* the setting is changed — sessions already in History are not retroactively re-checked (each session records the allergen profile that was in effect when it was recognized, and the Menu shows a footnote making that "as recognized" scope explicit).

**With the mock provider** (Settings → mock-provider toggle on, no API key required): recognition and FX conversion use fixed, deterministic providers. Demo Mode wins over any live provenance recorded on an older session, so the full core Capture → Menu → Bill → History flow — including dish explanations and a Bill refresh — makes no network request and does not read the Gemini key. The dish photo-search button remains an explicit external web action: tapping it opens Google Images in `SFSafariViewController`.

**With a real Gemini API key** (Settings → enter a key, mock-provider toggle off): Capture sends the selected menu images, target language, and any food-sensitivity preferences directly to Google's Gemini `generateContent` API. Dish-explanation requests send the selected dish text. The user-supplied API key authenticates those direct Google requests and may associate the data with the user's Google project. Menuscript has no proxy server. This path requires network access and a valid key. A historical informal simulator spot-check recognized 36 dishes from a handwritten Japanese izakaya menu, recorded in [docs/manual-verification.md](docs/manual-verification.md); the formal first-use/live-key cases and any physical-hardware run remain pending (see Intentionally Deferred Features below).

## Privacy & Data Handling

- Menu photos, recognized items, each session's allergen profile, bills, and history are stored locally with SwiftData. Current preferences and the seven-day FX cache use `UserDefaults`; the Gemini API key is stored at rest in Keychain.
- Menu photos are the dominant local storage cost. The selected policy is 30 days by default, 90 days, or keep forever; it applies to existing local history as well as newly completed sessions and measures fixed-day age from `createdAt` with an inclusive boundary. At launch and after finalization, only an old completed session whose stored bill decodes successfully in this app version is eligible. Missing, corrupt/malformed, and unsupported snapshots keep their photos. Pruning is local-only and changes only `photos = []` and `photosPrunedAt`; it does not transmit data or alter the session, dishes, or bill. Deletion is irreversible, so extending the window cannot restore photos already removed.
- Live mode sends the data needed for recognition or explanation directly to Google Gemini only after an in-app disclosure. Mock mode does not access Gemini, Frankfurter, Keychain credentials, or live networking for the core flow.
- FX requests contain currency pairs and go directly to Frankfurter. Dish photo search is user initiated and loads Google Images in a system browser view.
- The app declares no tracking and no tracking domains. Its privacy manifest conservatively declares linked Photos/Videos, Other User Content, and Health data for App Functionality, plus the approved UserDefaults required-reason API.

## Intentionally Deferred Features

These are explicitly out of the completed first-version scope — not oversights, but deferred so that the core feature slice (capture → recognize/translate → order → bill → history) and its persistence/safety work stay the focus:

- **Physical-device, airplane-mode, and formal live-key verification** — a historical informal simulator spot-check used a real Gemini key (`docs/manual-verification.md`, § 2026-07-22), but the app has never run on physical hardware. Real camera capture, device performance, airplane-mode isolation, and the formal first-use disclosure/live-key path remain unverified.
- **Retention UI/storage evidence gaps** — the pruned-session icon swap was observed, but the notice alert body was not successfully driven on screen and actual external-storage disk reclamation was not measured. Both remain explicitly pending rather than inferred from source or unit tests.
- **Additional UI/menu languages** — only Traditional Chinese and English are supported today; broader language coverage is future scope, not a limitation on who the app is meant to serve.
- **Itemized (unequal) bill splitting and tip calculators** — the current split is always even ("AA") across diners.
- **Offline live recognition** — live Gemini recognition has no on-device fallback. Mock mode is fully offline for the core flow, but returns fixed demo content rather than recognizing the photographed menu.
- **Social sharing / exporting translated menus** — not implemented.
- **Any custom backend server** — the app talks directly to third-party APIs (Gemini, Frankfurter) from the client; a backend proxy (e.g. to avoid bring-your-own-key) is a possible future direction, not current scope.
- **A distinct "danger" color for allergen warnings** — the allergen warning icon currently reuses the same amber warning color (`mtWarning`) as the low-confidence indicator, distinguished only by icon shape; adding a dedicated red danger color token to the theme is deferred.
- **Retroactive allergen re-checking of past sessions** — changing the food-sensitivity settings only affects menus recognized afterward; already-saved sessions are not re-analyzed against the updated allergen list (each session keeps the allergen profile it was recognized under, and the Menu footnote makes that scope explicit).

## Project Documents

- [Project Vision](docs/project-vision.md) — problem, users, goals, scope
- [Requirements](docs/requirements.md) — functional, data, and non-functional requirements
- [Architecture](docs/architecture.md) — components, data flow, and how the architecture evolved through Sprint 5, including photo-retention safety and completed-session write guards
- [Manual Verification](docs/manual-verification.md) — hands-on test cases with expected and observed results, issues found, and what was deliberately not exercised
- [AI Implementation Review](docs/ai-implementation-review.md) — how AI was used per sprint, the AI-assisted engineering reviews, and which findings were accepted or postponed

## Setup Notes

- This project uses XcodeGen — the `.xcodeproj` is generated from `project.yml`, not committed. Re-run `xcodegen generate` after pulling changes to `project.yml`. (The project, folders, and bundle id were renamed from the original working name `MenuTranslate` to `Menuscript` during Sprint 2 — the bundle id is now `com.leonwong.menuscript`. A Keychain-stored API key from a build under the old bundle id is not carried over; re-enter it in Settings after updating.)
- `RuntimeServiceResolver` atomically resolves a matched vision-and-FX service bundle: live mode uses `GeminiProvider` with `FXService`, while mock mode uses `MockVisionProvider` with `MockFXService` and remains fully offline.
- Currency conversion goes through `FXService`, which calls Frankfurter's v2 pair endpoint for blended reference rates (including TWD), then falls back to a cached quote only within a hard seven-day lifetime. A valid manual override takes precedence.
- Secrets never touch source or `UserDefaults`: the Gemini API key is entered at runtime and stored at rest only in iOS Keychain (`KeychainStore`). Live requests transmit it directly to Google as the API credential.
- Local data (session history) is stored on-device only via SwiftData — there is no backend server and no sync.
