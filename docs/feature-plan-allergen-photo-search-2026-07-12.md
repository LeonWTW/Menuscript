# Feature Plan：食物敏感原警示 + 菜式相片搜尋（2026-07-12）

## Context

兩個提升用家體驗嘅功能，屬 Sprint 2「carefully scoped extension」範圍：

1. **食物敏感原警示 + 每道菜簡短解釋**——Settings 加敏感原 filter（preset + 自訂），翻譯時 AI 為每道菜生成一句目標語言短解釋，並標示大機會含用家敏感原嘅菜式（warning icon + 「同餐廳確認」提示）。
2. **一鍵相片搜尋**——每道菜加 button，用原文菜名開 Google Images，等用家知道道菜大概咩樣。

### 已同 Leon 拍板嘅決策
- Photo search 用 **in-app SFSafariViewController**（唔離開 app）
- Preset 敏感原 = **US Big 9 + 麩質 + 軟體動物（11 項）** + 自由文字自訂
- 菜式短解釋**卡片常設顯示**；現有 ExplainSheet 保留做深入解釋（兩者用唔同欄位，互不干擾）

---

## 實作步驟（分 chunk，每個 chunk 可獨立 build/test）

### Chunk 0 — 保護現場
- 而家 working tree 有未 commit 嘅 bug-scan 修改（十幾個檔）——先 commit 成獨立 commit，再開新 feature 工作。

### Chunk 1 — Allergen model + Settings（唔掂 provider）
1. **NEW `Menuscript/Models/Allergen.swift`**
   - `enum Allergen: String, CaseIterable, Identifiable, Sendable`，11 個 case（rawValue 做儲存 slug）：`peanut, treeNuts, milk, egg, fish, crustacean, soy, wheat, sesame, gluten, molluscs`
   - `promptLabel: String`——俾 AI 睇嘅穩定英文名（如 "crustacean shellfish"）
   - `displayName: String`——經 `L10n.string(<zh-Hant literal>)`（跟 `AppLanguage`/`L10n` 現有 pattern）
   - `static func parse(presets: String, custom: String) -> [String]`——slug 拆解→promptLabel + 自訂文字按 `[,、\n]` split、trim、去空、case-insensitive dedupe、cap 總長 ~200 chars（純函數，可測）
   - `static func displayLabel(for hit: String) -> String`——AI 回傳字串 case-insensitive 對返 promptLabel→localized 名，對唔中就 verbatim 顯示
2. **`Menuscript/App/SettingsKeys.swift`**：加 `allergenPresets`（comma-joined slugs）、`allergenCustom`（raw 自由文字）兩個 key——跟現有 flat `@AppStorage` string 慣例，唔用 JSON。
3. **`Menuscript/Features/Settings/SettingsView.swift`**：「翻譯設定」之後加新 Section「食物敏感」：
   - `ForEach(Allergen.allCases)` 出 11 個 `Toggle`（Binding helper 對 comma-joined string insert/remove slug）
   - `TextField` 自訂敏感原（placeholder 註明逗號分隔）
   - Footer disclaimer：「AI 翻譯新菜單時會標示可能含有呢啲食材嘅菜式。判斷僅供參考，落單前請務必同餐廳確認。只影響之後新辨識嘅菜單。」

### Chunk 2 — Extraction contract（protocol + Gemini + Mock）
4. **`Menuscript/Services/MenuVisionProvider.swift`**
   - `ExtractedMenu.Item` 加 `var summary: String? = nil`、`var possibleAllergens: [String] = []`（有 default，現有 construction 唔郁）
   - Protocol 改：`extractMenu(images:targetLanguage:allergens: [String])`
5. **`Menuscript/Services/GeminiProvider.swift`**
   - `extractMenu` / `buildExtractRequest` 加 `allergens: [String] = []`；⚠️ **corrective retry（`GeminiProvider.swift:36-42`）嗰次 rebuild 一定要帶埋 allergens**
   - `extractPrompt(targetLanguage:allergens:)` 加兩條 rule：
     - Rule 11（常設）`summary`：一句 ≤~20 字目標語言短解釋，講道菜係咩嚟，唔好重覆譯名，每道菜都要有
     - Rule 12（allergens 非空先加）：「traveller avoids: [list]。`possibleAllergens` = 該 list 入面按典型食譜大機會存在嘅子集；有可能就標（err toward flagging）；只准用 list 入面嘅字串原樣輸出，唔准自創；冇就空 array。Advisory only。」
   - `extractResponseSchema(includeAllergens:)`：`summary` STRING 加入 `properties` + `required` + `propertyOrdering`（放 translated 後面）；`possibleAllergens` ARRAY<STRING> 只喺 includeAllergens 時加入（同樣入 required——強制明確空 array，唔會語意曖昧）
   - `WireItem` 加 `summary: String?`、`possibleAllergens: [String]?`（decode 容錯保持雙向兼容）；`parseExtractResponse` map 落 `Item`（trim、去空）
