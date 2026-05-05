$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Ensure-Dir {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function ConvertTo-Hashtable {
    param([Parameter(ValueFromPipeline = $true)]$InputObject)

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $table = [ordered]@{}
        foreach ($key in $InputObject.Keys) {
            $table[$key] = ConvertTo-Hashtable $InputObject[$key]
        }
        return $table
    }

    if (($InputObject -is [System.Collections.IEnumerable]) -and -not ($InputObject -is [string])) {
        $items = @()
        foreach ($item in $InputObject) {
            $items += ,(ConvertTo-Hashtable $item)
        }
        return ,$items
    }

    if ($InputObject -is [pscustomobject]) {
        $table = [ordered]@{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $table[$property.Name] = ConvertTo-Hashtable $property.Value
        }
        return $table
    }

    return $InputObject
}

function Load-JsonHashtable {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return [ordered]@{}
    }

    $raw = Get-Content $Path -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [ordered]@{}
    }

    return ConvertTo-Hashtable ($raw | ConvertFrom-Json)
}

function Save-Json {
    param(
        [string]$Path,
        $Data
    )

    $Data | ConvertTo-Json -Depth 20 | Set-Content -Path $Path -Encoding UTF8
}

function Normalize-BaseUrl {
    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return ""
    }

    $trimmed = $Url.Trim().TrimEnd("/")
    if (-not ($trimmed -match "/v1$")) {
        $trimmed = "$trimmed/v1"
    }
    return $trimmed
}

function Mask-Value {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return "(empty)"
    }

    if ($Value.Length -le 8) {
        return ("*" * $Value.Length)
    }

    return "{0}...{1}" -f $Value.Substring(0, 4), $Value.Substring($Value.Length - 4)
}

function Prompt-ValueOrKeep {
    param(
        [string]$Label,
        [string]$Current
    )

    $suffix = ""
    if (-not [string]::IsNullOrWhiteSpace($Current)) {
        $suffix = " [$Current]"
    }

    $value = Read-Host "$Label$suffix (Enter = keep)"
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $null
    }

    return $value.Trim()
}

function Prompt-SecretOrKeep {
    param(
        [string]$Label,
        [string]$CurrentMask
    )

    $secure = Read-Host "$Label [$CurrentMask] (Enter = keep)" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        $value = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }

    if ([string]::IsNullOrWhiteSpace($value)) {
        return $null
    }

    return $value
}

function Prompt-Choice {
    param(
        [string]$Label,
        [string[]]$Allowed,
        [string]$Default
    )

    $allowedText = $Allowed -join "/"
    while ($true) {
        $value = Read-Host "$Label [$Default] ($allowedText)"
        if ([string]::IsNullOrWhiteSpace($value)) {
            return $Default
        }

        $normalized = $value.Trim().ToLowerInvariant()
        foreach ($item in $Allowed) {
            if ($normalized -eq $item) {
                return $item
            }
        }

        Write-Host "Choose one of: $allowedText" -ForegroundColor Yellow
    }
}

function Parse-Models {
    param([string]$Value)

    $models = @(
        $Value.Split(",") |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ }
    )

    if ($models.Count -eq 0) {
        throw "At least one model is required."
    }

    return $models
}

function Ensure-Map {
    param(
        [System.Collections.IDictionary]$Parent,
        [string]$Key
    )

    if (-not $Parent.Contains($Key) -or $null -eq $Parent[$Key]) {
        $Parent[$Key] = [ordered]@{}
    }

    return $Parent[$Key]
}

function Normalize-ArrayValue {
    param($Value)

    if ($null -eq $Value) {
        return @()
    }

    if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string]) -and -not ($Value -is [System.Collections.IDictionary])) {
        return @($Value)
    }

    return @($Value)
}

