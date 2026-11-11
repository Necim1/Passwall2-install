#!/bin/sh

pw_detect() {
    [ "$(id -u)" = 0 ] || pw_die 'Run as root on OpenWrt.'
    [ -r /etc/openwrt_release ] || pw_die 'OpenWrt is required (including on Raspberry Pi/x86).'
    . /etc/openwrt_release
    case "${DISTRIB_RELEASE:-}" in
        SNAPSHOT) [ "$PW_ALLOW_SNAPSHOT" = 1 ] || pw_die 'Snapshot requires --allow-snapshot and matching kernel repositories.' ;;
        *)
            printf '%s\n' "${DISTRIB_RELEASE:-}" | awk -F . '{exit !($1>24 || ($1==24 && $2>=10))}' || \
                pw_die 'OpenWrt 24.10 or newer with firewall4 is required.' ;;
    esac
    PW_ARCH=${DISTRIB_ARCH:-}
    case "$PW_ARCH" in ''|*[!a-zA-Z0-9_+-]*) pw_die 'Cannot determine the OpenWrt package architecture.' ;; esac
    if command -v apk >/dev/null 2>&1; then PW_FORMAT=apk
    elif command -v opkg >/dev/null 2>&1; then PW_FORMAT=ipk
    else pw_die 'Neither apk nor opkg was found.'; fi
    command -v fw4 >/dev/null 2>&1 || pw_die 'This installer requires firewall4/nftables.'
    for tool in uci ubus jsonfilter sha256sum; do
        command -v "$tool" >/dev/null 2>&1 || pw_die "Missing OpenWrt tool: $tool"
    done
    PW_OVERLAY=/overlay
    [ -d "$PW_OVERLAY" ] || PW_OVERLAY=/
    ram=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    flash=$(pw_free_kb "$PW_OVERLAY")
    pw_resources "$ram" "$flash" || pw_die 'At least 128 MiB physical RAM is required; smaller devices are unsupported.'
    pw_log "OpenWrt $DISTRIB_RELEASE / $PW_ARCH / $PW_FORMAT; RAM $((ram / 1024)) MiB; free overlay $((flash / 1024)) MiB"
}

pw_conflicts() {
    for service in podkop forkop farkop passwall sing-box mihomo openclash; do
        if [ -x "/etc/init.d/$service" ] && "/etc/init.d/$service" enabled >/dev/null 2>&1; then
            pw_die "Enabled proxy service '$service' may conflict. Disable/reconfigure it first; nothing is removed automatically."
        fi
    done
}

pw_configure_zram() {
    [ "$PW_ZRAM" != off ] && [ "$PW_ZRAM_MIB" -gt 0 ] || return 0
    grep -q '^/dev/zram' /proc/swaps && return 0
    # Preparation also needs memory, especially UPX on 128/256 MiB devices.
    PW_CHANGED=1
    pw_pm_add kmod-zram zram-swap
    uci set "system.@system[0].zram_size_mb=$PW_ZRAM_MIB"
    uci commit system
    /etc/init.d/zram enable
    /etc/init.d/zram start
    grep -q '^/dev/zram' /proc/swaps || pw_die 'zram did not start; low-memory preparation is not ready.'
}

pw_backup() {
    mkdir -p "$PW_BACKUP_DIR"
    chmod 0700 "$PW_BACKUP_DIR"
    PW_BACKUP="$PW_BACKUP_DIR/$(date +%Y%m%d-%H%M%S)-$$"
    mkdir "$PW_BACKUP"
    # sysupgrade follows the user's existing include list, which can include large files.
    sysupgrade -b "$PW_BACKUP/settings.tgz" || pw_die 'Settings backup failed.'
    (cd "$PW_BACKUP" && sha256sum settings.tgz > SHA256SUMS)
    for file in /etc/config/passwall2 /etc/config/pwsetup /etc/config/system /etc/config/dhcp /etc/passwall2/pwsetup-runtime /etc/crontabs/root /etc/sysupgrade.conf; do
        if [ -f "$file" ]; then
            mkdir -p "$PW_BACKUP/previous$(dirname "$file")"
            cp -p "$file" "$PW_BACKUP/previous$file"
        fi
    done
    PW_WAS_ENABLED=0; PW_WAS_RUNNING=0
    /etc/init.d/passwall2 enabled >/dev/null 2>&1 && PW_WAS_ENABLED=1
    pgrep -f '/tmp/etc/passwall2/bin/xray' >/dev/null 2>&1 && PW_WAS_RUNNING=1
    # Keep the old executable in staging, not as an extra flash-sized copy.
    if [ -x /usr/bin/xray ]; then cp -L /usr/bin/xray "$PW_WORK/previous-xray"; fi
    if [ -d /usr/libexec/pwsetup ]; then
        tar -czf "$PW_WORK/previous-helpers.tgz" -C /usr/libexec pwsetup
    fi
    pw_log "Backup: $PW_BACKUP/settings.tgz (contains private settings; copy it off the router)."
}

