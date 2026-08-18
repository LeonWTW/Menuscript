# Sprint 5 Workflow Changelog（2026-08-16 / 17）

Peer Review Activity 2 嘅 multi-agent workflow 改動總結。全部改動喺 branch `sprint-5-professional-completion`（base `a41caf6`），**未 commit**。

---

## 1. Workflow 執行摘要

| 項目 | 值 |
|---|---|
| Run ID | `wf_ebd71f31-8cc` |
| Phase | Design → Execute → Verify |
| Agent 總數 | 16（最終 resume：16/16 成功、0 error） |
| 評分 | 初評 **16.5/20** → 修正後複評 **18/20** |

### Agent 編制

| Phase | Agent | Model / effort |
|---|---|---|
| Design | `design:phase0-unblock`、`phase1-retention`、`phase2-test-reorg`、`phase3-ax5-and-docs`、`phase5-reflection` | fable / max |
| Design | `design:critic`（對抗式批評，逐個 design 挑漏） | fable / max |
| Execute | `exec:phase0-baseline` | opus / xhigh |
| Execute | `exec:phase1-retention` | opus / max |
| Execute | `exec:phase2-test-reorg` | sonnet / xhigh |
| Execute | `exec:phase3a-dynamic-type`、`exec:phase3b-docs` | opus / xhigh |
| Execute | `exec:phase4-reflection` | opus / max |
| Verify | `verify:fact-check` | opus / xhigh |
| Verify | `verify:strict-grader`、`verify:corrective-edit`、`verify:regrade` | opus / max |

> `verify:strict-grader` 同 `verify:regrade` 原本設 `fable`，兩次 resume 都因為 **Fable 5 usage credit 未 reset** 而 fail（同 phase 嘅 opus agent 同時成功，可證唔關 prompt 事）。改咗做 `opus` 之後一次過綠。

---

## 2. 新增 production code

| 檔案 | 內容 |
|---|---|
| `Menuscript/Services/PhotoRetentionPolicy.swift` | `enum PhotoRetentionPolicy: String`（`30d` / `90d` / `forever`）、`retentionWindow`（固定 86,400 秒一日）、`resolve(from:)` 讀 `UserDefaults` 並 fallback 30 日 |
| `Menuscript/Services/PhotoRetentionService.swift` | `@MainActor struct`，`pruneExpiredPhotos(policy:now:) throws -> Int`；注入式 `SaveAction` / `FetchAllAction`；typed `PhotoRetentionError.fetchFailed` / `.saveFailed` |

**Prune 嘅安全界線（設計核心）**

- 只寫兩個 field：`session.photos = []`、`session.photosPrunedAt = now`。永不刪 session、永不改 `billSnapshotData`。
- 資格：`lifecycleStatus == .completed` **且** `billSnapshotData != nil` **且** 年齡 ≥ window **且** `photosPrunedAt == nil` **且** `!photos.isEmpty`。draft、舊版本 session、冇 snapshot 嘅 completed 全部受保護——嗰啲 case 相片係唯一紀錄。
- 所有寫入喺 `ModelContext(context.container)` + `autosaveEnabled = false`；save 失敗就整個 context 丟棄＝rollback，UI 個 context 唔可能 commit 半截。
- `photosPrunedAt == nil` 令佢 idempotent。

## 3. 修改 production code

| 檔案 | 改動 |
|---|---|
| `Menuscript/Models/MenuSession.swift` | +6：`var photosPrunedAt: Date?`（optional，保 lightweight migration）＋ init 參數 |
| `Menuscript/App/SettingsKeys.swift` | +1：`settings.photoRetention` key |
| `Menuscript/App/RootView.swift` | +14：`pruneExpiredPhotos()` 私有 method，喺 `.task`（啟動）同 finalize 之後各叫一次；失敗經現有 `persistenceErrorMessage` alert 出，唔靜靜吞 |
| `Menuscript/Features/Settings/SettingsView.swift` | +26：「菜單相片保留」Section ＋ Picker ＋ `retentionLabel(for:)`；footer 明講已清理相片無法還原 |
| `Menuscript/Features/Menu/MenuView.swift` | +16：`else if session.photosPrunedAt != nil` 分支，toolbar 換成 `photo.badge.exclamationmark` ＋ 說明 alert，令「已清理」同「從來冇相」分得開 |

## 4. Localization

`Menuscript/Resources/Localizable.xcstrings`：**194 → 214 keys（+20）**，全部 `en` / `zh-Hant` 兩語 `state: "translated"`。

- **10 條** = Sprint 5 新 UI 文案（`保留期限`、`30 日`、`90 日`、`永久保留`、`菜單相片保留`、`菜單相片已自動清理`、兩條 error message、兩條說明文）。
- **10 條** = Phase 0 補返嘅**歷史欠債**：`%@ 味菜 · %@`、`載入緊相片…（%@/%@）`、`%@ 人`、`第 %@ 頁嘅相片資料已損壞`、`%@ ×%@`、`%@%%`、`自訂 %@%%` 等——本身係 Xcode 抽咗但從未翻譯嘅 SwiftUI `Text` 插值，即係**英文 build 會顯示中文**。唔補呢批，`LocalizationTests` 一定紅，成個 workflow 入唔到 Phase 1。

