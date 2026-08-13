[CmdletBinding()]
param(
    [string]$Repository = $env:PWSETUP_REPOSITORY
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:AppName = 'PassWall2 Router Setup'
$script:Version = '1.0.0'
$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:RouterDir = Join-Path $script:Root 'router'
$script:ConfigDir = Join-Path $script:Root 'config'
$script:DataRoot = Join-Path $env:LOCALAPPDATA 'PassWall2RouterSetup'
$script:CacheRoot = Join-Path $script:DataRoot 'cache'
$script:BackupRoot = Join-Path $script:DataRoot 'backups'
$script:SessionRoot = Join-Path $env:TEMP ('pwsetup-' + [guid]::NewGuid().ToString('N'))
$script:Profile = $null
$script:RouterHost = $null
$script:RouterUser = 'root'
$script:SshKey = $null
$script:SshMarker = $null
$script:Connected = $false

New-Item -ItemType Directory -Force $script:CacheRoot, $script:BackupRoot, $script:SessionRoot | Out-Null

$releaseHelper = Join-Path $script:Root 'windows\PassWallRelease.ps1'
if (-not (Test-Path -LiteralPath $releaseHelper)) { throw 'Не найден компонент выбора релиза PassWall2.' }
. $releaseHelper

function Write-Color {
    param([string]$Text, [ConsoleColor]$Color = [ConsoleColor]::Gray, [switch]$NoNewline)
    Write-Host $Text -ForegroundColor $Color -NoNewline:$NoNewline
}

function Write-Banner {
    Clear-Host
    Write-Color '  ______________________________________________________________' DarkGray
    Write-Host
    Write-Color "              PassWall2 Router Setup $script:Version" Cyan
    Write-Host
    Write-Color '       OpenWrt 25.12.5+ / Cudy WR3000H-S / x86_64' DarkCyan
    Write-Host
    Write-Color '  ______________________________________________________________' DarkGray
    Write-Host
}

function Pause-Menu {
    Write-Host
    [void](Read-Host 'Нажмите Enter, чтобы продолжить')
}

function Assert-Command {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Не найдена команда '$Name'. Установите компонент OpenSSH Client в Windows."
    }
}

