function Select-CompletePassWallRelease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$Releases,
        [Parameter(Mandatory = $true)][ValidateSet('aarch64_cortex-a53', 'x86_64')][string]$Architecture
    )

    $bundleName = "passwall_packages_apk_$Architecture.zip"
    foreach ($release in $Releases) {
        if ($release.draft -or $release.prerelease) { continue }
        $assets = @($release.assets)
        $appAsset = $assets | Where-Object { $_.name -match '^luci-app-passwall2(?:-|_).+\.apk$' } | Select-Object -First 1
        $ruAsset = $assets | Where-Object { $_.name -match '^luci-i18n-passwall2-ru(?:-|_).+\.apk$' } | Select-Object -First 1
        $bundleAsset = $assets | Where-Object { $_.name -eq $bundleName } | Select-Object -First 1
        if ($appAsset -and $ruAsset -and $bundleAsset) {
            return [pscustomobject]@{
                Release = $release
                AppAsset = $appAsset
                RuAsset = $ruAsset
                BundleAsset = $bundleAsset
            }
        }
    }

    throw "GitHub не вернул ни одного полного APK-релиза PassWall2 для $Architecture."
}
