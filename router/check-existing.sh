#!/bin/sh
set -u

profile="${1:-}"

[ "$profile" = "cudy" ] || [ "$profile" = "x86" ] || {
	echo 'STATUS=error'
	echo 'MISSING=valid_profile'
	exit 2
}

package_line="$(apk list --installed 2>/dev/null | grep '^luci-app-passwall2-' | head -n 1 || true)"
package_version="$(printf '%s\n' "$package_line" | sed -n 's/^luci-app-passwall2-\([^ ]*\).*/\1/p')"
xray_version=""
config_dump=""
missing=""
evidence=0

if [ -n "$package_line" ]; then
	evidence=1
else
	missing="${missing}passwall2_package,"
fi

if [ -x /etc/init.d/passwall2 ]; then
	evidence=1
else
	missing="${missing}passwall2_init,"
fi

if [ -s /etc/config/passwall2 ]; then
	evidence=1
	config_dump="$(uci -q show passwall2 2>/dev/null || true)"
	if ! printf '%s\n' "$config_dump" | grep -Eq '^passwall2\.[^=]+=global$'; then
		missing="${missing}valid_passwall2_config,"
	fi
else
	missing="${missing}passwall2_config,"
fi

if [ -x /usr/bin/xray ]; then
	evidence=1
	xray_version="$(/usr/bin/xray version 2>/dev/null | head -n 1 || true)"
	if [ -z "$xray_version" ]; then
		missing="${missing}working_xray,"
	fi
else
	missing="${missing}xray_binary,"
fi

missing="${missing%,}"
node_count="$(printf '%s\n' "$config_dump" | grep -c '=nodes$' || true)"
subscription_count="$(printf '%s\n' "$config_dump" | grep -c '=subscribe_list$' || true)"
managed=no
[ -s /usr/libexec/pwsetup/installation.meta ] && managed=yes

echo "PROFILE=$profile"
echo "PASSWALL_VERSION=${package_version:-unknown}"
echo "XRAY_VERSION=${xray_version:-unknown}"
echo "NODE_COUNT=${node_count:-0}"
echo "SUBSCRIPTION_COUNT=${subscription_count:-0}"
echo "MANAGED_BY_PWSETUP=$managed"

if [ -z "$missing" ]; then
	echo 'STATUS=complete'
	echo 'EXISTING_OK=1'
	exit 0
fi

echo "MISSING=$missing"
if [ "$evidence" -eq 0 ]; then
	echo 'STATUS=clean'
	exit 10
fi

echo 'STATUS=incomplete'
exit 11