pw_recover() {
    [ "${PW_CHANGED:-0}" = 1 ] || return 0
    pw_log 'Attempting to restore previous settings, Xray and service state...' >&2
    /etc/init.d/passwall2 stop 2>/dev/null || true
    for file in /etc/config/passwall2 /etc/config/pwsetup /etc/config/system /etc/config/dhcp /etc/passwall2/pwsetup-runtime /etc/crontabs/root /etc/sysupgrade.conf; do
        if [ -f "$PW_BACKUP/previous$file" ]; then cp -p "$PW_BACKUP/previous$file" "$file"
        else rm -f "$file"; fi
    done
    if [ -f "$PW_WORK/previous-xray" ]; then
        cp "$PW_WORK/previous-xray" /usr/bin/xray
        chmod 0755 /usr/bin/xray
    fi
    if [ -f "$PW_WORK/previous-helpers.tgz" ]; then
        tar -xzf "$PW_WORK/previous-helpers.tgz" -C /usr/libexec
    fi
    uci -q revert passwall2 || true
    uci -q revert pwsetup || true
    uci -q revert system || true
    /etc/init.d/dnsmasq restart 2>/dev/null || true
    /etc/init.d/cron restart 2>/dev/null || true
    if [ "$PW_WAS_ENABLED" = 1 ]; then /etc/init.d/passwall2 enable 2>/dev/null || true
    else /etc/init.d/passwall2 disable 2>/dev/null || true; fi
    if [ "$PW_WAS_RUNNING" = 1 ]; then /etc/init.d/passwall2 restart 2>/dev/null || true; fi
    pw_log "Settings recovery attempted. Package versions are NOT rolled back. Backup: $PW_BACKUP" >&2
}

pw_install_helpers() {
    mkdir -p /usr/libexec/pwsetup/app/router /usr/libexec/pwsetup/app/config /etc/passwall2
    if [ "$PW_ROOT" != /usr/libexec/pwsetup/app ]; then
        cp "$PW_ROOT/install.sh" /usr/libexec/pwsetup/app/install.sh
        cp "$PW_ROOT/router/"*.sh /usr/libexec/pwsetup/app/router/
        cp "$PW_ROOT/config/passwall2-routing.conf" /usr/libexec/pwsetup/app/config/
    fi
    cp "$PW_ROOT/router/rebuild-balancer.sh" /usr/libexec/pwsetup/rebuild-balancer.sh
    chmod 0755 /usr/libexec/pwsetup/rebuild-balancer.sh
    cat > /usr/libexec/pwsetup/xray-runtime <<'RUNTIME'
#!/bin/sh
# Preserve argv[0]: PassWall2's monitor searches for its bin/xray symlink path.
if [ -r /etc/passwall2/pwsetup-runtime ]; then . /etc/passwall2/pwsetup-runtime; fi
exec -a "$0" /usr/bin/xray "$@"
RUNTIME
    chmod 0755 /usr/libexec/pwsetup/xray-runtime
    : > /etc/passwall2/pwsetup-runtime
    if [ "$PW_HEAP_MIB" -gt 0 ]; then
        printf 'export GOMEMLIMIT=%sMiB\nexport GOGC=%s\n' "$PW_HEAP_MIB" "$PW_GOGC" > /etc/passwall2/pwsetup-runtime
    fi
    chmod 0600 /etc/passwall2/pwsetup-runtime
    for path in /usr/libexec/pwsetup/ /etc/passwall2/ /etc/config/pwsetup; do
        grep -qxF "$path" /etc/sysupgrade.conf 2>/dev/null || printf '%s\n' "$path" >> /etc/sysupgrade.conf
    done
    pw_configure_zram
    pw_set_xray_path
    printf 'format=%s\narch=%s\nrelease=%s\nstorage=%s\nheap_mib=%s\n' \
        "$PW_FORMAT" "$PW_ARCH" "$PW_TAG" "$PW_STORAGE" "$PW_HEAP_MIB" > /usr/libexec/pwsetup/installation.meta
}

pw_health() {
    /etc/init.d/passwall2 restart || return 1
    attempt=0
    while [ "$attempt" -lt 20 ]; do
        config=$(find /tmp/etc/passwall2 -name global.json 2>/dev/null | head -n 1)
        if [ -n "$config" ] && pgrep -f '/tmp/etc/passwall2/bin/xray' >/dev/null 2>&1; then
            /usr/bin/xray run -test -c "$config" > "$PW_WORK/config-test.log" 2>&1 && return 0
        fi
        sleep 2
        attempt=$((attempt + 1))
    done
    return 1
}
