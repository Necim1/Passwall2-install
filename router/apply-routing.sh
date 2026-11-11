#!/bin/sh
set -eu

stage="${PWSETUP_STAGE:-/tmp/pwsetup}"
template="$stage/passwall2-routing.conf"
rebuild_source="$stage/rebuild-balancer.sh"
backup_dir=/root/pwsetup-backups
stamp="$(date +%Y%m%d-%H%M%S)"
work=/tmp/pwsetup-routing

[ -s "$template" ] || {
	echo 'Routing template is missing.' >&2
	exit 2
}
[ -s "$rebuild_source" ] || {
	echo 'Balancer helper is missing.' >&2
	exit 3
}

rm -rf "$work"
mkdir -p "$work" "$backup_dir" /usr/libexec/pwsetup

if [ -s /etc/config/passwall2 ]; then
	cp -p /etc/config/passwall2 "$backup_dir/passwall2-before-routing-$stamp"
	awk 'BEGIN { RS=""; ORS="\n\n" }
		/^config subscribe_list/ { print; next }
		/^config acl_rule/ { print; next }
		/^config nodes/ && $0 !~ /option protocol '\''_(shunt|balancing)'\''/ { print }
	' /etc/config/passwall2 > "$work/preserved.conf"
fi

cp "$template" "$work/passwall2"
if [ -s "$work/preserved.conf" ]; then
	printf '\n' >> "$work/passwall2"
	cat "$work/preserved.conf" >> "$work/passwall2"
fi

mkdir -p "$work/uci"
cp "$work/passwall2" "$work/uci/passwall2"
uci -c "$work/uci" show passwall2 >/dev/null

/etc/init.d/passwall2 stop 2>/dev/null || true
cp "$work/passwall2" /etc/config/passwall2
chmod 0600 /etc/config/passwall2
if [ -x /usr/libexec/pwsetup/xray-runtime ]; then
	uci set passwall2.@global_app[0].xray_file='/usr/libexec/pwsetup/xray-runtime'
	uci commit passwall2
fi
cp "$rebuild_source" /usr/libexec/pwsetup/rebuild-balancer.sh
chmod 0755 /usr/libexec/pwsetup/rebuild-balancer.sh
rm -rf /tmp/etc/passwall2 /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null || true

if /usr/libexec/pwsetup/rebuild-balancer.sh >/tmp/pwsetup-rebuild.log 2>&1; then
	/etc/init.d/passwall2 enable
	/etc/init.d/passwall2 restart
	echo 'RUNTIME=started'
else
	uci set passwall2.@global[0].enabled='0'
	uci commit passwall2
	echo 'RUNTIME=waiting_for_subscription'
fi

echo "ROUTING_OK=1"
echo "RULES=$(uci show passwall2 | grep -c '=shunt_rules')"
echo "SUBSCRIPTIONS=$(uci show passwall2 | grep -c '=subscribe_list' || true)"
echo "BACKUP=$backup_dir/passwall2-before-routing-$stamp"
