$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Yellow
}

function Load-JsonHashtable {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return @{}
    }

    try {
        $raw = Get-Content $Path -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return @{}
        }
        return $raw | ConvertFrom-Json -AsHashtable
    } catch {
        return @{}
    }
}

function Save-JsonHashtable {
    param(
        [string]$Path,
        [hashtable]$Data
    )

    $Data | ConvertTo-Json -Depth 20 | Set-Content -Path $Path -Encoding UTF8
}

function Remove-FileIfExists {
    param(
        [string]$Path,
        [System.Collections.Generic.List[string]]$RemovedItems,
        [string]$Label
    )

    if (Test-Path $Path) {
        Remove-Item $Path -Force
        $RemovedItems.Add($Label) | Out-Null
        return $true
    }

    return $false
}

function Remove-DirectoryIfEmpty {
    param(
        [string]$Path,
        [System.Collections.Generic.List[string]]$RemovedItems,
        [string]$Label
    )

    if (-not (Test-Path $Path)) {
        return $false
    }

    $children = Get-ChildItem -Path $Path -Force
    if ($children.Count -eq 0) {
        Remove-Item $Path -Force
        $RemovedItems.Add($Label) | Out-Null
        return $true
    }

    return $false
}

$configDir = Join-Path $env:USERPROFILE ".claude-code-router"
$pluginsDir = Join-Path $configDir "plugins"
$configPath = Join-Path $configDir "config.json"
$backupsDir = Join-Path $configDir "backups"
$pluginPath = Join-Path $pluginsDir "strip-reasoning.js"
$claudeDir = Join-Path $env:USERPROFILE ".claude"
$settingsPath = Join-Path $claudeDir "settings.json"
$ccrPackageDir = Join-Path $env:APPDATA "npm\node_modules\@musistudio\claude-code-router"
$cliPath = Join-Path $ccrPackageDir "dist\cli.js"
$ccrCmdPath = Join-Path $env:APPDATA "npm\ccr.cmd"
$ccrPs1Path = Join-Path $env:APPDATA "npm\ccr.ps1"
$ccrCmdBackup = Join-Path $backupsDir "ccr.cmd.original"
$ccrPs1Backup = Join-Path $backupsDir "ccr.ps1.original"
$installedSnippet = 'return e.thinking&&(r.reasoning={effort:EN(e.thinking.budget_tokens),enabled:e.thinking.type==="enabled"}),e.tool_choice&&'
$patchedSnippet = 'return e.tool_choice&&'

$removedItems = [System.Collections.Generic.List[string]]::new()
$notes = [System.Collections.Generic.List[string]]::new()

Write-Step "Stopping CCR processes"
$existing = Get-CimInstance Win32_Process | Where-Object {
    $_.CommandLine -like '*claude-code-router*dist*cli.js*start*'
}
foreach ($proc in $existing) {
    try {
        Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
    } catch {
    }
}
if ($existing) {
    $removedItems.Add("running CCR processes") | Out-Null
}

Write-Step "Removing CCR files created by this setup"
Remove-FileIfExists -Path $pluginPath -RemovedItems $removedItems -Label $pluginPath | Out-Null
Remove-FileIfExists -Path $configPath -RemovedItems $removedItems -Label $configPath | Out-Null

foreach ($helper in @(
    (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "start-ccr-hidden.vbs"),
    (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "run-claude.cmd")
)) {
    Remove-FileIfExists -Path $helper -RemovedItems $removedItems -Label $helper | Out-Null
}

if (-not (Remove-DirectoryIfEmpty -Path $pluginsDir -RemovedItems $removedItems -Label $pluginsDir)) {
    if (Test-Path $pluginsDir) {
        $notes.Add("Kept non-empty directory: $pluginsDir") | Out-Null
    }
}

if (-not (Remove-DirectoryIfEmpty -Path $configDir -RemovedItems $removedItems -Label $configDir)) {
    if (Test-Path $configDir) {
        $notes.Add("Kept non-empty directory: $configDir") | Out-Null
    }
}

