<#
.SYNOPSIS
    切換「已安裝版」RustDesk 的 ID/Relay Server 設定（一鍵、多組 profile）。

.DESCRIPTION
    RustDesk 本身沒有多組伺服器設定可供切換（1.4.x 只有單一組
    custom-rendezvous-server / relay-server / api-server / key）。
    本腳本以官方 CLI 介面 `rustdesk.exe --option <key> <value>` 透過 IPC 把整組設定
    送給 RustDesk 服務；服務端 (src/ipc.rs: CheckIfRestart) 會自動重啟
    rendezvous 連線，因此切換後不需重啟服務或重新安裝。
    - 空字串 "" 代表清除該選項（還原預設，例如 relay-server 留空表示不使用自訂 relay）。
    - `--option` 要求 installed + root，所以套用時必須是系統管理員（會自動提權跳 UAC）。

.PARAMETER Name
    要套用的 profile 名稱，需存在於 profiles.json。

.PARAMETER List
    列出 profiles.json 內所有 profile（不需管理員）。

.PARAMETER DryRun
    只顯示即將套用的四個選項，不做任何修改、也不提權。

.PARAMETER CreateShortcuts
    為每個 profile 在桌面建立一鍵切換捷徑（捷徑執行時會自行提權）。

.PARAMETER ShortcutDir
    捷徑輸出目錄，預設為目前使用者的桌面。

.PARAMETER RustDeskExe
    指定 rustdesk.exe 路徑，預設自動偵測（登錄檔 InstallLocation → Program Files）。

.PARAMETER ProfilesFile
    指定 profiles.json 路徑，預設為本腳本同目錄下的 profiles.json。

.EXAMPLE
    .\Switch-RustDeskServer.ps1 -List

.EXAMPLE
    .\Switch-RustDeskServer.ps1 -Name example-a

.EXAMPLE
    .\Switch-RustDeskServer.ps1 -Name example-a -DryRun

.EXAMPLE
    .\Switch-RustDeskServer.ps1 -CreateShortcuts
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Name,
    [switch]$List,
    [switch]$DryRun,
    [switch]$CreateShortcuts,
    [string]$ShortcutDir,
    [string]$RustDeskExe,
    [string]$ProfilesFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# RustDesk2.toml [options] 內的四個鍵；順序即套用順序
$OPTION_MAP = [ordered]@{
    idServer    = 'custom-rendezvous-server'
    relayServer = 'relay-server'
    apiServer   = 'api-server'
    key         = 'key'
}

$Script:ScriptPath = $MyInvocation.MyCommand.Path
$Script:ScriptDir  = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $Script:ScriptPath }
if (-not $ProfilesFile) { $ProfilesFile = Join-Path $Script:ScriptDir 'profiles.json' }

function Quote-Arg([string]$s) { return '"' + ($s -replace '"', '\"') + '"' }

function Test-AdminState {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-RustDeskPath {
    if ($RustDeskExe) {
        if (-not (Test-Path -LiteralPath $RustDeskExe)) { throw "找不到 rustdesk.exe：$RustDeskExe" }
        return (Resolve-Path -LiteralPath $RustDeskExe).Path
    }
    $uninstallKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\RustDesk',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\RustDesk'
    )
    foreach ($k in $uninstallKeys) {
        try {
            $loc = (Get-ItemProperty -LiteralPath $k -ErrorAction Stop).InstallLocation
            if ($loc) {
                $p = Join-Path $loc 'rustdesk.exe'
                if (Test-Path -LiteralPath $p) { return $p }
            }
        } catch { }
    }
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:ProgramFiles) { $candidates.Add((Join-Path $env:ProgramFiles 'RustDesk\rustdesk.exe')) }
    $pf86 = [Environment]::GetFolderPath('ProgramFilesX86')
    if ($pf86) { $candidates.Add((Join-Path $pf86 'RustDesk\rustdesk.exe')) }
    foreach ($p in $candidates) { if (Test-Path -LiteralPath $p) { return $p } }
    throw '找不到已安裝的 rustdesk.exe，請以 -RustDeskExe 指定路徑。'
}

