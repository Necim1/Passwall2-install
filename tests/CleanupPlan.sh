#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

mock_packages='luci-app-passwall2 luci-i18n-passwall2-ru xray-core geoview tcping v2ray-geoip v2ray-geosite podkop luci-app-podkop forkop luci-app-forkop luci-app-passwall luci-i18n-passwall-ru sing-box hysteria'

apk() {
	[ "${1:-}" = "info" ] || return 1
	printf '%s\n' $mock_packages
}

. "$root/router/cleanup-common.sh"

build_cleanup_plan conflicts
for expected in podkop luci-app-podkop forkop luci-app-forkop luci-app-passwall sing-box hysteria; do
	grep -qxF "$expected" "$cleanup_packages"
done
for preserved in luci-app-passwall2 luci-i18n-passwall2-ru xray-core geoview tcping v2ray-geoip v2ray-geosite; do
	if grep -qxF "$preserved" "$cleanup_packages"; then
		echo "Preserve plan unexpectedly removes $preserved" >&2
		exit 1
	fi
done

build_cleanup_plan full
for expected in luci-app-passwall2 luci-i18n-passwall2-ru xray-core geoview tcping v2ray-geoip v2ray-geosite; do
	grep -qxF "$expected" "$cleanup_packages"
done

mock_packages='xray-core geoview tcping v2ray-geoip v2ray-geosite'
build_cleanup_plan conflicts
for expected in xray-core geoview tcping v2ray-geoip v2ray-geosite; do
	grep -qxF "$expected" "$cleanup_packages"
done

mock_packages='busybox dnsmasq-full firewall4 luci'
build_cleanup_plan conflicts
if [ -s "$cleanup_packages" ]; then
	echo 'Clean-router plan selected unrelated system packages.' >&2
	exit 1
fi

echo 'Cleanup plan tests passed.'
