# Architecture

## Overview
Menuscript is a client-only iOS app (SwiftUI + SwiftData) that talks directly to third-party APIs — there is no custom backend server. The device does all orchestration: capturing photos, resolving a matched vision/FX provider pair, computing and freezing the bill, and persisting draft/completed history locally.

## Major Components
- **Client / User Interface**: SwiftUI views organized by feature — Capture (photo picker/camera), Menu (browse/translate/cart), Bill (surcharge, split, totals), Settings (API key, language, currency, photo retention), and a root History list.
- **Server / Application Logic**: No custom server. Application logic runs on-device. `RuntimeServiceResolver` resolves Gemini + Frankfurter together for live mode or deterministic mock vision + mock FX together for offline demos, preventing a mock recognition flow from accidentally reaching the live FX service.
- **Data / Persistence**: SwiftData stores session history locally on-device, including captured photos, `photosPrunedAt`, lifecycle state, menu items, and immutable completed-bill snapshot bytes. Keychain stores the Gemini API key at rest. `UserDefaults` stores preferences (including photo retention), manual FX overrides, and versioned cached quotes.

## Component Responsibilities
- **Capture**: gather one or more menu photos and hand them to the recognition pipeline.
- **Menu**: request recognition/translation from the provider, render categorized dish cards, manage cart state, request and cache per-dish AI explanations.
- **Bill**: compute subtotal, surcharge, total, and an even split across diners from cart and FX data, using bill math kept separate from the UI. Finalization encodes the displayed values into a versioned snapshot and saves lifecycle status and snapshot together.
- **Settings**: manage user-configurable state — API key, target language, home currency, model choice, mock-provider toggle, photo-retention choice, and app UI language.
- **Services layer**: isolate external I/O (LLM calls, FX calls, secure-storage access) behind small provider interfaces. `SessionStore` is the throwing persistence boundary for finalization, FX writes, and deletion; `PhotoRetentionService` is the separate throwing boundary for pruning expendable photo evidence. Destructive operations run in a short-lived context so a failed save cannot make the UI context appear deleted or pruned.

## Implementation Mapping (Sprint 2)

How the Sprint 2 feature slice maps onto the standard client/server/route/data breakdown, reflecting the actual implementation rather than the plan:

- **Client**: SwiftUI views, one module per feature under `Menuscript/Features/` — `Capture` (camera/photo-library picker), `Menu` (categorized translated dish cards, cart, per-dish AI explanation sheet), `Bill` (surcharge, even split, home-currency total), `Settings` (API key, model, target language, home currency, mock-provider toggle, app UI language), and a root `History` list backed by SwiftData. Screens hold view state; bill math and provider calls live outside the views so they're independently testable.
- **Server**: no custom backend — there is nothing to deploy or operate. All application logic that would otherwise live server-side runs on-device in the `Menuscript/Services/` layer: `RuntimeServiceResolver` atomically selects a matched live bundle (`GeminiProvider` + `FXService`) or fully offline bundle (`MockVisionProvider` + `MockFXService`) behind the vision and FX service protocols. This on-device services layer is the closest analogue to "server" in this architecture.
- **Route**: no app-defined API surface (no REST/GraphQL routes of our own). Live mode has two direct HTTPS integrations: `GeminiProvider` calls `POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent` for recognition/translation and explanations; `FXService` calls `GET https://api.frankfurter.dev/v2/rate/{base}/{quote}` for blended reference rates, including TWD. The photo-search feature opens `google.com` inside `SFSafariViewController`; it is an explicit user-triggered browser action, not an app API route. Mock core flow does not evaluate either live provider.
- **Data**: three local stores, no remote database. SwiftData persists photos, `photosPrunedAt`, recognized items, draft/completed lifecycle state, and versioned bill snapshots. Keychain holds the user's Gemini API key at rest — never source, `UserDefaults`, or SwiftData — while live API calls send it directly to Google as the credential. `UserDefaults`/`AppStorage` holds preferences, including `settings.photoRetention`, and FX payloads; cached quotes store a canonical market date separately from fetch time and expire after seven days.

