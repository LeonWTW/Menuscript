// Verifies that photo-library imports reserve stable slots, remain ordered,
// expose failures, and cannot update a capture screen after cancellation.

import Foundation
import SwiftData
import Testing
import UIKit
@testable import Menuscript

/// Actor-controlled loader that lets tests pause and finish imports in any order.
/// Actor isolation keeps continuation access safe across asynchronous tasks.
private actor ControlledPhotoLoader {
    /// The success-or-failure value produced by one prepared photo import.
    typealias Output = Result<ImagePrep.PreparedPhoto, CapturedPhotoFailure>

    private var continuations: [String: CheckedContinuation<Output, Never>] = [:]

    /// Suspends the named import until the test supplies its result.
    func load(_ key: String) async -> Output {
        await withCheckedContinuation { continuation in
            continuations[key] = continuation
        }
    }

    /// Reports whether a named import has reached its suspension point.
    func isWaiting(_ key: String) -> Bool {
        continuations[key] != nil
    }

    /// Finishes one named import with the exact result chosen by the test.
    func resume(_ key: String, with output: Output) {
        continuations.removeValue(forKey: key)?.resume(returning: output)
    }
}

/// Exercises the main-actor coordinator under the same isolation used by Capture UI.
@MainActor
@Suite("PhotoImportCoordinator")
struct PhotoImportCoordinatorTests {
    /// Creates isolated in-memory persistence so tests never touch saved menus.
    private func makeContext() throws -> ModelContext {
        let schema = Schema([MenuSession.self, MenuItem.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return ModelContext(container)
    }

    /// Creates a unique Settings domain for each test and returns its cleanup name.
    private func makeDefaults() throws -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "PhotoImportCoordinatorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(AppLanguage.zhHant.rawValue, forKey: SettingsKeys.appLanguage)
        defaults.set("JPY", forKey: SettingsKeys.homeCurrency)
        return (defaults, suiteName)
    }

    /// Builds a capture view model with fully offline services for coordinator tests.
    private func makeViewModel(defaults: UserDefaults) throws -> CaptureViewModel {
        CaptureViewModel(
            modelContext: try makeContext(),
            provider: MockVisionProvider(),
            defaults: defaults
        )
    }

    /// Makes a tiny prepared photo with a caller-chosen byte for order assertions.
    private func preparedPhoto(byte: UInt8) -> ImagePrep.PreparedPhoto {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        return ImagePrep.PreparedPhoto(preview: image, jpegData: Data([byte]))
    }

    /// Cooperatively waits for asynchronous state and records a readable timeout failure.
    private func waitUntil(
        _ description: String,
        condition: @escaping @MainActor () async -> Bool
    ) async {
        for _ in 0..<1_000 {
            if await condition() { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for \(description)")
    }

    /// Protects recognition readiness and selection order when independent import
    /// batches overlap and the later batch finishes first.
    @Test("Overlapping batches stay pending until both finish and preserve reservation order")
    func overlappingBatchesDoNotEnableRecognitionEarly() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = try makeViewModel(defaults: defaults)
        let coordinator = PhotoImportCoordinator()
        let gate = ControlledPhotoLoader()

        coordinator.importBatch(loaders: [{ await gate.load("A") }], into: viewModel)
        coordinator.importBatch(loaders: [{ await gate.load("B") }], into: viewModel)

        await waitUntil("both loader registrations") {
            let aIsWaiting = await gate.isWaiting("A")
            let bIsWaiting = await gate.isWaiting("B")
            return aIsWaiting && bIsWaiting
        }
        let reservedIDs = viewModel.photos.map(\.id)
        #expect(viewModel.pendingPhotoCount == 2)
        #expect(viewModel.canRecognize == false)

        await gate.resume("B", with: .success(preparedPhoto(byte: 0xB2)))
        await waitUntil("batch B completion") { viewModel.pendingPhotoCount == 1 }
        #expect(viewModel.canRecognize == false)
        #expect(viewModel.photos.map(\.id) == reservedIDs)

        await gate.resume("A", with: .success(preparedPhoto(byte: 0xA1)))
        await waitUntil("batch A completion") { viewModel.pendingPhotoCount == 0 }

        #expect(viewModel.canRecognize == true)
        #expect(viewModel.photos.map(\.id) == reservedIDs)
        #expect(viewModel.photos[0].jpegData == Data([0xA1]))
        #expect(viewModel.photos[1].jpegData == Data([0xB2]))
    }

    /// Protects a dismissed capture screen from a cancelled loader that returns late.
    @Test("Cancel removes pending reservations and ignores a loader that completes late")
    func cancelRejectsLateCompletion() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = try makeViewModel(defaults: defaults)
        let coordinator = PhotoImportCoordinator()
        let gate = ControlledPhotoLoader()

        coordinator.importBatch(loaders: [{ await gate.load("late") }], into: viewModel)
        await waitUntil("loader registration") { await gate.isWaiting("late") }
        #expect(viewModel.pendingPhotoCount == 1)

        coordinator.cancelAll(in: viewModel)
        #expect(viewModel.photos.isEmpty)

        await gate.resume("late", with: .success(preparedPhoto(byte: 0xCC)))
        for _ in 0..<20 { await Task.yield() }

        #expect(viewModel.photos.isEmpty)
        #expect(viewModel.canRecognize == false)
    }

    /// Protects visibility of import failures and prevents incomplete menus from recognition.
    @Test("A failed loader remains visible and blocks recognition")
    func failedLoaderRemainsExplicit() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = try makeViewModel(defaults: defaults)
        let coordinator = PhotoImportCoordinator()

        coordinator.importBatch(
            loaders: [{ .failure(.jpegEncodingFailed) }],
            into: viewModel
        )
        await waitUntil("failed loader resolution") { viewModel.pendingPhotoCount == 0 }

        #expect(viewModel.photos.count == 1)
        #expect(viewModel.failedPhotoCount == 1)
        #expect(viewModel.canRecognize == false)
        #expect(viewModel.photos.first?.failure == .jpegEncodingFailed)
    }

    /// Protects pending work while Capture is only covered by its own camera or
    /// Settings sheet, then cancels it when Capture actually leaves the screen.
    @Test("Camera and Settings child presentations do not cancel pending reservations")
    func childPresentationsPreservePendingReservations() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = try makeViewModel(defaults: defaults)
        let coordinator = PhotoImportCoordinator()

        _ = viewModel.reservePhotoSlots(count: 1)
        #expect(viewModel.pendingPhotoCount == 1)

        CaptureImportLifecycle.handleDisappear(
            isPresentingCamera: true,
            isPresentingSettings: false,
            coordinator: coordinator,
            viewModel: viewModel
        )
        #expect(viewModel.pendingPhotoCount == 1)

        CaptureImportLifecycle.handleDisappear(
            isPresentingCamera: false,
            isPresentingSettings: true,
            coordinator: coordinator,
            viewModel: viewModel
        )
        #expect(viewModel.pendingPhotoCount == 1)

        CaptureImportLifecycle.handleDisappear(
            isPresentingCamera: false,
            isPresentingSettings: false,
            coordinator: coordinator,
            viewModel: viewModel
        )
        #expect(viewModel.photos.isEmpty)
    }
}
