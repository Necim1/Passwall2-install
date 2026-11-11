#!/bin/sh

pw_asset_record() {
    asset=$1; role=$2
    name=$(pw_json "$asset" '@.name')
    url=$(pw_json "$asset" '@.browser_download_url')
    digest=$(pw_json "$asset" '@.digest' 2>/dev/null || true)
    size=$(pw_json "$asset" '@.size')
    case "$name" in *[!a-zA-Z0-9._+-]*|'') return 1 ;; esac
    case "$url" in https://github.com/Openwrt-Passwall/openwrt-passwall2/releases/download/*) ;; *) return 1 ;; esac
    case "$digest" in sha256:*) digest=${digest#sha256:} ;; *) return 1 ;; esac
    printf '%s\n' "$digest" | grep -Eq '^[a-f0-9]{64}$' || return 1
    pw_uint "$size" || return 1
    printf '%s|%s|%s|%s|%s\n' "$role" "$name" "$url" "$digest" "$size"
}

pw_select_release() {
    # jsonfilter emits a compact JSON object per line; no jq/Python dependency.
    metadata=$1; output=$2
    pw_json "$metadata" '@[*]' > "$PW_WORK/release-objects"
    while IFS= read -r release; do
        printf '%s\n' "$release" > "$PW_WORK/release.json"
        [ "$(pw_json "$PW_WORK/release.json" '@.draft')" = false ] || continue
        [ "$(pw_json "$PW_WORK/release.json" '@.prerelease')" = false ] || continue
        tag=$(pw_json "$PW_WORK/release.json" '@.tag_name')
        case "$tag" in ''|*[!a-zA-Z0-9._+-]*) continue ;; esac
        [ -z "${PW_RELEASE:-}" ] || [ "$PW_RELEASE" = "$tag" ] || continue
        : > "$output"
        pw_json "$PW_WORK/release.json" '@.assets[*]' > "$PW_WORK/asset-objects"
        while IFS= read -r asset; do
            printf '%s\n' "$asset" > "$PW_WORK/asset.json"
            name=$(pw_json "$PW_WORK/asset.json" '@.name')
            role=''
            case "$name" in
                luci-app-passwall2-*.$PW_FORMAT|luci-app-passwall2_*.$PW_FORMAT) role=app ;;
                luci-i18n-passwall2-ru-*.$PW_FORMAT|luci-i18n-passwall2-ru_*.$PW_FORMAT) role=ru ;;
                "packages_${PW_FORMAT}_${PW_ARCH}.zip"|"passwall_packages_${PW_FORMAT}_${PW_ARCH}.zip") role=bundle ;;
            esac
            [ -n "$role" ] || continue
            pw_asset_record "$PW_WORK/asset.json" "$role" >> "$output" || true
        done < "$PW_WORK/asset-objects"
        if [ "$(cut -d '|' -f 1 "$output" | sort -u | wc -l)" -eq 3 ]; then
            PW_TAG=$tag
            return 0
        fi
    done < "$PW_WORK/release-objects"
    return 1
}

pw_extract_bundle() {
    archive=$1
    set --
    for package in chinadns-ng geoview tcping v2ray-geoip v2ray-geosite xray-core; do
        # A single leading-* pattern matches root AND nested layouts. Separate
        # optional patterns make bsdtar fail on unmatched inclusions.
        set -- "$@" --include "*${package}[-_]*.$PW_FORMAT"
    done
    bsdtar -xf "$archive" -C "$PW_WORK/packages" "$@"
}

pw_flatten_packages() {
    find "$PW_WORK/packages" -mindepth 2 -type f -name "*.$PW_FORMAT" > "$PW_WORK/nested-packages"
    while IFS= read -r file; do
        [ ! -e "$PW_WORK/packages/${file##*/}" ] || return 1
        mv "$file" "$PW_WORK/packages/"
    done < "$PW_WORK/nested-packages"
}

pw_stream_bundle() {
    url=$1; digest=$2
    printf '%s\n' "$digest" | grep -Eq '^[a-f0-9]{64}$' || return 1
    # Only selected packages reach disk/RAM. The complete upstream ZIP is still hashed.
    mkfifo "$PW_WORK/bundle.fifo" || return 1
    sha256sum < "$PW_WORK/bundle.fifo" > "$PW_WORK/bundle.sha" &
    hash_pid=$!
    stream_status=0
    (curl --fail --location --connect-timeout 15 --max-time 900 --silent --show-error \
        --proto '=https' --proto-redir '=https' "$url" || touch "$PW_WORK/download.failed") | \
        tee "$PW_WORK/bundle.fifo" | pw_extract_bundle - || stream_status=$?
    wait "$hash_pid" || stream_status=1
    rm -f "$PW_WORK/bundle.fifo"
    [ "$stream_status" = 0 ] && [ ! -f "$PW_WORK/download.failed" ] || return 1
    [ "$(awk '{print $1}' "$PW_WORK/bundle.sha")" = "$digest" ] || return 1
    # Older archives have an architecture subdirectory. Flatten only verified packages.
    pw_flatten_packages
}

pw_fetch_release() {
    api=https://api.github.com/repos/Openwrt-Passwall/openwrt-passwall2/releases
    if [ -n "${PW_RELEASE:-}" ]; then
        pw_download "$api/tags/$PW_RELEASE" "$PW_WORK/single-release.json" || pw_die 'Cannot fetch the requested release.'
        { printf '['; cat "$PW_WORK/single-release.json"; printf ']\n'; } > "$PW_WORK/releases.json"
    else
        pw_download "$api?per_page=20" "$PW_WORK/releases.json" || pw_die 'Cannot fetch release metadata (network/GitHub API limit).'
    fi
    pw_select_release "$PW_WORK/releases.json" "$PW_WORK/assets" || \
        pw_die "No complete SHA-256-verified $PW_FORMAT release for $PW_ARCH. Nothing in PassWall2 was changed."
    pw_log "Release: $PW_TAG / $PW_ARCH / $PW_FORMAT"
    available=$(pw_free_kb "$PW_WORK")
    # Selected package payloads + one unpacked core; not the entire 50+ MiB ZIP.
    required=65536
    [ "$available" -ge "$required" ] || \
        pw_die "Staging needs at least $required KiB, available $available. Use --work-dir on USB/extroot."
    while IFS='|' read -r role name url digest size; do
        pw_log "Downloading $name"
        case "$role" in
            bundle) pw_stream_bundle "$url" "$digest" || pw_die 'Bundle download/hash verification failed.' ;;
            *) pw_download "$url" "$PW_WORK/packages/$name" "$digest" || pw_die "Download/hash verification failed: $name" ;;
        esac
    done < "$PW_WORK/assets"
    for package in chinadns-ng geoview tcping v2ray-geoip v2ray-geosite xray-core; do
        filename=$(find "$PW_WORK/packages" -maxdepth 1 -type f -name "${package}[-_]*.$PW_FORMAT" | head -n 1)
        [ -n "$filename" ] || pw_die "Missing package in release: $package"
        filename=${filename##*/}
        case "$filename" in *[!a-zA-Z0-9._+-]*) pw_die 'Unsafe package name.' ;; esac
    done
}
