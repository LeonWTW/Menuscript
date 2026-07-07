import SwiftUI

/// Explains a single dish in the target language. Shows the cached
/// `item.explanation` immediately when one already exists (no network call);
/// otherwise resolves a `MenuVisionProvider` on appearance and fetches one.
/// The toolbar's 重新生成 action always re-fetches and overwrites the cache,
/// even when a cached explanation is already on screen.
struct ExplainSheet: View {
    @Bindable private var item: MenuItem

    @State private var isLoading = false
    @State private var errorMessage: String?

    init(item: MenuItem) {
        self.item = item
    }

    private var targetLanguage: String {
        item.session?.targetLanguage
            ?? UserDefaults.standard.string(forKey: SettingsKeys.targetLanguage)
            ?? "繁體中文"
    }

    private var hasCachedExplanation: Bool {
        !(item.explanation?.isEmpty ?? true)
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
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.translatedName)
                .font(.mtDishName)
                .foregroundStyle(Color.mtTextPrimary)
            Text(item.originalName)
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
        } else if let explanation = item.explanation, !explanation.isEmpty {
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
            if item.lowConfidence {
                lowConfidenceNote
            }
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(message)
                .font(.body)
                .foregroundStyle(Color.mtTextPrimary)
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
        isLoading = true
        defer { isLoading = false }

        guard let provider = ProviderFactory.resolve() else {
            errorMessage = "未設定 API key，去 Settings 設定先用得解釋功能"
            return
        }

        do {
            let result = try await provider.explainDish(
                original: item.originalName,
                language: item.session?.detectedLanguage ?? "",
                targetLanguage: targetLanguage
            )
            guard !Task.isCancelled else { return }
            item.explanation = result
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = (error as? VisionProviderError)?.errorDescription ?? error.localizedDescription
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
            ))
        }
}
