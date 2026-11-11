"""Behavior tests with an isolated filesystem and command doubles; no router access."""
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SHELL = os.environ.get("PW_TEST_SHELL") or shutil.which("sh")
if not SHELL:
    SHELL = r"C:\Program Files\Git\bin\bash.exe"


def posix(path):
    value = str(path).replace("\\", "/")
    return "/" + value[0].lower() + value[2:] if len(value) > 1 and value[1] == ":" else value


def q(path):
    return shlex.quote(posix(path))


class NativeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pwsetup-test-")
        self.fs = Path(self.temp.name)
        for directory in ("bin", "tmp", "proc", "etc/config", "etc/init.d", "usr/bin", "usr/share/passwall2", "usr/libexec/pwsetup", "work/packages", "backup"):
            (self.fs / directory).mkdir(parents=True, exist_ok=True)
        self.env = os.environ.copy()
        self.env["PYTHONUTF8"] = "1"
        self.env["PW_TEST_PYTHON"] = posix(sys.executable)
        self.env["FAKE_ROOT"] = str(self.fs)
        # Keep command lookup inside the doubles before the real utilities.
        self.env["PATH"] = posix(self.fs / "bin") + ":" + "/usr/bin:/bin:" + self.env.get("PATH", "")
        fake = q(ROOT / "tests/fake_openwrt.py")
        for command in ("uci", "lua", "jsonfilter"):
            self.script("bin/" + command, f'exec "$PW_TEST_PYTHON" {fake} {command} "$@"\n')
        self.script("usr/bin/xray", "echo 'Xray fixture'\n")
        self.script("etc/init.d/passwall2", 'printf "%s\\n" "$*" >> "$FAKE_ROOT/service-events"\n')
        self.script("etc/init.d/dnsmasq", ":\n")
        self.script("etc/init.d/cron", ":\n")
        self.script("bin/sysupgrade", 'printf backup > "$2"\n')
        (self.fs / "usr/share/passwall2/subscribe.lua").touch()
        (self.fs / "proc/swaps").write_text("Filename Type Size Used Priority\n")
        (self.fs / "proc/meminfo").write_text("MemAvailable: 2048 kB\nSwapFree: 0 kB\n")
        self.config = self.fs / "etc/config/passwall2"
        self.initial = {"global": {".type": "global", "enabled": "0"},
                        "apps": {".type": "global_app"},
                        "subglobals": {".type": "global_subscribe"},
                        "pwsetup_main": {".type": "nodes", "protocol": "_shunt"},
                        "pwsetup_balancer": {".type": "nodes", "protocol": "_balancing"}}
        self.config.write_text(json.dumps(self.initial))
        for name in ("native-nodes.sh", "native-system.sh", "native-packages.sh"):
            text = (ROOT / "router" / name).read_text()
            # A single pass avoids rewriting /tmp again inside inserted Linux sandbox paths.
            text = re.sub(r"/(?:usr|etc|tmp|proc)/", lambda match: posix(self.fs) + match[0], text)
            (self.fs / name).write_text(text, newline="\n")
        shutil.copy(ROOT / "router/rebuild-balancer.sh", self.fs / "usr/libexec/pwsetup/rebuild-balancer.sh")

    def tearDown(self):
        self.temp.cleanup()

    def script(self, name, text):
        path = self.fs / name
        path.write_text("#!/bin/sh\n" + text, newline="\n")
        path.chmod(0o755)

    def run_sh(self, code, ok=True):
        setup = f"""set -eu
PW_WORK={q(self.fs / 'work')}
PW_ROOT={q(ROOT)}
PW_BACKUP_DIR={q(self.fs / 'backup')}
PW_YES=1; PW_ZRAM=off; PW_CHANGED=0; PW_OWNS_LINKS=0
. {q(ROOT / 'router/native-common.sh')}
. {q(ROOT / 'router/native-release.sh')}
"""
        result = subprocess.run([SHELL, "-c", setup + code], env=self.env, capture_output=True, text=True, timeout=30)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_resource_profiles(self):
        for ram, heap, swap in ((122000, 32, 64), (248000, 96, 128), (502000, 192, 0), (1000000, 0, 0)):
            with self.subTest(ram=ram):
                r = self.run_sh(f'pw_resources {ram} 50000; echo "$PW_HEAP_MIB $PW_ZRAM_MIB"')
                self.assertEqual(r.stdout.strip(), f"{heap} {swap}")
        self.assertNotEqual(self.run_sh("pw_resources 64000 50000", ok=False).returncode, 0)

    def test_storage_selection_and_rejection(self):
        for free, expected in ((100000, "full"), (40000, "compact")):
            r = self.run_sh(f"pw_choose_storage auto {free} 60000 20000 8192")
            self.assertEqual(r.stdout.strip(), expected)
        self.assertNotEqual(self.run_sh("pw_choose_storage auto 10000 60000 20000 8192", ok=False).returncode, 0)
        self.assertNotEqual(self.run_sh("pw_choose_storage full 40000 60000 20000 8192", ok=False).returncode, 0)

    def test_upx_cpu_mapping(self):
        for arch, upx in (("aarch64_cortex-a53", "arm64"), ("aarch64_cortex-a72", "arm64"),
                          ("aarch64_generic", "arm64"), ("arm_cortex-a7", "arm"),
                          ("mips_24kc", "mips"), ("mipsel_24kc", "mipsel"), ("x86_64", "amd64")):
            self.assertEqual(self.run_sh(f"pw_upx_arch {arch}").stdout.strip(), upx)
        self.assertNotEqual(self.run_sh("pw_upx_arch unknown", ok=False).returncode, 0)

    def test_flash_budget_counts_replacements(self):
        for new, old, largest, expected in ((70000, 65000, 30000, 35000), (60000, 0, 30000, 60000), (30000, 65000, 10000, 10000)):
            self.assertEqual(self.run_sh(f"pw_write_budget {new} {old} {largest}").stdout.strip(), str(expected))

    def test_broken_filter_never_enables_excluded_nodes(self):
        self.env["FILTER_FAIL"] = "1"
        data = dict(self.initial)
        data["a"] = {".type": "nodes", "type": "Xray", "protocol": "vless", "group": "pwsetup-link-test", "remarks": "Limited"}
        self.config.write_text(json.dumps(data))
        before = self.config.read_bytes()
        r = self.run_sh(f'sh {q(self.fs / "usr/libexec/pwsetup/rebuild-balancer.sh")}', ok=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.config.read_bytes(), before)

    def release(self, arch, fmt, tag="new", old=False, valid=True):
        prefix = "passwall_packages" if old else "packages"
        names = [f"luci-app-passwall2-test.{fmt}", f"luci-i18n-passwall2-ru-test.{fmt}", f"{prefix}_{fmt}_{arch}.zip"]
        return {"tag_name": tag, "draft": False, "prerelease": False, "assets": [
            {"name": name, "browser_download_url": f"https://github.com/Openwrt-Passwall/openwrt-passwall2/releases/download/{tag}/{name}",
             "digest": "sha256:" + "a" * 64 if valid else None, "size": 12345} for name in names]}

    def test_release_matrix(self):
        arches = ("aarch64_cortex-a53", "aarch64_cortex-a72", "aarch64_generic", "arm_cortex-a15_neon-vfpv4",
                  "arm_cortex-a7", "arm_cortex-a7_neon-vfpv4", "arm_cortex-a8_vfpv3", "arm_cortex-a9",
                  "mipsel_24kc", "mipsel_mips32", "mips_24kc", "mips_mips32", "x86_64")
        for arch in arches:
            for fmt in ("apk", "ipk"):
                with self.subTest(arch=arch, fmt=fmt):
                    releases = [self.release(arch, fmt, valid=False), self.release(arch, fmt, tag="old", old=True)]
                    file = self.fs / "releases.json"
                    file.write_text(json.dumps(releases))
                    r = self.run_sh(f'PW_FORMAT={fmt}; PW_ARCH={arch}; PW_RELEASE=""; pw_select_release {q(file)} "$PW_WORK/assets"; echo "$PW_TAG"')
                    self.assertEqual(r.stdout.strip(), "old")
                    self.assertEqual(len((self.fs / "work/assets").read_text().splitlines()), 3)

    def test_missing_architecture_fails(self):
        file = self.fs / "releases.json"
        file.write_text(json.dumps([self.release("x86_64", "apk")]))
        r = self.run_sh(f'PW_FORMAT=apk; PW_ARCH=mips_unknown; pw_select_release {q(file)} "$PW_WORK/assets"', ok=False)
        self.assertNotEqual(r.returncode, 0)

    def test_hash_and_cache_are_verified(self):
        source = self.fs / "source"
        source.write_bytes(b"verified payload")
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        curl = f'curl() {{ while [ "$1" != --output ]; do shift; done; cp {q(source)} "$2"; }}\n'
        self.run_sh(curl + f'pw_download https://fixture.invalid/a "$PW_WORK/result" {digest}')
        self.assertEqual((self.fs / "work/result").read_bytes(), source.read_bytes())
        self.run_sh('curl() { return 99; }; ' + f'pw_download https://fixture.invalid/a "$PW_WORK/result" {digest}')
        (self.fs / "work/result").write_text("corrupt cache")
        r = self.run_sh('curl() { return 99; }; ' + f'pw_download https://fixture.invalid/a "$PW_WORK/result" {digest}', ok=False)
        self.assertNotEqual(r.returncode, 0)
        r = self.run_sh(curl + 'pw_download https://fixture.invalid/a "$PW_WORK/bad" ' + '0' * 64, ok=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse((self.fs / "work/bad").exists())
        self.assertFalse((self.fs / "work/bad.part").exists())

    def bundle_fixture(self):
        bsdtar = shutil.which("bsdtar")
        if not bsdtar and os.name == "nt" and Path(r"C:\Windows\System32\tar.exe").exists():
            bsdtar = r"C:\Windows\System32\tar.exe"
        if not bsdtar:
            self.skipTest("bsdtar is not installed")
        self.script("bin/bsdtar", f'exec {q(bsdtar)} "$@"\n')
        archive = self.fs / "bundle.zip"
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as bundle:
            for name in ("xray-core", "geoview", "tcping", "chinadns-ng", "v2ray-geoip", "v2ray-geosite", "sing-box"):
                bundle.writestr(f"architecture/{name}-test.apk", name.encode())
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        return archive, digest

    def test_bsdtar_selects_only_needed_packages(self):
        archive, _ = self.bundle_fixture()
        self.run_sh(f'PW_FORMAT=apk; pw_extract_bundle {q(archive)}; pw_flatten_packages')
        extracted = {file.name for file in (self.fs / "work/packages").glob("*.apk")}
        self.assertEqual(len(extracted), 6)
        self.assertIn("xray-core-test.apk", extracted)
        self.assertNotIn("sing-box-test.apk", extracted)

    @unittest.skipIf(os.name == "nt", "Windows inbox bsdtar cannot read ZIP from a pipe; Linux CI covers this path")
    def test_verified_stream_extracts_only_selected_packages(self):
        archive, digest = self.bundle_fixture()
        code = f'PW_FORMAT=apk; curl() {{ cat {q(archive)}; }}; pw_stream_bundle https://fixture.invalid/bundle {digest}'
        result = self.run_sh(code, ok=False)
        if os.name == "nt" and "Function not implemented" in result.stderr:
            self.skipTest("Windows filesystem cannot create POSIX FIFOs")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        extracted = {file.name for file in (self.fs / "work/packages").glob("*.apk")}
        self.assertIn("xray-core-test.apk", extracted)
        self.assertEqual(len(extracted), 6)
        self.assertNotIn("sing-box-test.apk", extracted)
        self.assertFalse((self.fs / "work/bundle.fifo").exists())

    def test_stream_hash_failure_is_rejected(self):
        # A pipe consumer that reads the full stream isolates digest behavior from ZIP decoding.
        self.script("bin/bsdtar", "cat >/dev/null\n")
        result = self.run_sh('PW_FORMAT=apk; curl() { printf corrupted; }; pw_stream_bundle https://fixture.invalid/bundle ' + 'a' * 64, ok=False)
        if os.name == "nt" and "Function not implemented" in result.stderr:
            self.skipTest("Windows filesystem cannot create POSIX FIFOs")
        self.assertNotEqual(result.returncode, 0)

    def input_code(self, value):
        file = self.fs / "input.secret"
        file.write_text(value + "\n")
        return f"""
. {q(self.fs / 'native-nodes.sh')}
pw_health() {{ touch "$PW_WORK/health-checked"; }}
pw_schedule() {{ :; }}
PW_INPUT_FILE={q(file)}
pw_import_input
"""

    def test_single_links_are_passed_intact_to_upstream_importer(self):
        for link in ("vless://00000000-0000-4000-8000-000000000001@example.invalid:443?security=reality&type=xhttp&path=%2Fa#Node",
                     "vmess://eyJ2IjoiMiJ9", "trojan://test@example.invalid:443?sni=example.invalid#Node",
                     "ss://YWVzLTEyOC1nY206dGVzdA@example.invalid:443#Node"):
            with self.subTest(scheme=link.partition(":")[0]):
                self.config.write_text(json.dumps(self.initial))
                self.run_sh(self.input_code(link))
                self.assertEqual((self.fs / "received-input").read_text(), link)
                config = json.loads(self.config.read_text())
                self.assertEqual(config["pwsetup_balancer"]["balancing_node"], ["newnode"])
                self.assertEqual(config["global"]["enabled"], "1")
                self.assertTrue((self.fs / "work/health-checked").exists())
                self.assertFalse((self.fs / "tmp/links.conf").exists())

    def test_subscription_and_secret_redaction(self):
        url = "https://subscription.invalid/token?key=fixture-secret&mode=all"
        r = self.run_sh(self.input_code(url))
        self.assertEqual((self.fs / "received-input").read_text(), url)
        self.assertNotIn(url, r.stdout + r.stderr)
        config = json.loads(self.config.read_text())
        subscription = next(v for v in config.values() if v[".type"] == "subscribe_list")
        self.assertEqual(subscription["url"], url)
        self.assertEqual(config["pwsetup_balancer"]["balancing_node"], ["newnode"])

    def test_bad_and_multiline_input_do_not_change_config(self):
        for value in ("http://insecure.invalid/token", "https://a.invalid\nhttps://b.invalid", "$(touch /tmp/not-executed)"):
            before = self.config.read_bytes()
            r = self.run_sh(self.input_code(value), ok=False)
            self.assertNotEqual(r.returncode, 0)
            self.assertEqual(self.config.read_bytes(), before)

    def test_import_without_nodes_restores_previous_config(self):
        self.env["IMPORT_FAIL"] = "1"
        before = self.config.read_bytes()
        code = f'. {q(self.fs / "native-system.sh")}; pgrep() {{ return 1; }}; pw_backup; trap pw_recover 0\n'
        r = self.run_sh(code + self.input_code("https://subscription.invalid/empty"), ok=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.config.read_bytes(), before)

    def test_exclusion_survives_new_node_ids(self):
        data = dict(self.initial)
        data["sub"] = {".type": "subscribe_list", "remark": "Provider"}
        for node, name in (("a", "Russia"), ("b", "The limited server")):
            data[node] = {".type": "nodes", "type": "Xray", "protocol": "vless", "group": "Provider", "remarks": name}
        self.config.write_text(json.dumps(data))
        (self.fs / "etc/config/pwsetup").write_text(json.dumps({"main": {".type": "setup", "excluded_names": ["The limited server"]}}))
        self.run_sh(f'sh {q(self.fs / "usr/libexec/pwsetup/rebuild-balancer.sh")}')
        data = json.loads(self.config.read_text())
        self.assertEqual(data["pwsetup_balancer"]["balancing_node"], ["a"])
        data["new-id"] = data.pop("b")
        self.config.write_text(json.dumps(data))
        self.run_sh(f'sh {q(self.fs / "usr/libexec/pwsetup/rebuild-balancer.sh")}')
        self.assertEqual(json.loads(self.config.read_text())["pwsetup_balancer"]["balancing_node"], ["a"])

    def test_package_failure_triggers_settings_recovery(self):
        before = self.config.read_bytes()
        (self.fs / "work/packages/luci-app-passwall2-test.apk").touch()
        code = f"""
. {q(self.fs / 'native-system.sh')}
. {q(self.fs / 'native-packages.sh')}
pgrep() {{ return 1; }}
pw_backup
trap pw_recover 0
PW_FORMAT=apk; PW_STORAGE=full
apk() {{ case "$*" in *--simulate*) return 0 ;; *) return 1 ;; esac; }}
pw_install_packages
"""
        r = self.run_sh(code, ok=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.config.read_bytes(), before)
        self.assertIn("stop", (self.fs / "service-events").read_text())
        self.assertIn("Package versions are NOT rolled back", r.stderr)

    def test_dns_recovery_uses_cached_opkg_package(self):
        (self.fs / "etc/config/dhcp").write_text("existing DHCP settings")
        code = f"""
. {q(self.fs / 'native-packages.sh')}
PW_FORMAT=ipk; PW_ZRAM_MIB=0
pw_pm_has() {{ return 1; }}
opkg() {{
    printf '%s\\n' "$*" >> "$PW_WORK/package-events"
    case "$1" in
        download) touch dnsmasq_1_all.ipk dnsmasq-full_1_all.ipk ;;
        remove) test -f "$PW_WORK/dnsmasq/dnsmasq_1_all.ipk" && test -f "$PW_WORK/dnsmasq/dnsmasq-full_1_all.ipk" ;;
        install) case "$2" in *dnsmasq-full_*) return 1 ;; esac ;;
    esac
}}
pw_dependencies
"""
        r = self.run_sh(code, ok=False)
        self.assertNotEqual(r.returncode, 0)
        events = (self.fs / "work/package-events").read_text()
        self.assertLess(events.index("download dnsmasq"), events.index("remove dnsmasq"))
        self.assertIn("dnsmasq/dnsmasq_1_all.ipk", events)
        self.assertEqual((self.fs / "etc/config/dhcp").read_text(), "existing DHCP settings")

    def test_refresh_respects_disabled_proxy(self):
        before = self.config.read_bytes()
        self.run_sh(f'. {q(self.fs / "native-nodes.sh")}; pw_backup() {{ return 99; }}; pw_refresh')
        self.assertEqual(self.config.read_bytes(), before)
        self.assertFalse((self.fs / "received-input").exists())

    def test_runtime_passes_memory_settings_and_arguments(self):
        self.script("usr/bin/xray", 'printf "%s|%s|%s\\n" "$GOMEMLIMIT" "$GOGC" "$*"\n')
        code = f"""
. {q(self.fs / 'native-system.sh')}
PW_HEAP_MIB=96; PW_GOGC=50; PW_ZRAM_MIB=128
PW_TAG=fixture; PW_STORAGE=full; PW_FORMAT=apk; PW_ARCH=aarch64_cortex-a53
pw_install_helpers
{q(SHELL)} {q(self.fs / 'usr/libexec/pwsetup/xray-runtime')} run -test
"""
        r = self.run_sh(code)
        self.assertEqual(r.stdout.strip(), "96MiB|50|run -test")

    def test_new_zram_is_started_once_for_preparation(self):
        (self.fs / "etc/config/system").write_text(json.dumps({"s0": {".type": "system"}}))
        self.script("etc/init.d/zram", 'echo "$*" >> "$FAKE_ROOT/zram-events"; if [ "$1" = start ]; then echo "/dev/zram0 partition 65536 0 100" >> "$FAKE_ROOT/proc/swaps"; fi\n')
        code = f"""
. {q(self.fs / 'native-system.sh')}
PW_ZRAM=auto; PW_ZRAM_MIB=64
pw_pm_add() {{ echo "$*" >> "$PW_WORK/package-events"; }}
pw_configure_zram
pw_configure_zram
"""
        self.run_sh(code)
        self.assertEqual((self.fs / "zram-events").read_text().splitlines(), ["enable", "start"])
        self.assertEqual((self.fs / "work/package-events").read_text().splitlines(), ["kmod-zram zram-swap"])
        self.assertEqual(json.loads((self.fs / "etc/config/system").read_text())["s0"]["zram_size_mb"], "64")

    def test_existing_zram_is_not_changed(self):
        (self.fs / "proc/swaps").write_text("/dev/zram0 partition 262144 0 100\n")
        self.run_sh(f'. {q(self.fs / "native-system.sh")}; PW_ZRAM=auto; PW_ZRAM_MIB=64; pw_pm_add() {{ return 99; }}; pw_configure_zram')
        self.assertFalse((self.fs / "zram-events").exists())

    def test_upx_refuses_insufficient_preparation_memory(self):
        code = f'. {q(self.fs / "native-packages.sh")}; PW_ARCH=aarch64_cortex-a53; pw_pm_add() {{ touch "$PW_WORK/unexpected-install"; }}; pw_prepare_compact'
        result = self.run_sh(code, ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("128 MiB available RAM+swap", result.stderr)
        self.assertFalse((self.fs / "work/unexpected-install").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
