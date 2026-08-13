#!/bin/sh
set -eu

stage=/tmp/pwsetup
url_file="$stage/subscription.url"
name_file="$stage/subscription.name"
section=pwsetup_sub
backup_dir=/root/pwsetup-backups
stamp="$(date +%Y%m%d-%H%M%S)"
log=/tmp/pwsetup-subscription.log
success=0
backup=''

cleanup() {
	rm -f "$url_file" "$name_file" "$log"
	if [ "$success" -ne 1 ] && [ -n "$backup" ] && [ -s "$backup" ]; then
		cp "$backup" /etc/config/passwall2
		/etc/init.d/passwall2 restart 2>/dev/null || true
	fi
}
trap cleanup 0 1 2 15

if [ ! -s "$url_file" ] || [ ! -s "$name_file" ]; then
	echo 'Subscription input files are missing.' >&2
	exit 2
fi

url="$(tr -d '\r\n' < "$url_file")"
name="$(tr -d '\r\n' < "$name_file")"
case "$url" in
	http://*|https://*) ;;
	*) echo 'Subscription URL must start with http:// or https://.' >&2; exit 3 ;;
esac
[ -n "$name" ] || name='My subscription'

mkdir -p "$backup_dir"
backup="$backup_dir/passwall2-before-subscription-$stamp"
cp -p /etc/config/passwall2 "$backup"

old_group="$(uci -q get "passwall2.$section.remark" || true)"
if [ -n "$old_group" ]; then
	for node in $(uci show passwall2 | sed -n 's/^passwall2\.\([^.=]*\)=nodes$/\1/p'); do
		protocol="$(uci -q get "passwall2.$node.protocol" || true)"
		group="$(uci -q get "passwall2.$node.group" || true)"
		case "$protocol" in
			vless|vmess|trojan|shadowsocks)
				if [ "$group" = "$old_group" ]; then
					uci delete "passwall2.$node" 2>/dev/null || true
				fi
				;;
		esac
	done
fi

uci delete "passwall2.$section" 2>/dev/null || true
uci set "passwall2.$section=subscribe_list"
uci set "passwall2.$section.remark=$name"
uci set "passwall2.$section.url=$url"
uci set "passwall2.$section.allowInsecure=0"
uci set "passwall2.$section.filter_keyword_mode=0"
uci set "passwall2.$section.ss_type=xray"
uci set "passwall2.$section.trojan_type=xray"
uci set "passwall2.$section.vmess_type=xray"
uci set "passwall2.$section.vless_type=xray"
uci set "passwall2.$section.domain_strategy=global"
uci set "passwall2.$section.user_agent=v2rayN/9.99"
uci set "passwall2.$section.access_mode=direct"
uci set "passwall2.$section.update_week_mode=7"
uci set "passwall2.$section.update_time_mode=5:00"
uci commit passwall2

rm -f "$log"
if ! lua /usr/share/passwall2/subscribe.lua start "$section" manual >"$log" 2>&1; then
	echo 'PassWall2 could not import the subscription.' >&2
	sed -E 's#https?://[^ ]+#<subscription-url-redacted>#g' "$log" | tail -n 60 >&2
	exit 4
fi

/usr/libexec/pwsetup/rebuild-balancer.sh

cron=/etc/crontabs/root
tmp_cron=/tmp/pwsetup-cron
grep -v '# pwsetup-' "$cron" 2>/dev/null > "$tmp_cron" || true
echo "0 5 * * * lua /usr/share/passwall2/subscribe.lua start $section cron >/dev/null 2>&1 # pwsetup-subscription" >> "$tmp_cron"
echo "10 5 * * * /usr/libexec/pwsetup/rebuild-balancer.sh >/tmp/pwsetup-balancer.log 2>&1 && /etc/init.d/passwall2 restart # pwsetup-balancer" >> "$tmp_cron"
cp "$tmp_cron" "$cron"
/etc/init.d/cron restart 2>/dev/null || true

rm -rf /tmp/etc/passwall2 /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null || true
/etc/init.d/passwall2 enable
/etc/init.d/passwall2 restart

attempt=0
while ! pgrep xray >/dev/null 2>&1 && [ "$attempt" -lt 15 ]; do
	sleep 3
	attempt=$((attempt + 1))
done
pgrep xray >/dev/null 2>&1 || {
	echo 'Xray did not start after subscription import.' >&2
	exit 5
}

physical=0
for node in $(uci show passwall2 | sed -n 's/^passwall2\.\([^.=]*\)=nodes$/\1/p'); do
	case "$(uci -q get "passwall2.$node.protocol" || true)" in
		vless|vmess|trojan|shadowsocks) physical=$((physical + 1)) ;;
	esac
done

success=1
echo 'SUBSCRIPTION_OK=1'
echo "PHYSICAL_NODES=$physical"
echo "BALANCER_MEMBERS=$(uci -q get passwall2.pwsetup_balancer.balancing_node | wc -w)"
echo "BACKUP=$backup_dir/passwall2-before-subscription-$stamp"
