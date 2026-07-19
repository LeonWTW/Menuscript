# Menuscript

## Overview

Travelers who can't read the local language often can't understand a restaurant menu — dish names, ingredients, prices in an unfamiliar currency. The hard case isn't a clean, printed menu with a photo next to each item; it's the handwritten, locally-styled one: no printed layout, stylized handwriting, regional shorthand, nothing to point at. Generic camera-translation tools like Google Translate cope reasonably well with printed menus but tend to fall apart on these, producing garbled, near-unreadable output — which is exactly the case that actually matters once you're somewhere off the beaten path.

Menuscript is an iOS app built around solving that harder case. Point the camera at a menu — printed or handwritten, one photo or several — and an LLM vision model, not plain OCR, recognizes dish names in context, translates them, and flags anything it isn't confident about. From there you browse the translated menu by category, tap any dish for a plain-language AI explanation, and build a shared order. When it's time to settle up, the app computes a subtotal with a configurable surcharge/tax, splits the bill evenly ("AA") across diners, and converts the total into your home currency. Recognized sessions are saved as drafts; completing a bill freezes an immutable copy of the order and all values used to calculate it.

A core design principle: recognition quality on hard, handwritten menus is the product — the cart, bill-splitting, and history exist to make that useful end-to-end, not the other way around.

## Current Status

Prototype/spike stage — the core flow is implemented and working (milestones M1–M6 plus a bilingual-UI pass; see git history):

- **Capture** — multi-photo menu capture from the camera or photo library, feeding directly into the recognition pipeline.
- **Menu** — categorized, translated dish cards with a one-line AI summary per dish, advisory allergen warning icons, quantity controls, and one-tap Google Images photo search in an in-app browser; an on-demand AI "explain this dish" sheet, cached per dish; builds the cart.
- **Bill** — subtotal, configurable surcharge/tax, even ("AA") split across diners, converted to the home currency via Frankfurter v2 rates with a seven-day cached fallback. Completing a bill stores an immutable, versioned snapshot.
- **Settings** — bring-your-own Gemini API key (Keychain-backed, never bundled with the app), model selection (default `gemini-2.5-flash`), target language, a food-allergy filter (11 common presets + free-text custom), home currency, a mock-provider toggle, and app UI language (Traditional Chinese / English).
- **History** (the root screen) — locally persisted sessions separated into unfinished and completed sections. Saved menu photos can be reopened in an ordered, zoomable gallery; completed orders and bill inputs are read-only.

The automated suite covers provider requests, capture limits, offline mock behavior, FX fallback, persistence, immutable bill snapshots, localization, and privacy-manifest structure. See Quickstart below to run it locally.