### Feature extension: allergen advisories + photo search

Two later Sprint 2 UX features — per-dish allergen advisories (with an always-on one-line summary) and one-tap dish photo search — extend the same client/services/data breakdown without adding a server or a new outbound route:

- **New files.** `Menuscript/Models/Allergen.swift` defines the eleven preset allergens as a `CaseIterable` enum plus pure, unit-testable helpers: `Allergen.parse(presets:custom:)` turns the stored preset slugs and free-text custom entries into a de-duplicated, length-capped list of stable English `promptLabel`s for the prompt, `displayLabel(for:)` maps an AI-returned label back to a localized display name (verbatim fallback when it matches nothing), and `selectedSlugs`/`serialize` back the Settings toggle bindings. `Menuscript/Features/Menu/PhotoSearch.swift` builds the Google Images search URL for a dish (`imagesURL(query:)` → `https://www.google.com/search?q=…&tbm=isch`, `nil` on a blank query, CJK percent-encoding handled by `URLComponents`). `Menuscript/Features/Menu/Components/SafariView.swift` is a small `UIViewControllerRepresentable` wrapping `SFSafariViewController` so the image search opens in-app rather than kicking out to the system browser.
- **Extended extraction contract (services layer).** The `MenuVisionProvider` protocol's `extractMenu(images:targetLanguage:allergens:)` gains an `allergens: [String]` parameter. `ExtractedMenu.Item` (and the persisted `MenuItem`) gain a `summary` — always requested, a one-line description of the dish, kept separate from the on-demand `explanation` used by the ExplainSheet — and `possibleAllergens`, requested only when the user has allergens configured. `GeminiProvider` adds the corresponding prompt rules and JSON response-schema fields *conditionally* on whether the allergen list is non-empty (`summary` is always required in the schema; `possibleAllergens` is added to `properties`/`required` only when `includeAllergens` is true), and carries the allergen list through its one corrective-retry rebuild so the retry never silently downgrades to the no-allergen prompt/schema. `MockVisionProvider` returns fixed summaries and hard-coded allergen hits (e.g. 唐揚げ → wheat/soy/egg) so the whole feature demos offline. This is an extension of the existing single Gemini `generateContent` route — no new endpoint.
- **Persistence (Data).** `MenuItem` gains `summary` and `possibleAllergens`; `MenuSession` gains `allergenProfile` — a snapshot of the allergen list that was in effect when the menu was recognized, populated in `CaptureViewModel.recognize()` alongside the existing `fxRate`/`homeCurrency` snapshots, so a session's advisories stay tied to the settings under which it was produced (and stale settings never retroactively change an old session). All three new fields are optional/defaulted for lightweight SwiftData migration. Two new `UserDefaults`/`AppStorage` preference keys — `settings.allergenPresets` (comma-joined slugs) and `settings.allergenCustom` (raw free text) — hold the user's selections.

## Architecture Evolution: Sprint 2 to Sprint 3

Sprint 3 did not change the *shape* of the system. It is still client-only, still has no server of its own, still has the same feature modules under `Menuscript/Features/` and the same services layer under `Menuscript/Services/`, and still adds no third-party dependency. What Sprint 3 changed is **where the truth about a session lives**.

In Sprint 2, a session was a single mutable SwiftData row and the bill was whatever the Bill screen computed from that row at the moment you looked at it. There was no notion of a settled bill, so nothing in the design prevented a later FX refresh or a settings change from silently rewriting a total the user had already paid. Sprint 3 makes the lifecycle explicit and makes a completed bill immutable, and that single decision is what pulled the rest of the sprint's work into scope: a real persistence boundary to write it through, matched provider resolution so a mock recognition can't be settled against a live rate, deterministic photo capture so the photos kept with a session are the ones the user took in the order they took them, and a disclosure boundary because "we keep your data" demands saying what leaves the device.

