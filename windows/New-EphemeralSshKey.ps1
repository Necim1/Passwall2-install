[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$KeyPath,
    [Parameter(Mandatory = $true)][string]$Comment,
    [string]$SshKeygenPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($KeyPath.IndexOf('"') -ge 0 -or $KeyPath -match '[\r\n]') {
    throw 'The temporary SSH key path contains unsupported characters.'
}
if ($Comment -notmatch '^[a-zA-Z0-9_.-]+$') {
    throw 'The temporary SSH key comment contains unsupported characters.'
}

if ([string]::IsNullOrWhiteSpace($SshKeygenPath)) {
    $SshKeygenPath = (Get-Command ssh-keygen -CommandType Application -ErrorAction Stop).Source
}
if (-not (Test-Path -LiteralPath $SshKeygenPath -PathType Leaf)) {
    throw "ssh-keygen was not found at $SshKeygenPath"
}
$startInfo = New-Object Diagnostics.ProcessStartInfo
$startInfo.FileName = $SshKeygenPath
$startInfo.Arguments = '-q -t ed25519 -N "" -C "{0}" -f "{1}"' -f $Comment, $KeyPath
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true

$process = New-Object Diagnostics.Process
$process.StartInfo = $startInfo
try {
    if (-not $process.Start()) { throw 'Could not start ssh-keygen.' }
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
        $details = ($stderr + "`n" + $stdout).Trim()
        throw "ssh-keygen exited with code $($process.ExitCode). $details"
    }
}
finally {
    $process.Dispose()
}

if (-not (Test-Path -LiteralPath $KeyPath) -or -not (Test-Path -LiteralPath ($KeyPath + '.pub'))) {
    throw 'ssh-keygen did not create both key files.'
}