6. **`Menuscript/Services/MockVisionProvider.swift`**：改 signature；10 道菜全部加 summary；假設 Big 9 全開咁 hardcode `possibleAllergens`：唐揚げ→[wheat, soy, egg]、焼き鳥盛り合わせ→[soy]、豚汁→[soy]、生ビール(小)→[gluten, wheat]，其餘空——離線都 demo 到 icon + alert + summary。

### Chunk 3 — Persist + wire
7. **`Menuscript/Models/MenuItem.swift`**：加 `var summary: String?`、`var possibleAllergens: [String] = []`（init 加 defaulted params）。同現有 `explanation`（ExplainSheet 深入解釋 cache）分開，唔掂佢邏輯。
8. **`Menuscript/Models/MenuSession.swift`**：加 `var allergenProfile: [String] = []`（init defaulted）——snapshot 辨識當時用咗嘅敏感原清單（跟 fxRate/homeCurrency snapshot pattern）。
9. **`Menuscript/Features/Capture/CaptureViewModel.swift`** `recognize()`：讀兩個新 key（經 `SettingsKeys.nonEmptyString` 慣例唔適用 boolean/自由文字——直接讀 string）→ `Allergen.parse` → 傳入 `extractMenu`；map `summary`/`possibleAllergens` 落 `MenuItem`；`allergenProfile` 落 session。

### Chunk 4 — Photo search plumbing（同 Chunk 2-3 並行冇依賴）
10. **NEW `Menuscript/Features/Menu/PhotoSearch.swift`**：`enum PhotoSearch { static func imagesURL(query: String) -> URL? }`——`URLComponents`（host `www.google.com`、path `/search`、queryItems `q` + `tbm=isch`）；trim 後空 → nil。CJK percent-encoding 由 queryItems 處理。
11. **NEW `Menuscript/Features/Menu/Components/SafariView.swift`**：`UIViewControllerRepresentable` 包 `SFSafariViewController`（`import SafariServices`，~15 行）。

### Chunk 5 — Card + Menu UI
12. **`Menuscript/Features/Menu/MenuItemCard.swift`**
    - `nameBlock` 入面 `originalName` 下面加 summary `Text`（用 Theme secondary token、`lineLimit(2)`；nil/空就唔 render）
    - lowConfidence 三角後面加敏感原 icon `Image(systemName: "allergens")`（`Color.mtWarning` 或紅）做 Button → `@State showAllergenAlert` → `.alert` 列 `displayLabel` + 「AI 推測僅供參考，落單前請同餐廳確認」
    - Header 加 photo search Button（SF Symbol `photo`，accent 色）喺 explainButton 隔離，call 新 closure `onPhotoSearch: (MenuItem) -> Void`
    - `accessibilitySummary` 加「，可能含有 X、Y，請與餐廳確認」；card 加 `accessibilityAction` 開 alert（nameBlock 係 `children: .ignore`，icon 對 VoiceOver 係 hidden——資訊行 label 條路）
    - 更新 file 尾三個 preview
13. **`Menuscript/Features/Menu/MenuView.swift`**
    - 傳 `onPhotoSearch`；`@State photoSearchItem: MenuItem?`；`.sheet(item: $photoSearchItem)` → `SafariView(url: PhotoSearch.imagesURL(query: originalName 空就 fallback translatedName))`（跟現有 `explainItem` sheet pattern）
    - List 底加 footnote（`session.allergenProfile` 非空先出）：「敏感原警示根據辨識當時嘅設定，僅供參考」——處理「改咗設定舊 session 過時」+「冇 icon ≠ 安全」

