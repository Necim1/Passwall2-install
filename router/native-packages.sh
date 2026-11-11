#!/bin/sh

pw_pm_has() {
    if [ "$PW_FORMAT" = apk ]; then apk info -e "$1" >/dev/null 2>&1
    else opkg status "$1" 2>/dev/null | grep -q '^Status: .* installed$'; fi
}

pw_pm_add() {
    if [ "$PW_FORMAT" = apk ]; then apk add "$@"; else opkg install "$@"; fi
}

pw_bootstrap_tools() {
    pw_log 'Installing tools from the configured OpenWrt repositories...'
    if [ "$PW_FORMAT" = apk ]; then apk update; else opkg update; fi
    pw_pm_add ca-bundle curl unzip lua luci-lib-jsonc bsdtar libcap
    pw_configure_zram
}

pw_unpack_package() {
    package=$1; destination=$2
    mkdir -p "$destination"
    if [ "$PW_FORMAT" = apk ]; then
        apk verify --allow-untrusted "$package" >/dev/null || return 1
        apk extract --allow-untrusted --destination "$destination" "$package" >/dev/null || return 1
    else
        # OpenWrt IPKs are outer tar archives containing data.tar.gz.
        mkdir -p "$PW_WORK/ipk"
        rm -f "$PW_WORK/ipk/data.tar.gz"
        tar -xzf "$package" -C "$PW_WORK/ipk" ./data.tar.gz 2>/dev/null || \
            tar -xzf "$package" -C "$PW_WORK/ipk" data.tar.gz || return 1
        tar -xzf "$PW_WORK/ipk/data.tar.gz" -C "$destination" || return 1
        rm -f "$PW_WORK/ipk/data.tar.gz"
    fi
}

pw_measure_packages() {
    PW_FULL_KB=0; PW_OTHER_KB=0; PW_OLD_KB=0; PW_MAX_FILE_KB=0; PW_MAX_OTHER_KB=0
    for package in "$PW_WORK/packages/"*.$PW_FORMAT; do
        rm -rf "$PW_WORK/extract"
        pw_unpack_package "$package" "$PW_WORK/extract" || pw_die "Invalid package: ${package##*/}"
        installed_kb=$(du -sk "$PW_WORK/extract" | awk '{print $1}')
        PW_FULL_KB=$((PW_FULL_KB + installed_kb))
        find "$PW_WORK/extract" -type f > "$PW_WORK/extracted-files"
        while IFS= read -r new_file; do
            relative=${new_file#"$PW_WORK/extract"}
            size=$(du -k "$new_file" | awk '{print $1}')
            [ "$size" -le "$PW_MAX_FILE_KB" ] || PW_MAX_FILE_KB=$size
            case "$relative" in /usr/bin/xray) ;; *) [ "$size" -le "$PW_MAX_OTHER_KB" ] || PW_MAX_OTHER_KB=$size ;; esac
            old_file="/overlay/upper$relative"
            if [ ! -d /overlay/upper ] && [ ! -d /rom ]; then old_file=$relative; fi
            if [ -f "$old_file" ]; then
                old_size=$(du -k "$old_file" | awk '{print $1}')
                PW_OLD_KB=$((PW_OLD_KB + old_size))
            fi
        done < "$PW_WORK/extracted-files"
        case "${package##*/}" in
            xray-core[-_]*)
                [ -x "$PW_WORK/extract/usr/bin/xray" ] || pw_die 'Xray is missing from its package.'
                mv "$PW_WORK/extract/usr/bin/xray" "$PW_WORK/xray.full"
                ;;
            *) PW_OTHER_KB=$((PW_OTHER_KB + installed_kb)) ;;
        esac
    done
    rm -rf "$PW_WORK/extract"
    # Executing version separately avoids hiding a failed binary behind head's exit code.
    "$PW_WORK/xray.full" version > "$PW_WORK/xray-version" || pw_die 'This Xray binary does not run on this firmware.'
    head -n 1 "$PW_WORK/xray-version"
}