function Get-PrimaryProvider {
    param(
        [System.Collections.IDictionary]$Config,
        [string]$ProviderName
    )

    $providers = Normalize-ArrayValue $Config["Providers"]
    foreach ($candidate in $providers) {
        if ($candidate["name"] -eq $ProviderName) {
            return $candidate
        }
    }

    throw "Provider not found: $ProviderName"
}

function Normalize-CcrConfigShape {
    param(
        [System.Collections.IDictionary]$Config,
        [System.Collections.IDictionary]$Provider
    )

    $Config["Providers"] = @($Provider)
    if ($Config.Contains("transformers") -and $null -ne $Config["transformers"]) {
        $Config["transformers"] = Normalize-ArrayValue $Config["transformers"]
    }
}

function Resolve-ProviderName {
    param([System.Collections.IDictionary]$Config)

    $providers = Normalize-ArrayValue $Config["Providers"]
    if ($providers.Count -eq 0) {
        throw "No providers found in $configPath"
    }

    $router = $Config["Router"]
    if ($router -is [System.Collections.IDictionary]) {
        $routerDefault = [string]$router["default"]
        if (-not [string]::IsNullOrWhiteSpace($routerDefault) -and $routerDefault.Contains(",")) {
            $candidate = $routerDefault.Split(",")[0].Trim()
            foreach ($provider in $providers) {
                if ($provider["name"] -eq $candidate) {
                    return $candidate
                }
            }
        }
    }

    foreach ($provider in $providers) {
        if ($provider["name"] -eq "custom-openai") {
            return "custom-openai"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$providers[0]["name"])) {
        return [string]$providers[0]["name"]
    }

    throw "Could not resolve provider name."
}

function Get-Provider {
    param(
        [object[]]$Providers,
        [string]$ProviderName
    )

    foreach ($provider in $Providers) {
        if ($provider["name"] -eq $ProviderName) {
            return $provider
        }
    }

    throw "Provider not found: $ProviderName"
}

function Get-StringList {
    param($Value)

    if ($null -eq $Value) {
        return @()
    }

    if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string])) {
        return @(
            $Value |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
    }

    if ([string]::IsNullOrWhiteSpace([string]$Value)) {
        return @()
    }

    return @([string]$Value)
}

function Get-CurrentBaseUrl {
    param(
        [System.Collections.IDictionary]$Config,
        [System.Collections.IDictionary]$Provider
    )

    if (-not [string]::IsNullOrWhiteSpace([string]$Config["OPENAI_BASE_URL"])) {
        return Normalize-BaseUrl ([string]$Config["OPENAI_BASE_URL"])
    }

    $providerUrl = [string]$Provider["api_base_url"]
    if ([string]::IsNullOrWhiteSpace($providerUrl)) {
        return ""
    }

    if ($providerUrl.EndsWith("/chat/completions")) {
        $providerUrl = $providerUrl.Substring(0, $providerUrl.Length - "/chat/completions".Length)
    }

    return Normalize-BaseUrl $providerUrl
}

function Get-CurrentRouteModel {
    param(
        [System.Collections.IDictionary]$Config,
        [System.Collections.IDictionary]$Provider
    )

    if (-not [string]::IsNullOrWhiteSpace([string]$Config["OPENAI_MODEL"])) {
        return [string]$Config["OPENAI_MODEL"]
    }

    $router = $Config["Router"]
    if ($router -is [System.Collections.IDictionary]) {
        $routerDefault = [string]$router["default"]
        if (-not [string]::IsNullOrWhiteSpace($routerDefault) -and $routerDefault.Contains(",")) {
            return $routerDefault.Split(",", 2)[1].Trim()
        }
    }

    $models = Get-StringList $Provider["models"]
    if ($models.Count -gt 0) {
        return $models[0]
    }

    return ""
}

