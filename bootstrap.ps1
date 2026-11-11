[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-fA-F0-9]{40}$')][string]$Commit,
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$Sha256,
    [ValidatePattern('^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$')][string]$Repository = 'Necim1/Passwall2-install'
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$temporary = Join-Path $env:TEMP ('pwsetup-' + [guid]::NewGuid().ToString('N'))
$temporary = [IO.Path]::GetFullPath($temporary)
$tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
$archive = Join-Path $temporary 'source.zip'
$installRoot = Join-Path $env:LOCALAPPDATA ("PassWall2RouterSetup\$Commit")
try {
    New-Item -ItemType Directory -Force $temporary | Out-Null
    Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/$Repository/archive/$Commit.zip" -OutFile $archive
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $Sha256) { throw 'Installer archive SHA-256 mismatch.' }
    Expand-Archive -LiteralPath $archive -DestinationPath $temporary
    $source = Get-ChildItem -LiteralPath $temporary -Directory | Select-Object -First 1
    if (-not $source -or -not (Test-Path (Join-Path $source.FullName 'install.sh'))) { throw 'Installer files are missing.' }
    New-Item -ItemType Directory -Force $installRoot | Out-Null
    Copy-Item -Path (Join-Path $source.FullName '*') -Destination $installRoot -Recurse -Force
    & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -ExecutionPolicy Bypass -File (Join-Path $installRoot 'Setup.ps1')
    if ($LASTEXITCODE -ne 0) { throw "Installer exited with code $LASTEXITCODE." }
}
finally {
    if ($temporary.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
    }
}
