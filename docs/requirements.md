# Requirements

## Functional Requirements
- The system should let a user capture one or more photos of a menu, using the camera or photo library.
- The system should send captured photos to an LLM vision provider and return recognized dishes with translated names, prices, and detected menu currency.
- Before the first live recognition request, the system should clearly disclose that menu images and recognition context are sent directly to Google Gemini, and let the user continue or cancel.
- The system should flag low-confidence recognized items so the user knows to double-check them.
- The system should let a user browse translated menu items by category and add items, with quantity, to a cart.
- The system should provide an on-demand, plain-language AI explanation of a selected dish, and cache that explanation so it isn't re-requested.
- The system should calculate a bill from cart items, including a configurable surcharge/tax, producing a subtotal and total.
- The system should split a bill evenly ("AA") across a specified number of diners.
- The system should convert bill totals into the user's home currency using Frankfurter v2 blended reference rates, including TWD, falling back only to a cached quote no more than seven days old when live rates are unavailable.
- The system should save a recognized menu as an unfinished draft and separate unfinished and completed sessions in History.
- Completing a session should atomically save an immutable, versioned bill snapshot; retrying completion must be idempotent, and failed persistence must leave the session unfinished.
- Reopened completed sessions should keep order quantities, surcharge, people count, currencies, FX values, and totals read-only and identical to the saved snapshot.
- The system should let the user reopen saved menu photos from History in capture order, with page count, zoom, accessibility labels, and a safe placeholder for damaged image data.
- The system should let the user choose the app's UI language (Traditional Chinese or English) and home currency in Settings.
- The system should let the user supply their own Gemini API key in Settings, stored securely, with no key bundled in the app.
- The system should offer a mock-provider mode whose core Capture → Menu → Bill → History flow uses deterministic vision and FX providers without a live API key, Keychain read, or network request. User-initiated dish photo search remains an external web action.

## Data Requirements
- The system needs to store menu sessions: lifecycle status, captured photos, recognized menu items (name, translated name, price, currency, category, confidence), and a timestamp. Legacy sessions with no status must remain unfinished rather than being inferred as completed.
- The system needs to track cart state per session (selected items and quantities) until checkout.
- The system needs to store a completed bill as a versioned immutable snapshot containing selected line copies, unit prices or market-price notes, quantities, both currencies, FX rate/date/source, subtotal, surcharge, total, people count, per-person values, converted values, unpriced-item flag, and completion time.
- The system needs to track cached AI-generated dish explanations, keyed by dish, to avoid redundant API calls.
- The system needs to store user settings: target UI language, home currency, selected Gemini model, mock-provider toggle.
- The system needs to store the user's Gemini API key securely (Keychain), never in plain text or source control.
- The system needs to retrieve and cache foreign-exchange rates, using a manual-override → Frankfurter v2 live-fetch → fresh cached-value fallback order, with independent quote date and fetch time and a hard seven-day cache lifetime.

## Privacy Requirements

- The app must not track users or declare tracking domains.
- Live Gemini requests may send selected menu images, dish text, target language, and food-sensitivity preferences directly to Google for App Functionality. The disclosure must explain this before the first live request and must not imply that these data stay on-device.
- The user-supplied Gemini API key must be stored at rest only in Keychain. Live requests necessarily send it to Google as the API credential and may link request data to the user's Google project.
- The privacy manifest should conservatively declare linked Photos/Videos, Other User Content, and Health data for App Functionality, all with tracking disabled.
- Access to `UserDefaults` must declare required reason `CA92.1` under `NSPrivacyAccessedAPICategoryUserDefaults`.
- Camera and photo-library purpose strings must distinguish live Google Gemini transfer from mock-mode on-device processing.

## Non-Functional Requirements
- The project should be understandable to a new user: menu translation and bill actions should be discoverable without instructions.
- The project should provide clear feedback when something goes wrong (failed recognition, no network, invalid API key) rather than failing silently.
- The project should keep data organized and consistent — a session's photos, recognized items, and bill must stay linked and reload correctly from history.
- Destructive persistence failures must not silently remove History rows from the UI; completion failures must not show an unsaved bill as completed.
- The project should protect user secrets (the API key) using platform-appropriate secure storage, not plain text.
- The project should behave predictably when a core dependency is unavailable (FX API down, Gemini API error) by falling back gracefully rather than crashing.

## Out of Scope for the First Version
- This version will not support UI languages other than Traditional Chinese and English.
- This version will not support unequal/itemized bill splitting or tip calculators.
- This version will not include social sharing, exporting, or multi-device sync of history.
- This version will not recognize arbitrary menus offline — live recognition requires Gemini. The offline mock path returns fixed demo data.
- This version will not include a custom backend server — the app talks directly to third-party APIs (Gemini, Frankfurter) from the client.
