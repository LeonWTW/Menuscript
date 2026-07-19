# Architecture

## Overview
Menuscript is a client-only iOS app (SwiftUI + SwiftData) that talks directly to third-party APIs — there is no custom backend server. The device does all orchestration: capturing photos, resolving a matched vision/FX provider pair, computing and freezing the bill, and persisting draft/completed history locally.

## Major Components
- **Client / User Interface**: SwiftUI views organized by feature — Capture (photo picker/camera), Menu (browse/translate/cart), Bill (surcharge, split, totals), Settings (API key, language, currency), and a root History list.
- **Server / Application Logic**: No custom server. Application logic runs on-device. `RuntimeServiceResolver` resolves Gemini + Frankfurter together for live mode or deterministic mock vision + mock FX together for offline demos, preventing a mock recognition flow from accidentally reaching the live FX service.
- **Data / Persistence**: SwiftData stores session history locally on-device, including captured photos, lifecycle state, menu items, and immutable completed-bill snapshot bytes. Keychain stores the Gemini API key at rest. `UserDefaults` stores preferences, manual FX overrides, and versioned cached quotes.

## Component Responsibilities
- **Capture**: gather one or more menu photos and hand them to the recognition pipeline.
- **Menu**: request recognition/translation from the provider, render categorized dish cards, manage cart state, request and cache per-dish AI explanations.
- **Bill**: compute subtotal, surcharge, total, and an even split across diners from cart and FX data, using bill math kept separate from the UI. Finalization encodes the displayed values into a versioned snapshot and saves lifecycle status and snapshot together.
- **Settings**: manage user-configurable state — API key, target language, home currency, model choice, mock-provider toggle, app UI language.
- **Services layer**: isolate all external I/O (LLM calls, FX calls, secure-storage access) behind small provider interfaces. `SessionStore` is the throwing persistence boundary for finalization and deletion; destructive operations run in a short-lived context so a failed save cannot make the UI context appear deleted.

## Implementation Mapping (Sprint 2)

How the Sprint 2 feature slice maps onto the standard client/server/route/data breakdown, reflecting the actual implementation rather than the plan:

- **Client**: SwiftUI views, one module per feature under `Menuscript/Features/` — `Capture` (camera/photo-library picker), `Menu` (categorized translated dish cards, cart, per-dish AI explanation sheet), `Bill` (surcharge, even split, home-currency total), `Settings` (API key, model, target language, home currency, mock-provider toggle, app UI language), and a root `History` list backed by SwiftData. Screens hold view state; bill math and provider calls live outside the views so they're independently testable.
- **Server**: no custom backend — there is nothing to deploy or operate. All application logic that would otherwise live server-side runs on-device in the `Menuscript/Services/` layer: `RuntimeServiceResolver` atomically selects a matched live bundle (`GeminiProvider` + `FXService`) or fully offline bundle (`MockVisionProvider` + `MockFXService`) behind the vision and FX service protocols. This on-device services layer is the closest analogue to "server" in this architecture.
- **Route**: no app-defined API surface (no REST/GraphQL routes of our own). Live mode has two direct HTTPS integrations: `GeminiProvider` calls `POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent` for recognition/translation and explanations; `FXService` calls `GET https://api.frankfurter.dev/v2/rate/{base}/{quote}` for blended reference rates, including TWD. The photo-search feature opens `google.com` inside `SFSafariViewController`; it is an explicit user-triggered browser action, not an app API route. Mock core flow does not evaluate either live provider.
- **Data**: three local stores, no remote database. SwiftData persists photos, recognized items, draft/completed lifecycle state, and versioned bill snapshots. Keychain holds the user's Gemini API key at rest — never source, `UserDefaults`, or SwiftData — while live API calls send it directly to Google as the credential. `UserDefaults`/`AppStorage` holds preferences and FX payloads; cached quotes store a canonical market date separately from fetch time and expire after seven days.

### Feature extension: allergen advisories + photo search

Two later Sprint 2 UX features — per-dish allergen advisories (with an always-on one-line summary) and one-tap dish photo search — extend the same client/services/data breakdown without adding a server or a new outbound route:

- **New files.** `Menuscript/Models/Allergen.swift` defines the eleven preset allergens as a `CaseIterable` enum plus pure, unit-testable helpers: `Allergen.parse(presets:custom:)` turns the stored preset slugs and free-text custom entries into a de-duplicated, length-capped list of stable English `promptLabel`s for the prompt, `displayLabel(for:)` maps an AI-returned label back to a localized display name (verbatim fallback when it matches nothing), and `selectedSlugs`/`serialize` back the Settings toggle bindings. `Menuscript/Features/Menu/PhotoSearch.swift` builds the Google Images search URL for a dish (`imagesURL(query:)` → `https://www.google.com/search?q=…&tbm=isch`, `nil` on a blank query, CJK percent-encoding handled by `URLComponents`). `Menuscript/Features/Menu/Components/SafariView.swift` is a small `UIViewControllerRepresentable` wrapping `SFSafariViewController` so the image search opens in-app rather than kicking out to the system browser.
- **Extended extraction contract (services layer).** The `MenuVisionProvider` protocol's `extractMenu(images:targetLanguage:allergens:)` gains an `allergens: [String]` parameter. `ExtractedMenu.Item` (and the persisted `MenuItem`) gain a `summary` — always requested, a one-line description of the dish, kept separate from the on-demand `explanation` used by the ExplainSheet — and `possibleAllergens`, requested only when the user has allergens configured. `GeminiProvider` adds the corresponding prompt rules and JSON response-schema fields *conditionally* on whether the allergen list is non-empty (`summary` is always required in the schema; `possibleAllergens` is added to `properties`/`required` only when `includeAllergens` is true), and carries the allergen list through its one corrective-retry rebuild so the retry never silently downgrades to the no-allergen prompt/schema. `MockVisionProvider` returns fixed summaries and hard-coded allergen hits (e.g. 唐揚げ → wheat/soy/egg) so the whole feature demos offline. This is an extension of the existing single Gemini `generateContent` route — no new endpoint.
- **Persistence (Data).** `MenuItem` gains `summary` and `possibleAllergens`; `MenuSession` gains `allergenProfile` — a snapshot of the allergen list that was in effect when the menu was recognized, populated in `CaptureViewModel.recognize()` alongside the existing `fxRate`/`homeCurrency` snapshots, so a session's advisories stay tied to the settings under which it was produced (and stale settings never retroactively change an old session). All three new fields are optional/defaulted for lightweight SwiftData migration. Two new `UserDefaults`/`AppStorage` preference keys — `settings.allergenPresets` (comma-joined slugs) and `settings.allergenCustom` (raw free text) — hold the user's selections.

## Data Flow
A user opens Capture and photographs a menu → the runtime resolver selects one provider bundle → live mode presents the Google data disclosure, while mock mode stays local → the vision provider returns recognized and translated dish data → the draft session is saved and Menu lets the user request explanations and build a cart → Bill computes subtotal, surcharge, even split, and conversion → finalization atomically saves an immutable snapshot and completed lifecycle state → History separates drafts from completed records and can reopen the original photos in an ordered gallery.

## Session Lifecycle & Snapshot Boundary

`MenuSession.lifecycleStatusRaw` and `billSnapshotData` are optional additive fields so existing SwiftData stores can migrate automatically. New sessions explicitly start as `draft`; a missing or unknown legacy value maps to `legacyUnfinalized`, never completed. `BillSnapshot` version 1 copies every line and calculation input/output required to reproduce the completed bill. Completed screens read the snapshot instead of recomputing from mutable session fields.

`SessionStore.finalize` is idempotent: once completed it returns the persisted snapshot without writing again. It restores the prior lifecycle state if save fails. History deletion uses a separate `ModelContext` and publishes nothing to the UI context until the isolated save succeeds, avoiding unsafe rollback of faulted cascade relationships.

## Privacy Boundary

The first live recognition request is gated by a disclosure explaining that selected menu images and recognition context go directly to Google Gemini. Recognition can include target language and food-sensitivity preferences; explanation requests include selected dish text. Because the BYOK credential identifies a Google project, the privacy manifest conservatively treats Photos/Videos, Other User Content, and Health data as linked to the user for App Functionality. Tracking is disabled and there are no tracking domains.

`PrivacyInfo.xcprivacy` also declares UserDefaults access under reason `CA92.1`. Camera and photo-library permission prompts repeat the live-Gemini versus on-device-mock distinction. Mock runtime resolution does not read the Gemini key or construct live network services; the only external action still available is the user explicitly opening dish photo search.

## Initial Architecture Sketch
```
[Capture] --photos--> [Runtime Service Resolver]
                           | live              | mock (offline)
                           v                   v
                    [Gemini + FX]       [Mock Vision + Mock FX]
                           \                   /
                            v                 v
                       [Draft Menu Session]
                                |
                                v
                 [Bill calculation + immutable snapshot]
                                |
                                v
              [SwiftData: draft/completed] --> [History + photo gallery]

Keychain (API key) <---- [Settings] ----> Local prefs (language, currency, FX cache)
```

## Open Questions
- Should a lightweight backend proxy be introduced later so users don't each need their own Gemini API key (bring-your-own-key), and if so, who bears the API cost?
- How should additional UI/menu languages be added — is the current localization approach structured to scale, or does it need rework first?
- Is on-device-only history sufficient long-term, or will users eventually want sync across devices?
- What's the right confidence threshold and UX for flagging low-confidence menu recognition before it becomes more annoying than helpful?