| Concern | Sprint 2 | Sprint 3 |
|---|---|---|
| Session state | implicit — a row existed or it didn't | explicit `SessionLifecycleStatus`: `draft` / `completed` / `legacyUnfinalized` |
| Completed bill | no such concept; totals were always recomputed from live session fields | rendered from an immutable, versioned `BillSnapshot` (v1) and never recomputed |
| Persistence writes | no dedicated boundary — views and view models mutated session fields in the shared `ModelContext` | `SessionStore`, a throwing boundary that owns finalization, FX updates, and deletion |
| Provider selection | `ProviderFactory` handed back a vision provider; the FX service was resolved separately | `RuntimeServiceResolver` returns vision **and** FX as one matched bundle |
| API key at rest | `UserDefaults` | Keychain, behind a `SecretStore` protocol |
| Photo capture | imported ad hoc; ordering and partial-failure behavior unspecified | `PhotoImportCoordinator` + `CaptureLimits`: stable order, explicit cap, atomic save, cancellable |
| Outbound-data disclosure | `Info.plist` permission strings only | `GeminiDisclosureGate` before the first live request, plus `Resources/PrivacyInfo.xcprivacy` |
| FX provenance | tracked internally, never surfaced | persisted on the session, shown in the bill, and frozen into the snapshot |

### New responsibilities

Each of these is new in Sprint 3 and deliberately has one job:

| Responsibility | Where |
|---|---|
| Own every write of lifecycle state and snapshot bytes; fail loudly rather than half-succeed | `SessionStore` — `Menuscript/Services/SessionStore.swift` (`finalize`, `updateFXRate`, `delete`, `deleteAll`, `SessionStoreError`) |
| Define the frozen wire format of a settled bill and refuse to decode a version it does not understand | `BillSnapshot`, `BillSnapshotCodec`, `BillSnapshotError` — `Menuscript/Models/BillSnapshot.swift` |
| Classify what a session *is* right now, and keep a completed session from ever falling back to mutable fields | `SessionLifecycleStatus`, `SessionBillState`, `SessionBillUnavailableReason` — `Menuscript/Models/MenuSession.swift` |
| Resolve the vision and FX providers together so a run is entirely live or entirely offline | `RuntimeServiceResolver`, `RuntimeMode` — `Menuscript/Services/RuntimeServiceResolver.swift` |
| Hold the BYOK credential at rest, behind an interface the rest of the app can be tested against | `SecretStore` / `KeychainStore` — `Menuscript/Services/SecretStore.swift`, `KeychainStore.swift` |
| Import photos in a stable order, within a stated limit, atomically and cancellably | `PhotoImportCoordinator`, `CaptureLimits` — `Menuscript/Features/Capture/` |
| Gate the first live Gemini request on a recorded, one-time user consent | `GeminiDisclosureGate`, `GeminiDisclosureError` — `Menuscript/Services/GeminiDisclosureGate.swift` |
| Replay a session's saved photos in capture order, paged and zoomable | `HistoryPhotoGalleryView` — `Menuscript/Features/Menu/HistoryPhotoGalleryView.swift` |
| Declare collected data categories and required-reason API use | `Menuscript/Resources/PrivacyInfo.xcprivacy` |

### Persistence components

The persistence story is three local stores and one frozen format — no remote database, no sync, no server.

