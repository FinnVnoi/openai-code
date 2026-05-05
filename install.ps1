$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Prompt-Value {
    param(
        [string]$Label,
        [string]$Default = "",
        [switch]$Secret
    )

    $suffix = ""
    if ($Default) {
        $suffix = " [$Default]"
    }

    if ($Secret) {
        $secure = Read-Host "$Label$suffix" -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try {
            $value = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        } finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
        if ([string]::IsNullOrWhiteSpace($value)) {
            return $Default
        }
        return $value
    }

    $value = Read-Host "$Label$suffix"
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $Default
    }
    return $value
}

function Normalize-BaseUrl {
    param([string]$Url)

    $trimmed = $Url.Trim().TrimEnd("/")
    if (-not ($trimmed -match "/v1$")) {
        $trimmed = "$trimmed/v1"
    }
    return $trimmed
}

function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

Write-Step "Checking required commands"
foreach ($cmd in @("node", "npm", "claude")) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        throw "Missing required command: $cmd"
    }
}

$ccrPackageDir = Join-Path $env:APPDATA "npm\node_modules\@musistudio\claude-code-router"
$cliPath = Join-Path $ccrPackageDir "dist\cli.js"
if (-not (Test-Path $cliPath)) {
    Write-Step "Installing claude-code-router"
    npm install -g @musistudio/claude-code-router
}

if (-not (Test-Path $cliPath)) {
    throw "claude-code-router was not installed correctly: $cliPath"
}

$baseUrl = Normalize-BaseUrl (Prompt-Value -Label "Endpoint URL" -Default "https://example.com/v1")
$apiKey = Prompt-Value -Label "API key" -Secret
$modelsInput = Prompt-Value -Label "Model(s), comma-separated" -Default "gpt-5.4"

if ([string]::IsNullOrWhiteSpace($apiKey)) {
    throw "API key is required."
}

$models = @(
    $modelsInput.Split(",") |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ }
)

if ($models.Count -eq 0) {
    throw "At least one model is required."
}

$providerName = "custom-openai"
$defaultModel = $models[0]
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$configDir = Join-Path $env:USERPROFILE ".claude-code-router"
$pluginsDir = Join-Path $configDir "plugins"
$configPath = Join-Path $configDir "config.json"
$backupsDir = Join-Path $configDir "backups"
$claudeDir = Join-Path $env:USERPROFILE ".claude"
$settingsPath = Join-Path $claudeDir "settings.json"

Ensure-Dir $configDir
Ensure-Dir $pluginsDir
Ensure-Dir $claudeDir
Ensure-Dir $backupsDir

Write-Step "Writing CCR plugin"
$pluginPath = Join-Path $pluginsDir "strip-reasoning.js"
@'
class StripReasoningTransformer {
  constructor() {
    this.name = "strip-reasoning";
  }

  async transformRequestIn(request) {
    if (request && typeof request === "object") {
      delete request.reasoning;
      delete request.thinking;
    }
    return request;
  }

  async transformResponseOut(response) {
    return response;
  }
}

module.exports = StripReasoningTransformer;
'@ | Set-Content -Path $pluginPath -Encoding UTF8

Write-Step "Writing CCR config"
$provider = [ordered]@{
    name = $providerName
    api_base_url = "$baseUrl/chat/completions"
    api_key = $apiKey
    models = $models
    transformer = @{
        use = @("openai", "strip-reasoning")
    }
}

$config = [ordered]@{
    LOG = $true
    LOG_LEVEL = "debug"
    API_TIMEOUT_MS = 600000
    NON_INTERACTIVE_MODE = $false
    OPENAI_API_KEY = $apiKey
    OPENAI_BASE_URL = $baseUrl
    OPENAI_MODEL = $defaultModel
    transformers = @(
        @{
            path = $pluginPath
        }
    )
    Providers = @($provider)
    Router = @{
        default = "$providerName,$defaultModel"
        background = "$providerName,$defaultModel"
        think = "$providerName,$defaultModel"
        longContext = "$providerName,$defaultModel"
    }
}

$config | ConvertTo-Json -Depth 20 | Set-Content -Path $configPath -Encoding UTF8

Write-Step "Patching Claude settings"
$settings = @{}
if (Test-Path $settingsPath) {
    try {
        $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json -AsHashtable
    } catch {
        $settings = @{}
    }
}

