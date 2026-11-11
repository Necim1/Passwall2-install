#!/bin/sh
# Native OpenWrt entry point. Run a downloaded/reviewed project, not a network pipe.
set -eu
umask 077

PW_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$PW_ROOT/router/native-common.sh"
. "$PW_ROOT/router/native-release.sh"
. "$PW_ROOT/router/native-packages.sh"
. "$PW_ROOT/router/native-system.sh"
. "$PW_ROOT/router/native-nodes.sh"

pw_usage() {
    cat <<'HELP'
PassWall2 Router Setup — native OpenWrt installer
Usage: sh install.sh [menu|check|install|update|input|nodes|routing|backup|status|refresh] [options]
  --yes                  noninteractive confirmation (input: include all eligible nodes)
  --storage auto|full|compact
  --zram auto|off         preserve existing swap; auto adds zram on low-RAM devices
  --work-dir /mnt/usb     staging parent; default /tmp (large archives need RAM/storage)
  --backup-dir /path      persistent settings backups; default /root/pwsetup-backups
  --release TAG           select an exact PassWall2 release instead of latest complete
  --input-file /path      a private file with one HTTPS subscription or share link
  --allow-snapshot        allow a snapshot with matching configured kernel repositories
  --help
Raspberry Pi and x86 must run OpenWrt, not Raspberry Pi OS/desktop Linux.
HELP
}

PW_COMMAND=menu; PW_YES=0; PW_STORAGE_REQUEST=auto; PW_ZRAM=auto
PW_WORK_PARENT=/tmp; PW_BACKUP_DIR=/root/pwsetup-backups
PW_RELEASE=''; PW_INPUT_FILE=''; PW_ALLOW_SNAPSHOT=0
PW_CHANGED=0; PW_OWNS_LINKS=0; PW_ECHO_OFF=0
if [ "$#" -gt 0 ]; then
    case "$1" in --*) ;; *) PW_COMMAND=$1; shift ;; esac
fi
while [ "$#" -gt 0 ]; do
    case "$1" in
        --help|-h) pw_usage; exit 0 ;;
        --yes) PW_YES=1; shift ;;
        --allow-snapshot) PW_ALLOW_SNAPSHOT=1; shift ;;
        --storage|--zram|--work-dir|--backup-dir|--release|--input-file)
            [ "$#" -ge 2 ] || pw_die "Missing value for $1"
            case "$1" in
                --storage) PW_STORAGE_REQUEST=$2 ;;
                --zram) PW_ZRAM=$2 ;;
                --work-dir) PW_WORK_PARENT=$2 ;;
                --backup-dir) PW_BACKUP_DIR=$2 ;;
                --release) PW_RELEASE=$2 ;;
                --input-file) PW_INPUT_FILE=$2 ;;
            esac
            shift 2 ;;
        *) pw_die "Unknown option: $1" ;;
    esac
