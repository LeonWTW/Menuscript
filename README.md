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

Test suite: **42 tests across 11 suites, all passing** (`xcodebuild test`, iPhone 17 simulator, iOS 26.3 runtime — see Quickstart below to reproduce).

Pending before this becomes a real first release: end-to-end testing with a live Gemini API key on a real device (development so far has leaned on the mock provider), a technical rename of the Xcode project/bundle id to match the `Menuscript` product name, and the scope items tracked in [docs/project-vision.md](docs/project-vision.md#initial-scope) (additional languages, itemized splitting, offline support).

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

## Project Documents

- [Project Vision](docs/project-vision.md) — problem, users, goals, scope
- [Requirements](docs/requirements.md) — functional, data, and non-functional requirements
- [Architecture](docs/architecture.md) — components, data flow, open questions

## Setup Notes

- This project uses XcodeGen — the `.xcodeproj` is generated from `project.yml`, not committed. Re-run `xcodegen generate` after pulling changes to `project.yml`. (The Xcode project, folders, and bundle id are still internally named `MenuTranslate` — a technical rename to match the `Menuscript` product name is planned for a later sprint, not part of Sprint 1.)
- The vision/translation provider sits behind a small protocol (`MenuVisionProvider`) selected at runtime by `ProviderFactory`: the real `GeminiProvider`, or `MockVisionProvider` for offline development and demos — controlled by the mock-provider toggle in Settings.
- Currency conversion goes through `FXService`, which calls the free [Frankfurter](https://frankfurter.dev) API and falls back to the last cached rate (or a manual override) if the network call fails.
- Secrets never touch source or `UserDefaults`: the Gemini API key lives only in the iOS Keychain (`KeychainStore`), entered by the user at runtime.
- Local data (session history) is stored on-device only via SwiftData — there is no backend server and no sync.