if (-not $settings.ContainsKey("env") -or $null -eq $settings.env) {
    $settings.env = @{}
}

$settings.env.ANTHROPIC_BASE_URL = "http://127.0.0.1:3456"
$settings.env.ANTHROPIC_AUTH_TOKEN = "test"
$settings.env.ANTHROPIC_DEFAULT_HAIKU_MODEL = "claude-haiku"
$settings.env.ANTHROPIC_DEFAULT_OPUS_MODEL = "claude-opus"
$settings.env.ANTHROPIC_DEFAULT_SONNET_MODEL = "claude-sonnet"
$settings.env.CLAUDE_CODE_DISABLE_1M_CONTEXT = "1"

if ($settings.ContainsKey("statusLine")) {
    $settings.Remove("statusLine")
}

$settings.disableLoginPrompt = $true
if (-not $settings.ContainsKey("autoUpdatesChannel")) {
    $settings.autoUpdatesChannel = "latest"
}

$settings | ConvertTo-Json -Depth 20 | Set-Content -Path $settingsPath -Encoding UTF8

Write-Step "Patching local CCR OpenAI transformer"
if (Test-Path $cliPath) {
    $cliContent = [System.IO.File]::ReadAllText($cliPath)
    $oldSnippet = 'return e.thinking&&(r.reasoning={effort:EN(e.thinking.budget_tokens),enabled:e.thinking.type==="enabled"}),e.tool_choice&&'
    $newSnippet = 'return e.tool_choice&&'
    if ($cliContent.Contains($oldSnippet)) {
        $cliContent = $cliContent.Replace($oldSnippet, $newSnippet)
        [System.IO.File]::WriteAllText($cliPath, $cliContent)
    }
}

Write-Step "Patching ccr start wrapper"
$ccrCmdPath = Join-Path $env:APPDATA "npm\ccr.cmd"
$ccrPs1Path = Join-Path $env:APPDATA "npm\ccr.ps1"
$ccrCmdBackup = Join-Path $backupsDir "ccr.cmd.original"
$ccrPs1Backup = Join-Path $backupsDir "ccr.ps1.original"

if ((Test-Path $ccrCmdPath) -and -not (Test-Path $ccrCmdBackup)) {
    Copy-Item $ccrCmdPath $ccrCmdBackup -Force
}
if ((Test-Path $ccrPs1Path) -and -not (Test-Path $ccrPs1Backup)) {
    Copy-Item $ccrPs1Path $ccrPs1Backup -Force
}

$ccrCmdContent = @'
@ECHO off
GOTO start
:find_dp0
SET dp0=%~dp0
EXIT /b
:start
SETLOCAL
CALL :find_dp0

IF EXIST "%dp0%\node.exe" (
  SET "_prog=%dp0%\node.exe"
) ELSE (
  SET "_prog=node"
  SET PATHEXT=%PATHEXT:;.JS;=;%
)

IF /I "%~1"=="start" (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "$listening = Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort 3456 -State Listen -ErrorAction SilentlyContinue; if (-not $listening) { Start-Process -WindowStyle Hidden -FilePath '%_prog%' -ArgumentList '\"%dp0%\node_modules\@musistudio\claude-code-router\dist\cli.js\"','start' | Out-Null; $ready = $false; for ($i = 0; $i -lt 20; $i++) { try { $resp = Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:3456/' -Method Head -TimeoutSec 2; if ($resp.StatusCode -eq 200) { $ready = $true; break } } catch { Start-Sleep -Seconds 1 } }; if (-not $ready) { exit 1 } }"
  IF ERRORLEVEL 1 (
    echo CCR did not become ready on http://127.0.0.1:3456
    EXIT /B 1
  )
  shift
  claude %*
  EXIT /B %ERRORLEVEL%
)

endLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & "%_prog%"  "%dp0%\node_modules\@musistudio\claude-code-router\dist\cli.js" %*
'@
[System.IO.File]::WriteAllText($ccrCmdPath, $ccrCmdContent)

$ccrPs1Content = @'
#!/usr/bin/env pwsh
$basedir=Split-Path $MyInvocation.MyCommand.Definition -Parent

