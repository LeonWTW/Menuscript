import SwiftUI

@MainActor
enum DishExplanationService {
    typealias RuntimeResolver = @MainActor (RuntimeMode) throws -> RuntimeServices?

    static func fetch(
        original: String,
        detectedLanguage: String,
        targetLanguage: String,
        providerMode: RuntimeMode?,
        secretStore: any SecretStore,
        defaults: UserDefaults,
        liveFXFactory: RuntimeServiceResolver.LiveFXFactory,
        runtimeResolver: RuntimeResolver? = nil
    ) async throws -> String {
        guard !GeminiDisclosureGate.requiresConsent(
            explicitMode: providerMode,
            defaults: defaults
        ) else {
            throw GeminiDisclosureError.consentRequired
        }

        let effectiveMode = GeminiDisclosureGate.effectiveMode(
            explicitMode: providerMode,
            defaults: defaults
        )
        let model = SettingsKeys.nonEmptyString(
            SettingsKeys.geminiModel,
            from: defaults,
            default: "gemini-2.5-flash"
        )
        let services: RuntimeServices?
        if let runtimeResolver {
            services = try runtimeResolver(effectiveMode)
        } else {
            services = try RuntimeServiceResolver.resolve(
                configuration: RuntimeServiceConfiguration(
                    mode: effectiveMode,
                    geminiModel: model
                ),
                secretStore: secretStore,
                liveFXFactory: liveFXFactory
            )
        }

        guard let services else {
            throw VisionProviderError.missingAPIKey
        }
        return try await services.visionProvider.explainDish(
            original: original,
            language: detectedLanguage,
            targetLanguage: targetLanguage
        )
    }

    /// Shared cache short-circuit used by the view and focused tests. A cached
    /// explanation never evaluates the disclosure gate or runtime resolver.
    static func fetchIfNeeded(
        currentExplanation: String?,
        forceRefresh: Bool,
        original: String,
        detectedLanguage: String,
        targetLanguage: String,
        providerMode: RuntimeMode?,
        secretStore: any SecretStore,
        defaults: UserDefaults,
        liveFXFactory: RuntimeServiceResolver.LiveFXFactory,
        runtimeResolver: RuntimeResolver? = nil
    ) async throws -> String {
        if !forceRefresh,
           let currentExplanation,
           !currentExplanation.isEmpty {
            return currentExplanation
        }
        return try await fetch(
            original: original,
            detectedLanguage: detectedLanguage,
            targetLanguage: targetLanguage,
            providerMode: providerMode,
            secretStore: secretStore,
            defaults: defaults,
            liveFXFactory: liveFXFactory,
            runtimeResolver: runtimeResolver
        )
    }

    /// Action-context adapter used by `ExplainSheet`. Keeping the request
    /// inputs together prevents a completed card from reading mutable model
    /// names or provider provenance after the user taps it.
    static func fetchIfNeeded(
        currentExplanation: String?,
        forceRefresh: Bool,
        context: MenuItemActionContext,
        secretStore: any SecretStore,
        defaults: UserDefaults,
        liveFXFactory: RuntimeServiceResolver.LiveFXFactory,
        runtimeResolver: RuntimeResolver? = nil
    ) async throws -> String {
        try await fetchIfNeeded(
            currentExplanation: currentExplanation,
            forceRefresh: forceRefresh,
            original: context.originalName,
            detectedLanguage: context.detectedLanguage,
            targetLanguage: context.targetLanguage,
            providerMode: context.providerMode,
            secretStore: secretStore,
            defaults: defaults,
            liveFXFactory: liveFXFactory,
            runtimeResolver: runtimeResolver
        )
    }
}

/// Decides whether a fetched explanation can safely become part of a
/// session's persisted cache. Legacy sessions have no recorded provenance,
/// while recorded sessions only persist results produced by the same mode.
enum DishExplanationCachePolicy {
    static func shouldPersist(
        persistedMode: RuntimeMode?,
        effectiveMode: RuntimeMode
    ) -> Bool {
        guard let persistedMode else { return true }
        return persistedMode == effectiveMode
    }
}

