$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$failures = New-Object System.Collections.Generic.List[string]

function Add-Failure([string]$Message) {
    $script:failures.Add($Message)
}

foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.ps1') {
    $errors = $null
    $tokens = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    foreach ($error in $errors) {
        Add-Failure "$($file.Name):$($error.Extent.StartLineNumber): $($error.Message)"
    }
}

foreach ($name in @('Setup.ps1', 'windows/PassWallRelease.ps1')) {
    $bytes = [IO.File]::ReadAllBytes((Join-Path $root $name))
    if ($bytes.Length -lt 3 -or $bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) {
        Add-Failure "$name must have a UTF-8 BOM for Windows PowerShell 5.1."
    }
}

$bootstrapPath = Join-Path $root 'bootstrap.ps1'
$bootstrapBytes = [IO.File]::ReadAllBytes($bootstrapPath)
if ($bootstrapBytes.Length -ge 3 -and $bootstrapBytes[0] -eq 0xEF -and $bootstrapBytes[1] -eq 0xBB -and $bootstrapBytes[2] -eq 0xBF) {
    Add-Failure 'bootstrap.ps1 must not have a UTF-8 BOM because irm pipes it to Invoke-Expression.'
}
$bootstrapText = [Text.Encoding]::UTF8.GetString($bootstrapBytes)
$bootstrapErrors = $null
$bootstrapTokens = $null
[System.Management.Automation.Language.Parser]::ParseInput($bootstrapText, [ref]$bootstrapTokens, [ref]$bootstrapErrors) | Out-Null
foreach ($parseError in $bootstrapErrors) {
    Add-Failure "bootstrap.ps1 streamed parse: $($parseError.Message)"
}
foreach ($expected in @(
    'Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force',
    "System32\WindowsPowerShell\v1.0\powershell.exe",
    '$Branch.zip?nonce=$nonce',
    '-ExecutionPolicy Bypass',
    '-File (Join-Path $installRoot ''Setup.ps1'')',
    '$LASTEXITCODE -ne 0'
)) {
    if (-not $bootstrapText.Contains($expected)) { Add-Failure "bootstrap.ps1 is missing execution-policy handling: $expected" }
}

$readmeText = Get-Content -LiteralPath (Join-Path $root 'README.md') -Raw
foreach ($expected in @(
    'Set-ExecutionPolicy -Scope Process Bypass -Force',
    'bootstrap.ps1?nonce=$([guid]::NewGuid().ToString(''N''))'
)) {
    if (-not $readmeText.Contains($expected)) { Add-Failure "README.md is missing the safe bootstrap command: $expected" }
}

$versionPath = Join-Path $root 'VERSION'
if (-not (Test-Path -LiteralPath $versionPath)) {
    Add-Failure 'VERSION file is missing.'
}
elseif ((Get-Content -LiteralPath $versionPath -Raw).Trim() -ne '1.0.0') {
    Add-Failure 'VERSION must contain 1.0.0.'
}

foreach ($name in @('README.md', 'CHANGELOG.md')) {
    $content = Get-Content -LiteralPath (Join-Path $root $name) -Raw
    if ($content -match '(?i)\bv0\.[0-9]') { Add-Failure "$name contains a draft version." }
}
foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Extension -in @('.ps1', '.sh') }) {
    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $file.FullName) {
        $lineNumber++
        if ($line -match '^\s*#' -and $line -notmatch '^#!') {
            Add-Failure "$($file.Name):$lineNumber contains a code comment."
        }
    }
}

$routingPath = Join-Path $root 'config/passwall2-routing.conf'
$routing = Get-Content -LiteralPath $routingPath -Raw
$requiredSections = @(
    "config nodes 'pwsetup_main'",
    "config nodes 'pwsetup_balancer'",
    "config shunt_rules 'Discord'",
    "config shunt_rules 'Telegram'",
    "config shunt_rules 'Google'",
    "config shunt_rules 'WebRTC_Proxy'"
)
foreach ($section in $requiredSections) {
    if (-not $routing.Contains($section)) { Add-Failure "Routing template is missing: $section" }
}

