# Architecture

## Overview
Menuscript is a client-only iOS app (SwiftUI + SwiftData) that talks directly to third-party APIs — there is no custom backend server. The device does all orchestration: capturing photos, calling the LLM vision provider, computing the bill, and persisting history locally.

## Major Components
- **Client / User Interface**: SwiftUI views organized by feature — Capture (photo picker/camera), Menu (browse/translate/cart), Bill (surcharge, split, totals), Settings (API key, language, currency), and a root History list.
- **Server / Application Logic**: No custom server. Application logic runs on-device: a provider factory selects between a real Gemini-based vision provider (calls Google's Gemini API directly, using the user's own API key) and a mock vision provider for offline/demo use. A currency service calls a free public FX API for exchange rates.
- **Data / Persistence**: SwiftData models store session history locally on-device. The platform Keychain stores the user's Gemini API key. Local app preferences store settings and a cached copy of the last-known FX rates.

## Component Responsibilities
- **Capture**: gather one or more menu photos and hand them to the recognition pipeline.
- **Menu**: request recognition/translation from the provider, render categorized dish cards, manage cart state, request and cache per-dish AI explanations.
- **Bill**: compute subtotal, surcharge, total, and an even split across diners from cart and FX data, using bill math kept separate from the UI so it can be tested independently.
- **Settings**: manage user-configurable state — API key, target language, home currency, model choice, mock-provider toggle, app UI language.
- **Services layer**: isolate all external I/O (LLM calls, FX calls, secure-storage access) behind small provider interfaces, so the UI and business logic don't depend on a specific vendor.

## Implementation Mapping (Sprint 2)

How the Sprint 2 feature slice maps onto the standard client/server/route/data breakdown, reflecting the actual implementation rather than the plan:

- **Client**: SwiftUI views, one module per feature under `Menuscript/Features/` — `Capture` (camera/photo-library picker), `Menu` (categorized translated dish cards, cart, per-dish AI explanation sheet), `Bill` (surcharge, even split, home-currency total), `Settings` (API key, model, target language, home currency, mock-provider toggle, app UI language), and a root `History` list backed by SwiftData. Screens hold view state; bill math and provider calls live outside the views so they're independently testable.
- **Server**: no custom backend — there is nothing to deploy or operate. All application logic that would otherwise live server-side runs on-device in the `Menuscript/Services/` layer: `ProviderFactory` selects between `GeminiProvider` and `MockVisionProvider` behind the shared `MenuVisionProvider` protocol, and `FXService` owns currency-conversion logic. This on-device services layer is the closest analogue to "server" in this architecture.
- **Route**: no app-defined API surface (no REST/GraphQL routes of our own). The app's only outbound "routes" are two direct HTTPS calls to third-party APIs, each encapsulated behind its provider/service: `GeminiProvider` calls `POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent` for both menu recognition/translation and per-dish explanations; `FXService` calls `GET https://api.frankfurter.dev/v1/latest` for exchange rates. Nothing else in the app's own networking code makes API calls (the photo-search feature opens `google.com` inside a system `SFSafariViewController` — a browser view, not an app API route).
- **Data**: three local, on-device stores, no remote database. SwiftData persists session history (photos, recognized/translated items, bill) for the History list. The iOS Keychain (via `KeychainStore`) holds the user's Gemini API key — never written to source, `UserDefaults`, or SwiftData. `UserDefaults`/`AppStorage` holds user preferences (target language, home currency, model choice, mock-provider toggle, app UI language) and a cached last-known FX rate used as a fallback when `FXService`'s network call fails.

### Feature extension: allergen advisories + photo search

Two later Sprint 2 UX features — per-dish allergen advisories (with an always-on one-line summary) and one-tap dish photo search — extend the same client/services/data breakdown without adding a server or a new outbound route:

- **New files.** `Menuscript/Models/Allergen.swift` defines the eleven preset allergens as a `CaseIterable` enum plus pure, unit-testable helpers: `Allergen.parse(presets:custom:)` turns the stored preset slugs and free-text custom entries into a de-duplicated, length-capped list of stable English `promptLabel`s for the prompt, `displayLabel(for:)` maps an AI-returned label back to a localized display name (verbatim fallback when it matches nothing), and `selectedSlugs`/`serialize` back the Settings toggle bindings. `Menuscript/Features/Menu/PhotoSearch.swift` builds the Google Images search URL for a dish (`imagesURL(query:)` → `https://www.google.com/search?q=…&tbm=isch`, `nil` on a blank query, CJK percent-encoding handled by `URLComponents`). `Menuscript/Features/Menu/Components/SafariView.swift` is a small `UIViewControllerRepresentable` wrapping `SFSafariViewController` so the image search opens in-app rather than kicking out to the system browser.
- **Extended extraction contract (services layer).** The `MenuVisionProvider` protocol's `extractMenu(images:targetLanguage:allergens:)` gains an `allergens: [String]` parameter. `ExtractedMenu.Item` (and the persisted `MenuItem`) gain a `summary` — always requested, a one-line description of the dish, kept separate from the on-demand `explanation` used by the ExplainSheet — and `possibleAllergens`, requested only when the user has allergens configured. `GeminiProvider` adds the corresponding prompt rules and JSON response-schema fields *conditionally* on whether the allergen list is non-empty (`summary` is always required in the schema; `possibleAllergens` is added to `properties`/`required` only when `includeAllergens` is true), and carries the allergen list through its one corrective-retry rebuild so the retry never silently downgrades to the no-allergen prompt/schema. `MockVisionProvider` returns fixed summaries and hard-coded allergen hits (e.g. 唐揚げ → wheat/soy/egg) so the whole feature demos offline. This is an extension of the existing single Gemini `generateContent` route — no new endpoint.
- **Persistence (Data).** `MenuItem` gains `summary` and `possibleAllergens`; `MenuSession` gains `allergenProfile` — a snapshot of the allergen list that was in effect when the menu was recognized, populated in `CaptureViewModel.recognize()` alongside the existing `fxRate`/`homeCurrency` snapshots, so a session's advisories stay tied to the settings under which it was produced (and stale settings never retroactively change an old session). All three new fields are optional/defaulted for lightweight SwiftData migration. Two new `UserDefaults`/`AppStorage` preference keys — `settings.allergenPresets` (comma-joined slugs) and `settings.allergenCustom` (raw free text) — hold the user's selections.

## Data Flow
A user opens Capture and photographs a menu → photos are sent through the provider factory to the LLM vision provider, which returns recognized and translated dish data → the Menu screen renders this and lets the user request per-dish explanations and build a cart → the user proceeds to Bill, where subtotal, surcharge, and an even split are computed and converted to the home currency via the FX service → the completed session (photos, items, bill) is saved locally and appears in the root History list for later reopening.

## Initial Architecture Sketch
```
[Capture] --photos--> [Provider Factory] --> [Gemini Provider | Mock Provider]
                                                     |
                                                     v
                                    [Menu: dish cards, cart, dish explanations]
                                                     |
                                                     v
                                [Bill: subtotal/surcharge/split --> home-currency total]
                                                     |
                                                     v
                                    [Local storage: session] --> [History list]

Keychain (API key) <---- [Settings] ----> Local prefs (language, currency, FX cache)
```

## Open Questions
- Should a lightweight backend proxy be introduced later so users don't each need their own Gemini API key (bring-your-own-key), and if so, who bears the API cost?
- How should additional UI/menu languages be added — is the current localization approach structured to scale, or does it need rework first?
- Is on-device-only history sufficient long-term, or will users eventually want sync across devices?
- What's the right confidence threshold and UX for flagging low-confidence menu recognition before it becomes more annoying than helpful?