function Get-Profiles {
    if (-not (Test-Path -LiteralPath $ProfilesFile)) { throw "找不到設定檔：$ProfilesFile" }
    $raw = Get-Content -LiteralPath $ProfilesFile -Raw -Encoding UTF8
    if (-not $raw -or -not $raw.Trim()) { throw "設定檔是空的：$ProfilesFile" }
    $obj = $raw | ConvertFrom-Json
    $table = @{}
    foreach ($prop in $obj.PSObject.Properties) {
        $vals = @{}
        foreach ($field in $OPTION_MAP.Keys) {
            $v = $prop.Value.$field
            if ($null -eq $v) { $v = '' }
            $vals[$field] = [string]$v
        }
        if (-not $vals['idServer']) { throw "profile '$($prop.Name)' 缺少 idServer。" }
        $table[$prop.Name] = $vals
    }
    if ($table.Count -eq 0) { throw "$ProfilesFile 內沒有任何 profile。" }
    return $table
}

function Invoke-RustDeskCli {
    # rustdesk.exe --option <key> [value]
    # 必須自行組命令列：Windows PowerShell 5.1 會把「空字串引數」整個丟掉，
    # 導致清空選項（--option relay-server ""）退化成讀取選項。
    param([string]$Exe, [string]$Key, [string]$Value, [switch]$WithValue)
    if ($Key -match '"' -or ($WithValue -and $Value -match '"')) {
        throw "選項名稱或值不可包含雙引號：key='$Key' value='$Value'"
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = if ($WithValue) { '--option "{0}" "{1}"' -f $Key, $Value } else { '--option "{0}"' -f $Key }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    return (($stdout + $stderr).Trim())
}

function Get-CurrentOption([string]$exe, [string]$key) {
    return (Invoke-RustDeskCli -Exe $exe -Key $key)
}

function Set-RustDeskOption([string]$exe, [string]$key, [string]$value) {
    # 空字串是有效參數：服務端 ipc::set_option 會 remove 該鍵（還原預設）
    return (Invoke-RustDeskCli -Exe $exe -Key $key -Value $value -WithValue)
}

function Show-Usage([hashtable]$profiles) {
    Write-Output ''
    Write-Output '用法：'
    Write-Output '  Switch-RustDeskServer.ps1 -List                    # 列出所有 profile'
    Write-Output '  Switch-RustDeskServer.ps1 -Name <profile>          # 套用（會跳 UAC 提權）'
    Write-Output '  Switch-RustDeskServer.ps1 -Name <profile> -DryRun  # 只預覽'
    Write-Output '  Switch-RustDeskServer.ps1 -CreateShortcuts         # 桌面建立一鍵捷徑'
    Write-Output ''
    Write-Output ("可用 profile：{0}" -f (($profiles.Keys | Sort-Object) -join ', '))
    Write-Output ("設定檔：{0}" -f $ProfilesFile)
}

function New-RustDeskShortcuts {
    param([string]$OutputDir)

    $profiles = Get-Profiles
    $exe = Resolve-RustDeskPath
    $shortcutProfilesFile = (Resolve-Path -LiteralPath $ProfilesFile).Path
    if (-not $OutputDir) { $OutputDir = [Environment]::GetFolderPath('Desktop') }
    if (-not (Test-Path -LiteralPath $OutputDir)) { New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null }
    $OutputDir = (Resolve-Path -LiteralPath $OutputDir).Path
    $shell = New-Object -ComObject WScript.Shell
    foreach ($n in ($profiles.Keys | Sort-Object)) {
        $lnkPath = Join-Path $OutputDir ("RustDesk - {0}.lnk" -f $n)
        $lnk = $shell.CreateShortcut($lnkPath)
        $lnk.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -File $(Quote-Arg $Script:ScriptPath) -Name $(Quote-Arg $n) -ProfilesFile $(Quote-Arg $shortcutProfilesFile)"
        if ($RustDeskExe) { $lnk.Arguments += " -RustDeskExe $(Quote-Arg $exe)" }
        $lnk.WorkingDirectory = $Script:ScriptDir
        $lnk.IconLocation = "$exe,0"
        $lnk.Description = "把 RustDesk 的 ID/Relay Server 切換到 $n"
        $lnk.Save()
        Write-Output "已建立捷徑：$lnkPath"
    }
}

# ── 列出 ────────────────────────────────────────────────────────────────
if ($List) {
    $profiles = Get-Profiles
    $rows = foreach ($n in ($profiles.Keys | Sort-Object)) {
        $p = $profiles[$n]
        $masked = if ($p['key'].Length -gt 8) { $p['key'].Substring(0, 8) + '…' } else { $p['key'] }
        [pscustomobject]@{
            Profile       = $n
            'ID Server'   = $p['idServer']
            'Relay Server'= $p['relayServer']
            'API Server'  = $p['apiServer']
            Key           = $masked
        }
    }
    $rows | Format-Table -AutoSize | Out-String | Write-Output
    Show-Usage $profiles
    return
}

# ── 建立捷徑 ────────────────────────────────────────────────────────────
if ($CreateShortcuts) {
    New-RustDeskShortcuts -OutputDir $ShortcutDir
    if (-not $Name) { return }
}

if (-not $Name) {
    $profiles = Get-Profiles
    Show-Usage $profiles
    return
}

# ── 套用 ────────────────────────────────────────────────────────────────
$profiles = Get-Profiles
if (-not $profiles.ContainsKey($Name)) {
    throw "profiles.json 內沒有 '$Name'（可用：$((($profiles.Keys | Sort-Object) -join ', '))）"
}
$target = $profiles[$Name]
$exe = Resolve-RustDeskPath

if ($DryRun) {
    Write-Output 'DRY-RUN：不會修改任何設定'
    Write-Output ("rustdesk.exe : {0}" -f $exe)
    foreach ($field in $OPTION_MAP.Keys) {
        Write-Output ("  {0,-24} <- '{1}'" -f $OPTION_MAP[$field], $target[$field])
    }
    return
}

if (-not (Get-Service -Name RustDesk -ErrorAction SilentlyContinue)) {
    throw '找不到 RustDesk 服務；本腳本支援已安裝模式（有 RustDesk 服務）的環境。'
}

if (-not (Test-AdminState)) {
    Write-Host '需要系統管理員權限（RustDesk --option 要求 installed + root），正在提權…'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Quote-Arg $Script:ScriptPath),
                 '-Name', (Quote-Arg $Name))
    if ($ProfilesFile) { $argList += @('-ProfilesFile', (Quote-Arg $ProfilesFile)) }
    if ($RustDeskExe) { $argList += @('-RustDeskExe', (Quote-Arg $RustDeskExe)) }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
    return
}

