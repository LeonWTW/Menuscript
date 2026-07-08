# Requirements

## Functional Requirements
- The system should let a user capture one or more photos of a menu, using the camera or photo library.
- The system should send captured photos to an LLM vision provider and return recognized dishes with translated names, prices, and detected menu currency.
- The system should flag low-confidence recognized items so the user knows to double-check them.
- The system should let a user browse translated menu items by category and add items, with quantity, to a cart.
- The system should provide an on-demand, plain-language AI explanation of a selected dish, and cache that explanation so it isn't re-requested.
- The system should calculate a bill from cart items, including a configurable surcharge/tax, producing a subtotal and total.
- The system should split a bill evenly ("AA") across a specified number of diners.
- The system should convert bill totals into the user's home currency using live foreign-exchange rates, falling back to a cached rate when live rates are unavailable.
- The system should save each completed menu session (photos, recognized items, bill) so the user can browse a history and reopen a past session.
- The system should let the user choose the app's UI language (Traditional Chinese or English) and home currency in Settings.
- The system should let the user supply their own Gemini API key in Settings, stored securely, with no key bundled in the app.
- The system should offer a mock-provider mode so the app can be exercised without a live API key.

## Data Requirements
- The system needs to store menu sessions: captured photos (or references), recognized menu items (name, translated name, price, currency, category, confidence), and a timestamp.
- The system needs to track cart state per session (selected items and quantities) until checkout.
- The system needs to store computed bill results (subtotal, surcharge, total, per-diner split) tied to a session.
- The system needs to track cached AI-generated dish explanations, keyed by dish, to avoid redundant API calls.
- The system needs to store user settings: target UI language, home currency, selected Gemini model, mock-provider toggle.
- The system needs to store the user's Gemini API key securely (Keychain), never in plain text or source control.
- The system needs to retrieve and cache foreign-exchange rates, using a manual-override → live-fetch → last-cached-value fallback order.

## Non-Functional Requirements
- The project should be understandable to a new user: menu translation and bill actions should be discoverable without instructions.
- The project should provide clear feedback when something goes wrong (failed recognition, no network, invalid API key) rather than failing silently.
- The project should keep data organized and consistent — a session's photos, recognized items, and bill must stay linked and reload correctly from history.
- The project should protect user secrets (the API key) using platform-appropriate secure storage, not plain text.
- The project should behave predictably when a core dependency is unavailable (FX API down, Gemini API error) by falling back gracefully rather than crashing.

## Out of Scope for the First Version
- This version will not support UI languages other than Traditional Chinese and English.
- This version will not support unequal/itemized bill splitting or tip calculators.
- This version will not include social sharing, exporting, or multi-device sync of history.
- This version will not work fully offline — menu recognition requires a network connection to the LLM provider.
- This version will not include a custom backend server — the app talks directly to third-party APIs (Gemini, Frankfurter) from the client.
