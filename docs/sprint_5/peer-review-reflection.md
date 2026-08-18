# Peer Review Reflection — Menuscript

**Leon Wong · Sprint 5 · branch `sprint-5-professional-completion`**

I received one peer review (`docs/peer-review-1.txt`), covering `sprint-4-quality` at commits `41df014` / `d5794d6`.

## 1. Most Valuable Feedback

The most valuable recommendation was a retention policy for stored menu photos. Deleting a session already removed its photos, but nothing pruned them on its own, and nothing let a user keep a finished bill while dropping its photos. The reviewer ranked it above the XCUITest migration: "unbounded storage growth is a critical user-facing defect."

I agree with the direction, but sized it myself rather than inheriting the label. What persists is not the "full-resolution (downsampled to 2560px)" image the review assumes: 2,560 px is only the decode bound, and persistence re-encodes at a 1,600 px long edge, quality 0.7 (`ImagePrep.swift:28`). Read out of my simulator stores with `sqlite3`, the two real captures measure 437 KB and 299 KB, so a ten-day trip costs tens of megabytes — "gigabytes over time" is about two orders out. It is still the top defect, but for a different reason than the one given: the harm is how long the photos exist, not how much room they take. The praise deserves the same scepticism. 236 unit tests partly earn the claim that a joining engineer could refactor with "absolute confidence", but no CI, no second committer and nothing automated checking the rendered interface make *absolute* an overstatement.

The reviewer also arrived at a gap I had written down and left alone. At the commit reviewed, `d5794d6:docs/architecture.md` listed as an open question that "nothing currently prunes them… no per-session 'delete photos but keep the bill' option"; the same bullet now reads *Partially resolved in Sprint 5*. I had filed it as a known limitation; an outside reader filed the same sentence as the project's highest-priority defect. I had been treating persistence as append-only, and Sprint 3, spent making completed bills immutable, hardened the instinct until deletion looked like the opposite of quality. For an app whose privacy argument is that content stays on the device, "we keep it forever by default" is a weak position I had not noticed I was standing in.

## 2. Improvements You Made

I acted on three of the five recommendations — retention, test-suite structure, and the verification half of the Dynamic Type request — declined a fourth on evidence (§ 3) and postponed the fifth. None of it is committed; all of it is working-tree state at `a41caf6`.

**Photo retention — the greatest improvement.** `PhotoRetentionPolicy` offers 30 days, 90 days or keep-forever, defaulting to 30. `PhotoRetentionService` prunes with the narrowest blast radius I could give it: it assigns `session.photos = []` and `session.photosPrunedAt = now`, nothing else. Only *completed* sessions holding a stored bill are eligible — for a draft, the photos are the only surviving record of the meal. All mutation happens in a short-lived `ModelContext` with `autosaveEnabled = false`, so discarding that context *is* the rollback, the discipline `SessionStore.persistDeletion` already used.

Two artifacts back that. `PhotoRetentionServiceTests` re-fetches through a fresh `ModelContext` after pruning and asserts `billSnapshotData` is byte-identical and every line item and metadata field unchanged. `manual-verification.md` § 2026-08-16 runs it on a simulator: an aged completed session's `photos` column falls from 1113 to 219 bytes while its bill snapshot hashes to `faab8d3d…` before and after, and an aged draft keeps everything. That pass also states its limit — the demo photos are small enough to store inline, so no on-disk reclamation was measurable.

**Why a window, not the alternatives.** `architecture.md` named a size budget and a per-session "delete photos now" control. Since the harm is duration rather than volume, only the window addresses it directly: a budget bounds bytes but not exposure and triggers on global store state, making it unpredictable ("my photos vanished because I took more later"), while a per-session control protects only the user who thinks to use it, who is not the user at risk. The budget stays open as a complement.