function Get-FamilyModelMapping {
    param(
        [string]$Path,
        [string]$DefaultModel
    )

    $mapping = [ordered]@{
        sonnet = $DefaultModel
        opus = $DefaultModel
        haiku = $DefaultModel
    }

    if (-not (Test-Path $Path)) {
        return $mapping
    }

    $content = [System.IO.File]::ReadAllText($Path)
    foreach ($family in @("sonnet", "opus", "haiku")) {
        $pattern = "claude-$family['`"]\s*:\s*['`"]([^'`"]+)['`"]"
        $match = [regex]::Match($content, $pattern)
        if ($match.Success) {
            $mapping[$family] = $match.Groups[1].Value
        }
    }

    return $mapping
}

function Write-FamilyRouter {
    param(
        [string]$Path,
        [string]$ProviderName,
        [string]$SonnetModel,
        [string]$OpusModel,
        [string]$HaikuModel
    )

    $providerLiteral = $ProviderName.Replace("\", "\\").Replace("'", "\'")
    $sonnetLiteral = $SonnetModel.Replace("\", "\\").Replace("'", "\'")
    $opusLiteral = $OpusModel.Replace("\", "\\").Replace("'", "\'")
    $haikuLiteral = $HaikuModel.Replace("\", "\\").Replace("'", "\'")

    $content = @"
const provider = '$providerLiteral';
const familyModels = {
  'claude-sonnet': '$sonnetLiteral',
  'claude-opus': '$opusLiteral',
  'claude-haiku': '$haikuLiteral',
  'sonnet': '$sonnetLiteral',
  'opus': '$opusLiteral',
  'haiku': '$haikuLiteral'
};

module.exports = async function router(req) {
  const requestedModel = req && req.body && req.body.model;
  if (typeof requestedModel === 'string') {
    for (const [familyModel, downstreamModel] of Object.entries(familyModels)) {
      if (requestedModel === familyModel || requestedModel.includes(familyModel)) {
        return provider + ',' + downstreamModel;
      }
    }
  }
  return null;
};
"@

    [System.IO.File]::WriteAllText($Path, $content)
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$configDir = Join-Path $env:USERPROFILE ".claude-code-router"
$configPath = Join-Path $configDir "config.json"
$customRouterPath = Join-Path $configDir "custom-router.js"
$claudeDir = Join-Path $env:USERPROFILE ".claude"
$settingsPath = Join-Path $claudeDir "settings.json"

if (-not (Test-Path $configPath)) {
    throw "Missing CCR config: $configPath. Run install.ps1 first."
}

Ensure-Dir $configDir
Ensure-Dir $claudeDir

Write-Step "Loading current configuration"
$config = Load-JsonHashtable -Path $configPath
$settings = Load-JsonHashtable -Path $settingsPath
$settingsEnv = Ensure-Map -Parent $settings -Key "env"

if (-not $config.Contains("Providers") -or (Normalize-ArrayValue $config["Providers"]).Count -eq 0) {
    throw "No providers found in $configPath"
}

$providerName = Resolve-ProviderName -Config $config
$provider = Get-PrimaryProvider -Config $config -ProviderName $providerName
$currentBaseUrl = Get-CurrentBaseUrl -Config $config -Provider $provider
$currentApiKey = [string]$provider["api_key"]
if ([string]::IsNullOrWhiteSpace($currentApiKey)) {
    $currentApiKey = [string]$config["OPENAI_API_KEY"]
}
$currentModels = @(Get-StringList $provider["models"])
$currentRouteModel = Get-CurrentRouteModel -Config $config -Provider $provider
$currentFamilyModels = Get-FamilyModelMapping -Path $customRouterPath -DefaultModel $currentRouteModel
$currentSonnetModel = [string]$currentFamilyModels["sonnet"]
$currentOpusModel = [string]$currentFamilyModels["opus"]
$currentHaikuModel = [string]$currentFamilyModels["haiku"]

if ([string]::IsNullOrWhiteSpace($currentSonnetModel)) {
    $currentSonnetModel = $currentRouteModel
}
if ([string]::IsNullOrWhiteSpace($currentOpusModel)) {
    $currentOpusModel = $currentRouteModel
}
if ([string]::IsNullOrWhiteSpace($currentHaikuModel)) {
    $currentHaikuModel = $currentRouteModel
}

Write-Host ""
Write-Host "Current values:" -ForegroundColor Green
Write-Host "  Provider: $providerName"
Write-Host "  Endpoint: $currentBaseUrl"
Write-Host "  API key: $(Mask-Value $currentApiKey)"
Write-Host "  Provider models: $($currentModels -join ', ')"
Write-Host "  Default CCR route model: $currentRouteModel"
Write-Host "  Sonnet downstream model: $currentSonnetModel"
Write-Host "  Opus downstream model: $currentOpusModel"
Write-Host "  Haiku downstream model: $currentHaikuModel"

$currentPermissionMode = "default"
if ($settings.Contains("permissions") -and $settings["permissions"] -is [System.Collections.IDictionary]) {
    $storedPermissionMode = [string]$settings["permissions"]["defaultMode"]
    if (-not [string]::IsNullOrWhiteSpace($storedPermissionMode)) {
        $currentPermissionMode = $storedPermissionMode
    }
}
Write-Host "  Permission mode: $currentPermissionMode"
Write-Host ""

$newBaseUrlInput = Prompt-ValueOrKeep -Label "Endpoint URL" -Current $currentBaseUrl
$newApiKey = Prompt-SecretOrKeep -Label "API key" -CurrentMask (Mask-Value $currentApiKey)
$newModelsInput = Prompt-ValueOrKeep -Label "Provider models (comma-separated)" -Current ($currentModels -join ", ")
$newRouteModelInput = Prompt-ValueOrKeep -Label "Default CCR route model" -Current $currentRouteModel
$modelMode = Prompt-Choice -Label "Claude family downstream routing" -Allowed @("keep", "all", "individual") -Default "keep"
$bypassMode = Prompt-Choice -Label "Bypass permissions mode" -Allowed @("keep", "enable", "disable") -Default "keep"

$baseUrl = $currentBaseUrl
if (-not [string]::IsNullOrWhiteSpace($newBaseUrlInput)) {
    $baseUrl = Normalize-BaseUrl $newBaseUrlInput
}

$apiKey = $currentApiKey
if (-not [string]::IsNullOrWhiteSpace($newApiKey)) {
    $apiKey = $newApiKey
}

$providerModels = $currentModels
if (-not [string]::IsNullOrWhiteSpace($newModelsInput)) {
    $providerModels = Parse-Models $newModelsInput
}

$routeModel = $currentRouteModel
if (-not [string]::IsNullOrWhiteSpace($newRouteModelInput)) {
    $routeModel = $newRouteModelInput.Trim()
}
if ([string]::IsNullOrWhiteSpace($routeModel) -and $providerModels.Count -gt 0) {
    $routeModel = $providerModels[0]
}
if ([string]::IsNullOrWhiteSpace($routeModel)) {
    throw "A default CCR route model is required."
}
if ($providerModels.Count -eq 0) {
    $providerModels = @($routeModel)
}

$sonnetModel = $currentSonnetModel
$opusModel = $currentOpusModel
$haikuModel = $currentHaikuModel

switch ($modelMode) {
    "all" {
        $allModel = Prompt-ValueOrKeep -Label "Downstream model for Sonnet/Opus/Haiku" -Current $currentSonnetModel
        if (-not [string]::IsNullOrWhiteSpace($allModel)) {
            $sonnetModel = $allModel
            $opusModel = $allModel
            $haikuModel = $allModel
        }
    }
    "individual" {
        $newSonnetModel = Prompt-ValueOrKeep -Label "Sonnet downstream model" -Current $currentSonnetModel
        $newOpusModel = Prompt-ValueOrKeep -Label "Opus downstream model" -Current $currentOpusModel
        $newHaikuModel = Prompt-ValueOrKeep -Label "Haiku downstream model" -Current $currentHaikuModel

        if (-not [string]::IsNullOrWhiteSpace($newSonnetModel)) {
            $sonnetModel = $newSonnetModel
        }
        if (-not [string]::IsNullOrWhiteSpace($newOpusModel)) {
            $opusModel = $newOpusModel
        }
        if (-not [string]::IsNullOrWhiteSpace($newHaikuModel)) {
            $haikuModel = $newHaikuModel
        }
    }
}

$modelsToInclude = @($providerModels) + @($routeModel, $sonnetModel, $opusModel, $haikuModel, "claude-sonnet", "claude-opus", "claude-haiku") |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Select-Object -Unique

$addedModels = @(
    $modelsToInclude |
    Where-Object { $providerModels -notcontains $_ }
)
if ($addedModels.Count -gt 0) {
    Write-Host "Adding family models to provider models: $($addedModels -join ', ')" -ForegroundColor Yellow
}
$providerModels = @($modelsToInclude)

if ([string]::IsNullOrWhiteSpace($baseUrl)) {
    throw "Endpoint URL is required."
}
if ([string]::IsNullOrWhiteSpace($apiKey)) {
    throw "API key is required."
}

Write-Step "Updating CCR config"
$provider["api_base_url"] = "$baseUrl/chat/completions"
$provider["api_key"] = $apiKey
$provider["models"] = $providerModels
$config["OPENAI_BASE_URL"] = $baseUrl
$config["OPENAI_API_KEY"] = $apiKey
$config["OPENAI_MODEL"] = $routeModel
$config["CUSTOM_ROUTER_PATH"] = $customRouterPath
$router = Ensure-Map -Parent $config -Key "Router"
foreach ($routeKey in @("default", "background", "think", "longContext")) {
    $router[$routeKey] = "$providerName,$routeModel"
}
Normalize-CcrConfigShape -Config $config -Provider $provider
Write-FamilyRouter -Path $customRouterPath -ProviderName $providerName -SonnetModel $sonnetModel -OpusModel $opusModel -HaikuModel $haikuModel
Save-Json -Path $configPath -Data $config

Write-Step "Updating Claude settings"
$settingsEnv["ANTHROPIC_BASE_URL"] = "http://127.0.0.1:3456"
$settingsEnv["ANTHROPIC_AUTH_TOKEN"] = "test"
$settingsEnv["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = "claude-haiku"
$settingsEnv["ANTHROPIC_DEFAULT_OPUS_MODEL"] = "claude-opus"
$settingsEnv["ANTHROPIC_DEFAULT_SONNET_MODEL"] = "claude-sonnet"
$settingsEnv["CLAUDE_CODE_DISABLE_1M_CONTEXT"] = "1"
$permissions = Ensure-Map -Parent $settings -Key "permissions"
switch ($bypassMode) {
    "enable" {
        $permissions["defaultMode"] = "bypassPermissions"
    }
    "disable" {
        $permissions["defaultMode"] = "default"
    }
}
$effectivePermissionMode = [string]$permissions["defaultMode"]
if ([string]::IsNullOrWhiteSpace($effectivePermissionMode)) {
    $effectivePermissionMode = "default"
}
Save-Json -Path $settingsPath -Data $settings

Write-Step "Done"
Write-Host ""
Write-Host "Updated values:" -ForegroundColor Green
Write-Host "  Endpoint: $baseUrl"
Write-Host "  API key: $(Mask-Value $apiKey)"
Write-Host "  Provider models: $($providerModels -join ', ')"
Write-Host "  Default CCR route model: $routeModel"
Write-Host "  Sonnet downstream model: $sonnetModel"
Write-Host "  Opus downstream model: $opusModel"
Write-Host "  Haiku downstream model: $haikuModel"
Write-Host "  Permission mode: $effectivePermissionMode"
Write-Host ""
Write-Host "Open a new terminal before running claude again." -ForegroundColor Green
