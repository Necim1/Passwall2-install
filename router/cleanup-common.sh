#!/bin/sh

cleanup_stage=/tmp/pwsetup/cleanup-plan
cleanup_packages="$cleanup_stage/packages.txt"
cleanup_artifacts="$cleanup_stage/artifacts.txt"

add_cleanup_package() {
	name="$1"
	printf '%s\n' "$installed_packages" | grep -qxF "$name" || return 0
	grep -qxF "$name" "$cleanup_packages" 2>/dev/null || printf '%s\n' "$name" >> "$cleanup_packages"
}

add_cleanup_artifact() {
	path="$1"
	[ -e "$path" ] || [ -L "$path" ] || return 0
	grep -qxF "$path" "$cleanup_artifacts" 2>/dev/null || printf '%s\n' "$path" >> "$cleanup_artifacts"
}

build_cleanup_plan() {
	scope="$1"
	[ "$scope" = "conflicts" ] || [ "$scope" = "full" ] || return 2

	rm -rf "$cleanup_stage"
	mkdir -p "$cleanup_stage"
	: > "$cleanup_packages"
	: > "$cleanup_artifacts"
	installed_packages="$(apk info 2>/dev/null || true)"

	if printf '%s\n' "$installed_packages" | grep -qxF 'luci-app-passwall2'; then
		preserve_passwall2=yes
	else
		preserve_passwall2=no
	fi
	[ "$scope" = "full" ] && preserve_passwall2=no

	for package in $installed_packages; do
		case "$package" in
			podkop|podkop-plus|luci-app-podkop|luci-app-podkop-plus|luci-i18n-podkop-*|luci-i18n-podkop-plus-*|\
			forkop|farkop|luci-app-forkop|luci-app-farkop|luci-i18n-forkop-*|luci-i18n-farkop-*|\
			passwall|passwall-server|luci-app-passwall|luci-app-passwall-server|luci-i18n-passwall-*)
				add_cleanup_package "$package"
				;;
			sing-box|hysteria|hysteria2|naiveproxy|tuic-client|dns2socks|ipt2socks|microsocks|\
			shadowsocks-libev-*|shadowsocks-rust-*|shadowsocksr-libev-*|simple-obfs|\
			v2ray-plugin|xray-plugin|shadow-tls|trojan|trojan-go|trojan-plus|brook|\
			byedpi|luci-app-byedpi|luci-i18n-byedpi-*|\
			zapret|zapret-*|zapret2|zapret2-*|luci-app-zapret|luci-app-zapret-*|luci-app-zapret2|luci-app-zapret2-*|\
			luci-i18n-zapret-*|luci-i18n-zapret2-*|nfqws)
				add_cleanup_package "$package"
				;;
		esac
		if [ "$scope" = "full" ]; then
			case "$package" in
				luci-app-passwall2|luci-i18n-passwall2-*) add_cleanup_package "$package" ;;
			esac
		fi
		if [ "$preserve_passwall2" = "no" ]; then
			case "$package" in
				xray-core|v2ray-core|v2ray-geodata|v2ray-geoip|v2ray-geosite|chinadns-ng|geoview|tcping)
					add_cleanup_package "$package"
					;;
			esac
		fi
	done

	for path in \
		/etc/config/podkop /etc/init.d/podkop /etc/podkop /usr/bin/podkop /usr/lib/podkop /usr/share/podkop /tmp/podkop /var/run/podkop \
		/etc/config/forkop /etc/init.d/forkop /etc/forkop /usr/bin/forkop /usr/lib/forkop /usr/share/forkop /tmp/forkop /var/run/forkop \
		/etc/config/farkop /etc/init.d/farkop /etc/farkop /usr/bin/farkop /usr/lib/farkop /usr/share/farkop /tmp/farkop /var/run/farkop \
		/etc/config/passwall /etc/config/passwall_server /etc/init.d/passwall /usr/share/passwall /usr/libexec/passwall /tmp/etc/passwall /tmp/passwall \
		/www/luci-static/resources/view/podkop /www/luci-static/resources/view/forkop /www/luci-static/resources/view/farkop \
		/www/luci-static/resources/view/passwall /usr/share/luci/menu.d/luci-app-podkop.json \
		/usr/share/luci/menu.d/luci-app-forkop.json /usr/share/luci/menu.d/luci-app-farkop.json \
		/usr/share/luci/menu.d/luci-app-passwall.json /usr/share/rpcd/acl.d/luci-app-podkop.json \
		/usr/share/rpcd/acl.d/luci-app-forkop.json /usr/share/rpcd/acl.d/luci-app-farkop.json \
		/usr/share/rpcd/acl.d/luci-app-passwall.json \
		/etc/config/sing-box /etc/sing-box /var/lib/sing-box /usr/share/sing-box /tmp/sing-box /usr/bin/sing-box \
		/etc/config/hysteria /etc/hysteria /usr/bin/hysteria /usr/bin/hysteria2 \
		/etc/config/zapret /etc/init.d/zapret /opt/zapret /usr/share/zapret /tmp/zapret /usr/bin/nfqws \
		/etc/config/byedpi /etc/init.d/byedpi /usr/share/byedpi /tmp/byedpi /usr/bin/ciadpi
	do
		add_cleanup_artifact "$path"
	done

	if [ "$preserve_passwall2" = "no" ]; then
		for path in \
			/etc/config/passwall2 /etc/init.d/passwall2 /usr/share/passwall2 /usr/libexec/passwall2 \
			/tmp/etc/passwall2 /tmp/passwall2 /www/luci-static/resources/view/passwall2 \
			/usr/share/luci/menu.d/luci-app-passwall2.json /usr/share/rpcd/acl.d/luci-app-passwall2.json \
			/usr/libexec/pwsetup /usr/bin/xray /usr/share/v2ray /usr/share/xray
		do
			add_cleanup_artifact "$path"
		done
	fi

	sort -u "$cleanup_packages" -o "$cleanup_packages"
	sort -u "$cleanup_artifacts" -o "$cleanup_artifacts"
}