/// Explains a single dish in the target language. Shows the cached
/// `item.explanation` immediately when one already exists (no network call);
/// otherwise resolves a `MenuVisionProvider` on appearance and fetches one.
/// The toolbar's 重新生成 action always re-fetches. Results with incompatible
/// runtime/session provenance remain transient instead of corrupting cache.
struct ExplainSheet: View {
    @Bindable private var item: MenuItem

    @Environment(\.dismiss) private var dismiss

    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var recoveryAction: ProviderRecoveryAction?
    @State private var showSettings = false
    @State private var disclosureIsRequired = false
    @State private var showDisclosure = false
    @State private var transientExplanation: String?

    private let secretStore: any SecretStore
    private let defaults: UserDefaults
    private let liveFXFactory: RuntimeServiceResolver.LiveFXFactory
    private let actionContext: MenuItemActionContext
    private let onDeleteAllSucceeded: () -> Void

    init(
        item: MenuItem,
        actionContext: MenuItemActionContext? = nil,
        secretStore: any SecretStore = KeychainStore(),
        defaults: UserDefaults,
        liveFXFactory: @escaping RuntimeServiceResolver.LiveFXFactory = { FXService() },
        onDeleteAllSucceeded: @escaping () -> Void = {}
    ) {
        self.item = item
        self.secretStore = secretStore
        self.defaults = defaults
        self.liveFXFactory = liveFXFactory
        self.actionContext = actionContext ?? .live(item, defaults: defaults)
        self.onDeleteAllSucceeded = onDeleteAllSucceeded
    }

    private var displayedExplanation: String? {
        if let transientExplanation, !transientExplanation.isEmpty {
            return transientExplanation
        }
        if let explanation = item.explanation, !explanation.isEmpty {
            return explanation
        }
        return nil
    }

