// Verifies the Settings delete-all workflow coordinates storage, dismissal, and navigation safely.
// Side effects are supplied as closures so success and failure behavior can be checked independently.

import Testing
@testable import Menuscript

/// Errors injected to represent either a fetch or save failure in the persistence layer.
private enum DeleteAllFlowFailure: Error, CaseIterable {
    case fetch
    case save
}

@MainActor
@Suite("Settings delete-all flow")
/// Protects the rule that the screen changes only after all history has been deleted successfully.
struct SettingsDeleteAllFlowTests {
    @Test("Success dismisses and invokes navigation callback exactly once")
    /// Confirms a successful deletion runs each storage and presentation action once.
    func successRunsEachEffectOnce() throws {
        var deleteCount = 0
        var dismissCount = 0
        var callbackCount = 0

        let deleted = try SettingsDeleteAllFlow.perform(
            deleteAll: {
                deleteCount += 1
                return 3
            },
            dismiss: {
                dismissCount += 1
            },
            onSucceeded: {
                callbackCount += 1
            }
        )

        #expect(deleted == 3)
        #expect(deleteCount == 1)
        #expect(dismissCount == 1)
        #expect(callbackCount == 1)
    }

    @Test("Fetch and save failures leave presentation and navigation untouched")
    /// Confirms any persistence error stays visible on the current screen and skips success callbacks.
    func failureHasNoPresentationEffects() {
        for failure in DeleteAllFlowFailure.allCases {
            var deleteCount = 0
            var dismissCount = 0
            var callbackCount = 0

            do {
                _ = try SettingsDeleteAllFlow.perform(
                    deleteAll: {
                        deleteCount += 1
                        throw failure
                    },
                    dismiss: {
                        dismissCount += 1
                    },
                    onSucceeded: {
                        callbackCount += 1
                    }
                )
                Issue.record("Expected \(failure) failure")
            } catch let caught as DeleteAllFlowFailure {
                #expect(caught == failure)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(deleteCount == 1)
            #expect(dismissCount == 0)
            #expect(callbackCount == 0)
        }
    }
}
