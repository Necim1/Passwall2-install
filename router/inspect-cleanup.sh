#!/bin/sh
set -eu

scope="${1:-}"
stage=/tmp/pwsetup
[ -f "$stage/cleanup-common.sh" ] || {
	echo 'Cleanup planner is missing.' >&2
	exit 12
}
. "$stage/cleanup-common.sh"
build_cleanup_plan "$scope"

package_count="$(wc -l < "$cleanup_packages" | awk '{print $1}')"
artifact_count="$(wc -l < "$cleanup_artifacts" | awk '{print $1}')"

echo '=== Packages selected for removal ==='
if [ "$package_count" -gt 0 ]; then
	sed 's/^/  - /' "$cleanup_packages"
else
	echo '  (none)'
fi

echo '=== Remaining files selected for removal ==='
if [ "$artifact_count" -gt 0 ]; then
	sed 's/^/  - /' "$cleanup_artifacts"
else
	echo '  (none)'
fi

simulation_ok=1
preserve_blocked=0
if [ "$package_count" -gt 0 ]; then
	echo '=== Package-manager simulation ==='
	if apk del --simulate $(tr '\n' ' ' < "$cleanup_packages") > "$cleanup_stage/simulation.txt" 2>&1; then
		cat "$cleanup_stage/simulation.txt"
	else
		simulation_ok=0
		cat "$cleanup_stage/simulation.txt"
	fi
	if [ "$scope" = "conflicts" ] && grep -q 'luci-app-passwall2' "$cleanup_stage/simulation.txt"; then
		preserve_blocked=1
	fi
fi

has_targets=0
[ "$package_count" -gt 0 ] && has_targets=1
[ "$artifact_count" -gt 0 ] && has_targets=1
echo "SCOPE=$scope"
echo "PACKAGE_COUNT=$package_count"
echo "ARTIFACT_COUNT=$artifact_count"
echo "HAS_TARGETS=$has_targets"
echo "SIMULATION_OK=$simulation_ok"
echo "PRESERVE_BLOCKED=$preserve_blocked"
echo "PRESERVE_PASSWALL2=$preserve_passwall2"
