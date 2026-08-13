#!/bin/sh
set -eu

scope="${1:-}"
confirmation="${2:-}"
stage=/tmp/pwsetup

case "$scope:$confirmation" in
	conflicts:REMOVE-CONFLICTS|full:REMOVE-ALL-PROXIES) ;;
	*)
		echo 'Cleanup confirmation token is invalid.' >&2
		exit 30
		;;
esac

[ -f "$stage/cleanup-common.sh" ] || {
	echo 'Cleanup planner is missing.' >&2
	exit 12
}
. "$stage/cleanup-common.sh"
build_cleanup_plan "$scope"

package_count="$(wc -l < "$cleanup_packages" | awk '{print $1}')"
artifact_count="$(wc -l < "$cleanup_artifacts" | awk '{print $1}')"
[ "$package_count" -gt 0 ] || [ "$artifact_count" -gt 0 ] || {
	echo 'Nothing to clean.'
	echo 'CLEANUP_OK=1'
	exit 0
}

before_kb="$(df -Pk /overlay 2>/dev/null | awk 'NR == 2 {print $4}')"
[ -n "$before_kb" ] || before_kb="$(df -Pk / 2>/dev/null | awk 'NR == 2 {print $4}')"

if [ "$package_count" -gt 0 ]; then
	if ! apk del --simulate $(tr '\n' ' ' < "$cleanup_packages") > "$cleanup_stage/simulation.txt" 2>&1; then
		cat "$cleanup_stage/simulation.txt" >&2
		echo 'Package removal simulation failed; nothing was changed.' >&2
		exit 31
	fi
	if [ "$scope" = "conflicts" ] && grep -q 'luci-app-passwall2' "$cleanup_stage/simulation.txt"; then
		cat "$cleanup_stage/simulation.txt" >&2
		echo 'Cleanup would remove PassWall2, so the preserve mode was blocked.' >&2
		exit 32
	fi
fi

echo '[1/5] Stopping proxy services and restoring their runtime state...'
services='podkop forkop farkop passwall zapret byedpi'
[ "$scope" = "full" ] && services="$services passwall2"
for service in $services; do
	if [ -x "/etc/init.d/$service" ]; then
		"/etc/init.d/$service" stop 2>/dev/null || true
		"/etc/init.d/$service" disable 2>/dev/null || true
	fi
done

restore_stack_dns() {
	prefix="$1"
	current_servers="$(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null || true)"
	backup_servers="$(uci -q get "dhcp.@dnsmasq[0].${prefix}_server" 2>/dev/null || true)"
	managed=0
	printf '%s\n' "$current_servers" | grep -qw '127.0.0.42' && managed=1

	if [ -n "$backup_servers" ]; then
		uci -q delete dhcp.@dnsmasq[0].server || true
		for server in $backup_servers; do
			uci -q add_list "dhcp.@dnsmasq[0].server=$server"
		done
	elif [ "$managed" -eq 1 ]; then
		uci -q del_list 'dhcp.@dnsmasq[0].server=127.0.0.42' || true
		uci -q set dhcp.@dnsmasq[0].resolvfile='/tmp/resolv.conf.d/resolv.conf.auto'
	fi

	for option in noresolv cachesize; do
		backup_value="$(uci -q get "dhcp.@dnsmasq[0].${prefix}_${option}" 2>/dev/null || true)"
		if [ -n "$backup_value" ]; then
			uci -q set "dhcp.@dnsmasq[0].${option}=$backup_value"
		elif [ "$managed" -eq 1 ]; then
			if [ "$option" = "noresolv" ]; then
				uci -q set dhcp.@dnsmasq[0].noresolv='0'
			else
				uci -q set dhcp.@dnsmasq[0].cachesize='150'
			fi
		fi
		uci -q delete "dhcp.@dnsmasq[0].${prefix}_${option}" || true
	done
	uci -q delete "dhcp.@dnsmasq[0].${prefix}_server" || true

	if [ "$prefix" = "forkop" ] || [ "$prefix" = "farkop" ]; then
		backup_notinterface="$(uci -q get "dhcp.@dnsmasq[0].${prefix}_notinterface" 2>/dev/null || true)"
		if [ -n "$backup_notinterface" ]; then
			uci -q delete dhcp.@dnsmasq[0].notinterface || true
			for interface in $backup_notinterface; do
				uci -q add_list "dhcp.@dnsmasq[0].notinterface=$interface"
			done
		fi
		uci -q delete "dhcp.@dnsmasq[0].${prefix}_notinterface" || true
		uci -q delete "dhcp.$prefix" || true
	fi
}

