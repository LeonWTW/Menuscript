# Project Vision

## Problem
Travelers visiting a place where they can't read the local language often can't understand restaurant menus — dish names, ingredients, and prices in an unfamiliar currency. This leads to guesswork ordering, missed dietary concerns, and difficulty splitting a bill fairly across a group when everyone thinks in a different home currency.

This is especially true for handwritten, locally-styled menus — no printed layout, no photos, often regional shorthand. I ran into this myself on a trip to Japan: plenty of small local restaurants only had handwritten menus, and pointing Google Translate's camera feature at them produced translations that were close to unreadable. Generic OCR-translation tools aren't built to handle stylized handwriting or menu-specific shorthand — and closing that gap, between "technically translated" and "actually understandable," is the core problem this project addresses.

## Intended Users
General international travelers who encounter a menu in a language they don't read, regardless of what language they speak natively. The current implementation provides a bilingual Traditional Chinese / English UI as the first supported languages; broader language support is a future expansion, not a limitation of who the app is meant to serve.

## Goals
- Let a user photograph a menu and get an accurate translation of dish names within seconds.
- Help users understand unfamiliar dishes (what they are, roughly how they're prepared) before ordering.
- Let a group build a shared order, then split the bill fairly — including surcharge/tax — converted into their home currency.
- Keep completed-bill history durable through frozen snapshots so readable bills can be revisited without recomputation, invalid snapshot states fail safely, and records remain until the user deletes them. Original menu photos are supporting evidence governed by the user's 30-day, 90-day, or keep-forever retention choice, not an unconditional part of bill history.

## Why This Project
I've personally experienced how disorienting it is to order food abroad without being able to read the menu — guessing from pictures, pointing at random, or ending up with something unexpected. Beyond the personal motivation, this project lets me apply software engineering coursework to a real, non-trivial product: integrating a multi-modal LLM (vision + translation) into a mobile app, and handling the practical concerns — API key security, graceful fallback when a network call fails, currency data — that separate a working product from a classroom toy exercise.

## Initial Scope

**In scope for v1:**
- Multi-photo menu capture (camera or photo library)
- LLM-based menu recognition and translation (dish name, price, currency)
- On-demand, plain-language explanation of a selected dish
- Cart / order building from the translated menu
- Bill calculation: subtotal, configurable surcharge/tax, even ("AA") split across diners
- Home-currency conversion via live FX rates, with a cached fallback
- Local session history — readable completed orders/bills stay browsable without recomputation until the user deletes them, while invalid snapshot states surface safely; original menu photos remain browsable only while retained under the selected policy
- Bilingual app UI (Traditional Chinese, English), user-selectable, with USD default currency

**Waits for later:**
- Additional UI languages beyond Traditional Chinese / English
- Unequal (itemized) bill splitting and tip calculators
- Social sharing or exporting translated menus
- Offline-first recognition (current version requires network access to the LLM provider)
- Any custom backend server (the app currently talks directly to third-party APIs from the client)
