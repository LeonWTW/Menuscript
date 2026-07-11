# Menuscript

## Overview

Travelers who can't read the local language often can't understand a restaurant menu — dish names, ingredients, prices in an unfamiliar currency. The hard case isn't a clean, printed menu with a photo next to each item; it's the handwritten, locally-styled one: no printed layout, stylized handwriting, regional shorthand, nothing to point at. Generic camera-translation tools like Google Translate cope reasonably well with printed menus but tend to fall apart on these, producing garbled, near-unreadable output — which is exactly the case that actually matters once you're somewhere off the beaten path.

Menuscript is an iOS app built around solving that harder case. Point the camera at a menu — printed or handwritten, one photo or several — and an LLM vision model, not plain OCR, recognizes dish names in context, translates them, and flags anything it isn't confident about. From there you browse the translated menu by category, tap any dish for a plain-language AI explanation, and build a shared order. When it's time to settle up, the app computes a subtotal with a configurable surcharge/tax, splits the bill evenly ("AA") across diners, and converts the total into your home currency using live exchange rates. Every session — the photos, the recognized items, the final bill — is saved locally so you can revisit it later.

A core design principle: recognition quality on hard, handwritten menus is the product — the cart, bill-splitting, and history exist to make that useful end-to-end, not the other way around.

## Current Status

Prototype/spike stage — the core flow is implemented and working (milestones M1–M6 plus a bilingual-UI pass; see git history):

- **Capture** — multi-photo menu capture from the camera or photo library, feeding directly into the recognition pipeline.
- **Menu** — categorized, translated dish cards with quantity controls; an on-demand AI "explain this dish" sheet, cached per dish; builds the cart.
- **Bill** — subtotal, configurable surcharge/tax, even ("AA") split across diners, converted to the home currency via live FX rates with a cached fallback if the FX API is unreachable.
- **Settings** — bring-your-own Gemini API key (Keychain-backed, never bundled with the app), model selection (default `gemini-2.5-flash`), target language, home currency, a mock-provider toggle, and app UI language (Traditional Chinese / English).
- **History** (the root screen) — past sessions — photos, recognized items, bill — persisted locally with SwiftData and reopenable.

Test suite: **46 tests across 12 suites, all passing** (`xcodebuild test`, iPhone 17 simulator, iOS 26.3 runtime — see Quickstart below to reproduce).

See [Intentionally Deferred Features](#intentionally-deferred-features) below for what's explicitly out of scope for this prototype.

## Quickstart

Prerequisites: Xcode 16+ (iOS 17+ deployment target), [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
git clone git@github.com:LeonWTW/Menuscript.git
cd Menuscript
xcodegen generate
open MenuTranslate.xcodeproj
```

Build and run (`Cmd+R`) on an iOS 17+ simulator or device. On first launch, either:

- enter your own Gemini API key in Settings (stored in Keychain — nothing is bundled with the app), or
- turn on the mock-provider toggle in Settings to explore the app without a live key.

### Tests

```bash
xcodebuild test -project MenuTranslate.xcodeproj -scheme MenuTranslate \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

## Expected Behavior

Running one full feature slice end to end, from a fresh launch:

1. **Launch** — the app opens on **History** (the root screen), showing past sessions if any exist, or an empty state on first run.
2. **Capture** — start a new session; take a photo of a menu with the camera, or pick one or more photos from the library. Multi-photo capture is supported for menus that span several pages.
3. **Recognition** — the captured photo(s) are sent to the active vision provider (mock or Gemini, per the Settings toggle). A loading state is shown while recognition runs.
4. **Menu** — the recognized menu renders as categorized, translated dish cards (original name, translated name, price). Tapping a dish opens an on-demand, plain-language AI explanation (cached after the first request); quantity controls on each card build the order.
5. **Order → Bill** — proceeding from the built order computes a subtotal, applies the configurable surcharge/tax, splits the total evenly ("AA") across a chosen number of diners, and converts the home-currency total using a live FX rate (or the last cached rate if the FX API is unreachable).
6. **History** — completing the session saves the photos, recognized/translated items, and bill to local storage (SwiftData); it appears at the top of the History list and can be reopened to review the same data later.

**With the mock provider** (Settings → mock-provider toggle on, no API key required): recognition returns a fixed, deterministic sample menu instantly, with no network call. This is the fastest way to exercise the full Capture → Menu → Bill → History flow, including on the simulator, and is what the current automated test suite and day-to-day development exercise against.

**With a real Gemini API key** (Settings → enter a key, mock-provider toggle off): Capture sends the photo(s) to the live Gemini `generateContent` API and returns a real recognition/translation result for whatever menu was photographed — including handwritten and non-printed menus, which is the app's core differentiator. This path requires network access and a valid key, and has so far been exercised in development primarily through unit/integration tests against recorded responses rather than a full run on a physical device (see Intentionally Deferred Features below).

## Intentionally Deferred Features

These are explicitly out of scope for the current prototype — not oversights, but deferred so the core feature slice (capture → recognize/translate → order → bill → history) stays the focus of Sprint 2:

- **Real-device, live-API end-to-end verification** — development so far has leaned on the mock provider and simulator; a full run with a live Gemini key on a physical device is outstanding.
- **Technical rename of the Xcode project/bundle id** — the project, folders, and bundle id are still internally named `MenuTranslate`; renaming to match the `Menuscript` product name is planned for a later sprint (Keychain-stored API keys are tied to the current bundle id, so this needs care).
- **Additional UI/menu languages** — only Traditional Chinese and English are supported today; broader language coverage is future scope, not a limitation on who the app is meant to serve.
- **Itemized (unequal) bill splitting and tip calculators** — the current split is always even ("AA") across diners.
- **Offline-first recognition** — the app requires network access to reach the LLM provider; there's no on-device recognition fallback.
- **Social sharing / exporting translated menus** — not implemented.
- **Any custom backend server** — the app talks directly to third-party APIs (Gemini, Frankfurter) from the client; a backend proxy (e.g. to avoid bring-your-own-key) is a possible future direction, not current scope.

## Project Documents

- [Project Vision](docs/project-vision.md) — problem, users, goals, scope
- [Requirements](docs/requirements.md) — functional, data, and non-functional requirements
- [Architecture](docs/architecture.md) — components, data flow, open questions

## Setup Notes

- This project uses XcodeGen — the `.xcodeproj` is generated from `project.yml`, not committed. Re-run `xcodegen generate` after pulling changes to `project.yml`. (The Xcode project, folders, and bundle id are still internally named `MenuTranslate` — see Intentionally Deferred Features above.)
- The vision/translation provider sits behind a small protocol (`MenuVisionProvider`) selected at runtime by `ProviderFactory`: the real `GeminiProvider`, or `MockVisionProvider` for offline development and demos — controlled by the mock-provider toggle in Settings.
- Currency conversion goes through `FXService`, which calls the free [Frankfurter](https://frankfurter.dev) API and falls back to the last cached rate (or a manual override) if the network call fails.
- Secrets never touch source or `UserDefaults`: the Gemini API key lives only in the iOS Keychain (`KeychainStore`), entered by the user at runtime.
- Local data (session history) is stored on-device only via SwiftData — there is no backend server and no sync.
