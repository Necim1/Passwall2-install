#!/bin/sh
set -u

. /etc/openwrt_release
echo '=== SYSTEM ==='
echo "OpenWrt ${DISTRIB_RELEASE:-unknown} / ${DISTRIB_ARCH:-unknown}"
ubus call system board 2>/dev/null | jsonfilter -e '@.model' 2>/dev/null || true
uptime
df -h /overlay 2>/dev/null || df -h /
free -h 2>/dev/null || free

echo '=== VERSIONS ==='
apk list --installed 2>/dev/null | grep -E '^(luci-app-passwall2|xray-core|chinadns-ng|geoview|v2ray-geoip|v2ray-geosite|zram-swap)' || true
/usr/bin/xray version 2>/dev/null | head -n 1 || true
ls -lh /usr/bin/xray 2>/dev/null || true

echo '=== SERVICES ==='
pgrep -a xray 2>/dev/null || echo 'Xray: stopped'
if /etc/init.d/passwall2 enabled 2>/dev/null; then
	echo 'PassWall2 autostart: yes'
else
	echo 'PassWall2 autostart: no'
fi
echo "PassWall2 nftables lines: $(nft list table inet passwall2 2>/dev/null | wc -l)"

echo '=== SUBSCRIPTIONS AND NODES ==='
echo "Subscriptions: $(uci show passwall2 2>/dev/null | grep -c '=subscribe_list' || true)"
for node in $(uci show passwall2 2>/dev/null | sed -n 's/^passwall2\.\([^.=]*\)=nodes$/\1/p'); do
	protocol="$(uci -q get "passwall2.$node.protocol" || true)"
	case "$protocol" in
		_*) continue ;;
	esac
	printf '%s | %s\n' "$protocol" "$(uci -q get "passwall2.$node.remarks" || true)"
done
echo "Balancer members: $(uci -q get passwall2.pwsetup_balancer.balancing_node 2>/dev/null | wc -w)"

echo '=== ROUTES ==='
for rule in Discord Telegram Google WebRTC_Proxy; do
	value="$(uci -q get "passwall2.pwsetup_main.$rule" || true)"
	printf '%s -> %s\n' "$rule" "$(uci -q get "passwall2.$value.remarks" || echo "$value")"
done

echo '=== ZRAM ==='
cat /proc/swaps 2>/dev/null || true
cat /sys/block/zram0/comp_algorithm 2>/dev/null || true

echo '=== CONFIG CHECK ==='
config="$(find /tmp/etc/passwall2 -path '*/global.json' 2>/dev/null | head -n 1)"
if [ -n "$config" ]; then
	/usr/bin/xray run -test -c "$config" 2>&1 | tail -n 5
else
	echo 'No generated Xray config found.'
fi