- **SwiftData (`AppSchema`, `MenuSession`, `MenuItem`)** is the durable record: captured photos (`@Attribute(.externalStorage)`), recognized items, the allergen profile the session was recognized under, FX fields including the canonical market `fxQuoteDate` and `fxSource`, `lifecycleStatusRaw`, and `billSnapshotData`.
- **`BillSnapshot` v1** is the frozen format. It is `Codable`, `Equatable`, `Sendable`, versioned, and stored as opaque bytes on the session rather than as columns, precisely so that adding a field to the live model can never retroactively change a bill that was already settled. Decoding is one-way-safe: an unknown version surfaces as `SessionBillState.unavailable(.unsupportedVersion)`, and unreadable bytes as `.unavailable(.unreadable)` — in neither case does the app quietly recompute a plausible-looking replacement.
- **Keychain (`KeychainStore`)** holds the Gemini API key at rest. It is never in source, `UserDefaults`, or SwiftData; live calls send it directly to Google as the credential.
- **`UserDefaults`** holds preferences, the manual FX override, the seven-day cached quote, and the recorded disclosure acceptance (`privacy.googleGeminiDisclosureAccepted.v1`).

**Migration.** Every field Sprint 3 added to the SwiftData model — `lifecycleStatusRaw`, `billSnapshotData`, `fxSource`, `fxQuoteDate`, `fxFetchedAt`, `providerModeRaw` — is optional or defaulted, so an existing on-device store migrates under SwiftData lightweight migration with no schema-version bump and no migration plan. The one place this could have gone wrong is the default reading: a `nil` status resolves to `legacyUnfinalized`, never `completed`, so an old row can never be mistaken for a settled bill it has no snapshot for.

### What deliberately did not change

Named here because leaving them alone was also a decision: no custom backend and no proxy for the API key; no new runtime dependency; no schema version bump; no rework of the Sprint 2 feature modules or of `BillMath`, which stayed pure `Decimal`-in/`Decimal`-out arithmetic and is now simply what the snapshot records the output of.

## Sprint 4 Quality Invariants

Sprint 4 changes no product boundary, persistence format, or production service topology. It sharpens the invariants at the boundary between persisted provenance, the current Demo Mode preference, asynchronous image preparation, and dependency injection.

- **Current Demo Mode is the safety override.** `RuntimeServiceResolver.effectiveMode(persistedMode:defaults:)` returns `.mock` whenever `SettingsKeys.useMockProvider` is true; only with Demo Mode off does recorded provenance win, and an unrecorded legacy session falls back to `.live`. `RuntimeServiceResolver.resolve` keeps a mock resolution local: it creates `MockVisionProvider` and `MockFXService` without reading `SecretStore` or evaluating the live-FX factory. `GeminiDisclosureGate`, `DishExplanationService`, and `MenuView.billFXSelection` use that same effective-mode rule.
- **Explanation cache has provenance protection.** `ExplainSheet` receives a `MenuItemActionContext` carrying the session's recorded provider mode. `DishExplanationCachePolicy` writes a fetched explanation to `MenuItem.explanation` only if the effective mode is compatible with recorded provenance (or provenance is absent for a legacy item). A result fetched under Demo Mode for a recorded live session stays in `transientExplanation`, so it is shown in the open sheet but cannot relabel the persisted live cache. `ExplainSheet` requires `defaults`; `MenuView` forwards both its injected defaults and its live-FX factory instead of silently falling back to another dependency scope.
- **Direct photos reserve before they encode.** `CaptureViewModel.addPhotos` synchronously calls `reservePhotoSlots`, so pending slots consume the six-photo capacity immediately and establish insertion order. It then starts one serial task for that batch; each `@Sendable` JPEG preparer invocation runs in a detached, off-main task and resolves its reserved slot before the next request. A failed or unfinished slot makes `canRecognize` false, preventing a partial photo set from reaching a provider. The DEBUG `RootView` demo waits on `pendingPhotoCount` rather than a fixed number of yields and returns promptly when its task is cancelled.
- **Mock data is deterministic and never rejects a target-language field.** `MockTargetLanguage` maps exactly `en` and any value containing `english` to the English fixture; all other values map to the Traditional Chinese fixture. `MockFXService` holds `unitsPerUSD` and derives every supported pair as `toUnits / fromUnits`, including the 15 added quotes (PHP, INR, IDR, MYR, NZD, DKK, NOK, SEK, PLN, CZK, TRY, AED, SAR, BRL, ZAR). The finite table deliberately returns `nil` for unsupported pairs; `BillFXPresentation` selects a Demo-Mode coverage message only when the already-resolved bill mode is `.mock`.
- **Test/preview injection is hermetic without altering production resolution.** When `CaptureViewModel` is given an injected vision provider but no FX provider, it infers the vision provenance as before but assigns `MockFXService` for FX. An explicit injected FX provider still wins. The normal, non-injected path remains `RuntimeServiceResolver.resolveFromPreferences`, preserving the production live pair and Demo Mode override. `MenuView` resolves the bill provider and `RuntimeMode` once into `BillFXProviderSelection` before constructing `BillView`, preventing independent provider/mode decisions from drifting apart.