pw_prepare_compact() {
    upx_arch=$(pw_upx_arch "$PW_ARCH") || pw_die 'UPX is unavailable for this architecture. Use external storage.'
    preparation_kb=$(awk '/^MemAvailable:|^SwapFree:/ {s += $2} END {print s+0}' /proc/meminfo)
    [ "$preparation_kb" -ge 131072 ] || pw_die 'UPX preparation needs 128 MiB available RAM+swap. Stop heavy transfers; use USB staging/zram or full storage.'
    pw_pm_add xz
    pw_download https://api.github.com/repos/upx/upx/releases/latest "$PW_WORK/upx-release.json" || pw_die 'Cannot fetch UPX metadata.'
    pw_json "$PW_WORK/upx-release.json" '@.assets[*]' > "$PW_WORK/upx-assets"
    upx_record=''
    while IFS= read -r asset; do
        printf '%s\n' "$asset" > "$PW_WORK/upx-asset.json"
        name=$(pw_json "$PW_WORK/upx-asset.json" '@.name')
        case "$name" in upx-*-${upx_arch}_linux.tar.xz) ;; *) continue ;; esac
        url=$(pw_json "$PW_WORK/upx-asset.json" '@.browser_download_url')
        case "$url" in https://github.com/upx/upx/releases/download/*) ;; *) continue ;; esac
        digest=$(pw_json "$PW_WORK/upx-asset.json" '@.digest' 2>/dev/null || true)
        case "$digest" in sha256:*) digest=${digest#sha256:} ;; *) continue ;; esac
        pw_download "$url" "$PW_WORK/upx.tar.xz" "$digest" || pw_die 'UPX SHA-256 verification failed.'
        upx_record=ok; break
    done < "$PW_WORK/upx-assets"
    [ "$upx_record" = ok ] || pw_die 'No verified UPX build for this CPU.'
    mkdir -p "$PW_WORK/upx"
    xz -dc "$PW_WORK/upx.tar.xz" | tar -xf - -C "$PW_WORK/upx"
    upx=$(find "$PW_WORK/upx" -type f -name upx | head -n 1)
    [ -n "$upx" ] || pw_die 'UPX executable is missing.'
    chmod 0755 "$upx"
    cp "$PW_WORK/xray.full" "$PW_WORK/xray.compact"
    # Fast compression avoids the large preparation cost of --best --lzma on low-RAM CPUs.
    "$upx" -1 "$PW_WORK/xray.compact" || pw_die 'UPX cannot compress this Xray build.'
    "$upx" -t "$PW_WORK/xray.compact" || pw_die 'UPX integrity test failed.'
    "$PW_WORK/xray.compact" version > "$PW_WORK/compact-version" || pw_die 'Compressed Xray cannot run on this CPU.'
    cmp "$PW_WORK/xray-version" "$PW_WORK/compact-version" || pw_die 'Compressed Xray version mismatch.'
    compact_xray_kb=$(du -k "$PW_WORK/xray.compact" | awk '{print $1}')
    PW_COMPACT_KB=$((PW_OTHER_KB + compact_xray_kb))
    PW_COMPACT_MAX=$compact_xray_kb
    [ "$PW_COMPACT_MAX" -ge "$PW_MAX_OTHER_KB" ] || PW_COMPACT_MAX=$PW_MAX_OTHER_KB
}

pw_dependencies() {
    pw_log 'Installing official dependencies before stopping PassWall2...'
    pw_pm_add coreutils coreutils-base64 coreutils-nohup coreutils-timeout \
        ip-full libcap libuci-lua lua luci luci-compat luci-lib-jsonc lyaml resolveip \
        kmod-nft-socket kmod-nft-tproxy kmod-tun
    if ! pw_pm_has dnsmasq-full; then
        mkdir -p "$PW_WORK/dnsmasq"
        cp /etc/config/dhcp "$PW_WORK/dnsmasq/dhcp"
        if [ "$PW_FORMAT" = apk ]; then
            apk fetch --output "$PW_WORK/dnsmasq" dnsmasq dnsmasq-full
            full=$(find "$PW_WORK/dnsmasq" -name 'dnsmasq-full-[0-9]*.apk' | head -n 1)
            plain=$(find "$PW_WORK/dnsmasq" -name 'dnsmasq-[0-9]*.apk' | head -n 1)
        else
            # Cache BOTH variants before removing DNS: recovery must not need DNS/network.
            (cd "$PW_WORK/dnsmasq" && opkg download dnsmasq dnsmasq-full)
            full=$(find "$PW_WORK/dnsmasq" -name 'dnsmasq-full_*.ipk' | head -n 1)
            plain=$(find "$PW_WORK/dnsmasq" -name 'dnsmasq_*.ipk' | head -n 1)
        fi
        [ -n "$full" ] && [ -n "$plain" ] || pw_die 'Cannot cache DNS packages for offline recovery.'
        if [ "$PW_FORMAT" = ipk ]; then
            opkg remove dnsmasq
        fi
        if ! pw_pm_add "$full" || ! /etc/init.d/dnsmasq restart; then
            pw_pm_add "$plain" || true
            cp "$PW_WORK/dnsmasq/dhcp" /etc/config/dhcp
            /etc/init.d/dnsmasq restart || true
            pw_die 'dnsmasq-full installation/startup failed; attempted offline DNS recovery.'
        fi
    fi
}

pw_install_packages() {
    set --
    for package in "$PW_WORK/packages/"*.$PW_FORMAT; do
        if [ "$PW_STORAGE" = compact ]; then
            case "${package##*/}" in xray-core[-_]*) continue ;; esac
        fi
        set -- "$@" "$package"
    done
    if [ "$PW_FORMAT" = apk ]; then
        apk add --simulate --allow-untrusted "$@"
    else
        opkg --noaction install "$@"
    fi
    if [ "$PW_STORAGE" = compact ] && pw_pm_has xray-core; then
        if [ "$PW_FORMAT" = apk ]; then apk del --simulate xray-core > "$PW_WORK/remove-xray-plan"
        else opkg --noaction remove xray-core > "$PW_WORK/remove-xray-plan"; fi
        grep -q 'luci-app-passwall2' "$PW_WORK/remove-xray-plan" && pw_die 'The installed UI requires the packaged Xray; select full storage.'
    fi
    PW_CHANGED=1
    /etc/init.d/passwall2 stop 2>/dev/null || true
    if [ "$PW_STORAGE" = compact ] && pw_pm_has xray-core; then
        if [ "$PW_FORMAT" = apk ]; then apk del xray-core; else opkg remove xray-core; fi
    fi
    if [ "$PW_FORMAT" = apk ]; then apk add --allow-untrusted "$@"; else opkg install "$@"; fi
    if [ "$PW_STORAGE" = compact ]; then
        cp "$PW_WORK/xray.compact" /usr/bin/xray.new
        chmod 0755 /usr/bin/xray.new
        mv /usr/bin/xray.new /usr/bin/xray
        grep -qxF /usr/bin/xray /etc/sysupgrade.conf 2>/dev/null || echo /usr/bin/xray >> /etc/sysupgrade.conf
    fi
}
