#!/bin/sh
# Shared by the router entry point and offline tests. No changes at source time.

pw_die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
pw_log() { printf '%s\n' "$*"; }
pw_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }

pw_resources() {
    # Space is checked again with actual extracted package sizes before install.
    pw_uint "$1" && pw_uint "$2" || return 2
    [ "$1" -ge 114688 ] || return 3
    PW_RAM_KB=$1
    PW_FLASH_KB=$2
    if [ "$1" -lt 196608 ]; then
        PW_HEAP_MIB=32; PW_GOGC=50; PW_ZRAM_MIB=64
    elif [ "$1" -lt 393216 ]; then
        PW_HEAP_MIB=96; PW_GOGC=50; PW_ZRAM_MIB=128
    elif [ "$1" -lt 786432 ]; then
        PW_HEAP_MIB=192; PW_GOGC=75; PW_ZRAM_MIB=0
    else
        PW_HEAP_MIB=0; PW_GOGC=100; PW_ZRAM_MIB=0
    fi
}

pw_upx_arch() {
    case "$1" in
        aarch64_*) printf 'arm64\n' ;;
        arm_*) printf 'arm\n' ;;
        x86_64) printf 'amd64\n' ;;
        i386*|i486*|i586*|i686*) printf 'i386\n' ;;
        mipsel_*) printf 'mipsel\n' ;;
        mips_*) printf 'mips\n' ;;
        *) return 1 ;;
    esac
}

pw_input_kind() {
    case "$1" in
        https://*) printf 'subscription\n' ;;
        vless://*|vmess://*|trojan://*|ss://*) printf 'link\n' ;;
        *) return 1 ;;
    esac
}

pw_choose_storage() {
    # Arguments: mode, free KiB, full install KiB, compact install KiB, reserve KiB.
    mode=$1; free_kb=$2; full_kb=$3; compact_kb=$4; reserve_kb=$5
    case "$mode" in
        auto)
            if [ "$free_kb" -ge "$((full_kb + reserve_kb))" ]; then
                printf 'full\n'
            elif [ "$free_kb" -ge "$((compact_kb + reserve_kb))" ]; then
                printf 'compact\n'
            else return 1; fi ;;
        full) [ "$free_kb" -ge "$((full_kb + reserve_kb))" ] && printf 'full\n' ;;
        compact) [ "$free_kb" -ge "$((compact_kb + reserve_kb))" ] && printf 'compact\n' ;;
        *) return 2 ;;
    esac
}

pw_write_budget() {
    # Peak additional flash: on update old files are replaced one at a time.
    # Files from read-only /rom do not count as reclaimable overlay space.
    new_kb=$1; old_kb=$2; largest_kb=$3
    if [ "$old_kb" -eq 0 ]; then printf '%s\n' "$new_kb"
    else
        growth=$((new_kb - old_kb)); [ "$growth" -ge 0 ] || growth=0
        printf '%s\n' "$((growth + largest_kb))"
    fi
}

pw_free_kb() { df -Pk "$1" | awk 'NR==2 {print $4}'; }
pw_json() { jsonfilter -i "$1" -e "$2"; }

pw_download() {
    url=$1; destination=$2; digest=${3:-}
    case "$url" in https://*) ;; *) return 2 ;; esac
    if [ -n "$digest" ]; then
        printf '%s\n' "$digest" | grep -Eq '^[a-f0-9]{64}$' || return 2
        if [ -f "$destination" ] && printf '%s  %s\n' "$digest" "$destination" | sha256sum -c - >/dev/null 2>&1; then
            return 0
        fi
    fi
    rm -f "$destination.part"
    if ! curl --fail --location --retry 2 --connect-timeout 15 --max-time 900 \
        --proto '=https' --proto-redir '=https' --silent --show-error \
        --output "$destination.part" "$url"; then
        rm -f "$destination.part"; return 1
    fi
    if [ -n "$digest" ] && ! printf '%s  %s\n' "$digest" "$destination.part" | sha256sum -c - >/dev/null 2>&1; then
        rm -f "$destination.part"; return 1
    fi
    [ -s "$destination.part" ] || { rm -f "$destination.part"; return 1; }
    mv "$destination.part" "$destination"
}

pw_confirm() {
    [ "${PW_YES:-0}" = 1 ] && return 0
    printf '%s [y/N]: ' "$1"
    IFS= read -r reply || return 1
    case "$reply" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

pw_nodes() { uci -q show passwall2 | sed -n 's/^passwall2\.\([^.=]*\)=nodes$/\1/p'; }

pw_physical_nodes() {
    for n in $(pw_nodes); do
        [ "$(uci -q get "passwall2.$n.type" || true)" = Xray ] || continue
        case "$(uci -q get "passwall2.$n.protocol" || true)" in
            vless|vmess|trojan|shadowsocks) printf '%s\n' "$n" ;;
        esac
    done
}

pw_set_xray_path() {
    app_section=$(uci -q show passwall2 | sed -n 's/^passwall2\.\([^=]*\)=global_app$/\1/p' | head -n 1)
    [ -n "$app_section" ] || app_section=$(uci add passwall2 global_app)
    uci set "passwall2.$app_section.xray_file=/usr/libexec/pwsetup/xray-runtime"
    uci commit passwall2
}
