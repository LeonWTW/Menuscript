// Presents user preferences, secure API-key management, manual FX overrides,
// and destructive history controls while delegating storage to focused services.

import SwiftData
import SwiftUI

/// Minimal Settings screen: Gemini API key (Keychain-backed), model id,
/// target translation language, home currency, and a mock-provider toggle
/// so the app can be demoed without a real API key (BYOK).
struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @AppStorage(SettingsKeys.targetLanguage) private var targetLanguage: String = SettingsKeys.defaultTargetLanguage()
    @AppStorage(SettingsKeys.homeCurrency) private var homeCurrency: String = "USD"
    @AppStorage(SettingsKeys.geminiModel) private var geminiModel: String = "gemini-2.5-flash"
    @AppStorage(SettingsKeys.useMockProvider) private var useMockProvider: Bool = false
    @AppStorage(SettingsKeys.appLanguage) private var appLanguageRaw: String = "system"
    @AppStorage(SettingsKeys.allergenPresets) private var allergenPresets: String = ""
    @AppStorage(SettingsKeys.allergenCustom) private var allergenCustom: String = ""

    @State private var apiKeyState: APIKeySettingsModel

    @State private var fxFromCode: String = ""
    @State private var fxToCode: String = ""
    @State private var fxRateInput: String = ""
    @State private var showDeleteAllConfirm = false
    @State private var persistenceErrorMessage: String?

    private let fxOverrideStore: any FXManualOverrideStoring
    private let onDeleteAllSucceeded: () -> Void
    private let commonCurrencies = ["USD", "HKD", "TWD", "JPY", "EUR", "GBP", "CNY"]

    /// Reads the marketing version from the app bundle for a simple footer display.
    private var appVersionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
    }

    /// Creates Settings with secure and FX storage dependencies that can be
    /// replaced in tests while production defaults remain convenient.
    init(
        secretStore: any SecretStore = KeychainStore(),
        fxOverrideStore: any FXManualOverrideStoring = FXManualOverrideStore(),
        onDeleteAllSucceeded: @escaping () -> Void = {}
    ) {
        _apiKeyState = State(
            initialValue: APIKeySettingsModel(secretStore: secretStore)
        )
        self.fxOverrideStore = fxOverrideStore
        self.onDeleteAllSucceeded = onDeleteAllSucceeded
    }

    /// Organizes settings by user purpose and binds simple preferences directly
    /// to persistent storage while routing complex actions through helper models.
    var body: some View {
        @Bindable var keyState = apiKeyState
        Form {
            Section {
                Picker("語言", selection: $appLanguageRaw) {
                    ForEach(AppLanguage.allCases) { language in
                        languageLabel(for: language).tag(language.rawValue)
                    }
                }
            } header: {
                Text("語言")
            }

            Section {
                SecureField("Gemini API Key", text: $keyState.input)
                if keyState.hasStoredKey {
                    Label("已設定 ✓", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.footnote)
                }
                if let keychainError = keyState.errorMessage {
                    Label(keychainError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
                HStack {
                    Button("儲存") { keyState.save() }
                        .disabled(keyState.input.isEmpty)
                    Spacer()
                    Button("清除", role: .destructive) { keyState.delete() }
                        .disabled(!keyState.hasStoredKey)
                }
                TextField("模型名稱", text: $geminiModel)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text("Gemini API")
            } footer: {
                Text("需要自備 Gemini API Key（BYOK）先可以使用真實功能。API Key 會儲存喺裝置 Keychain；使用真實辨識或菜式解釋時，App 會將 Key 同相關請求直接傳送到 Google Gemini，唔會經我哋嘅伺服器。")
            }

            Section {
                TextField("目標語言", text: $targetLanguage)
            } header: {
                Text("翻譯設定")
            } footer: {
                Text("菜單項目會翻譯做呢個語言，例如「繁體中文」。")
            }

            Section {
                ForEach(Allergen.allCases) { allergen in
                    Toggle(isOn: allergenBinding(for: allergen)) {
                        Text(allergen.displayName)
                    }
                }
                TextField("自訂敏感原（逗號分隔）", text: $allergenCustom)
            } header: {
                Text("食物敏感")
            } footer: {
                Text("AI 翻譯新菜單時會標示可能含有呢啲食材嘅菜式。判斷僅供參考，未必準確，落單前請務必同餐廳確認。設定只影響之後新辨識嘅菜單。")
            }

            Section {
                Picker("常用貨幣", selection: $homeCurrency) {
                    ForEach(commonCurrencies, id: \.self) { code in
                        Text(code).tag(code)
                    }
                }
                TextField("自訂貨幣代碼", text: $homeCurrency)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
            } header: {
                Text("主要貨幣")
            } footer: {
                Text("用嚟顯示匯率換算後嘅價錢。清單冇你想要嘅貨幣可以喺下面手動輸入 ISO 代碼，例如 THB。")
            }

            Section {
                HStack {
                    TextField("從 (例如 JPY)", text: $fxFromCode)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                    TextField("至 (例如 HKD)", text: $fxToCode)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                }
                TextField("手動匯率", text: $fxRateInput)
                    .keyboardType(.decimalPad)
                HStack {
                    Button("儲存") { saveFXOverride() }
                        .disabled(!isValidFXOverrideInput)
                    Spacer()
                    Button("清除 Override", role: .destructive) { clearFXOverride() }
                        .disabled(fxFromCode.isEmpty || fxToCode.isEmpty)
                }
            } header: {
                Text("匯率")
            } footer: {
                Text("留空用自動匯率（ECB 日更）。呢度嘅設定只會影響之後新辨識嘅菜單，唔會改到已經辨識咗嘅舊記錄。")
            }

            Section {
                Toggle("示範模式（Mock 數據）", isOn: $useMockProvider)
            } footer: {
                Text("開啟之後會用內置嘅示範菜單數據，唔會呼叫真實 API，方便測試同示範，唔需要 API Key。")
            }

            Section {
                Button("清除全部菜單記錄", role: .destructive) {
                    showDeleteAllConfirm = true
                }
                .confirmationDialog(
                    "確定要清除全部菜單記錄？",
                    isPresented: $showDeleteAllConfirm,
                    titleVisibility: .visible
                ) {
                    Button("清除全部", role: .destructive) { deleteAllSessions() }
                    Button("取消", role: .cancel) {}
                }
            } header: {
                Text("資料")
            } footer: {
                Text("呢個操作無法還原。")
            }

            Section {
            } footer: {
                HStack {
                    Spacer()
                    Text("版本 \(appVersionString)")
                    Spacer()
                }
            }
        }
        .navigationTitle("設定")
        .onAppear { apiKeyState.refresh() }
        .alert("清除全部菜單記錄", isPresented: persistenceErrorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(persistenceErrorMessage ?? "")
        }
    }

    /// Maps each stored app-language choice to its human-readable picker label.
    @ViewBuilder
    private func languageLabel(for language: AppLanguage) -> some View {
        switch language {
        case .system:
            Text("跟隨系統")
        case .zhHant:
            Text(verbatim: "繁體中文")
        case .english:
            Text(verbatim: "English")
        }
    }

    /// Toggle binding that inserts/removes an allergen slug in the
    /// comma-joined `allergenPresets` `@AppStorage` string.
    private func allergenBinding(for allergen: Allergen) -> Binding<Bool> {
        Binding(
            get: { Allergen.selectedSlugs(allergenPresets).contains(allergen.rawValue) },
            set: { isOn in
                var slugs = Allergen.selectedSlugs(allergenPresets)
                if isOn {
                    slugs.insert(allergen.rawValue)
                } else {
                    slugs.remove(allergen.rawValue)
                }
                allergenPresets = Allergen.serialize(slugs)
            }
        )
    }

    /// Validates positive numeric rate input plus two three-letter currency codes.
    private var isValidFXOverrideInput: Bool {
        guard let rate = Double(fxRateInput), rate.isFinite, rate > 0 else { return false }
        return isValidCurrencyCode(fxFromCode) && isValidCurrencyCode(fxToCode)
    }

    /// Accepts only a trimmed ISO-style three-letter alphabetic currency code.
    private func isValidCurrencyCode(_ code: String) -> Bool {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return trimmed.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil
    }

    /// Persists the entered rate only after the complete override form is valid.
    private func saveFXOverride() {
        guard isValidFXOverrideInput, let rate = Double(fxRateInput) else { return }
        fxOverrideStore.setManualOverride(rate, from: fxFromCode, to: fxToCode)
    }

    /// Removes the override for the entered currency pair and clears its rate field.
    private func clearFXOverride() {
        guard !fxFromCode.isEmpty, !fxToCode.isEmpty else { return }
        fxOverrideStore.setManualOverride(nil, from: fxFromCode, to: fxToCode)
        fxRateInput = ""
    }

    /// Bridges an optional persistence failure to SwiftUI's Boolean alert API.
    private var persistenceErrorBinding: Binding<Bool> {
        Binding(
            get: { persistenceErrorMessage != nil },
            set: { if !$0 { persistenceErrorMessage = nil } }
        )
    }

    /// Deletes all saved menu sessions, dismisses only after success, and lets
    /// the presenting flow reset any now-invalid navigation state.
    private func deleteAllSessions() {
        do {
            try SettingsDeleteAllFlow.perform(
                deleteAll: {
                    try SessionStore(context: modelContext).deleteAll()
                },
                dismiss: {
                    dismiss()
                },
                onSucceeded: onDeleteAllSucceeded
            )
        } catch {
            persistenceErrorMessage = error.localizedDescription
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
    .modelContainer(for: MenuSession.self, inMemory: true)
}
