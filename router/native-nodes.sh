#!/bin/sh

pw_apply_routing() {
    cp "$PW_ROOT/config/passwall2-routing.conf" "$PW_WORK/passwall2-routing.conf"
    cp "$PW_ROOT/router/rebuild-balancer.sh" "$PW_WORK/rebuild-balancer.sh"
    PW_CHANGED=1
    PWSETUP_STAGE="$PW_WORK" sh "$PW_ROOT/router/apply-routing.sh"
    [ ! -x /usr/libexec/pwsetup/xray-runtime ] || pw_set_xray_path
}

pw_import_input() {
    # The secret lives in a mode-600 file, never in process arguments or shell eval.
    [ -s "$PW_INPUT_FILE" ] || pw_die 'Input file is empty.'
    [ "$(wc -c < "$PW_INPUT_FILE")" -le 16384 ] || pw_die 'Input must be one URL/link, at most 16 KiB.'
    lines=$(awk 'NF {n++} END {print n+0}' "$PW_INPUT_FILE")
    [ "$lines" = 1 ] || pw_die 'Provide exactly one share link or HTTPS subscription URL.'
    input=$(tr -d '\r\n' < "$PW_INPUT_FILE")
    kind=$(pw_input_kind "$input") || pw_die 'Supported: HTTPS subscription, vless://, vmess://, trojan://, ss://.'
    [ -x /usr/bin/xray ] && [ -f /usr/share/passwall2/subscribe.lua ] || pw_die 'Install PassWall2 and Xray first.'
    uci -q get passwall2.pwsetup_main >/dev/null || pw_die 'Apply the supplied routing profile first (routing command).'
    PW_CHANGED=1
    subscribe_global=$(uci -q show passwall2 | sed -n 's/^passwall2\.\([^=]*\)=global_subscribe$/\1/p' | head -n 1)
    [ -n "$subscribe_global" ] || subscribe_global=$(uci add passwall2 global_subscribe)
    for protocol in ss trojan vmess vless; do
        uci set "passwall2.$subscribe_global.${protocol}_type=xray"
    done
    uci commit passwall2
    if [ "$kind" = subscription ]; then
        section=$(uci add passwall2 subscribe_list)
        group="pwsetup-sub-$section"
        uci set "passwall2.$section.remark=$group"
        uci set "passwall2.$section.url=$input"
        uci set "passwall2.$section.access_mode=direct"
        uci set "passwall2.$section.allowInsecure=0"
        uci set "passwall2.$section.filter_keyword_mode=0"
        for protocol in ss trojan vmess vless; do uci set "passwall2.$section.${protocol}_type=xray"; done
        uci commit passwall2
        lua /usr/share/passwall2/subscribe.lua start "$section" manual > "$PW_WORK/import.log" 2>&1 || pw_die 'Subscription importer failed; secret log is kept in the private staging directory.'
    else
        [ ! -e /tmp/links.conf ] || pw_die 'Another PassWall import owns /tmp/links.conf. Try again later.'
        group="pwsetup-link-$(date +%s)-$$"
        PW_OWNS_LINKS=1
        printf '%s\n' "$input" > /tmp/links.conf
        chmod 0600 /tmp/links.conf
        lua /usr/share/passwall2/subscribe.lua add "$group" > "$PW_WORK/import.log" 2>&1 || pw_die 'Share link importer failed.'
        rm -f /tmp/links.conf
        PW_OWNS_LINKS=0
    fi
    input=''
    imported=0
    for node in $(pw_physical_nodes); do
        [ "$(uci -q get "passwall2.$node.group" || true)" = "$group" ] && imported=$((imported + 1))
    done
    [ "$imported" -gt 0 ] || pw_die 'No usable Xray nodes imported. Previous settings will be restored.'
    pw_log "Imported Xray nodes: $imported"
    if [ "$PW_YES" != 1 ]; then pw_select_nodes; fi
    sh /usr/libexec/pwsetup/rebuild-balancer.sh
    pw_health || pw_die 'Generated configuration/startup check failed; restoring previous settings.'
    /etc/init.d/passwall2 enable
    pw_schedule
}

pw_select_nodes() {
    : > "$PW_WORK/node-menu"
    index=0
    for node in $(pw_physical_nodes); do
        index=$((index + 1))
        name=$(uci -q get "passwall2.$node.remarks" || printf '%s' "$node")
        printf '%s\n' "$node" >> "$PW_WORK/node-menu"
        printf '%s) %s\n' "$index" "$name"
    done
    [ "$index" -gt 0 ] || pw_die 'No Xray nodes found.'
    printf 'Select node numbers separated by spaces, or all [keep current selection]: '
    IFS= read -r selected || return 1
    [ -n "$selected" ] || return 0
    if [ "$selected" != all ]; then
        for number in $selected; do
            pw_uint "$number" && [ "$number" -gt 0 ] && [ "$number" -le "$index" ] || pw_die 'Invalid node selection.'
        done
    fi
    uci -q get pwsetup.main >/dev/null || uci set pwsetup.main=setup
    uci -q delete pwsetup.main.excluded_names || true
    index=0
    while IFS= read -r node; do
        index=$((index + 1))
        case " $selected " in *" $index "*|' all ') continue ;; esac
        name=$(uci -q get "passwall2.$node.remarks" || printf '%s' "$node")
        uci add_list "pwsetup.main.excluded_names=$name"
    done < "$PW_WORK/node-menu"
    uci commit pwsetup
}

pw_schedule() {
    mkdir -p /etc/crontabs
    { grep -v '# pwsetup-' /etc/crontabs/root 2>/dev/null || true
      printf '0 5 * * * /bin/sh /usr/libexec/pwsetup/app/install.sh refresh --yes >/dev/null 2>&1 # pwsetup-refresh\n'
    } > "$PW_WORK/crontab"
    cp "$PW_WORK/crontab" /etc/crontabs/root
    /etc/init.d/cron restart
}

pw_refresh() {
    # A disabled proxy must not be re-enabled by the daily maintenance task.
    [ "$(uci -q get passwall2.@global[0].enabled || true)" = 1 ] || return 0
    /etc/init.d/passwall2 enabled >/dev/null 2>&1 || return 0
    # No daily persistent backup accumulation: the recovery snapshot is in staging.
    PW_BACKUP_DIR="$PW_WORK/refresh-backup"
    pw_backup
    PW_CHANGED=1
    lua /usr/share/passwall2/subscribe.lua start all cron > "$PW_WORK/import.log" 2>&1
    sh /usr/libexec/pwsetup/rebuild-balancer.sh
    pw_health || pw_die 'Refresh failed; restoring the previous configuration.'
}