## Architecture Evolution: Sprint 4 to Sprint 5 — Photo Retention (2026-08-16–18)

Sprint 5 answers a question this document has carried as open since Sprint 3: how long sessions and their photos should be kept. The first external peer review of the project (2026-08-02, `docs/peer-review-1.txt`) read that open question and named closing it the highest-priority recommendation of the whole review — a gap this project had documented about itself in Sprint 3 and then left unscheduled until now. The answer implemented here is deliberately narrow: **for an eligible record, prune the photos and keep the readable bill/session until the user deletes that history.**

### Sprint 5 responsibility mapping

| Responsibility | Final implementation |
|---|---|
| Store the user's policy | `SettingsKeys.photoRetention` and the `SettingsView` picker/footer — `Menuscript/App/SettingsKeys.swift:15`, `Menuscript/Features/Settings/SettingsView.swift:165-175` |
| Represent policy and its deterministic window | `PhotoRetentionPolicy` (`30d`, `90d`, `forever`; fixed 86,400-second days) — `Menuscript/Services/PhotoRetentionPolicy.swift:7-32` |
| Mark photo removal without deleting history | Optional `MenuSession.photosPrunedAt`; `photos` remains the external-storage field — `Menuscript/Models/MenuSession.swift:50-63` |
| Decide whether the frozen bill is authoritative and readable | `MenuSession.billState` / `billSnapshot`, using the canonical `BillSnapshotCodec.decode` path — `Menuscript/Models/MenuSession.swift:103-124`, `Menuscript/Models/BillSnapshot.swift:154-160` |
| Perform the destructive write and fail safely | `PhotoRetentionService.pruneExpiredPhotos` in a short-lived non-autosaving context — `Menuscript/Services/PhotoRetentionService.swift:45-83` |
| Trigger pruning and surface failure | `RootView` at launch and after finalization — `Menuscript/App/RootView.swift:45-49`, `:113-115`, `:189-195` |