done
case "$PW_COMMAND" in menu|check|install|update|input|nodes|routing|backup|status|refresh) ;; *) pw_usage; exit 2 ;; esac
case "$PW_STORAGE_REQUEST" in auto|full|compact) ;; *) pw_die 'Invalid storage mode.' ;; esac
case "$PW_ZRAM" in auto|off) ;; *) pw_die 'Invalid zram mode.' ;; esac
case "$PW_RELEASE" in *[!a-zA-Z0-9._+-]*) pw_die 'Invalid release tag.' ;; esac
for directory in "$PW_WORK_PARENT" "$PW_BACKUP_DIR"; do
    case "$directory" in /*) ;; *) pw_die 'Work/backup directories must be absolute paths.' ;; esac
    case "$directory" in *[!a-zA-Z0-9_./+-]*) pw_die 'Work/backup paths may not contain spaces or shell characters.' ;; esac
done

pw_detect
[ "$PW_COMMAND" != check ] || exit 0
if [ "$PW_COMMAND" = status ]; then
    if [ "$PW_FORMAT" = apk ]; then apk info | grep -E 'passwall2|xray' || true
    else opkg list-installed | grep -E 'passwall2|xray' || true; fi
    /usr/bin/xray version 2>/dev/null || true
    free; df -h "$PW_OVERLAY"; cat /proc/swaps
    pgrep -f '/tmp/etc/passwall2/bin/xray' || true
    exit 0
fi
if [ "$PW_COMMAND" = menu ]; then
    printf '\n1) Install\n2) Update (keep settings)\n3) Add server link / subscription\n4) Select nodes\n5) Apply routing profile\n6) Backup\n0) Exit\nChoice: '
    IFS= read -r choice
    case "$choice" in 1) PW_COMMAND=install ;; 2) PW_COMMAND=update ;; 3) PW_COMMAND=input ;;
        4) PW_COMMAND=nodes ;; 5) PW_COMMAND=routing ;; 6) PW_COMMAND=backup ;; 0) exit 0 ;; *) pw_die 'Invalid choice.' ;; esac
fi

mkdir -p /var/lock "$PW_WORK_PARENT"
mkdir /var/lock/pwsetup-native.lock 2>/dev/null || pw_die 'Another installer/refresh holds /var/lock/pwsetup-native.lock.'
printf '%s\n' "$$" > /var/lock/pwsetup-native.lock/pid
PW_WORK=$(mktemp -d "$PW_WORK_PARENT/pwsetup.XXXXXX") || {
    rm -f /var/lock/pwsetup-native.lock/pid
    rmdir /var/lock/pwsetup-native.lock
    pw_die 'Cannot create staging directory.'
}
mkdir "$PW_WORK/packages" || {
    rmdir "$PW_WORK"
    rm -f /var/lock/pwsetup-native.lock/pid
    rmdir /var/lock/pwsetup-native.lock
    pw_die 'Cannot create package staging directory.'
}
pw_finish() {
    code=$?
    trap - 0 1 2 15
    set +e
    if [ "$PW_ECHO_OFF" = 1 ]; then stty echo; fi
    if [ "$PW_OWNS_LINKS" = 1 ]; then rm -f /tmp/links.conf; fi
    if [ "$code" -ne 0 ]; then pw_recover; fi
    rm -f "$PW_WORK/input.secret" "$PW_WORK/import.log"
    rm -f /var/lock/pwsetup-native.lock/pid
    rmdir /var/lock/pwsetup-native.lock
    if [ "$code" = 0 ]; then rm -rf "$PW_WORK"
    else pw_log "Recovery files kept in private directory: $PW_WORK" >&2; fi
    exit "$code"
}
trap pw_finish 0
trap 'exit 129' 1
trap 'exit 130' 2
trap 'exit 143' 15

pw_prepare_input() {
    [ -z "$PW_INPUT_FILE" ] || return 0
    PW_INPUT_FILE="$PW_WORK/input.secret"
    printf 'Paste HTTPS subscription URL or vless/vmess/trojan/ss link (hidden): '
    if [ -t 0 ]; then stty -echo; PW_ECHO_OFF=1; fi
    IFS= read -r secret
    if [ "$PW_ECHO_OFF" = 1 ]; then stty echo; PW_ECHO_OFF=0; fi
    printf '\n'
    printf '%s\n' "$secret" > "$PW_INPUT_FILE"
    secret=''
}

pw_install_or_update() {
    pw_conflicts
    if [ "$PW_COMMAND" = install ]; then
        if pw_pm_has luci-app-passwall2 || [ -s /etc/config/passwall2 ]; then
            pw_die 'Existing PassWall2 data found. Use update; installation will not overwrite it.'
        fi
    else
        pw_pm_has luci-app-passwall2 && [ -x /usr/bin/xray ] && [ -s /etc/config/passwall2 ] || pw_die 'Update requires an existing complete installation.'
    fi
    pw_confirm 'Install/update PassWall2 and dependencies? Settings backup will be created.' || exit 0
    pw_backup
    pw_bootstrap_tools
    pw_fetch_release
    pw_measure_packages
    free_kb=$(pw_free_kb "$PW_OVERLAY")
    full_budget=$(pw_write_budget "$PW_FULL_KB" "$PW_OLD_KB" "$PW_MAX_FILE_KB")
    compact_budget=$full_budget
    if [ "$PW_STORAGE_REQUEST" = compact ] || { [ "$PW_STORAGE_REQUEST" = auto ] && [ "$free_kb" -lt "$((full_budget + 8192))" ]; }; then
        pw_prepare_compact
        compact_budget=$(pw_write_budget "$PW_COMPACT_KB" "$PW_OLD_KB" "$PW_COMPACT_MAX")
    fi
    PW_STORAGE=$(pw_choose_storage "$PW_STORAGE_REQUEST" "$free_kb" "$full_budget" "$compact_budget" 8192) || \
        pw_die 'Insufficient flash even for the selected runtime. Use extroot/USB; no PassWall2 service was stopped.'
    pw_log "Storage: $PW_STORAGE; Go memory target: $PW_HEAP_MIB MiB (0 = default); existing swap is preserved."
    pw_dependencies
    # Dependencies and backup can consume flash: do not rely on an earlier measurement.
    free_kb=$(pw_free_kb "$PW_OVERLAY")
    needed=$full_budget; [ "$PW_STORAGE" != compact ] || needed=$compact_budget
    [ "$free_kb" -ge "$((needed + 8192))" ] || pw_die 'Not enough remaining flash after dependencies; use extroot.'
    pw_install_packages
    pw_install_helpers
    if [ "$PW_COMMAND" = install ]; then
        pw_apply_routing
        pw_set_xray_path
        pw_log 'Installed. Routing remains disabled until a valid input is imported.'
        if [ -n "$PW_INPUT_FILE" ] || { [ "$PW_YES" != 1 ] && pw_confirm 'Add a server link or subscription now?'; }; then
            pw_prepare_input
            pw_import_input
        fi
    else
        # Restore the exact config after package postinst hooks, then change only our runtime path.
        cp -p "$PW_BACKUP/previous/etc/config/passwall2" /etc/config/passwall2
        pw_set_xray_path
        if [ "$PW_WAS_ENABLED" = 1 ]; then /etc/init.d/passwall2 enable
        else /etc/init.d/passwall2 disable; fi
        if [ "$PW_WAS_RUNNING" = 1 ]; then
            pw_health || pw_die 'Updated runtime did not pass its configuration/startup check.'
        else
            /etc/init.d/passwall2 stop
        fi
    fi
}

case "$PW_COMMAND" in
    install|update) pw_install_or_update ;;
    backup) pw_backup ;;
    input) pw_prepare_input; pw_backup; pw_import_input ;;
    routing)
        pw_confirm 'Apply supplied routing rules (replaces existing global routing settings)?' || exit 0
        pw_backup; pw_apply_routing
        if [ "$(uci -q get passwall2.@global[0].enabled || true)" = 1 ]; then pw_health || pw_die 'Routing configuration did not start.'; fi ;;
    nodes) pw_backup; PW_CHANGED=1; pw_select_nodes; sh /usr/libexec/pwsetup/rebuild-balancer.sh; pw_health || pw_die 'Selected nodes did not start.' ;;
    refresh) pw_refresh ;;
esac
PW_CHANGED=0
pw_log 'Done. Startup/configuration checks do not prove server reachability; test traffic from a LAN client.'
