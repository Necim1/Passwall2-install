#!/usr/bin/env python
"""Offline command doubles. Never imported by the installer."""
import json
import os
import re
import sys
from pathlib import Path


def main():
    tool, *args = sys.argv[1:]
    root = Path(os.environ["FAKE_ROOT"])
    if tool == "jsonfilter":
        data = json.loads(Path(args[args.index("-i") + 1]).read_text(encoding="utf-8-sig"))
        query = args[args.index("-e") + 1]
        if query == "@[*]":
            result = data
        elif query.endswith("[*]"):
            result = data[query[2:-3]]
        else:
            result = [data.get(query[2:])]
        for item in result:
            if item is not None:
                print(item if isinstance(item, str) else json.dumps(item, separators=(",", ":")))
        return 0

    def load(config):
        file = root / "etc/config" / config
        return json.loads(file.read_text()) if file.exists() else {}

    def save(config, data):
        file = root / "etc/config" / config
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(json.dumps(data))

    def resolve(data, section):
        match = re.fullmatch(r"@([^\[]+)\[(\d+)\]", section)
        if match:
            candidates = [k for k, v in data.items() if v.get(".type") == match[1]]
            return candidates[int(match[2])]
        return section

    if tool == "uci":
        args = [arg for arg in args if arg != "-q"]
        action = args[0]
        if action in ("commit", "revert"):
            return 0
        if action == "add":
            data = load(args[1])
            section = "cfg%04d" % (len(data) + 1)
            data[section] = {".type": args[2]}
            save(args[1], data)
            print(section)
            return 0
        if action == "show":
            for section, options in load(args[1]).items():
                print(f"{args[1]}.{section}={options['.type']}")
                for key, value in options.items():
                    if key != ".type":
                        print(f"{args[1]}.{section}.{key}={value!r}")
            return 0
        target, separator, value = args[1].partition("=")
        config, *parts = target.split(".")
        data = load(config)
        try:
            section = resolve(data, parts[0])
            option = parts[1] if len(parts) > 1 else ".type"
            if action == "get":
                result = data[section][option]
                print(" ".join(result) if isinstance(result, list) else result)
            elif action == "set":
                data.setdefault(section, {})[option] = value
                save(config, data)
            elif action == "add_list":
                data.setdefault(section, {}).setdefault(option, []).append(value)
                save(config, data)
            elif action == "delete":
                del data[section][option]
                save(config, data)
            else:
                return 1
        except (KeyError, IndexError):
            return 1
        return 0
    if tool == "lua":
        data = load("passwall2")
        if args[0] == "-":
            if os.environ.get("FILTER_FAIL") == "1":
                return 1
            return 0 if args[1] in load("pwsetup").get("main", {}).get("excluded_names", []) else 10
        _, operation, group, *unused = args
        if operation == "add":
            raw = (root / "tmp/links.conf").read_text().strip()
        else:
            raw = data[group]["url"]
            group = data[group]["remark"]
        (root / "received-input").write_text(raw)
        if os.environ.get("IMPORT_FAIL") == "1":
            return 0  # Upstream can exit zero even when no nodes were parsed.
        protocol = raw.partition("://")[0] if operation == "add" else "vless"
        if protocol == "ss":
            protocol = "shadowsocks"
        data["newnode"] = {".type": "nodes", "type": "Xray", "protocol": protocol,
                           "group": group, "remarks": "Test node"}
        save("passwall2", data)
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
