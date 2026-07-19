import Testing
@testable import Menuscript

private enum DeleteAllFlowFailure: Error, CaseIterable {
    case fetch
    case save
}

@MainActor
@Suite("Settings delete-all flow")
struct SettingsDeleteAllFlowTests {
    @Test("Success dismisses and invokes navigation callback exactly once")
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