補譯用逐條 `Edit` 做（唔用 `json.dump`，否則會毀 Xcode 嘅 catalog 格式），並守 printf placeholder 位置／型別契約。

## 5. Tests

**目錄鏡像化（R2）**：31 個檔用 `git mv` 搬入 `MenuscriptTests/{App,Features/{Bill,Capture,Menu},Models,Resources,Services,Support}/`。`project.yml` 個 `sources` 係遞迴，**唔使改**。

**踩中並修好嘅陷阱**：4 個檔（`LocalizationTests`、`PrivacyLocalizationContractTests`、`PrivacyManifestTests`、`SessionStoreTests`）本身靠 `#filePath` 剝**剛好兩層**搵 repo root，搬深一層會靜靜咁指去 `MenuscriptTests/`。新增 `MenuscriptTests/Support/RepoPaths.swift`，改為向上行搵 `project.yml` marker，搵唔到就 `preconditionFailure` 大聲死。呢個改法對將來再搬檔免疫。

**新測試**：`PhotoRetentionPolicyTests.swift`（5 `@Test`）、`PhotoRetentionServiceTests.swift`（11 `@Test`）＝ **16 條**。當中包含「prune 後用**全新** `ModelContext` 重新 fetch，assert `billSnapshotData` byte-identical、每個 line item 同 metadata 不變」——即係將安全論證測試化。

**數量**：220 → **236** 條 static 宣告（195 `@Test` + 41 XCTest `func test`）。搬檔前後靜態數同樣係 236，係「冇靜靜漏檔」嘅憑據。記錄嘅 run：`Test run with 195 tests in 35 suites passed`、`Executed 41 tests, with 0 failures`、`** TEST SUCCEEDED **`。

## 6. Docs

| 檔案 | 改動 |
|---|---|
| `docs/architecture.md` | +15/−2：新增 *Architecture Evolution: Sprint 4 to Sprint 5 — Photo Retention* 一節（政策、點解 30 日、刪除界線、失敗模式、migration）；原本 Sprint 3 嗰條 open question 改寫成 *Partially resolved in Sprint 5*，並列明仲未解決嘅部分 |
| `docs/manual-verification.md` | +161：兩節新驗證紀錄——(a) Dynamic Type AX3/AX5 × 5 個畫面，pass/fail 準則事前寫死，記錄 4 個 finding（D1–D4，其中 D2 係唯一 clipping：History 個 camera FAB 蓋住最後一行 status text，`RootView.swift:60`）同 5 項 harness 限制；(b) Photo retention pruning 端到端驗證：session 老化 31 日、相片 column 1113 → 219 bytes、bill snapshot `shasum` 前後一致、draft 不受影響 |
| `docs/ai-implementation-review.md` | +61：R1–R5 逐項 disposition 表、AI 協作方式、拒絕 R3 嘅證據、押後 R5 嘅理由同重啟條件、AI 之後嘅自行覆核 |
| `README.md` | +2/−1：History 段落 ＋ Privacy & Data Handling 補保留行為（本機刪除、不可還原） |
| `docs/sprint_5/peer-review-reflection.md` | **新檔（交件本體）**，英文，5 節對應 5 條問題 |

## 7. Verify phase 揪出嘅錯

`verify:fact-check` 逐條核 reflection 入面 **45 個事實聲稱**，得出 **4 REFUTED + 1 UNVERIFIABLE**，全部由 `verify:corrective-edit` 修正：

1. 「nothing ever removed them」誇大——`delete` / `deleteAll` 喺 `d5794d6` 已經存在。
2. 錯誤歸因 reviewer 嘅理據（佢只係將 retention 同 XCUITest 對比排序）。
3. 講錯畫面——「已清理」嘅區分係喺 `MenuView`（session detail），唔係 History 列表。
4. XCUITest 入 CI 需要 signing 嘅講法錯——`CODE_SIGN_STYLE: Automatic`，simulator test 唔使 signing identity。

---

## 8. 唔屬於今次 workflow 嘅 working-tree 改動

以下係之前 doc-comment 那輪（`622049e`）嘅手尾，唔好當成 Sprint 5 產物：`Info.plist`、`Menuscript/Resources/PrivacyInfo.xcprivacy`、`project.yml`、`Menuscript/Resources/InfoPlist.xcstrings`（全部只加註解 header）。

untracked 但同今次無關：`.agents/`、`.github/`、`cluade.md`、`concept-check-site/`、`docs/Prototype_Progress_todo.md`、`docs/canvas-submission-drafts.md`、`docs/commercial-roadmap.md`、`docs/sprint2_todo.md`、兩個 `docs/*.html`。

---

## 9. 仲未收嘅尾

- **字數超標**：`peer-review-reflection.md` 現時 **1472 prose words（約 2.6 頁）**，brief 寫「approximately one to two pages」，複評 grader 亦點名要 ≤1,200。要落到兩頁就要剷「Why a window, not the alternatives」、pruning 驗證數據、或 XCUITest 成本估算其中兩項——三者分別撐住 rubric 第 2、3 格。
- **18/20 係打喺 1743 字嗰版**；之後嘅壓縮同修正未經重評。
- **全部未 commit**：14 個 modified、31 個 staged rename、5 個新 Swift/MD 檔。