### Chunk 6 — Project + l10n + docs
14. `xcodegen generate`（4 個新檔入 project；project.yml 係 folder globbing，唔使逐檔登記）
15. **`Menuscript/Resources/Localizable.xcstrings`**：所有新 zh-Hant literal key 補 `en` 值（11 個敏感原名、section header/footer、alert、footnote、a11y label、自訂欄 placeholder）——唔補英文 UI 會直接現 zh-Hant key
16. Docs（Sprint 2 課程證據）：`README.md`（expected behavior + 新設定）、`docs/manual-verification.md`（新 cases + observed results）、`docs/ai-implementation-review.md`、`docs/architecture.md`（新檔案）

---

## Tests

| 檔案 | 內容 |
|---|---|
| NEW `AllergenTests.swift`（swift-testing） | `parse`：dedupe/trim/split 自訂/全空→[]/cap 長度；`displayLabel`：slug 對中→localized、對唔中→verbatim |
| NEW `PhotoSearchTests.swift` | host/path、`tbm=isch`、`q` 存在、CJK percent-encoding（宮保雞丁）、空/whitespace → nil |
| `GeminiRequestTests.swift` | allergen 條款 iff 非空；summary rule 常設；schema 有 `summary`（required）；`possibleAllergens` 只喺有 allergens 時存在；corrective-suffix build 保留 allergens |
| `ExtractedMenuDecodeTests.swift` | 帶 summary+possibleAllergens fixture 解到；舊 fixture（冇新欄位）照解到 |
| `CaptureViewModelTests.swift` | Failing/Slow doubles 改 signature；mock 數據 summary/possibleAllergens 落到 `MenuItem`；`allergenProfile` snapshot 落 session |

---

## 要留意（風險排序）

1. **安全定位（最大 product 風險）**：食物敏感係健康問題，LLM 判斷唔可靠——成個 UI 語言只可以係「提示 + 請確認」，永遠唔顯示「安全/無敏感原」狀態；disclaimer 三處落齊（Settings footer / alert / session footnote）。
2. **Prompt↔UI 對字合約**：AI 回傳嘅 allergen 字串要 verbatim 等於我哋送入去嘅（prompt 明文要求 + UI case-insensitive 對返；對唔中 fallback verbatim 顯示，唔會跌 warning）。
3. **Corrective retry 帶 allergens**：retry 用同一個 builder rebuild，漏咗 param 會靜靜地變咗「冇敏感原」嗰版 schema。
4. **SwiftData lightweight migration**：三個新欄位全部 optional/defaulted；升級後開舊 session 要驗證（舊 record 冇 warning、冇 crash）。
5. **Token/latency**：summary 令 output 大 ~30-50%，50+ 道菜嘅菜單會慢幾秒——Leon 已接受呢個 trade-off。
6. **XcodeGen**：新檔要 `xcodegen generate` 先入 project，唔係 build 唔到。
7. **自訂敏感原係 user 文字直入 prompt**：cap ~200 chars + trim，防止爆 prompt。
8. **xcstrings**：新 key 唔補 en 值，英文 UI 會現中文 key。
9. iPhone portrait only（`TARGETED_DEVICE_FAMILY: 1`）——唔使處理 iPad presentation。

---

## 驗收

1. **自動化**：`xcodegen generate && xcodebuild test -scheme Menuscript -destination 'platform=iOS Simulator,name=iPhone 16'` 全綠（貼 exit code + 尾段做證據）。
2. **Mock 模式 manual script**：
   - Settings 見 11 個 toggle + 自訂欄；開「小麥、大豆」、自訂輸入「香菜」
   - Scan（mock）→ 唐揚げ/豚汁 有 warning icon；每張卡有一句 summary；撳 icon → alert 列敏感原 + 確認提示
   - 撳 photo button → in-app Safari 開 Google Images（原文菜名、URL 有 `tbm=isch`）；撳 Done 返菜單
   - 熄晒敏感原 → 新 scan 嘅 request 冇 allergen 條款（用 GeminiRequestTests 證，mock 冇網絡層）
3. **真 Gemini smoke test**（有 API key 時）：真菜單相 → summary 係目標語言；含花生菜式（宮保雞丁類）→ 花生警告出現。
4. **Migration**:升級前已存在嘅 session 開得返、正常顯示、冇 warning icon。
5. **A11y/UI**：VoiceOver 讀出敏感原警告；dark mode + accessibility text size 排版唔爆。
6. **課程文檔**：README / manual-verification / ai-implementation-review 更新齊，同實作一致。

**規模估算**：新檔 4 個（Allergen、PhotoSearch、SafariView、AllergenTests+PhotoSearchTests）＋ 改 ~10 個現有檔；一個 session 完成到。