$exe=""
if ($PSVersionTable.PSVersion -lt "6.0" -or $IsWindows) {
  $exe=".exe"
}
$cliPath = "$basedir/node_modules/@musistudio/claude-code-router/dist/cli.js"
$nodePath = if (Test-Path "$basedir/node$exe") { "$basedir/node$exe" } else { "node$exe" }

if ($args.Length -gt 0 -and $args[0] -eq "start") {
  $listening = Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort 3456 -State Listen -ErrorAction SilentlyContinue
  if (-not $listening) {
    Start-Process -WindowStyle Hidden -FilePath $nodePath -ArgumentList @($cliPath, "start") | Out-Null
    $ready = $false
    for ($i = 0; $i -lt 20; $i++) {
      try {
        $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:3456/" -Method Head -TimeoutSec 2
        if ($resp.StatusCode -eq 200) {
          $ready = $true
          break
        }
      } catch {
        Start-Sleep -Seconds 1
      }
    }
    if (-not $ready) {
      Write-Error "CCR did not become ready on http://127.0.0.1:3456"
      exit 1
    }
  }

  if ($args.Length -gt 1) {
    & claude @($args[1..($args.Length-1)])
  } else {
    & claude
  }
  exit $LASTEXITCODE
}

$ret=0
if (Test-Path "$basedir/node$exe") {
  if ($MyInvocation.ExpectingInput) {
    $input | & "$basedir/node$exe"  $cliPath $args
  } else {
    & "$basedir/node$exe"  $cliPath $args
  }
  $ret=$LASTEXITCODE
} else {
  if ($MyInvocation.ExpectingInput) {
    $input | & "node$exe"  $cliPath $args
  } else {
    & "node$exe"  $cliPath $args
  }
  $ret=$LASTEXITCODE
}
exit $ret
'@
[System.IO.File]::WriteAllText($ccrPs1Path, $ccrPs1Content)

Write-Step "Writing helper launchers"
$vbsPath = Join-Path $scriptDir "start-ccr-hidden.vbs"
$cmdPath = Join-Path $scriptDir "run-claude.cmd"

$vbsContent = @"
Set shell = CreateObject("WScript.Shell")
shell.Run "cmd.exe /c node ""$cliPath"" start", 0, False
"@
[System.IO.File]::WriteAllText($vbsPath, $vbsContent)

$cmdContent = @"
@echo off
setlocal
for /f "tokens=5" %%a in ('netstat -ano ^| findstr /R /C:":3456 .*LISTENING"') do set CCR_PID=%%a
if not defined CCR_PID (
  wscript.exe "$vbsPath"
  powershell -NoProfile -ExecutionPolicy Bypass -Command "$$ready=`$false; for (`$i=0; `$i -lt 20; `$i++) { try { `$resp = Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:3456/' -Method Head -TimeoutSec 2; if (`$resp.StatusCode -eq 200) { `$ready=`$true; break } } catch { Start-Sleep -Seconds 1 } }; if (-not `$ready) { exit 1 }"
  if errorlevel 1 (
    echo CCR did not become ready on http://127.0.0.1:3456
    exit /b 1
  )
)
claude %*
"@
[System.IO.File]::WriteAllText($cmdPath, $cmdContent)

Write-Step "Restarting CCR"
$existing = Get-CimInstance Win32_Process | Where-Object {
    $_.CommandLine -like '*claude-code-router*dist\cli.js*start*'
}
foreach ($proc in $existing) {
    try {
        Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
    } catch {
    }
}

Start-Process -WindowStyle Hidden -FilePath "wscript.exe" -ArgumentList "`"$vbsPath`"" | Out-Null

$ready = $false
for ($i = 0; $i -lt 20; $i++) {
    try {
        $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:3456/" -Method Head -TimeoutSec 2
        if ($resp.StatusCode -eq 200) {
            $ready = $true
            break
        }
    } catch {
        Start-Sleep -Seconds 1
    }
}

if (-not $ready) {
    throw "CCR did not become ready on http://127.0.0.1:3456"
}

Write-Step "Done"
Write-Host ""
Write-Host "Config written to:" -ForegroundColor Green
Write-Host "  $configPath"
Write-Host "  $settingsPath"
Write-Host "  $vbsPath"
Write-Host "  $cmdPath"
Write-Host ""
Write-Host "Open a new terminal and run:" -ForegroundColor Green
Write-Host "  $cmdPath"
