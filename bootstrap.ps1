param(
    [string]$Repository = 'Necim1/Passwall2-install',
    [string]$Branch = 'main'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

try {
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction Stop
}
catch {
    Write-Warning 'Could not set the process execution policy. Continuing with an isolated PowerShell process.'
}

if ($Repository -notmatch '^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$') {
    throw 'Invalid repository name. Expected owner/repository.'
}

$installRoot = Join-Path $env:LOCALAPPDATA 'PassWall2RouterSetup\app'
$temporary = Join-Path $env:TEMP ('pwsetup-bootstrap-' + [guid]::NewGuid().ToString('N'))
$archive = Join-Path $temporary 'source.zip'
$expanded = Join-Path $temporary 'expanded'
$nonce = [guid]::NewGuid().ToString('N')
$uri = "https://github.com/$Repository/archive/refs/heads/$Branch.zip?nonce=$nonce"
$powerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

if (-not (Test-Path -LiteralPath $powerShellExe)) {
    throw 'Windows PowerShell 5.1 was not found.'
}

try {
    New-Item -ItemType Directory -Force $temporary, $expanded | Out-Null
    Write-Host "Downloading $Repository ($Branch)..." -ForegroundColor Cyan
    Invoke-WebRequest -UseBasicParsing -Headers @{ 'User-Agent' = 'PassWall2-Router-Setup' } -Uri $uri -OutFile $archive
    Expand-Archive -LiteralPath $archive -DestinationPath $expanded -Force
    $sourceRoot = Get-ChildItem -LiteralPath $expanded -Directory | Select-Object -First 1
    if (-not $sourceRoot -or -not (Test-Path (Join-Path $sourceRoot.FullName 'Setup.ps1'))) {
        throw 'Downloaded repository does not contain Setup.ps1.'
    }

    if (Test-Path -LiteralPath $installRoot) {
        Remove-Item -LiteralPath $installRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Force $installRoot | Out-Null
    Copy-Item -Path (Join-Path $sourceRoot.FullName '*') -Destination $installRoot -Recurse -Force

    & $powerShellExe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $installRoot 'Setup.ps1') -Repository $Repository
    if ($LASTEXITCODE -ne 0) {
        throw "Setup.ps1 exited with code $LASTEXITCODE."
    }
}
finally {
    Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
}