function Convert-SecureStringToText {
    param([Security.SecureString]$SecureString)
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

function Get-SshArguments {
    $args = @(
        '-i', $script:SshKey,
        '-o', 'BatchMode=yes',
        '-o', 'IdentitiesOnly=yes',
        '-o', 'ConnectTimeout=12',
        '-o', 'ServerAliveInterval=15',
        '-o', 'ServerAliveCountMax=3'
    )
    return $args
}

function Invoke-Ssh {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [switch]$AllowFailure,
        [switch]$Capture
    )

    if (-not $script:Connected) { throw 'SSH-сессия ещё не настроена.' }
    $args = Get-SshArguments
    $target = '{0}@{1}' -f $script:RouterUser, $script:RouterHost
    if ($Capture) {
        $output = & ssh @args $target $Command 2>&1
        $code = $LASTEXITCODE
        if ($code -ne 0 -and -not $AllowFailure) {
            throw "Команда на роутере завершилась с кодом $code.`n$($output -join "`n")"
        }
        return ,$output
    }

    & ssh @args $target $Command
    $code = $LASTEXITCODE
    if ($code -ne 0 -and -not $AllowFailure) {
        throw "Команда на роутере завершилась с кодом $code."
    }
    if ($AllowFailure) { return $code }
}

function Copy-ToRouter {
    param(
        [Parameter(Mandatory = $true)][string]$LocalPath,
        [Parameter(Mandatory = $true)][string]$RemotePath
    )
    $args = @('-O') + @(Get-SshArguments)
    $destination = '{0}@{1}:{2}' -f $script:RouterUser, $script:RouterHost, $RemotePath
    & scp @args $LocalPath $destination
    if ($LASTEXITCODE -ne 0) { throw "Не удалось загрузить $LocalPath на роутер." }
}

function Copy-FromRouter {
    param(
        [Parameter(Mandatory = $true)][string]$RemotePath,
        [Parameter(Mandatory = $true)][string]$LocalPath
    )
    $args = @('-O') + @(Get-SshArguments)
    $source = '{0}@{1}:{2}' -f $script:RouterUser, $script:RouterHost, $RemotePath
    & scp @args $source $LocalPath
    if ($LASTEXITCODE -ne 0) { throw "Не удалось скачать $RemotePath с роутера." }
}

function Invoke-RouterScript {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string[]]$Arguments = @()
    )
    $local = Join-Path $script:RouterDir $Name
    if (-not (Test-Path -LiteralPath $local)) { throw "Не найден компонент $local" }
    $remote = '/tmp/pwsetup/' + $Name
    Copy-ToRouter $local $remote
    $safeArgs = @()
    foreach ($argument in $Arguments) {
        if ($argument -notmatch '^[a-zA-Z0-9_.-]+$') { throw "Небезопасный аргумент: $argument" }
        $safeArgs += $argument
    }
    $command = 'sh {0} {1}' -f $remote, ($safeArgs -join ' ')
    Invoke-Ssh $command
}

function Remove-EphemeralKey {
    if ($script:Connected -and $script:SshMarker) {
        $marker = $script:SshMarker
        $command = "sed -i '/$marker`$/d' /etc/dropbear/authorized_keys 2>/dev/null || true"
        try { [void](Invoke-Ssh -Command $command -AllowFailure) } catch { }
    }
    $script:Connected = $false
}

function Initialize-SshSession {
    Assert-Command ssh
    Assert-Command scp
    Assert-Command ssh-keygen

    Remove-EphemeralKey
    $keyDir = Join-Path $script:SessionRoot 'ssh'
    New-Item -ItemType Directory -Force $keyDir | Out-Null
    $script:SshKey = Join-Path $keyDir 'id_ed25519'
    $script:SshMarker = 'pwsetup-' + [guid]::NewGuid().ToString('N')

    $keyHelper = Join-Path $script:Root 'windows\New-EphemeralSshKey.ps1'
    if (-not (Test-Path -LiteralPath $keyHelper)) { throw 'Не найден компонент создания временного SSH-ключа.' }
    & $keyHelper -KeyPath $script:SshKey -Comment $script:SshMarker

    Write-Color 'Сейчас SSH один раз попросит пароль root и подтверждение ключа хоста.' Yellow
    Write-Host
    $target = '{0}@{1}' -f $script:RouterUser, $script:RouterHost
    Get-Content -Raw ($script:SshKey + '.pub') |
        & ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 $target "umask 077; mkdir -p /etc/dropbear; cat >> /etc/dropbear/authorized_keys"
    if ($LASTEXITCODE -ne 0) { throw 'Не удалось авторизоваться на роутере.' }

    $script:Connected = $true
    $result = Invoke-Ssh -Command 'echo PWSETUP_SSH_OK' -Capture
    if (($result -join "`n") -notmatch 'PWSETUP_SSH_OK') { throw 'Проверка временного SSH-ключа не прошла.' }
}

function Select-Profile {
    Write-Banner
    Write-Color 'Выберите платформу вручную:' White
    Write-Host
    Write-Color '  [1] ' Gray -NoNewline
    Write-Color 'Cudy WR3000H / WR3000S' Green -NoNewline
    Write-Color '  - ARM64, UPX, zram 256 МБ' DarkGray
    Write-Color '  [2] ' Gray -NoNewline
    Write-Color 'x86_64' Green -NoNewline
    Write-Color '                    - обычный Xray, без UPX/zram' DarkGray
    Write-Host
    do { $choice = (Read-Host 'Ваш выбор [1/2]').Trim() } until ($choice -in @('1', '2'))
    if ($choice -eq '1') { $script:Profile = 'cudy' } else { $script:Profile = 'x86' }
}

function Connect-Router {
    Select-Profile
    $hostInput = Read-Host 'Адрес роутера [192.168.1.1]'
    if ([string]::IsNullOrWhiteSpace($hostInput)) { $hostInput = '192.168.1.1' }
    if ($hostInput -notmatch '^[a-zA-Z0-9.:-]+$') { throw 'Некорректный адрес роутера.' }
    $script:RouterHost = $hostInput.Trim()
    $script:RouterUser = 'root'

    Initialize-SshSession
    Invoke-Ssh -Command 'rm -rf /tmp/pwsetup; mkdir -p /tmp/pwsetup/packages'
    Invoke-RouterScript -Name 'preflight.sh' -Arguments @($script:Profile)
    Write-Color 'Платформа и версия OpenWrt подтверждены.' Green
}

function Get-PassWallInstallationState {
    $local = Join-Path $script:RouterDir 'check-existing.sh'
    $remote = '/tmp/pwsetup/check-existing.sh'
    Copy-ToRouter $local $remote
    $command = "sh $remote $($script:Profile); code=`$?; echo PWSETUP_CHECK_EXIT=`$code; exit 0"
    $output = Invoke-Ssh -Command $command -Capture
    $text = ($output -join "`n")

    function Read-StateField([string]$Name) {
        $match = [regex]::Match($text, '(?m)^' + [regex]::Escape($Name) + '=(.*)$')
        if ($match.Success) { return $match.Groups[1].Value.Trim() }
        return ''
    }

    $exitText = Read-StateField 'PWSETUP_CHECK_EXIT'
    if ($exitText -notmatch '^\d+$') {
        throw "Проверка существующей установки вернула непонятный результат.`n$text"
    }
    $exitCode = [int]$exitText
    if ($exitCode -notin @(0, 10, 11)) {
        throw "Не удалось проверить существующую установку (код $exitCode).`n$text"
    }

    return [pscustomobject]@{
        Complete = ($exitCode -eq 0)
        Clean = ($exitCode -eq 10)
        Incomplete = ($exitCode -eq 11)
        PassWallVersion = Read-StateField 'PASSWALL_VERSION'
        XrayVersion = Read-StateField 'XRAY_VERSION'
        NodeCount = Read-StateField 'NODE_COUNT'
        SubscriptionCount = Read-StateField 'SUBSCRIPTION_COUNT'
        Missing = Read-StateField 'MISSING'
        Managed = Read-StateField 'MANAGED_BY_PWSETUP'
    }
}

function Get-ProxyCleanupInventory {
    param([ValidateSet('conflicts', 'full')][string]$Scope)

    foreach ($name in @('cleanup-common.sh', 'inspect-cleanup.sh')) {
        Copy-ToRouter (Join-Path $script:RouterDir $name) ('/tmp/pwsetup/' + $name)
    }
    $output = Invoke-Ssh -Command "sh /tmp/pwsetup/inspect-cleanup.sh $Scope" -Capture
    $text = ($output -join "`n")

    function Read-CleanupField([string]$Name) {
        $match = [regex]::Match($text, '(?m)^' + [regex]::Escape($Name) + '=(.*)$')
        if ($match.Success) { return $match.Groups[1].Value.Trim() }
        return ''
    }

    foreach ($field in @('PACKAGE_COUNT', 'ARTIFACT_COUNT', 'HAS_TARGETS', 'SIMULATION_OK', 'PRESERVE_BLOCKED')) {
        if ((Read-CleanupField $field) -notmatch '^\d+$') {
            throw "Проверка очистки не вернула поле $field.`n$text"
        }
    }

    return [pscustomobject]@{
        Scope = $Scope
        PackageCount = [int](Read-CleanupField 'PACKAGE_COUNT')
        ArtifactCount = [int](Read-CleanupField 'ARTIFACT_COUNT')
        HasTargets = ((Read-CleanupField 'HAS_TARGETS') -eq '1')
        SimulationOk = ((Read-CleanupField 'SIMULATION_OK') -eq '1')
        PreserveBlocked = ((Read-CleanupField 'PRESERVE_BLOCKED') -eq '1')
        PreservePassWall2 = ((Read-CleanupField 'PRESERVE_PASSWALL2') -eq 'yes')
        Lines = @($output | Where-Object { ([string]$_) -notmatch '^(SCOPE|PACKAGE_COUNT|ARTIFACT_COUNT|HAS_TARGETS|SIMULATION_OK|PRESERVE_BLOCKED|PRESERVE_PASSWALL2)=' })
    }
}

function Save-AutomaticBackup {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeHost = $script:RouterHost -replace '[^a-zA-Z0-9.-]', '_'
    $folder = Join-Path $script:BackupRoot ("$safeHost-$stamp")
    New-Item -ItemType Directory -Force $folder | Out-Null
    $local = Join-Path $folder 'sysupgrade-backup.tgz'

    Write-Color 'Создаю автоматический бэкап настроек...' Cyan
    Invoke-Ssh -Command 'sysupgrade -b /tmp/pwsetup-backup.tgz && sha256sum /tmp/pwsetup-backup.tgz'
    Copy-FromRouter '/tmp/pwsetup-backup.tgz' $local
    Invoke-Ssh -Command 'rm -f /tmp/pwsetup-backup.tgz'
    $hash = (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath (Join-Path $folder 'SHA256.txt') -Value "$hash  sysupgrade-backup.tgz" -Encoding ASCII
    Write-Color "Бэкап сохранён: $local" DarkGreen
    return $local
}

function Invoke-Download {
    param([string]$Uri, [string]$Destination)
    if (Test-Path -LiteralPath $Destination) { return }
    $parent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Force $parent | Out-Null
    Write-Color "Скачиваю $(Split-Path $Destination -Leaf)..." DarkCyan
    $temporary = $Destination + '.download'
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    try {
        Invoke-WebRequest -UseBasicParsing -Headers @{ 'User-Agent' = 'PassWall2-Router-Setup' } -Uri $Uri -OutFile $temporary
        if ((Get-Item -LiteralPath $temporary).Length -lt 512) { throw "Загруженный файл слишком мал: $Destination" }
        Move-Item -LiteralPath $temporary -Destination $Destination -Force
    }
    finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

function Get-PassWallRelease {
    Write-Color 'Проверяю последний полный релиз PassWall2...' Cyan
    $releaseResponse = Invoke-RestMethod -UseBasicParsing -Headers @{ 'User-Agent' = 'PassWall2-Router-Setup' } `
        -Uri 'https://api.github.com/repos/Openwrt-Passwall/openwrt-passwall2/releases?per_page=20'
    $releases = @($releaseResponse)
    if ($releases.Count -eq 0) { throw 'GitHub не вернул список релизов PassWall2.' }

    $latest = $releases | Where-Object { -not $_.draft -and -not $_.prerelease } | Select-Object -First 1
    if (-not $latest) { throw 'GitHub не вернул ни одного стабильного релиза PassWall2.' }

    $arch = if ($script:Profile -eq 'cudy') { 'aarch64_cortex-a53' } else { 'x86_64' }
    $selection = Select-CompletePassWallRelease -Releases $releases -Architecture $arch
    $release = $selection.Release
    $tag = [string]$release.tag_name
    if ([string]::IsNullOrWhiteSpace($tag)) { throw 'GitHub не вернул тег полного релиза PassWall2.' }
    if ([string]$latest.tag_name -ne $tag) {
        Write-Color "Последний релиз $($latest.tag_name) пока не содержит полный APK-комплект для $arch." Yellow
        Write-Color "Использую последний полный релиз $tag." Yellow
    }

    $appAsset = $selection.AppAsset
    $ruAsset = $selection.RuAsset
    $bundleAsset = $selection.BundleAsset

    $releaseDir = Join-Path $script:CacheRoot (Join-Path $tag $arch)
    New-Item -ItemType Directory -Force $releaseDir | Out-Null
    $appPath = Join-Path $releaseDir $appAsset.name
    $ruPath = Join-Path $releaseDir $ruAsset.name
    $bundlePath = Join-Path $releaseDir $bundleAsset.name
    Invoke-Download $appAsset.browser_download_url $appPath
    Invoke-Download $ruAsset.browser_download_url $ruPath
    Invoke-Download $bundleAsset.browser_download_url $bundlePath

    $expanded = Join-Path $releaseDir 'packages'
    $complete = Join-Path $expanded '.complete'
    if (-not (Test-Path -LiteralPath $complete)) {
        Remove-Item -LiteralPath $expanded -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force $expanded | Out-Null
        Expand-Archive -LiteralPath $bundlePath -DestinationPath $expanded -Force
        Set-Content -LiteralPath $complete -Value $tag -Encoding ASCII
    }

    $requiredPatterns = @(
        'chinadns-ng-*.apk',
        'geoview-*.apk',
        'tcping-*.apk',
        'v2ray-geoip-*.apk',
        'v2ray-geosite-*.apk',
        'xray-core-*.apk'
    )
    $selected = @($appPath, $ruPath)
    foreach ($pattern in $requiredPatterns) {
        $file = Get-ChildItem -LiteralPath $expanded -Recurse -File -Filter $pattern | Select-Object -First 1
        if (-not $file) { throw "В комплекте PassWall2 отсутствует $pattern" }
        $selected += $file.FullName
    }

    return [pscustomobject]@{
        Tag = $tag
        Architecture = $arch
        Files = $selected
        XrayPackage = ($selected | Where-Object { (Split-Path $_ -Leaf) -like 'xray-core-*.apk' } | Select-Object -First 1)
    }
}

function Get-UpxExecutable {
    $release = Invoke-RestMethod -UseBasicParsing -Headers @{ 'User-Agent' = 'PassWall2-Router-Setup' } `
        -Uri 'https://api.github.com/repos/upx/upx/releases/latest'
    $asset = $release.assets | Where-Object { $_.name -match '^upx-.*-win64\.zip$' } | Select-Object -First 1
    if (-not $asset) { throw 'В последнем релизе UPX отсутствует win64-архив.' }
    $folder = Join-Path $script:CacheRoot (Join-Path 'upx' ([string]$release.tag_name))
    $archive = Join-Path $folder $asset.name
    Invoke-Download $asset.browser_download_url $archive
    $expanded = Join-Path $folder 'expanded'
    $complete = Join-Path $expanded '.complete'
    if (-not (Test-Path -LiteralPath $complete)) {
        Remove-Item -LiteralPath $expanded -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force $expanded | Out-Null
        Expand-Archive -LiteralPath $archive -DestinationPath $expanded -Force
        Set-Content -LiteralPath $complete -Value ([string]$release.tag_name) -Encoding ASCII
    }
    $upx = Get-ChildItem -LiteralPath $expanded -Recurse -File -Filter 'upx.exe' | Select-Object -First 1
    if (-not $upx) { throw 'Не удалось найти upx.exe после распаковки.' }
    return $upx.FullName
}

function Prepare-CudyXray {
    param([string]$XrayPackage)
    Write-Color 'Извлекаю свежий Xray и сжимаю его на компьютере...' Cyan
    Copy-ToRouter $XrayPackage '/tmp/pwsetup/xray.apk'
    Invoke-Ssh -Command 'rm -rf /tmp/pwsetup/xray-extract; mkdir -p /tmp/pwsetup/xray-extract; apk verify --allow-untrusted /tmp/pwsetup/xray.apk; apk extract --allow-untrusted --destination /tmp/pwsetup/xray-extract /tmp/pwsetup/xray.apk >/dev/null; /tmp/pwsetup/xray-extract/usr/bin/xray version | head -n 1'
    $raw = Join-Path $script:SessionRoot 'xray.raw'
    $packed = Join-Path $script:SessionRoot 'xray.upx'
    Copy-FromRouter '/tmp/pwsetup/xray-extract/usr/bin/xray' $raw
    Copy-Item -LiteralPath $raw -Destination $packed -Force

    $upx = Get-UpxExecutable
    & $upx --best --lzma $packed
    if ($LASTEXITCODE -ne 0) { throw 'UPX не смог сжать Xray.' }
    & $upx -t $packed
    if ($LASTEXITCODE -ne 0) { throw 'Проверка сжатого Xray завершилась ошибкой.' }

    $rawSize = (Get-Item -LiteralPath $raw).Length
    $packedSize = (Get-Item -LiteralPath $packed).Length
    Write-Color ('Xray: {0:N1} МБ -> {1:N1} МБ' -f ($rawSize / 1MB), ($packedSize / 1MB)) Green
    Copy-ToRouter $packed '/tmp/pwsetup/xray.upx'
    Invoke-Ssh -Command 'chmod 0755 /tmp/pwsetup/xray.upx; /tmp/pwsetup/xray.upx version | head -n 1; rm -rf /tmp/pwsetup/xray.apk /tmp/pwsetup/xray-extract'
}

function Stage-PassWallPackages {
    param($Release)
    Invoke-Ssh -Command 'rm -rf /tmp/pwsetup/packages; mkdir -p /tmp/pwsetup/packages'
    foreach ($file in $Release.Files) {
        $name = Split-Path $file -Leaf
        if ($script:Profile -eq 'cudy' -and $name -like 'xray-core-*.apk') { continue }
        Copy-ToRouter $file ('/tmp/pwsetup/packages/' + $name)
    }
}

function Apply-Routing {
    param([switch]$SkipBackup)
    if (-not $SkipBackup) { [void](Save-AutomaticBackup) }
    Write-Color 'Применяю эталонные списки маршрутизации...' Cyan
    $template = Join-Path $script:ConfigDir 'passwall2-routing.conf'
    $helper = Join-Path $script:RouterDir 'rebuild-balancer.sh'
    Copy-ToRouter $template '/tmp/pwsetup/passwall2-routing.conf'
    Copy-ToRouter $helper '/tmp/pwsetup/rebuild-balancer.sh'
    Invoke-RouterScript -Name 'apply-routing.sh'
    Write-Color 'Маршрутизация установлена. До импорта подписки прокси оставлен выключенным.' Green
}

function Import-Subscription {
    param([switch]$SkipBackup)
    if (-not $SkipBackup) { [void](Save-AutomaticBackup) }
    $routingState = Invoke-Ssh -Command "uci -q get passwall2.pwsetup_main.protocol 2>/dev/null || true" -Capture
    if (($routingState -join "`n").Trim() -ne '_shunt') {
        Write-Color 'Шаблон маршрутизации ещё не установлен — применяю его автоматически.' Yellow
        Apply-Routing -SkipBackup
    }
    Write-Color 'Адрес подписки вводится скрыто и не записывается в журнал.' DarkGray
    $secureUrl = Read-Host 'Вставьте URL подписки' -AsSecureString
    $url = Convert-SecureStringToText $secureUrl
    if ([string]::IsNullOrWhiteSpace($url)) { throw 'Адрес подписки не введён.' }
    if ($url -notmatch '^https?://') { throw 'Поддерживаются только адреса http:// и https://.' }
    $name = Read-Host 'Название подписки [My subscription]'
    if ([string]::IsNullOrWhiteSpace($name)) { $name = 'My subscription' }
    $name = ($name -replace "[\r\n]", ' ').Trim()

    $urlFile = Join-Path $script:SessionRoot 'subscription.url'
    $nameFile = Join-Path $script:SessionRoot 'subscription.name'
    [IO.File]::WriteAllText($urlFile, $url, (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText($nameFile, $name, (New-Object Text.UTF8Encoding($false)))
    try {
        Copy-ToRouter $urlFile '/tmp/pwsetup/subscription.url'
        Copy-ToRouter $nameFile '/tmp/pwsetup/subscription.name'
        Invoke-RouterScript -Name 'import-subscription.sh'
        Write-Color 'Подписка импортирована, узлы добавлены в leastPing-балансировщик.' Green
    }
    finally {
        Remove-Item -LiteralPath $urlFile, $nameFile -Force -ErrorAction SilentlyContinue
    }
}

function Install-PassWallFresh {
    $state = Get-PassWallInstallationState
    if ($state.Complete) {
        throw 'PassWall2 и Xray уже установлены. Для их безопасного обновления выберите пункт 2.'
    }
    if ($state.Incomplete) {
        throw "Найдена неполная установка PassWall2/Xray ($($state.Missing)). Автоматическая установка остановлена. Используйте пункт 7 для полной очистки либо восстановите установку вручную."
    }
    $conflicts = Get-ProxyCleanupInventory -Scope 'conflicts'
    if ($conflicts.HasTargets) {
        throw "Найдены компоненты Podkop/Forkop/старого PassWall или их остатки: пакетов $($conflicts.PackageCount), файлов $($conflicts.ArtifactCount). Сначала используйте пункт 7 — очистку конфликтов."
    }

    Write-Host
    Write-Color 'Будут изменены пакеты dnsmasq/PassWall2 и конфигурация маршрутизации.' Yellow
    Write-Color 'Соединение с интернетом может прерваться примерно на минуту.' Yellow
    $confirmation = (Read-Host 'Продолжить установку? [y/N]').Trim().ToLowerInvariant()
    if ($confirmation -notin @('y', 'д')) {
        Write-Color 'Установка отменена.' DarkYellow
        return
    }
    $release = Get-PassWallRelease
    Write-Color "Найден PassWall2 $($release.Tag), архитектура $($release.Architecture)." Green
    $backup = Save-AutomaticBackup
    Stage-PassWallPackages $release
    if ($script:Profile -eq 'cudy') { Prepare-CudyXray $release.XrayPackage }
    Invoke-RouterScript -Name 'install.sh' -Arguments @($script:Profile, 'install')
    Apply-Routing -SkipBackup
    Write-Host
    $answer = (Read-Host 'Импортировать подписку сейчас? [Y/n]').Trim().ToLowerInvariant()
    if ($answer -ne 'n') { Import-Subscription -SkipBackup }
    Write-Host
    Write-Color "Готово. Резервная копия перед установкой: $backup" Green
}

function Update-PassWall {
    $state = Get-PassWallInstallationState
    if (-not $state.Complete) {
        if ($state.Clean) {
            throw 'Это чистый роутер: обновление запрещено. Сначала выберите пункт 1 — чистую установку.'
        }
        throw "Установка PassWall2/Xray неполная ($($state.Missing)). Обновление запрещено до исправления компонентов."
    }

    Write-Host
    Write-Color "Сейчас установлено: PassWall2 $($state.PassWallVersion)" Cyan
    Write-Color "Xray: $($state.XrayVersion)" Cyan
    Write-Color "Узлов: $($state.NodeCount); подписок: $($state.SubscriptionCount)." DarkCyan
    Write-Host
    Write-Color 'Будут обновлены только PassWall2, Xray, GeoIP/GeoSite и их компоненты.' Yellow
    Write-Color 'Подписки, узлы и списки маршрутизации повторно применяться не будут.' Yellow
    Write-Color 'Соединение с интернетом может прерваться примерно на минуту.' Yellow
    $confirmation = (Read-Host 'Продолжить обновление? [y/N]').Trim().ToLowerInvariant()
    if ($confirmation -notin @('y', 'д')) {
        Write-Color 'Обновление отменено.' DarkYellow
        return
    }

    $release = Get-PassWallRelease
    Write-Color "Найден PassWall2 $($release.Tag), архитектура $($release.Architecture)." Green
    $backup = Save-AutomaticBackup
    Stage-PassWallPackages $release
    if ($script:Profile -eq 'cudy') { Prepare-CudyXray $release.XrayPackage }
    Invoke-RouterScript -Name 'install.sh' -Arguments @($script:Profile, 'update')

    $updated = Get-PassWallInstallationState
    if (-not $updated.Complete) { throw 'Пакеты установились, но итоговая проверка PassWall2/Xray не пройдена.' }
    Write-Host
    Write-Color "Обновлено: PassWall2 $($updated.PassWallVersion)" Green
    Write-Color "Xray: $($updated.XrayVersion)" Green
    Write-Color "Конфигурация сохранена: узлов $($updated.NodeCount), подписок $($updated.SubscriptionCount)." Green
    Write-Color "Резервная копия перед обновлением: $backup" DarkGreen
}

function Invoke-Diagnostics {
    Invoke-RouterScript -Name 'diagnose.sh'
}

function Invoke-ProxyCleanup {
    Write-Banner
    Write-Color 'Очистка старых прокси-компонентов' Cyan
    Write-Host
    Write-Color '  [1] ' Gray -NoNewline
    Write-Color 'Убрать конфликты, сохранить рабочий PassWall2/Xray' Green
    Write-Color '  [2] ' Gray -NoNewline
    Write-Color 'Полная очистка, включая PassWall2/Xray' Red
    Write-Color '  [0] ' Gray -NoNewline
    Write-Color 'Назад' Yellow
    Write-Host
    $choice = (Read-Host 'Ваш выбор [1/2/0]').Trim()
    if ($choice -eq '0') { return }
    if ($choice -notin @('1', '2')) { return }

    $scope = if ($choice -eq '1') { 'conflicts' } else { 'full' }
    $inventory = Get-ProxyCleanupInventory -Scope $scope
    Write-Host
    foreach ($line in $inventory.Lines) { Write-Host ([string]$line) }
    Write-Host

    if (-not $inventory.HasTargets) {
        Write-Color 'Нечего удалять: подходящие пакеты и остатки не найдены.' Green
        return
    }
    if (-not $inventory.SimulationOk) {
        throw 'Пакетный менеджер не смог построить безопасный план удаления. На роутере ничего не изменено.'
    }
    if ($inventory.PreserveBlocked) {
        throw 'План удаления затрагивает PassWall2, хотя выбран режим сохранения. Очистка заблокирована; используйте полную очистку или разберите зависимости вручную.'
    }

    Write-Color "Будет удалено пакетов: $($inventory.PackageCount); оставшихся файлов/каталогов: $($inventory.ArtifactCount)." Yellow
    Write-Color 'Системные и используемые другими пакетами зависимости принудительно не удаляются.' DarkYellow
    if ($scope -eq 'full') {
        Write-Color 'ВНИМАНИЕ: подписки, узлы и конфигурация PassWall2 тоже будут удалены.' Red
    }
    $confirmation = (Read-Host 'Для продолжения введите DELETE').Trim()
    if ($confirmation -cne 'DELETE') {
        Write-Color 'Очистка отменена.' DarkYellow
        return
    }

    $backup = Save-AutomaticBackup
    Copy-ToRouter (Join-Path $script:RouterDir 'cleanup-common.sh') '/tmp/pwsetup/cleanup-common.sh'
    $token = if ($scope -eq 'conflicts') { 'REMOVE-CONFLICTS' } else { 'REMOVE-ALL-PROXIES' }
    Invoke-RouterScript -Name 'cleanup.sh' -Arguments @($scope, $token)
    Write-Host
    Write-Color 'Очистка завершена. Firewall, DNS и LuCI перезапущены.' Green
    Write-Color "Бэкап до очистки: $backup" DarkGreen
    if ($scope -eq 'conflicts') {
        Write-Color 'PassWall2/Xray сохранены. Остальные найденные прокси-стеки удалены.' Green
    }
    else {
        Write-Color 'Теперь можно запускать пункт 1 — чистую установку.' Green
    }
}

function Show-Help {
    Write-Banner
    Write-Color 'Что делает установщик' Cyan
    Write-Host @'

  • работает только с OpenWrt 25.12.5 и новее (пакетный менеджер apk);
  • вручную выбранный профиль сверяется с реальным устройством;
  • скачивает последний официальный релиз PassWall2 с GitHub;
  • устанавливает только Xray и необходимые компоненты;
  • не устанавливает Sing-box, Hysteria и NaiveProxy;
  • на Cudy сжимает Xray через UPX на компьютере и включает zram 256 МБ;
  • на x86_64 устанавливает обычный пакет Xray без UPX и zram;
  • ставит списки маршрутизации Discord, Telegram, Google, WebRTC и другие;
  • не добавляет фильтры к подписке — импортируются все Xray-совместимые узлы;
  • отдельно обновляет PassWall2/Xray без замены подписок и маршрутизации;
  • не запускает обновление на чистом или неполностью настроенном роутере;
  • умеет удалять Podkop, Forkop, старый PassWall и их ненужные прокси-компоненты;
  • перед очисткой показывает симуляцию apk и позволяет отдельно сохранить PassWall2/Xray;
  • создаёт бэкап настроек перед установкой, обновлением и очисткой.

  Ссылка подписки содержит секретный токен. Не публикуйте её в issue или логах.
'@
    Pause-Menu
}

function Show-MainMenu {
    while ($true) {
        Write-Banner
        $profileLabel = if ($script:Profile -eq 'cudy') { 'Cudy WR3000H/S' } else { 'x86_64' }
        Write-Color "  Роутер: $($script:RouterHost)    Профиль: $profileLabel" DarkCyan
        Write-Host
        Write-Color '  [1] ' Gray -NoNewline; Write-Color 'Чистая установка PassWall2 и Xray' Green
        Write-Color '  [2] ' Gray -NoNewline; Write-Color 'Обновить существующие PassWall2 и Xray' Green
        Write-Color '  [3] ' Gray -NoNewline; Write-Color 'Добавить или заменить подписку' Green
        Write-Color '  [4] ' Gray -NoNewline; Write-Color 'Повторно применить списки маршрутизации' Green
        Write-Color '  [5] ' Gray -NoNewline; Write-Color 'Проверить состояние' Green
        Write-Color '  [6] ' Gray -NoNewline; Write-Color 'Создать бэкап настроек' Green
        Write-Color '  [7] ' Gray -NoNewline; Write-Color 'Очистить старые прокси-компоненты' Yellow
        Write-Host
        Write-Color '  [C] ' Gray -NoNewline; Write-Color 'Сменить роутер / профиль' Yellow
        Write-Color '  [H] ' Gray -NoNewline; Write-Color 'Справка' Yellow
        Write-Color '  [0] ' Gray -NoNewline; Write-Color 'Выход' Yellow
        Write-Host
        Write-Color '  ______________________________________________________________' DarkGray
        Write-Host
        $choice = (Read-Host 'Выберите пункт [1,2,3,4,5,6,7,C,H,0]').Trim().ToUpperInvariant()
        try {
            switch ($choice) {
                '1' { Install-PassWallFresh; Pause-Menu }
                '2' { Update-PassWall; Pause-Menu }
                '3' { Import-Subscription; Pause-Menu }
                '4' { Apply-Routing; Pause-Menu }
                '5' { Invoke-Diagnostics; Pause-Menu }
                '6' { [void](Save-AutomaticBackup); Pause-Menu }
                '7' { Invoke-ProxyCleanup; Pause-Menu }
                'C' { Connect-Router }
                'H' { Show-Help }
                '0' { return }
                default { }
            }
        }
        catch {
            Write-Host
            Write-Color ('Ошибка: ' + $_.Exception.Message) Red
            Pause-Menu
        }
    }
}

try {
    if (-not (Test-Path -LiteralPath $script:RouterDir) -or -not (Test-Path -LiteralPath $script:ConfigDir)) {
        throw 'Файлы проекта неполные. Запустите bootstrap.ps1 или скачайте весь репозиторий.'
    }
    Connect-Router
    Show-MainMenu
}
catch {
    Write-Host
    Write-Color ('Критическая ошибка: ' + $_.Exception.Message) Red
    Pause-Menu
}
finally {
    Remove-EphemeralKey
    Remove-Item -LiteralPath $script:SessionRoot -Recurse -Force -ErrorAction SilentlyContinue
}
