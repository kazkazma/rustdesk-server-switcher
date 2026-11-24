# RustDesk Server Switcher

在同一台 Windows 電腦上使用多組 RustDesk 伺服器時，用這個工具取代手動重填 ID Server、Relay Server、API Server 和 Key。每組設定可建立一個桌面捷徑。工具切換的是同一個 RustDesk 安裝的目前設定，不會同時維持多組設定，也不需要重新安裝或手動重啟服務。

## 需求與設定

- Windows PowerShell 5.1，以及有 `RustDesk` 服務的已安裝版 RustDesk；不支援免安裝版。
- 套用設定需要系統管理員權限，腳本會跳出 UAC。列出設定、預覽及建立捷徑不需要提升權限。

第一次使用時，在專案目錄複製範本。已有 `profiles.json` 就直接編輯，不要覆蓋。

```powershell
Copy-Item .\profiles.example.json .\profiles.json
```

在 `profiles.json` 以 profile 名稱為最外層的鍵（例如 `office`），填入 `idServer`、`relayServer`、`apiServer`、`key` 四個欄位。`idServer` 必須有值；其餘欄位不用時填 `""`，套用時會清除該自訂選項。範本只含示例網域，請改成自己的設定再套用。

## 切換與桌面捷徑

在 PowerShell 內執行（下例假設已建立 `office` profile）：

```powershell
.\Switch-RustDeskServer.ps1 -List
.\Switch-RustDeskServer.ps1 -Name office -DryRun
.\Switch-RustDeskServer.ps1 -Name office
.\Switch-RustDeskServer.ps1 -CreateShortcuts
```

`-CreateShortcuts` 會在目前使用者的桌面為每組設定建立 `RustDesk - <profile>.lnk`。建立捷徑不會切換設定；雙擊捷徑並同意 UAC 後才會套用。新增或改名 profile 後重新執行即可建立對應捷徑；已刪除或改名的舊捷徑需手動移除。捷徑記錄腳本與設定檔的絕對路徑，搬移檔案後要重建。

可用 `-ShortcutDir` 指定捷徑輸出目錄、`-ProfilesFile` 指定另一份設定檔，或在無法自動找到 RustDesk 時用 `-RustDeskExe` 指定程式路徑。

套用前會把原本的四個選項寫到 `backups/pre-<profile>-<時間>.json`；套用後會讀回選項比對。RustDesk 服務會重新連線到 ID Server，不需手動重啟服務。

## 私密設定

本機的 `profiles.json`、備份和產生的捷徑不會納入 Git。自訂名稱的設定檔請放在儲存庫外。預覽與套用輸出可能包含伺服器位址和完整 Key；分享畫面或日誌前請遮蔽。
