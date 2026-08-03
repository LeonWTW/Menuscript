import Foundation
import Testing

@Suite("Privacy and localization contract")
struct PrivacyLocalizationContractTests {
    private static let wave3ExactTranslations = [
        "未能儲存菜單，請再試一次。": [
            "en": "Couldn't save the menu. Try again.",
            "zh-Hant": "未能儲存菜單，請再試一次。",
        ],
        "帳單未能安全顯示": [
            "en": "Bill unavailable",
            "zh-Hant": "帳單未能安全顯示",
        ],
        "已完成帳單資料已損壞，因此未有顯示任何帳單內容。": [
            "en": "The completed bill data is unreadable, so no bill details are shown.",
            "zh-Hant": "已完成帳單資料已損壞，因此未有顯示任何帳單內容。",
        ],
        "未有加入已完成訂單": [
            "en": "Not included in the completed order",
            "zh-Hant": "未有加入已完成訂單",
        ],
        "示範模式暫時唔支援呢個貨幣組合，請喺設定揀另一隻貨幣。": [
            "en": "Demo Mode doesn't support this currency pair yet. Choose another currency in Settings.",
            "zh-Hant": "示範模式暫時唔支援呢個貨幣組合，請喺設定揀另一隻貨幣。",
        ],
    ]

    private static let criticalKeys = [
        "最多只可以加入 %lld 張相；今次有 %lld 張未加入。",
        "仲有 %lld 張相載入緊，等全部完成先可以辨識。",
        "。請刪除失敗嘅相，再重新揀選或拍攝。",
        "相片資料太大（上限 %.0f MB）。請刪除部分相片再試。",
        "未完成",
        "已完成",
        "菜單相片",
        "相片無法顯示",
        "載入失敗",
        "第 %lld 頁，共 %lld 頁",
        "菜單相片，第 %lld 頁，共 %lld 頁",
        "第 %lld 頁嘅相片資料已損壞",
        "正在載入第 %lld 頁菜單相片",
        "附加費／稅 %@%%",
        "請先揀至少一款菜式先完成帳單。",
        "帳單記錄版本（%lld）未能讀取。",
        "已完成帳單缺少可讀取嘅快照，記錄未有再被修改。",
        "部分菜單記錄未完成儲存，今次未有刪除任何記錄。",
        "未能儲存帳單，請再試一次。（%@）",
        "未能讀取菜單記錄，請再試一次。（%@）",
        "未能刪除菜單記錄，原有記錄已保留。（%@）",
        "Keychain 回傳咗無效資料。",
        "Keychain 內嘅 API Key 資料已損壞。",
        "Keychain 暫時無法使用，請稍後再試。",
        "安全儲存空間暫時無法使用，請稍後再試。",
        "Gemini API Key 無效或已失效，請去設定更新。",
        "離線示範模式暫時唔支援「%@」，請選擇繁體中文或 English。",
        "Gemini 專案無權使用呢個功能，請檢查 API Key 所屬專案權限。",
        "Gemini 專案嘅計費設定未啟用或有問題，請檢查 Google AI 專案。",
        "Gemini API 用量已達上限，請等限額重置或檢查專案配額。",
        "已選嘅 Gemini model 不存在或者專案無權使用，請檢查 model 設定。",
        "Gemini 拒絕咗呢次請求，請檢查 model 設定或重新選擇相片。",
        "Gemini 服務暫時不可用，請稍後再試。",
        "相片資料太大，請減少相片或重新影過。",
        "傳送資料到 Google Gemini",
        "使用真實辨識前，請確認：你嘅 Gemini API Key、菜單相片、目標語言、敏感原設定，以及之後要求解釋嘅菜式名稱，會由裝置直接傳送到 Google Gemini。資料保留方式視乎你使用嘅 Google 免費或付費方案。",
        "同意並繼續",
        "取消",
        "檢查專案權限",
        "檢查計費設定",
        "檢查 Model 設定",
        "再試一次",
        "辨識暫時失敗，請再試一次。",
        "菜式解釋暫時失敗，請再試一次。",
        "更新匯率失敗",
        "示範模式暫時唔支援呢個貨幣組合，請喺設定揀另一隻貨幣。",
        "暫時攞唔到最新匯率，請檢查網絡或稍後再試。",
        "最新匯率未能儲存，請稍後再試。",
        "%@（示範匯率，%@）",
        "%@（示範匯率）",
        "需要自備 Gemini API Key（BYOK）先可以使用真實功能。API Key 會儲存喺裝置 Keychain；使用真實辨識或菜式解釋時，App 會將 Key 同相關請求直接傳送到 Google Gemini，唔會經我哋嘅伺服器。",
    ]

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func catalog(named name: String) throws -> [String: Any] {
        let url = Self.repoRoot
            .appendingPathComponent("Menuscript/Resources")
            .appendingPathComponent(name)
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    private func localizedValue(
        for key: String,
        language: String,
        in strings: [String: Any]
    ) -> String? {
        let entry = strings[key] as? [String: Any]
        let localizations = entry?["localizations"] as? [String: Any]
        let localization = localizations?[language] as? [String: Any]
        let unit = localization?["stringUnit"] as? [String: Any]
        guard unit?["state"] as? String == "translated" else { return nil }
        return unit?["value"] as? String
    }

    @Test("Wave 2 user-facing keys have explicit English and Traditional Chinese")
    func criticalKeysAreLocalized() throws {
        let root = try catalog(named: "Localizable.xcstrings")
        let strings = try #require(root["strings"] as? [String: Any])

        for key in Self.criticalKeys {
            for language in ["en", "zh-Hant"] {
                let value = localizedValue(for: key, language: language, in: strings)
                #expect(value?.isEmpty == false, "\(key) is missing a translated \(language) value")
            }
        }
    }

    @Test("Every literal L10n key used by Swift source exists in the catalog")
    func literalL10nKeysExist() throws {
        let root = try catalog(named: "Localizable.xcstrings")
        let strings = try #require(root["strings"] as? [String: Any])
        let sourceRoot = Self.repoRoot.appendingPathComponent("Menuscript")
        let enumerator = try #require(
            FileManager.default.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        )
        let regex = try NSRegularExpression(
            pattern: #"L10n\.string\(\s*\"((?:\\.|[^\"\\])*)\""#
        )
        var sourceKeys = Set<String>()

        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            for match in regex.matches(in: source, range: range) {
                guard let keyRange = Range(match.range(at: 1), in: source) else { continue }
                sourceKeys.insert(String(source[keyRange]))
            }
        }