Write-Step "Cleaning Claude settings"
if (Test-Path $settingsPath) {
    $settings = Load-JsonHashtable -Path $settingsPath

    if ($settings.ContainsKey("env") -and $null -ne $settings.env) {
        foreach ($key in @(
            "ANTHROPIC_BASE_URL",
            "ANTHROPIC_AUTH_TOKEN",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL",
            "ANTHROPIC_DEFAULT_OPUS_MODEL",
            "ANTHROPIC_DEFAULT_SONNET_MODEL",
            "CLAUDE_CODE_DISABLE_1M_CONTEXT"
        )) {
            if ($settings.env.ContainsKey($key)) {
                $settings.env.Remove($key)
                $removedItems.Add("settings env.$key") | Out-Null
            }
        }
        if ($settings.env.Count -eq 0) {
            $settings.Remove("env")
            $removedItems.Add("settings env container") | Out-Null
        }
    }

    if ($settings.ContainsKey("disableLoginPrompt") -and $settings.disableLoginPrompt -eq $true) {
        $settings.Remove("disableLoginPrompt")
        $removedItems.Add("settings disableLoginPrompt") | Out-Null
    }

    if ($settings.ContainsKey("autoUpdatesChannel") -and $settings.autoUpdatesChannel -eq "latest") {
        $settings.Remove("autoUpdatesChannel")
        $removedItems.Add("settings autoUpdatesChannel") | Out-Null
    }

    Save-JsonHashtable -Path $settingsPath -Data $settings
    $notes.Add("statusLine was not restored because install.ps1 removed it without a backup.") | Out-Null
}

Write-Step "Reverting CCR package patch"
if (Test-Path $cliPath) {
    $cliContent = [System.IO.File]::ReadAllText($cliPath)
    if ($cliContent.Contains($installedSnippet)) {
        $notes.Add("CCR CLI patch was already absent: $cliPath") | Out-Null
    } elseif ($cliContent.Contains($patchedSnippet)) {
        $cliContent = $cliContent.Replace($patchedSnippet, $installedSnippet)
        [System.IO.File]::WriteAllText($cliPath, $cliContent)
        $removedItems.Add("CCR CLI patch in $cliPath") | Out-Null
    } else {
        $notes.Add("Skipped CCR CLI restore because the expected snippet was not found: $cliPath") | Out-Null
    }
} else {
    $notes.Add("CCR CLI file not found: $cliPath") | Out-Null
}

Write-Step "Restoring ccr wrappers"
if ((Test-Path $ccrCmdBackup) -and (Test-Path $ccrCmdPath)) {
    Copy-Item $ccrCmdBackup $ccrCmdPath -Force
    $removedItems.Add("restored $ccrCmdPath") | Out-Null
}
if ((Test-Path $ccrPs1Backup) -and (Test-Path $ccrPs1Path)) {
    Copy-Item $ccrPs1Backup $ccrPs1Path -Force
    $removedItems.Add("restored $ccrPs1Path") | Out-Null
}

Remove-FileIfExists -Path $ccrCmdBackup -RemovedItems $removedItems -Label $ccrCmdBackup | Out-Null
Remove-FileIfExists -Path $ccrPs1Backup -RemovedItems $removedItems -Label $ccrPs1Backup | Out-Null
Remove-DirectoryIfEmpty -Path $backupsDir -RemovedItems $removedItems -Label $backupsDir | Out-Null
$notes.Add("Kept global npm package @musistudio/claude-code-router installed to make reinstall stable.") | Out-Null

Write-Step "Done"
Write-Host ""
Write-Host "Removed items:" -ForegroundColor Green
if ($removedItems.Count -eq 0) {
    Write-Host "  (nothing to remove)"
} else {
    foreach ($item in $removedItems) {
        Write-Host "  - $item"
    }
}

Write-Host ""
Write-Host "Notes:" -ForegroundColor Green
if ($notes.Count -eq 0) {
    Write-Host "  (no additional notes)"
} else {
    foreach ($note in $notes) {
        Write-Host "  - $note"
    }
}

Write-Host ""
Write-Host "Open a new terminal before running claude again." -ForegroundColor Green
