# Repository Guidelines

These guidelines apply to every contribution to Menuscript, whether written by hand or drafted with AI assistance. AI tools are used in this project to support implementation, review, and documentation — never to replace engineering judgment. Every change is reviewed, tested, and approved by the project owner before it lands.

## Project Structure & Module Organization

Menuscript is a client-only iOS app targeting iOS 17+ and written in Swift 6. App code lives in `Menuscript/`:

- `App/` contains the app entry point, root view, settings keys, and localization helpers.
- `Features/` groups SwiftUI screens by flow: `Capture`, `Menu`, `Bill`, and `Settings`; reusable menu controls belong in `Features/Menu/Components/`.
- `Models/` holds SwiftData models and pure business logic such as `BillMath`.
- `Services/` isolates external I/O (Gemini, FX rates, Keychain, image preparation) behind small protocols.
- `Resources/` contains asset catalogs and `.xcstrings` localization files.

Tests live in `MenuscriptTests/`, normally in a file named after the unit under test (for example, `BillMathTests.swift`). Product and design documentation lives in `docs/`.

## Build, Test, and Development Commands

The Xcode project is generated and intentionally ignored by Git. After cloning or changing `project.yml`, run:

```bash
xcodegen generate                 # regenerate Menuscript.xcodeproj
open Menuscript.xcodeproj         # develop/run in Xcode
xcodebuild test -project Menuscript.xcodeproj -scheme Menuscript \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Use the mock vision provider for repeatable local runs; it works fully offline and needs no Gemini key.

## Coding Style & Naming Conventions

Follow the existing Swift style: four-space indentation, one type per focused file, `UpperCamelCase` types and `lowerCamelCase` functions/properties. Keep views thin and put deterministic calculations, parsing, and URL construction in testable model or feature-logic types. Prefer `Decimal` for prices and totals. Document non-obvious behavior with concise `///` comments. There is no committed formatter or linter, so match nearby code.

## Testing Guidelines

The suite mixes Swift Testing (`@Suite`, `@Test`, `#expect`) and XCTest. Add focused regression tests for behavior changes, especially provider request construction, localization, settings fallbacks, and bill arithmetic. Tests must never call live Gemini or FX services; use mocks, injected dependencies, or recorded responses. Run the full `xcodebuild test` command and confirm a green suite before opening a PR.

## Commit & Pull Request Guidelines

Use concise conventional-style subjects reflected in history: `feat:`, `fix:`, `refactor:`, `docs:`, or `chore:`. Keep commits single-purpose. PRs should explain the user-visible change and the testing performed, and include simulator screenshots for UI changes. Never commit API keys, signing material, `.env` files, or generated Xcode project files; Gemini keys belong only in the iOS Keychain.

## Responsible AI Use

AI assistance in this repository follows four principles:

- **Human ownership.** All commits are authored and approved by the project owner. AI-drafted code is treated as a proposal: it is read, understood, and often revised before it is committed, and it must meet the same style, testing, and documentation standards as hand-written code.
- **Verification before trust.** No AI-produced change is accepted on faith. The full test suite must pass before any merge, behavior changes require regression tests, and findings from AI-assisted code review are independently verified against the actual code before fixes are applied.
- **Transparency.** `docs/ai-implementation-review.md` records how AI supported each sprint, including suggestions that were accepted, revised, or rejected — and why.
- **Privacy and security.** Secrets, API keys, and user data are never shared with AI tools or committed to the repository. The product applies the same standard to its own AI features: menu photos are sent to Gemini only in live mode, only after explicit user disclosure and consent, and the app defaults to a fully offline demo mode.
