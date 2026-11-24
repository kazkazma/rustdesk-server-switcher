# 開發慣例

- `Switch-RustDeskServer.ps1` 是唯一的 CLI 入口。捷徑產生邏輯放在同檔的內部函式，透過 `-CreateShortcuts` 呼叫。
- 維持 Windows PowerShell 5.1 相容性。含中文字的 PowerShell 腳本保留 UTF-8 BOM；呼叫 RustDesk CLI 時，空字串必須作為引數傳入，才能清除選項。
- `-List`、`-DryRun` 和單獨執行 `-CreateShortcuts` 都不得修改 RustDesk 設定或要求提權。只有套用時才提權；保留套用前備份及套用後讀回比對。
- 只提交使用示例網域、無實際 Key 的 `profiles.example.json`。不要提交 `profiles.json`、其他本機 profile、`backups/`、產生的 `.lnk`，或含真實位址及 Key 的日誌。
- 驗證捷徑時，用範本或無機密的暫存 profile 搭配 `-ShortcutDir` 輸出到暫存目錄，再用捷徑的目標和引數加上 `-DryRun` 驗證；不要套用到目前的 RustDesk 安裝。

## Git 提交慣例

- 採用 Conventional Commits，標題格式為 `<type>(<scope>): <中文摘要>`；`scope` 可省略。
- 依主要變更選擇類型：`feat` 新功能、`fix` 修正錯誤、`docs` 文件、`refactor` 不改行為的重構、`chore` 維護。
- 需要補充時，標題與內文之間留一個空行，內文以中文說明變更原因與影響。
- 範例：`docs: 補充 Git 提交慣例`。
