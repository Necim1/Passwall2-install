[CmdletBinding()]
param(
    [string]$RouterHost,
    [ValidateSet('menu', 'check', 'install', 'update', 'restore', 'input', 'nodes', 'routing', 'backup', 'status')]
    [string]$Action = 'menu',
    [ValidateSet('auto', 'full', 'compact')][string]$Storage = 'auto',
    [ValidatePattern('^/[a-zA-Z0-9_./+-]+$')][string]$WorkDirectory = '/tmp',
    [ValidatePattern('^/[a-zA-Z0-9_./+-]+$')][string]$BackupDirectory = '/root/pwsetup-backups',
    [string]$Repository
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
foreach ($command in @('ssh', 'scp', 'tar')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "Required command: $command" }
}
if (-not $RouterHost) { $RouterHost = Read-Host 'OpenWrt IP/hostname [192.168.1.1]' }
if (-not $RouterHost) { $RouterHost = '192.168.1.1' }
if ($RouterHost -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.-]*$') { throw 'Use an IPv4 address or hostname.' }
$sessionId = [guid]::NewGuid().ToString('N')
$archive = Join-Path $env:TEMP ("pwsetup-$sessionId.tgz")
$remote = "/tmp/pwsetup-source-$sessionId"
$target = "root@$RouterHost"

try {
    & tar -czf $archive -C $root install.sh router config
    if ($LASTEXITCODE -ne 0) { throw 'Cannot create installer archive.' }
    Write-Host 'Uploading installer. SSH uses your existing key or asks for the root password.'
    & scp -O $archive "${target}:$remote.tgz"
    if ($LASTEXITCODE -ne 0) { throw 'Upload failed.' }
    $script = 'umask 077; mkdir {0} && tar -xzf {0}.tgz -C {0} && rm -f {0}.tgz && sh {0}/install.sh {1} --storage {2} --work-dir {3} --backup-dir {4}; result=$?; rm -rf {0}; exit $result' -f $remote, $Action, $Storage, $WorkDirectory, $BackupDirectory
    & ssh -t $target $script
    if ($LASTEXITCODE -ne 0) { throw "Router installer exited with code $LASTEXITCODE. Read its recovery message." }
}
finally {
    Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
}