    private var hasCachedExplanation: Bool {
        displayedExplanation != nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    Divider()
                    explanationSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(MTSpacing.screenMargin)
            }
            .background(Color.mtBackground.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    regenerateButton
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            guard !hasCachedExplanation else { return }
            await fetchExplanation(forceRefresh: false)
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView(onDeleteAllSucceeded: {
                    dismiss()
                    onDeleteAllSucceeded()
                })
            }
        }
        .alert("傳送資料到 Google Gemini", isPresented: $showDisclosure) {
            Button("同意並繼續") {
                GeminiDisclosureGate.accept(defaults: defaults)
                disclosureIsRequired = false
                errorMessage = nil
                Task { await fetchExplanation(forceRefresh: true) }
            }
            Button("取消", role: .cancel) {
                showDisclosure = false
            }
        } message: {
            Text("使用真實辨識前，請確認：你嘅 Gemini API Key、菜單相片、目標語言、敏感原設定，以及之後要求解釋嘅菜式名稱，會由裝置直接傳送到 Google Gemini。資料保留方式視乎你使用嘅 Google 免費或付費方案。")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(actionContext.translatedName)
                .font(.mtDishName)
                .foregroundStyle(Color.mtTextPrimary)
            Text(actionContext.originalName)
                .font(.mtOriginalName)
                .foregroundStyle(Color.mtTextSecondary)
        }
        .textSelection(.enabled)
    }

    // MARK: - Body states

    @ViewBuilder
    private var explanationSection: some View {
        if isLoading {
            loadingState
        } else if let errorMessage {
            errorState(errorMessage)
        } else if let explanation = displayedExplanation {
            loadedState(explanation)
        } else {
            // .task hasn't produced a result yet; avoid a blank flash.
            loadingState
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("問緊 AI 呢味係咩…")
                .font(.footnote)
                .foregroundStyle(Color.mtTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 32)
    }

    private func loadedState(_ explanation: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(explanation)
                .font(.body)
                .foregroundStyle(Color.mtTextPrimary)
                .lineSpacing(6)
                .textSelection(.enabled)
            if actionContext.lowConfidence {
                lowConfidenceNote
            }
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(message)
                .font(.body)
                .foregroundStyle(Color.mtTextPrimary)
            if disclosureIsRequired {
                Button("傳送資料到 Google Gemini") {
                    showDisclosure = true
                }
                .buttonStyle(.bordered)
            } else if let recoveryAction {
                recoveryButton(for: recoveryAction)
            }
        }
    }

    @ViewBuilder
    private func recoveryButton(for action: ProviderRecoveryAction) -> some View {
        switch action {
        case .openSettings:
            Button("去 Settings") { showSettings = true }
                .buttonStyle(.bordered)
        case .reviewPermissions:
            Button("檢查專案權限") { showSettings = true }
                .buttonStyle(.bordered)
        case .reviewBilling:
            Button("檢查計費設定") { showSettings = true }
                .buttonStyle(.bordered)
        case .reviewModel:
            Button("檢查 Model 設定") { showSettings = true }
                .buttonStyle(.bordered)
        case .retry:
            Button("再試一次") {
                Task { await fetchExplanation(forceRefresh: true) }
            }
            .buttonStyle(.bordered)
        }
    }

    private var lowConfidenceNote: some View {
        Label("辨識可能有誤，請對照原文", systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(Color.mtWarning)
    }

    private var regenerateButton: some View {
        Button {
            Task { await fetchExplanation(forceRefresh: true) }
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .disabled(isLoading)
        .accessibilityLabel("重新生成")
    }

    // MARK: - Fetching

    private func fetchExplanation(forceRefresh: Bool) async {
        guard forceRefresh || !hasCachedExplanation else { return }

        errorMessage = nil
        recoveryAction = nil
        disclosureIsRequired = false
        isLoading = true
        defer { isLoading = false }

        do {
            let effectiveMode = GeminiDisclosureGate.effectiveMode(
                explicitMode: actionContext.providerMode,
                defaults: defaults
            )
            let result = try await DishExplanationService.fetchIfNeeded(
                currentExplanation: item.explanation,
                forceRefresh: forceRefresh,
                context: actionContext,
                secretStore: secretStore,
                defaults: defaults,
                liveFXFactory: liveFXFactory
            )
            guard !Task.isCancelled else { return }
            if DishExplanationCachePolicy.shouldPersist(
                persistedMode: actionContext.providerMode,
                effectiveMode: effectiveMode
            ) {
                item.explanation = result
                transientExplanation = nil
            } else {
                transientExplanation = result
            }
        } catch {
            guard !Task.isCancelled else { return }
            if error as? GeminiDisclosureError == .consentRequired {
                errorMessage = L10n.string("使用真實辨識前，請確認：你嘅 Gemini API Key、菜單相片、目標語言、敏感原設定，以及之後要求解釋嘅菜式名稱，會由裝置直接傳送到 Google Gemini。資料保留方式視乎你使用嘅 Google 免費或付費方案。")
                disclosureIsRequired = true
                showDisclosure = true
            } else if let providerError = error as? VisionProviderError {
                errorMessage = providerError.errorDescription
                recoveryAction = providerError.recoveryAction
            } else if let keychainError = error as? KeychainError {
                errorMessage = keychainError.errorDescription
                recoveryAction = .retry
            } else {
                errorMessage = L10n.string("菜式解釋暫時失敗，請再試一次。")
                recoveryAction = .retry
            }
        }
    }
}

#Preview {
    Text("菜單")
        .sheet(isPresented: .constant(true)) {
            ExplainSheet(item: MenuItem(
                originalName: "唐揚げ",
                translatedName: "日式炸雞",
                priceValue: 650,
                category: "燒烤",
                lowConfidence: true,
                explanation: "「唐揚げ」係日式炸雞嘅一種，用生粉同醬油醃料炸至外脆內嫩，係居酒屋常見嘅下酒菜。",
                sortOrder: 0
            ), defaults: .standard)
        }
}
