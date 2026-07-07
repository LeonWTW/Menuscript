import SwiftUI

/// Minimal Settings screen: Gemini API key (Keychain-backed), model id,
/// target translation language, home currency, and a mock-provider toggle
/// so the app can be demoed without a real API key (BYOK).
struct SettingsView: View {
    @AppStorage(SettingsKeys.targetLanguage) private var targetLanguage: String = "繁體中文"
    @AppStorage(SettingsKeys.homeCurrency) private var homeCurrency: String = "HKD"
    @AppStorage(SettingsKeys.geminiModel) private var geminiModel: String = "gemini-2.5-flash"
    @AppStorage(SettingsKeys.useMockProvider) private var useMockProvider: Bool = false

    @State private var apiKeyInput: String = ""
    @State private var hasStoredKey: Bool = false

    private let keychainStore = KeychainStore()
    private let commonCurrencies = ["HKD", "TWD", "USD", "JPY", "EUR", "GBP", "CNY"]

    var body: some View {
        Form {
            Section {
                SecureField("Gemini API Key", text: $apiKeyInput)
                if hasStoredKey {
                    Label("已設定 ✓", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.footnote)
                }
                HStack {
                    Button("儲存") { saveAPIKey() }
                        .disabled(apiKeyInput.isEmpty)
                    Spacer()
                    Button("清除", role: .destructive) { clearAPIKey() }
                        .disabled(!hasStoredKey)
                }
                TextField("模型名稱", text: $geminiModel)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text("Gemini API")
            } footer: {
                Text("需要自備 Gemini API Key（BYOK）先可以使用真實辨識功能。API Key 只會儲存喺裝置嘅 Keychain 入面，唔會上傳到第三方伺服器。")
            }

            Section {
                TextField("目標語言", text: $targetLanguage)
            } header: {
                Text("翻譯設定")
            } footer: {
                Text("菜單項目會翻譯做呢個語言，例如「繁體中文」。")
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
                Toggle("示範模式（Mock 數據）", isOn: $useMockProvider)
            } footer: {
                Text("開啟之後會用內置嘅示範菜單數據，唔會呼叫真實 API，方便測試同示範，唔需要 API Key。")
            }
        }
        .navigationTitle("設定")
        .onAppear(perform: refreshKeyState)
    }

    private func refreshKeyState() {
        let stored = keychainStore.get(KeychainStore.geminiAPIKey)
        hasStoredKey = !(stored?.isEmpty ?? true)
    }

    private func saveAPIKey() {
        guard !apiKeyInput.isEmpty else { return }
        try? keychainStore.set(apiKeyInput, forKey: KeychainStore.geminiAPIKey)
        apiKeyInput = ""
        hasStoredKey = true
    }

    private func clearAPIKey() {
        try? keychainStore.delete(KeychainStore.geminiAPIKey)
        apiKeyInput = ""
        hasStoredKey = false
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}
