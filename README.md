# Menuscript

## Overview
Menuscript is an iOS app that helps travelers understand foreign-language restaurant menus — including the handwritten, locally-styled menus that are the real challenge: no printed layout, stylized handwriting, regional shorthand. This is exactly where generic tools like Google Translate's camera mode tend to fall apart, producing garbled, near-unreadable output. Menuscript uses an LLM vision model instead of plain OCR, so it can actually make sense of these menus — recognizing dish names in context, translating them accurately, and explaining unfamiliar dishes in plain language — then lets you build an order and split the bill, converted into your home currency.

## Current Status
Prototype/spike stage. The core end-to-end flow is implemented and working (milestones M1–M6): multi-photo menu capture, LLM-based menu recognition and translation, per-dish AI explanations, cart building, bill calculation with surcharge and even ("AA") splitting, foreign-exchange conversion, session history, and a bilingual (Traditional Chinese / English) UI with USD as the default currency. This validates that the core idea is technically feasible. Sprint 1 formalizes the project definition — vision, requirements, architecture — that will guide hardening this prototype into a polished first release in later sprints.

## Project Documents
- [Project Vision](docs/project-vision.md) — problem, users, goals, scope
- [Requirements](docs/requirements.md) — functional, data, and non-functional requirements
- [Architecture](docs/architecture.md) — components, data flow, open questions

## Setup Notes
- Requires Xcode with an iOS 17+ simulator or device.
- This project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) — the `.xcodeproj` is generated from `project.yml`, not committed. Run `xcodegen generate` in the repo root, then open the generated `MenuTranslate.xcodeproj` in Xcode. (The Xcode project, folders, and bundle id are still internally named `MenuTranslate` — a technical rename to match the `Menuscript` product name is planned for a later sprint, not part of Sprint 1.)
- Bring your own Gemini API key: enter it in the app's Settings screen (stored in Keychain, never bundled with the app). A mock-provider toggle in Settings lets you run the app without a live key.
