#!/bin/sh
set -eu

app=passwall2
balancer=pwsetup_balancer
members=''
count=0

is_subscription_group() {
	wanted="$1"
	for subscription in $(uci show "$app" | sed -n "s/^$app\.\([^.=]*\)=subscribe_list$/\1/p"); do
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
	is_subscription_group "$group" || continue
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
