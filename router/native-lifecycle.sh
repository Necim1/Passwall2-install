#!/bin/sh

pw_validate_install_mode() {
    case "$PW_COMMAND" in
        install)
            if pw_pm_has luci-app-passwall2 || [ -s /etc/config/passwall2 ]; then
                pw_die 'Existing PassWall2 data found. Use update or restore; installation will not overwrite it.'
            fi
            ;;
        update)
            pw_pm_has luci-app-passwall2 && [ -x /usr/bin/xray ] && [ -s /etc/config/passwall2 ] || \
                pw_die 'Update requires a complete installation. After an OpenWrt upgrade, use restore.'
            ;;
        restore)
            [ -s /etc/config/passwall2 ] || \
                pw_die 'No saved PassWall2 configuration. Restore your settings backup first, or choose a fresh install.'
            ;;
        *) pw_die 'Unknown package operation.' ;;
    esac
    if [ "$PW_COMMAND" != install ]; then
        uci -q show passwall2 >/dev/null || pw_die 'Saved PassWall2 configuration is invalid; packages were not changed.'
        [ "$(uci -q get passwall2.@global[0] || true)" = global ] || \
            pw_die 'Saved PassWall2 configuration has no global section; packages were not changed.'
    fi
    PW_HAD_INIT=0
    [ ! -x /etc/init.d/passwall2 ] || PW_HAD_INIT=1
}

pw_capture_service_intent() {
    PW_DESIRED_ENABLED=$PW_WAS_ENABLED
    PW_DESIRED_RUNNING=$PW_WAS_RUNNING
    if [ "$PW_COMMAND" = restore ]; then
        saved_enabled=$(uci -q get passwall2.@global[0].enabled || true)
        # A firmware upgrade can remove the init script and rc.d symlink. In that
        # case only the saved global enabled flag expresses the user's intent.
        if [ "$PW_HAD_INIT" = 0 ]; then
            PW_DESIRED_ENABLED=0
            [ "$saved_enabled" != 1 ] || PW_DESIRED_ENABLED=1
        fi
        PW_DESIRED_RUNNING=0
        if [ "$saved_enabled" = 1 ] && { [ "$PW_DESIRED_ENABLED" = 1 ] || [ "$PW_WAS_RUNNING" = 1 ]; }; then
            PW_DESIRED_RUNNING=1
        fi
    fi
}

pw_finish_existing_install() {
    # Package postinst hooks may create defaults. Restore before setting only the
    # managed runtime path; never import a subscription or apply routing here.
    cp -p "$PW_BACKUP/previous/etc/config/passwall2" /etc/config/passwall2
    if [ -f "$PW_BACKUP/previous/etc/config/pwsetup" ]; then
        cp -p "$PW_BACKUP/previous/etc/config/pwsetup" /etc/config/pwsetup
    fi
    uci -q revert passwall2 || true
    uci -q revert pwsetup || true
    pw_set_xray_path
    if [ "$PW_DESIRED_ENABLED" = 1 ]; then /etc/init.d/passwall2 enable
    else /etc/init.d/passwall2 disable; fi
    if [ "$PW_DESIRED_RUNNING" = 1 ]; then
        pw_health || pw_die 'Restored/updated runtime did not pass its configuration/startup check.'
    else
        /etc/init.d/passwall2 stop
    fi
    if [ "$PW_COMMAND" = restore ]; then
        pw_log 'PassWall2/Xray packages restored for the current OpenWrt. Saved nodes, subscriptions and routing were kept.'
    fi
}

pw_install_stack() {
    pw_conflicts
    pw_validate_install_mode
    if [ "$PW_COMMAND" = restore ]; then
        pw_log 'Restore reinstalls the PassWall2/Xray stack for the CURRENT firmware; old package files/kernel modules are not reused.'
        pw_log 'Other applications (for example OpenVPN) are outside this stack restore.'
    fi
    pw_confirm 'Install/update/restore PassWall2 and dependencies? Settings backup will be created.' || exit 0
    pw_backup
    pw_capture_service_intent
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
        pw_finish_existing_install
    fi
}