# 備份切換前的四個現值
$backupDir = Join-Path $Script:ScriptDir 'backups'
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
$before = [ordered]@{}
foreach ($field in $OPTION_MAP.Keys) { $before[$field] = Get-CurrentOption $exe $OPTION_MAP[$field] }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$safeName = ($Name -replace '[^\w\-\.]', '_')
$backupFile = Join-Path $backupDir ("pre-{0}-{1}.json" -f $safeName, $stamp)
($before | ConvertTo-Json) | Set-Content -LiteralPath $backupFile -Encoding UTF8
Write-Output "已備份切換前設定 → $backupFile"

foreach ($field in $OPTION_MAP.Keys) {
    $msg = Set-RustDeskOption $exe $OPTION_MAP[$field] $target[$field]
    if ($msg) { Write-Host ("  {0,-24} : {1}" -f $OPTION_MAP[$field], $msg) -ForegroundColor Yellow }
}

$failed = 0
Write-Host ''
foreach ($field in $OPTION_MAP.Keys) {
    $optKey = $OPTION_MAP[$field]
    $now = Get-CurrentOption $exe $optKey
    $want = $target[$field]
    if ($now -eq $want) {
        Write-Host ("  {0,-24} OK   '{1}'" -f $optKey, $now) -ForegroundColor Green
    } else {
        $failed++
        Write-Host ("  {0,-24} FAIL 期望 '{1}'，實得 '{2}'" -f $optKey, $want, $now) -ForegroundColor Red
    }
}

Write-Output ("verify: {0}/{1} option(s) match" -f ($OPTION_MAP.Count - $failed), $OPTION_MAP.Count)
if ($failed -gt 0) { throw "$failed 個選項未生效（可能是伺服器端策略鎖定，見上方 CLI 輸出）。" }
Write-Host ''
Write-Output "切換完成：$Name（服務已自動重啟 rendezvous 連線，不需重啟服務）"
