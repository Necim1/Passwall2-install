#!/bin/sh
set -eu

profile="${1:-}"
mode="${2:-install}"
stage=/tmp/pwsetup
packages="$stage/packages"
backup_dir=/root/pwsetup-backups
stamp="$(date +%Y%m%d-%H%M%S)"

[ "$profile" = "cudy" ] || [ "$profile" = "x86" ] || {
	echo "Unknown profile: $profile" >&2
	exit 2
}
[ "$mode" = "install" ] || [ "$mode" = "update" ] || {
	echo "Unknown mode: $mode" >&2
	exit 2
}
[ -f "$stage/check-existing.sh" ] || {
	echo 'Safety check is missing; refusing to change packages.' >&2
	exit 12
}

set +e
sh "$stage/check-existing.sh" "$profile" > "$stage/existing-state.txt" 2>&1
state_code=$?
set -e
cat "$stage/existing-state.txt"
if [ "$mode" = "update" ] && [ "$state_code" -ne 0 ]; then
	echo 'UPDATE_BLOCKED: PassWall2/Xray is not a complete existing installation. Choose fresh install instead.' >&2
	exit 20
fi
if [ "$mode" = "install" ] && [ "$state_code" -ne 10 ]; then
	echo 'INSTALL_BLOCKED: PassWall2 data already exists. Choose update, or repair/remove the incomplete installation first.' >&2
	exit 21
fi
[ -d "$packages" ] || {
	echo "Package staging directory is missing." >&2
	exit 3
}

mkdir -p "$backup_dir"
if [ -s /etc/config/passwall2 ]; then
	cp -p /etc/config/passwall2 "$backup_dir/passwall2-before-$mode-$stamp"
fi
if [ "$mode" = "update" ] && [ -x /usr/bin/xray ]; then
	cp -p /usr/bin/xray "$backup_dir/xray-before-update-$stamp"
fi

echo '[1/7] Updating official OpenWrt package indexes...'
apk update

echo '[2/7] Installing official dependencies...'
official_packages='coreutils coreutils-base64 coreutils-nohup coreutils-timeout curl ip-full ipset kmod-inet-diag kmod-netlink-diag kmod-nft-socket kmod-nft-tproxy kmod-tun libcap libuci-lua lua luci luci-app-package-manager luci-compat luci-lib-jsonc luci-lua-runtime luci-ssl lyaml resolveip unzip'
if [ "$profile" = "cudy" ]; then
	official_packages="$official_packages kmod-zram zram-swap"
fi
apk add $official_packages

echo '[3/7] Ensuring dnsmasq-full is installed...'
if ! apk list --installed 2>/dev/null | grep -q '^dnsmasq-full-'; then
	if ! apk --update-cache add dnsmasq-full; then
		if ! apk list --installed 2>/dev/null | grep -Eq '^dnsmasq(-full)?-'; then
			apk --update-cache add dnsmasq 2>/dev/null || true
		fi
		/etc/init.d/dnsmasq restart 2>/dev/null || true
		echo 'Could not install dnsmasq-full from the configured OpenWrt repositories.' >&2
		exit 4
	fi
	/etc/init.d/dnsmasq restart
fi

echo '[4/7] Verifying PassWall2 release packages...'
for package in "$packages"/*.apk; do
	apk verify --allow-untrusted "$package"
done

echo '[5/7] Installing the minimal PassWall2 stack...'
set -- \
	"$(find "$packages" -maxdepth 1 -name 'chinadns-ng-*.apk' | head -n 1)" \
	"$(find "$packages" -maxdepth 1 -name 'geoview-*.apk' | head -n 1)" \
	"$(find "$packages" -maxdepth 1 -name 'tcping-*.apk' | head -n 1)" \
	"$(find "$packages" -maxdepth 1 -name 'v2ray-geoip-*.apk' | head -n 1)" \
	"$(find "$packages" -maxdepth 1 -name 'v2ray-geosite-*.apk' | head -n 1)" \
	"$(find "$packages" -maxdepth 1 -name 'luci-app-passwall2-*.apk' | head -n 1)" \
	"$(find "$packages" -maxdepth 1 -name 'luci-i18n-passwall2-ru-*.apk' | head -n 1)"

for package in "$@"; do
	[ -s "$package" ] || {
		echo 'One or more required release packages are missing.' >&2
		exit 5
	}
done

if [ "$profile" = "x86" ]; then
	xray_apk="$(find "$packages" -maxdepth 1 -name 'xray-core-*.apk' | head -n 1)"
	[ -s "$xray_apk" ] || {
		echo 'The xray-core package is missing.' >&2
		exit 6
	}
	set -- "$@" "$xray_apk"
fi

/etc/init.d/passwall2 stop 2>/dev/null || true
killall xray 2>/dev/null || true
if [ "$profile" = "cudy" ] && apk list --installed 2>/dev/null | grep -q '^xray-core-'; then
	apk del xray-core 2>/dev/null || true
fi
apk add --allow-untrusted "$@"

echo '[6/7] Applying the platform-specific runtime...'
if [ "$profile" = "cudy" ]; then
	[ -x "$stage/xray.upx" ] || {
		echo 'Compressed Xray binary is missing.' >&2
		exit 7
	}
	cp "$stage/xray.upx" /usr/bin/xray
	chmod 0755 /usr/bin/xray
	/usr/bin/xray version | head -n 1
	grep -qxF '/usr/bin/xray' /etc/sysupgrade.conf 2>/dev/null || echo '/usr/bin/xray' >> /etc/sysupgrade.conf

	uci set system.@system[0].zram_size_mb='256'
	uci set system.@system[0].zram_comp_algo='lzo-rle'
	uci commit system
	/etc/init.d/zram enable
	/etc/init.d/zram restart || true
	if [ -r /sys/block/zram0/comp_algorithm ] && ! grep -q '\[lzo-rle\]' /sys/block/zram0/comp_algorithm; then
		uci set system.@system[0].zram_comp_algo='lzo'
		uci commit system
		/etc/init.d/zram restart || true
	fi
fi

mkdir -p /usr/libexec/pwsetup
grep -qxF '/usr/libexec/pwsetup/' /etc/sysupgrade.conf 2>/dev/null || echo '/usr/libexec/pwsetup/' >> /etc/sysupgrade.conf
{
	echo "profile=$profile"
	echo "last_action=$mode"
	echo "timestamp=$stamp"
	echo "passwall_version=$(apk list --installed 2>/dev/null | sed -n 's/^luci-app-passwall2-\([^ ]*\).*/\1/p' | head -n 1)"
	echo "xray_version=$(/usr/bin/xray version 2>/dev/null | head -n 1)"
} > /usr/libexec/pwsetup/installation.meta
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null || true
/etc/init.d/rpcd restart 2>/dev/null || true
/etc/init.d/uhttpd restart 2>/dev/null || true

echo '[7/7] Verifying installation...'
/usr/bin/xray version | head -n 1
apk list --installed | grep -E '^(luci-app-passwall2|chinadns-ng|geoview|v2ray-geoip|v2ray-geosite)'
if [ "$profile" = "cudy" ]; then
	ls -lh /usr/bin/xray
	cat /proc/swaps 2>/dev/null || true
fi
if [ "$mode" = "update" ]; then
	uci -q show passwall2 >/dev/null
	/etc/init.d/passwall2 restart
	echo 'UPDATE_OK=1'
else
	echo 'INSTALL_OK=1'
fi
df -h /overlay 2>/dev/null || df -h /