if command -v uci >/dev/null 2>&1; then
	restore_stack_dns podkop
	restore_stack_dns forkop
	restore_stack_dns farkop
	uci -q commit dhcp || true
fi

echo '[2/5] Removing selected packages and their no-longer-needed dependencies...'
if [ "$package_count" -gt 0 ]; then
	apk del $(tr '\n' ' ' < "$cleanup_packages")
fi

echo '[3/5] Removing named leftovers...'
while IFS= read -r path; do
	[ -n "$path" ] || continue
	rm -rf "$path"
done < "$cleanup_artifacts"

for table in PodkopTable ForkopTable FarkopTable; do
	if nft list table inet "$table" >/dev/null 2>&1; then
		nft delete table inet "$table" 2>/dev/null || true
	fi
done
for route_table in podkop forkop farkop; do
	while ip rule del table "$route_table" 2>/dev/null; do :; done
	while ip -6 rule del table "$route_table" 2>/dev/null; do :; done
	ip route flush table "$route_table" 2>/dev/null || true
	ip -6 route flush table "$route_table" 2>/dev/null || true
done
while ip -4 rule show 2>/dev/null | grep -Eq '^[[:space:]]*105:.*lookup 105'; do
	ip -4 rule del priority 105 2>/dev/null || break
done
while ip -6 rule show 2>/dev/null | grep -Eq '^[[:space:]]*105:.*lookup 105'; do
	ip -6 rule del priority 105 2>/dev/null || break
done
ip -4 route flush table 105 2>/dev/null || true
ip -6 route flush table 105 2>/dev/null || true
sed -i '/[[:space:]]podkop[[:space:]]*$/d; /[[:space:]]forkop[[:space:]]*$/d; /[[:space:]]farkop[[:space:]]*$/d' /etc/iproute2/rt_tables 2>/dev/null || true
sed -i '/podkop/d; /forkop/d; /farkop/d' /etc/crontabs/root 2>/dev/null || true
if [ "$scope" = "full" ]; then
	sed -i '\|^/usr/bin/xray$|d; \|^/usr/libexec/pwsetup/$|d' /etc/sysupgrade.conf 2>/dev/null || true
fi

echo '[4/5] Reloading firewall, DNS and LuCI...'
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null || true
/etc/init.d/firewall restart 2>/dev/null || true
/etc/init.d/dnsmasq restart 2>/dev/null || true
/etc/init.d/rpcd restart 2>/dev/null || true
/etc/init.d/uhttpd restart 2>/dev/null || true

echo '[5/5] Verifying cleanup...'
build_cleanup_plan "$scope"
remaining_packages="$(wc -l < "$cleanup_packages" | awk '{print $1}')"
remaining_artifacts="$(wc -l < "$cleanup_artifacts" | awk '{print $1}')"
after_kb="$(df -Pk /overlay 2>/dev/null | awk 'NR == 2 {print $4}')"
[ -n "$after_kb" ] || after_kb="$(df -Pk / 2>/dev/null | awk 'NR == 2 {print $4}')"
freed_kb=0
if [ -n "$before_kb" ] && [ -n "$after_kb" ]; then
	freed_kb=$((after_kb - before_kb))
fi

echo "REMAINING_PACKAGES=$remaining_packages"
echo "REMAINING_ARTIFACTS=$remaining_artifacts"
echo "FREED_KB=$freed_kb"
if [ "$remaining_packages" -ne 0 ] || [ "$remaining_artifacts" -ne 0 ]; then
	echo 'Cleanup verification found remaining targets.' >&2
	exit 33
fi
echo 'CLEANUP_OK=1'
