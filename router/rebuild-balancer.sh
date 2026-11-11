#!/bin/sh
set -eu

app=passwall2
balancer=pwsetup_balancer
members=''
count=0

is_subscription_group() {
	wanted="$1"
	for subscription in $(uci show "$app" | sed -n "s/^$app\.\([^.=]*\)=subscribe_list$/\1/p"); do
		[ "$(uci -q get "$app.$subscription.enabled" || true)" != 0 ] || continue
		[ "$(uci -q get "$app.$subscription.remark" || true)" = "$wanted" ] && return 0
	done
	return 1
}

for node in $(uci show "$app" | sed -n "s/^$app\.\([^.=]*\)=nodes$/\1/p"); do
	protocol="$(uci -q get "$app.$node.protocol" || true)"
	case "$protocol" in
		vless|vmess|trojan|shadowsocks) ;;
		*) continue ;;
	esac
	group="$(uci -q get "$app.$node.group" || true)"
	case "$group" in
		pwsetup-link-*) ;;
		*) is_subscription_group "$group" || continue ;;
	esac
	[ "$(uci -q get "$app.$node.type" || true)" = Xray ] || continue
	remarks="$(uci -q get "$app.$node.remarks" || true)"
	# Lua UCI preserves list entries containing spaces and avoids eval/word splitting.
	command -v lua >/dev/null 2>&1 || { echo 'Lua is required for node exclusions.' >&2; exit 3; }
	filter_status=0
	lua - "$remarks" <<'FILTER' || filter_status=$?
local uci = require("uci").cursor()
local excluded = uci:get("pwsetup", "main", "excluded_names") or {}
if type(excluded) == "string" then excluded = {excluded} end
for _, name in ipairs(excluded) do if name == arg[1] then os.exit(0) end end
os.exit(10)
FILTER
	case "$filter_status" in
		0) continue ;;
		10) ;;
		*) echo 'Cannot evaluate saved node exclusions; balancer unchanged.' >&2; exit 3 ;;
	esac
	members="${members}${members:+ }$node"
	count=$((count + 1))
done

[ "$count" -gt 0 ] || {
	echo 'No Xray-compatible subscription nodes were found.' >&2
	exit 2
}

uci delete "$app.$balancer.balancing_node" 2>/dev/null || true
for node in $members; do
	uci add_list "$app.$balancer.balancing_node=$node"
done
uci set "$app.@global[0].node=pwsetup_main"
uci set "$app.@global[0].enabled=1"
uci commit "$app"

echo "BALANCER_MEMBERS=$count"