$forbiddenRoutingPatterns = @(
    '(?m)^config subscribe_list',
    '(?m)^\s*(list|option) filter_discard_list',
    '(?m)^\s*option (url|uuid|address|publicKey|shortId) ',
    '(?i)subscription\.url'
)
foreach ($pattern in $forbiddenRoutingPatterns) {
    if ($routing -match $pattern) { Add-Failure "Routing template contains private node/subscription data: $pattern" }
}

if ($routing -notmatch "option enabled '0'") { Add-Failure 'Routing template must be disabled before subscription import.' }
if ($routing -notmatch "option balancingStrategy 'leastPing'") { Add-Failure 'leastPing balancer is missing.' }
if ($routing -notmatch "option probeInterval '30s'") { Add-Failure '30-second probe interval is missing.' }

$shellFiles = @(
    Get-ChildItem -LiteralPath (Join-Path $root 'router') -File -Filter '*.sh'
    Get-ChildItem -LiteralPath (Join-Path $root 'tests') -File -Filter '*.sh'
)
foreach ($file in $shellFiles) {
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    for ($i = 0; $i -lt ($bytes.Length - 1); $i++) {
        if ($bytes[$i] -eq 13 -and $bytes[$i + 1] -eq 10) {
            Add-Failure "$($file.Name) contains CRLF line endings."
            break
        }
    }
}

$setup = Get-Content -LiteralPath (Join-Path $root 'Setup.ps1') -Raw
foreach ($expected in @(
    '$script:Version = ''1.0.0''',
    '$script:Profile = ''cudy''',
    '$script:Profile = ''x86''',
    'Prepare-CudyXray',
    'Save-AutomaticBackup',
    'windows\New-EphemeralSshKey.ps1',
    'Get-PassWallInstallationState',
    '$releaseResponse = Invoke-RestMethod',
    '$releases = @($releaseResponse)',
    'Install-PassWallFresh',
    'Update-PassWall',
    'Get-ProxyCleanupInventory',
    'Invoke-ProxyCleanup',
    "@(`$script:Profile, 'install')",
    "@(`$script:Profile, 'update')"
)) {
    if (-not $setup.Contains($expected)) { Add-Failure "Setup.ps1 is missing expected behavior: $expected" }
}

foreach ($name in @('cleanup-common.sh', 'inspect-cleanup.sh', 'cleanup.sh')) {
    $path = Join-Path $root (Join-Path 'router' $name)
    if (-not (Test-Path -LiteralPath $path)) { Add-Failure "Cleanup component is missing: router/$name" }
}

$cleanupCommon = Get-Content -LiteralPath (Join-Path $root 'router/cleanup-common.sh') -Raw
foreach ($expected in @('podkop', 'forkop', 'luci-app-passwall', 'luci-app-passwall2', 'preserve_passwall2')) {
    if (-not $cleanupCommon.Contains($expected)) { Add-Failure "Cleanup inventory is missing target or safeguard: $expected" }
}

$cleanupInspect = Get-Content -LiteralPath (Join-Path $root 'router/inspect-cleanup.sh') -Raw
foreach ($expected in @('apk del --simulate', 'PRESERVE_BLOCKED=', 'HAS_TARGETS=')) {
    if (-not $cleanupInspect.Contains($expected)) { Add-Failure "Cleanup preview is missing: $expected" }
}

$cleanupApply = Get-Content -LiteralPath (Join-Path $root 'router/cleanup.sh') -Raw
foreach ($expected in @('REMOVE-CONFLICTS', 'REMOVE-ALL-PROXIES', 'apk del --simulate', '/etc/init.d/firewall restart', '/etc/init.d/dnsmasq restart', 'CLEANUP_OK=1')) {
    if (-not $cleanupApply.Contains($expected)) { Add-Failure "Cleanup execution is missing safety behavior: $expected" }
}
if ($cleanupApply -match 'apk del\s+--force') { Add-Failure 'Cleanup must not force package removal.' }

