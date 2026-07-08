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
- The Xcode project, folder names, and bundle id are still internally named `MenuTranslate`, pending a technical rename to match the `Menuscript` product name — when should that rename happen, and what does it risk (Keychain-stored API keys are tied to the current bundle id)?
- Should a lightweight backend proxy be introduced later so users don't each need their own Gemini API key (bring-your-own-key), and if so, who bears the API cost?
- How should additional UI/menu languages be added — is the current localization approach structured to scale, or does it need rework first?
- Is on-device-only history sufficient long-term, or will users eventually want sync across devices?
- What's the right confidence threshold and UX for flagging low-confidence menu recognition before it becomes more annoying than helpful?
