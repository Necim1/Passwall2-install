$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$failures = @()
foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.ps1') {
    $errors = $null
    $tokens = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    foreach ($error in $errors) { $failures += "$($file.Name): $($error.Message)" }
}
foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.sh') {
    $text = [IO.File]::ReadAllText($file.FullName)
    if ($text.Contains("`r`n")) { $failures += "$($file.Name): shell scripts require LF line endings." }
}
if ($failures.Count) { throw ($failures -join "`n") }
Write-Host 'PowerShell syntax and shell line endings passed.'