- **The policy and its safe eligibility boundary.** `settings.photoRetention` holds `30d` / `90d` / `forever`; a missing or unknown value currently resolves to 30 days. For a finite window, the service checks cheap scalar state first — completed lifecycle, no prior prune stamp, and inclusive age from `createdAt` — then requires `session.billSnapshot` to be non-`nil`, which means the canonical codec successfully decoded a snapshot version this app understands, and only then loads `photos` (`PhotoRetentionService.swift:61-70`). Missing, malformed/corrupt, and future/unsupported snapshot bytes therefore protect the photos. Fixed 86,400-second days keep the 30/90-day boundary deterministic. This ordering makes photo evidence expendable only after a readable completed bill exists.
- **Why the split is clean.** Sprint 3 already put a settled bill in its own frozen field. `MenuSession.photos` (`Menuscript/Models/MenuSession.swift:50`, `@Attribute(.externalStorage)`) and `MenuSession.billSnapshotData` (`:59`) were never the same record, so clearing the first cannot rewrite the second. The important Sprint 5 qualification is that mere non-`nil` bytes are not enough: `billState` distinguishes missing, unreadable, and unsupported data, and pruning accepts only `.completed(snapshot)`. Photos remain the recovery evidence for every invalid state.
- **Why 30 days by default.** Menu photos earn their storage during a trip — re-checking a dish, settling who ordered what, comparing a later menu against an earlier one. Thirty days covers a long trip plus the reconciliation that follows it, and it matches the threshold the peer review suggested. It errs generous because this deletion is irreversible. The 90-day and keep-forever options exist because the right window is a user judgment about their own photos, not an engineering constant.
- **The bounded mutation and save scope.** Pruning writes exactly two fields — `session.photos = []` and `session.photosPrunedAt = now` (`Menuscript/Services/PhotoRetentionService.swift:73-75`). It never deletes the session and never rewrites its snapshot, dishes, lifecycle, or FX fields. A batch with no eligible session returns before saving; an eligible batch is persisted once. Because a pruned session differs from one that never had photos, `MenuView` swaps its photo-gallery toolbar button for a notice (`Menuscript/Features/Menu/MenuView.swift:133-151`, `:178-181`) rather than silently showing nothing. Extending the policy later cannot recover bytes already deleted.
- **Where it runs, and how it fails.** Both `PhotoRetentionService` and its `RootView` caller are main-actor code. Pruning runs synchronously at two lifecycle moments: inside the launch `.task`, before the DEBUG demo continuation, and in the post-finalize callback after navigation is cleared. It is not a background worker; “outside the active editing flow” describes timing, not threading. The service uses a short-lived `ModelContext(context.container)` with `autosaveEnabled = false`; fetch/save failures become typed `PhotoRetentionError` values, the isolated context is discarded, and every photo remains. `RootView` routes the error into the existing persistence alert instead of swallowing it.
- **Existing history and migration.** `photosPrunedAt` is optional with a defaulted initializer parameter (`MenuSession.swift:63`, `:154`), so old rows read `nil`. The service fetches the whole local history and applies the current default/selection to any eligible row; it is not limited to sessions created after Sprint 5. Menuscript has no shipped installed base, so this behavior does not currently migrate real users. Before a future release with an installed base, the missing-preference fallback needs a deliberate migration decision (for example, explicit opt-in or a temporary keep-forever fallback) rather than assuming today's no-user premise still holds.

### Rejected retention alternatives

- **Use completion time as the age anchor — rejected for this version.** `createdAt` represents when the menu/photos entered the session and matches the user-facing promise and the existing inclusive-boundary/manual evidence. Completion time would be more conservative, but it would silently redefine the retention window. An unusually old draft may become immediately eligible after finalization once it has a readable snapshot; the new dialog at least requires confirmation before finalization, although its copy describes bill immutability rather than the retention edge specifically.
- **Treat a missing preference as keep forever, or add first-run/upgrade state — rejected for the current unshipped app.** There is no installed user population to migrate, while the chosen default directly answers the peer review's storage concern. This is a current-state decision, not a permanent migration policy; the caveat above becomes actionable before a shipped upgrade exists.
- **Move pruning to a background actor — rejected without performance evidence.** The current operation is a synchronous main-actor full-history fetch/filter/decode with at most one save, run at two deterministic transition points. A background design would require reconciliation and scheduling semantics; it should be reconsidered if real history size shows this scan affects responsiveness rather than assumed necessary now.

**What deliberately did not change.** There is still no total size budget, no expiry for the sessions themselves, no per-session "delete photos now" control, and no change to the snapshot format. The age threshold reduces growth for eligible sessions but does not promise a hard storage bound: keep-forever and protected invalid-snapshot records may retain photos. The remainder is left as open questions below rather than guessed at.

## Data Flow
A user opens Capture and photographs a menu → the runtime resolver selects one provider bundle → live mode presents the Google data disclosure, while mock mode stays local → the vision provider returns recognized and translated dish data → the draft session is saved and Menu lets the user request explanations and build a cart → Bill computes subtotal, surcharge, even split, and conversion → the user confirms finalization → finalization atomically saves an immutable snapshot and completed lifecycle state → History separates drafts from completed records and can reopen original photos while the retention policy keeps them → launch/post-finalize pruning removes photos only after the completed snapshot is readable.