$keyHelperPath = Join-Path $root 'windows/New-EphemeralSshKey.ps1'
if (-not (Test-Path -LiteralPath $keyHelperPath)) {
    Add-Failure 'Windows PowerShell 5.1 SSH key helper is missing.'
}
else {
    $keyHelper = Get-Content -LiteralPath $keyHelperPath -Raw
    if (-not $keyHelper.Contains('-N ""')) { Add-Failure 'SSH key helper does not preserve the empty passphrase argument.' }
    if (-not $keyHelper.Contains('Diagnostics.ProcessStartInfo')) { Add-Failure 'SSH key helper must bypass Windows PowerShell 5.1 native empty-argument loss.' }
}

$releaseHelperPath = Join-Path $root 'windows/PassWallRelease.ps1'
if (-not (Test-Path -LiteralPath $releaseHelperPath)) {
    Add-Failure 'PassWall2 complete-release selector is missing.'
}
else {
    . $releaseHelperPath
    $incomplete = [pscustomobject]@{
        tag_name = 'new-incomplete'
        draft = $false
        prerelease = $false
        assets = @(
            [pscustomobject]@{ name = 'luci-app-passwall2-new.apk' },
            [pscustomobject]@{ name = 'luci-i18n-passwall2-ru-new.apk' }
        )
    }
    $complete = [pscustomobject]@{
        tag_name = 'older-complete'
        draft = $false
        prerelease = $false
        assets = @(
            [pscustomobject]@{ name = 'luci-app-passwall2-old.apk' },
            [pscustomobject]@{ name = 'luci-i18n-passwall2-ru-old.apk' },
            [pscustomobject]@{ name = 'passwall_packages_apk_aarch64_cortex-a53.zip' },
            [pscustomobject]@{ name = 'passwall_packages_apk_x86_64.zip' }
        )
    }
    foreach ($architecture in @('aarch64_cortex-a53', 'x86_64')) {
        try {
            $selectedRelease = Select-CompletePassWallRelease -Releases @($incomplete, $complete) -Architecture $architecture
            if ($selectedRelease.Release.tag_name -ne 'older-complete') {
                Add-Failure "Release selector did not skip an incomplete release for $architecture."
            }
        }
        catch {
            Add-Failure "Release selector failed for ${architecture}: $($_.Exception.Message)"
        }
    }
}

$updateBlock = [regex]::Match($setup, '(?s)function Update-PassWall \{(.*?)\r?\n\}\r?\n\r?\nfunction Invoke-Diagnostics').Groups[1].Value
if ([string]::IsNullOrWhiteSpace($updateBlock)) {
    Add-Failure 'Could not locate the Update-PassWall function body.'
}
else {
    foreach ($forbidden in @('Apply-Routing', 'Import-Subscription')) {
        if ($updateBlock.Contains($forbidden)) { Add-Failure "Update-PassWall must preserve configuration and not call $forbidden." }
    }
}

$checkPath = Join-Path $root 'router/check-existing.sh'
if (-not (Test-Path -LiteralPath $checkPath)) {
    Add-Failure 'router/check-existing.sh is missing.'
}
else {
    $check = Get-Content -LiteralPath $checkPath -Raw
    foreach ($expected in @('STATUS=complete', 'STATUS=clean', 'STATUS=incomplete', 'EXISTING_OK=1')) {
        if (-not $check.Contains($expected)) { Add-Failure "Existing-installation check is missing: $expected" }
    }
}

$installer = Get-Content -LiteralPath (Join-Path $root 'router/install.sh') -Raw
foreach ($expected in @('mode="${2:-install}"', 'UPDATE_BLOCKED:', 'INSTALL_BLOCKED:', 'UPDATE_OK=1')) {
    if (-not $installer.Contains($expected)) { Add-Failure "Router installer is missing update safety behavior: $expected" }
}
if (-not $installer.Contains('apk --update-cache add dnsmasq-full')) {
    Add-Failure 'Router installer must install dnsmasq-full through its configured signed repository.'
}
if ($installer -match 'apk fetch[^\r\n]*dnsmasq') {
    Add-Failure 'Router installer must not fetch dnsmasq packages for local installation.'
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    exit 1
}

Write-Host 'Validation passed.' -ForegroundColor Green