**Test suite organization.** Mirroring the app's structure across thirty-odd flat test files was not pure tidying: four of them found the repository root from `#filePath` by stripping exactly two path components, so moving them one level deeper would have silently pointed their file reads at the wrong place. `RepoPaths.root` replaces that arithmetic by walking upward to `project.yml`, or failing loudly. The suite grew from 220 tests to 236 — the sixteen new ones exactly those I wrote for retention — and `xcodebuild test` exits 0: `Test run with 195 tests in 35 suites passed`, `Executed 41 tests, with 0 failures`, `** TEST SUCCEEDED **`. The static count of test declarations is 236 before and after the move, which is how I know it lost nothing.

**Dynamic Type.** Asked for evidence that the accessibility-size layout branches work, I drove a simulator at both ends of that range across five screens: the branches render, and one clips — the History camera button covers a row's status text, documented and unfixed. That closes the recommendation's verification half, not its automation half.

## 3. Engineering Judgment

I postponed migrating manual verification from `osascript`/`cliclick` into a native XCUITest target. The reviewer is right that the harness is fragile and that it makes continuous integration effectively impossible.

Both sides needed sizing. The port is a new target plus the launch-argument seeding it needs, then the simulator-portable flows — perhaps half a dozen, since the live-Gemini and physical-device cases cannot move — and CI additionally needs a macOS runner, because `xcodebuild` is macOS-only. Against that, XCUITest may relocate some fragility rather than remove it, since the capture flows begin at permission dialogs the app does not own; that much is an untested estimate, as this repository has never had a UI-test target. Retention was a defect that reached users, so the defect wins — until more than one person commits here, at which point unverified change becomes the dominant risk.

The cheaper middle path needs its own answer. Snapshot tests never touch a permission dialog, and my own notes call them "the right next investment". I postponed them for a different reason: this sprint's accessibility pass ended with four documented layout findings, and baselines recorded now would enshrine the clipping I had just found as the expected result. Fix, then record.

I also declined one recommendation on evidence. The reviewer suggested centralising the `xcodegen generate` and `xcodebuild test` commands into the root README, calling them scattered through the verification documents; at the exact commit reviewed, `git show d5794d6:README.md` already contains a `## Quickstart` section with both. They read a genuinely large documentation set and reasonably missed it. I mention it because accepting every recommendation uncritically would have had me "fix" something that was not broken.

## 4. Looking Back

The decision I am most proud of is making completed bills immutable in Sprint 3: at checkout the rate, currencies, surcharge and line items are frozen into versioned, opaque bytes stored separately from the editable session, and a completed bill is decoded from those bytes rather than recomputed. The reviewer independently named it the project's leading strength, but what convinced me was watching it pay off this sprint. Because the finalized bill depends on nothing that can later change, pruning photos was safe by construction rather than by care — I never had to reason about whether deleting a photo might invalidate a historical total.

What I would do differently is smaller and harder. A limitation with no owner and no date is not a plan; it is a tidy record of a decision I keep deferring, and this one sat for two sprints because writing it down felt like having handled it. From now on, when an open question describes something a user would experience as a defect, it gets a name and a sprint attached the moment I write it. The second habit this review taught, by accident, is to check a severity claim myself rather than inherit the label — in either direction.

## 5. Looking Forward

My next priority is automated UI verification that runs in CI, because manual verification is the binding constraint on safe change: 236 tests cover money arithmetic, persistence, localization and dependency wiring in about three seconds, while anything visual costs a manual pass and so gets checked less often than it should.

Concretely: fix the four layout findings this sprint recorded, then record snapshot baselines for the five main screens at default size, AX3 and AX5, inside the existing hosted unit-test target — no permission dialog, no new target. Done means a layout change on those screens fails the build with a rendered diff instead of passing quietly. The macOS-runner blocker is real but bounded: the repository's only workflow runs a third-party review action on `ubuntu-latest` and never invokes `xcodebuild`, so this means adding a macOS workflow, not fixing an existing one — and a simulator-destination run needs no signing identity. XCUITest for the camera and library flows stays behind that, covering what no snapshot can.