## Session Lifecycle & Snapshot Boundary

`MenuSession.lifecycleStatusRaw` and `billSnapshotData` are optional additive fields so existing SwiftData stores can migrate automatically. New sessions explicitly start as `draft`; a missing or unknown legacy value maps to `legacyUnfinalized`, never completed. `BillSnapshot` version 1 copies every line and calculation input/output required to reproduce the completed bill. Completed screens read the snapshot instead of recomputing from mutable session fields.

`SessionStore.finalize` is idempotent: once completed it returns the persisted snapshot without writing again. It restores the prior lifecycle state if save fails. `SessionStore.updateFXRate` guards the same immutable boundary: for a completed session it throws payload-free `completedSessionCannotUpdateFXRate` before reading or mutating any of the five FX fields (`Menuscript/Services/SessionStore.swift:65-74`). `BillView.refreshFXRate` independently rechecks completion after its awaited provider fetch and before the store call; it also catches that exact typed race without showing an alert, while generic persistence failures still alert (`Menuscript/Features/Bill/BillView.swift:438-464`). History deletion uses a separate `ModelContext` and publishes nothing to the UI context until the isolated save succeeds, avoiding unsafe rollback of faulted cascade relationships.

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
              [SwiftData: draft/completed] --> [History + retained-photo gallery]
                           |
                           v
              [Retention: readable completed bill required]

Keychain (API key) <---- [Settings] ----> Local prefs (language, currency, retention, FX cache)
```

## Open Questions
- Should a lightweight backend proxy be introduced later so users don't each need their own Gemini API key (bring-your-own-key), and if so, who bears the API cost?
- How should additional UI/menu languages be added — is the current localization approach structured to scale, or does it need rework first?
- Is on-device-only history sufficient long-term, or will users eventually want sync across devices?
- What's the right confidence threshold and UX for flagging low-confidence menu recognition before it becomes more annoying than helpful?

### Remaining questions raised by the Sprint 3 persistence work

- **What is the migration path when `BillSnapshot` reaches v2?** The codec refuses unknown versions by design, which is the safe failure, but it is not a strategy: a real v2 needs either an upgrade path that re-encodes v1 bytes on read or a permanent multi-version decoder. Deciding which — and whether an already-settled bill may ever be rewritten even to change its encoding — is unresolved.
- **How long should sessions and their photos be kept?** *Partially resolved in Sprint 5 (2026-08-18):* photos are still the dominant cost in the store, but original photos of eligible completed sessions are pruned after a user-selected window (30 days by default) only when the frozen bill is readable. The session and `BillSnapshot` remain until the user invokes the existing history deletion/delete-all controls — they are durable, not undeletable. See *Architecture Evolution: Sprint 4 to Sprint 5 — Photo Retention* above. Still open: whether sessions themselves should ever expire automatically, whether a size budget should complement the age threshold, and whether the user should get a per-session "delete photos now" control.
- **Where does an unreadable snapshot get repaired?** Today `.unavailable(.unreadable)` is honestly surfaced and the record is left untouched. Whether the user should be offered any recovery — re-derive an advisory total from the live fields while clearly labelling it as *not* the settled bill, or export the raw bytes for diagnosis — is an open product question, not just a technical one.
- **Should the snapshot record the model and prompt version that produced the menu?** A settled bill is currently reproducible in its *arithmetic* but not in its *recognition*: nothing in the snapshot says which Gemini model or prompt revision generated the dish names and prices it froze. If recognition quality is the product, that provenance may belong in v2.
- **Is `UserDefaults` the right home for the FX cache now that bills are immutable?** The cached quote and the manual override still live in preferences while the values they produced live in SwiftData snapshots — two stores with different durability and backup semantics for one causal chain.
