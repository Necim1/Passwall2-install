#!/bin/sh
set -eu

profile="${1:-}"
[ "$profile" = "cudy" ] || [ "$profile" = "x86" ] || {
	echo "ERROR=unknown_profile"
	exit 2
}
[ "$(id -u)" = "0" ] || {
	echo "ERROR=root_required"
	exit 6
}
command -v apk >/dev/null 2>&1 || {
	echo "ERROR=apk_not_found"
	exit 7
}

. /etc/openwrt_release
board="$(ubus call system board 2>/dev/null | jsonfilter -e '@.board_name' 2>/dev/null || true)"
model="$(ubus call system board 2>/dev/null | jsonfilter -e '@.model' 2>/dev/null || true)"
release="${DISTRIB_RELEASE:-unknown}"
arch="${DISTRIB_ARCH:-unknown}"

version_supported() {
	awk -v version="$1" 'BEGIN {
		split(version, v, /[.-]/)
		major = v[1] + 0
		minor = v[2] + 0
		patch = v[3] + 0
		exit !((major > 25) || (major == 25 && minor > 12) || (major == 25 && minor == 12 && patch >= 5))
	}'
}

version_supported "$release" || {
	echo "ERROR=unsupported_openwrt"
	echo "RELEASE=$release"
	exit 3
}

case "$profile" in
	cudy)
		case "$board" in
			cudy,wr3000h-v1|cudy,wr3000h-v1-ubootmod|cudy,wr3000s-v1|cudy,wr3000s-v1-ubootmod) ;;
			*)
				echo "ERROR=profile_mismatch"
				echo "EXPECTED=Cudy WR3000H/WR3000S"
				echo "BOARD=$board"
				exit 4
				;;
		esac
		[ "$arch" = "aarch64_cortex-a53" ] || {
			echo "ERROR=architecture_mismatch"
			echo "EXPECTED_ARCH=aarch64_cortex-a53"
			echo "ARCH=$arch"
			exit 5
		}
		;;
	x86)
		[ "$arch" = "x86_64" ] || {
			echo "ERROR=profile_mismatch"
			echo "EXPECTED=x86_64"
			echo "BOARD=$board"
			echo "ARCH=$arch"
			exit 4
		}
		;;
esac

available_kb="$(df -Pk /overlay 2>/dev/null | awk 'NR == 2 {print $4}')"
[ -n "$available_kb" ] || available_kb="$(df -Pk / 2>/dev/null | awk 'NR == 2 {print $4}')"
if curl -fsS --connect-timeout 5 --max-time 10 https://downloads.openwrt.org/ >/dev/null 2>&1; then
	internet=yes
else
	internet=no
fi

echo "OK=1"
echo "PROFILE=$profile"
echo "MODEL=$model"
echo "BOARD=$board"
echo "RELEASE=$release"
echo "ARCH=$arch"
echo "AVAILABLE_KB=${available_kb:-0}"
echo "APK=$(command -v apk 2>/dev/null || true)"
echo "INTERNET=$internet"