        let missing = sourceKeys.subtracting(strings.keys)
        #expect(missing.isEmpty, "Missing literal L10n keys: \(missing.sorted())")
    }

    @Test("Wave 3 safe-failure strings have exact bilingual translations")
    func wave3SafeFailureStringsAreExact() throws {
        let root = try catalog(named: "Localizable.xcstrings")
        let strings = try #require(root["strings"] as? [String: Any])

        for (key, translations) in Self.wave3ExactTranslations {
            for (language, expected) in translations {
                #expect(
                    localizedValue(for: key, language: language, in: strings) == expected,
                    "\(key) has the wrong \(language) translation"
                )
            }
        }
    }

    @Test("Camera and photo-library disclosures are exact in both languages")
    func photoPurposeStringsAreExact() throws {
        let root = try catalog(named: "InfoPlist.xcstrings")
        let strings = try #require(root["strings"] as? [String: Any])
        let expected = [
            "NSCameraUsageDescription": [
                "en": "Use the camera to photograph menus for recognition and translation. In Live Mode, photographed menu images are sent to Google Gemini; Demo Mode processes them only on this device.",
                "zh-Hant": "用相機拍攝菜單相作辨識翻譯。真實模式會將所拍菜單相傳送至 Google Gemini；示範模式只會喺裝置本機處理。",
            ],
            "NSPhotoLibraryUsageDescription": [
                "en": "Select menu photos for recognition and translation. In Live Mode, selected menu images are sent to Google Gemini; Demo Mode processes them only on this device.",
                "zh-Hant": "選取菜單相作辨識翻譯。真實模式會將所選菜單相傳送至 Google Gemini；示範模式只會喺裝置本機處理。",
            ],
        ]

        for (key, translations) in expected {
            for (language, value) in translations {
                #expect(localizedValue(for: key, language: language, in: strings) == value)
            }
        }

        let project = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        #expect(project.contains(expected["NSCameraUsageDescription"]?["zh-Hant"] ?? "missing"))
        #expect(project.contains(expected["NSPhotoLibraryUsageDescription"]?["zh-Hant"] ?? "missing"))
    }
}
