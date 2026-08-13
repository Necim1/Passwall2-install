$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$temporary = Join-Path $env:TEMP ('pwsetup key test ' + [guid]::NewGuid().ToString('N'))
$keyPath = Join-Path $temporary 'id_ed25519'

try {
    New-Item -ItemType Directory -Force $temporary | Out-Null
    $gitCommand = @(Get-Command git.exe -CommandType Application -All -ErrorAction Stop)[0]
    $gitRoot = Split-Path -Parent (Split-Path -Parent ([string]$gitCommand.Source))
    $sshKeygen = [string](Join-Path $gitRoot 'usr\bin\ssh-keygen.exe')
    if (-not (Test-Path -LiteralPath $sshKeygen -PathType Leaf)) {
        $sshKeygen = (Get-Command ssh-keygen -CommandType Application -ErrorAction Stop).Source
    }
    & (Join-Path $root 'windows\New-EphemeralSshKey.ps1') -KeyPath $keyPath -Comment 'pwsetup-ci-test' -SshKeygenPath $sshKeygen
    if (-not (Test-Path -LiteralPath $keyPath)) { throw 'Private key was not created.' }
    if (-not (Test-Path -LiteralPath ($keyPath + '.pub'))) { throw 'Public key was not created.' }
    $firstLine = Get-Content -LiteralPath ($keyPath + '.pub') -TotalCount 1
    if ($firstLine -notmatch '^ssh-ed25519\s+') { throw 'Generated public key is not Ed25519.' }
    Write-Host 'Windows ssh-keygen compatibility test passed.' -ForegroundColor Green
}
finally {
    Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
}