See [Intentionally Deferred Features](#intentionally-deferred-features) below for what's explicitly out of scope for this prototype.

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

## Expected Behavior

Running one full feature slice end to end, from a fresh launch:

1. **Launch** — the app opens on **History** (the root screen), showing past sessions if any exist, or an empty state on first run.
2. **Capture** — start a new session; take a photo of a menu with the camera, or pick one or more photos from the library. Multi-photo capture is supported for menus that span several pages.
3. **Recognition** — before the first live request, the app explains that the selected menu photos and recognition context will be sent directly to Google Gemini. The user can continue or cancel. Mock mode uses built-in menu and FX providers and keeps the core Capture → Menu → Bill → History flow on-device.
4. **Menu** — the recognized menu renders as categorized, translated dish cards (original name, translated name, price), each with a one-line AI summary of what the dish is shown under the original name. Tapping a dish opens an on-demand, plain-language AI explanation (cached after the first request, and kept separate from the always-on summary); quantity controls on each card build the order. Each card also has a **photo button** that opens an in-app Safari view (`SFSafariViewController`, without leaving the app) searching Google Images for the dish's original-language name, so you can see roughly what it looks like. If you have configured any food-sensitivity allergens (see below), a dish that may contain one of them shows an **allergen warning icon**; tapping it opens an alert listing the specific flagged allergens alongside an advisory-only disclaimer — the app never states that a dish is safe, and always tells you to confirm with the restaurant.
5. **Order → Bill** — proceeding from the built order computes a subtotal, applies the configurable surcharge/tax, splits the total evenly ("AA") across a chosen number of diners, and converts the home-currency total using Frankfurter v2 blended reference rates. TWD is supported; a cached quote is used only while it is no more than seven days old.
6. **Complete** — tapping Done saves a versioned snapshot of the chosen lines, prices and market-price notes, quantities, currencies, FX quote/date/source, surcharge, totals, people count, per-person values, and completion time. Unpriced items remain visible but are explicitly excluded from totals. A repeated completion attempt is idempotent.
7. **History** — recognized sessions exist as unfinished drafts until completion. History separates unfinished and completed sessions; reopening a completed session shows the frozen order and bill read-only. When photos were saved, the photo-stack button opens them in capture order with page count and zoom.

**Food sensitivities (Settings).** Settings includes a **食物敏感 (food-sensitivity)** section where you can toggle any of eleven preset allergens — the US "Big 9" (peanut, tree nuts, milk, egg, fish, crustacean shellfish, soy, wheat, sesame) plus gluten and molluscs — and add free-text custom allergens. When any are set, they are passed into the recognition prompt so the vision model can flag dishes that, by typical recipe, may contain them. These flags are advisory only and, by design, apply only to menus recognized *after* the setting is changed — sessions already in History are not retroactively re-checked (each session records the allergen profile that was in effect when it was recognized, and the Menu shows a footnote making that "as recognized" scope explicit).

**With the mock provider** (Settings → mock-provider toggle on, no API key required): recognition and FX conversion use fixed, deterministic providers. The full core Capture → Menu → Bill → History flow makes no network request. The dish photo-search button remains an explicit external web action: tapping it opens Google Images in `SFSafariViewController`.

**With a real Gemini API key** (Settings → enter a key, mock-provider toggle off): Capture sends the selected menu images, target language, and any food-sensitivity preferences directly to Google's Gemini `generateContent` API. Dish-explanation requests send the selected dish text. The user-supplied API key authenticates those direct Google requests and may associate the data with the user's Google project. Menuscript has no proxy server. This path requires network access and a valid key, and has so far been exercised in development primarily through unit/integration tests rather than a full run on a physical device (see Intentionally Deferred Features below).

## Privacy & Data Handling

- Menu photos, recognized items, each session's allergen profile, bills, and history are stored locally with SwiftData. Current preferences and the seven-day FX cache use `UserDefaults`; the Gemini API key is stored at rest in Keychain.
- Live mode sends the data needed for recognition or explanation directly to Google Gemini only after an in-app disclosure. Mock mode does not access Gemini, Frankfurter, Keychain credentials, or live networking for the core flow.
- FX requests contain currency pairs and go directly to Frankfurter. Dish photo search is user initiated and loads Google Images in a system browser view.
- The app declares no tracking and no tracking domains. Its privacy manifest conservatively declares linked Photos/Videos, Other User Content, and Health data for App Functionality, plus the approved UserDefaults required-reason API.

## Intentionally Deferred Features

These are explicitly out of scope for the current prototype — not oversights, but deferred so the core feature slice (capture → recognize/translate → order → bill → history) stays the focus of Sprint 2:

- **Real-device, live-API end-to-end verification** — development so far has leaned on the mock provider and simulator; a full run with a live Gemini key on a physical device is outstanding.
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
- [Architecture](docs/architecture.md) — components, data flow, open questions

## Setup Notes

- This project uses XcodeGen — the `.xcodeproj` is generated from `project.yml`, not committed. Re-run `xcodegen generate` after pulling changes to `project.yml`. (The project, folders, and bundle id were renamed from the original working name `MenuTranslate` to `Menuscript` during Sprint 2 — the bundle id is now `com.leonwong.menuscript`. A Keychain-stored API key from a build under the old bundle id is not carried over; re-enter it in Settings after updating.)
- `RuntimeServiceResolver` atomically resolves a matched vision-and-FX service bundle: live mode uses `GeminiProvider` with `FXService`, while mock mode uses `MockVisionProvider` with `MockFXService` and remains fully offline.
- Currency conversion goes through `FXService`, which calls Frankfurter's v2 pair endpoint for blended reference rates (including TWD), then falls back to a cached quote only within a hard seven-day lifetime. A valid manual override takes precedence.
- Secrets never touch source or `UserDefaults`: the Gemini API key is entered at runtime and stored at rest only in iOS Keychain (`KeychainStore`). Live requests transmit it directly to Google as the API credential.
- Local data (session history) is stored on-device only via SwiftData — there is no backend server and no sync.
