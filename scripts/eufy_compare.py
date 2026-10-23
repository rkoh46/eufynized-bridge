#!/usr/bin/env python3
"""Diff two official-app baselines and cross-reference against the libraries and Eufynized.

Usage: eufy_compare.py NEW_BASELINE PREV_BASELINE|- UPSTREAM_DIR SOURCES_DIR
  Writes NEW_BASELINE/coverage.txt and, when PREV_BASELINE is given,
  NEW_BASELINE/diff-from-<prev version>.md. Prints a short markdown summary.

coverage.txt has one row per P2P command name known to anyone:
  id  name  official  eufy-sdk  bropat  eufynized
where id comes from the libraries (the official app's iOS binaries carry the
names but not the numbers) and "eufynized" means that id appears as a command
constant in Sources/EufyKit (a heuristic: numeric literals on command lines).
"""
import os
import re
import sys

# Files whose first tab-separated field is the key and the rest is "where seen".
KEYED = {"p2p-commands.txt", "sub-commands.txt", "api-paths.txt", "hosts.txt", "models.txt", "crypto.txt"}
SHOW = 60


def load(path, keyed):
    if not os.path.exists(path):
        return set()
    with open(path, encoding="utf-8") as f:
        lines = [l.rstrip("\n") for l in f if l.strip()]
    return {l.split("\t", 1)[0] for l in lines} if keyed else set(lines)


def version_of(baseline):
    with open(os.path.join(baseline, "app.txt")) as f:
        for line in f:
            if line.startswith("version\t"):
                return line.split("\t", 1)[1].strip()
    return os.path.basename(baseline.rstrip("/"))


def read_catalog(path):
    out = {}
    if os.path.exists(path):
        for line in open(path):
            v, k = line.rstrip("\n").split("\t")
            out[k] = int(v)
    return out


def norm(name):
    return name[4:] if name.startswith("APP_") else name


def eufynized_command_ids(sources):
    ids = set()
    rx_line = re.compile(r"(cmd|command)", re.I)
    for root, _d, files in os.walk(sources):
        for fn in files:
            if not fn.endswith(".swift"):
                continue
            for line in open(os.path.join(root, fn), encoding="utf-8", errors="replace"):
                code = line.split("//", 1)[0]
                # Command lines, plus UInt16 constants (how the P2P code declares command ids).
                if rx_line.search(code) or re.search(r"let \w+\s*:\s*UInt16\s*=\s*\d{3,5}\b", code):
                    ids.update(int(n) for n in re.findall(r"(?<![\w.])(\d{3,5})(?![\w.])", code))
    return ids


def eufynized_models(sources):
    found = set()
    for root, _d, files in os.walk(sources):
        for fn in files:
            if fn.endswith(".swift"):
                found.update(re.findall(r"\bT8[0-9A-Z]{3}\b", open(os.path.join(root, fn), errors="replace").read()))
    return found


def main():
    if len(sys.argv) != 5:
        print(__doc__, file=sys.stderr)
        return 2
    new, prev, upstream, sources = sys.argv[1:]
    out = []

    # --- diff against previous baseline --------------------------------------
    if prev != "-":
        pv, nv = version_of(prev), version_of(new)
        md = [f"# Official app inventory diff: {pv} → {nv}", ""]
        total = 0
        for name in sorted(os.listdir(new)):
            if not name.endswith(".txt") or name == "coverage.txt":
                continue
            keyed = name in KEYED
            a, b = load(os.path.join(prev, name), keyed), load(os.path.join(new, name), keyed)
            added, removed = sorted(b - a), sorted(a - b)
            if not added and not removed:
                continue
            total += len(added) + len(removed)
            md += [f"## {name}: +{len(added)} / -{len(removed)}", ""]
            md += [f"- `+ {x[:200]}`" for x in added[:SHOW]]
            if len(added) > SHOW:
                md.append(f"- … {len(added) - SHOW} more added")
            md += [f"- `- {x[:200]}`" for x in removed[:SHOW]]
            if len(removed) > SHOW:
                md.append(f"- … {len(removed) - SHOW} more removed")
            md.append("")
        if not total:
            md.append("No inventory changes.")
        path = os.path.join(new, f"diff-from-{pv}.md")
        with open(path, "w") as f:
            f.write("\n".join(md) + "\n")
        out.append(f"- official app diff {pv} → {nv}: {total} changed entries (diff-from-{pv}.md)")

    # --- command coverage ----------------------------------------------------
    official = {norm(n) for n in load(os.path.join(new, "p2p-commands.txt"), True)}
    sdk = read_catalog(os.path.join(upstream, "mega-yfue__eufy-sdk", "commands.txt"))
    bro = read_catalog(os.path.join(upstream, "bropat__eufy-security-client", "commands.txt"))
    used = eufynized_command_ids(os.path.join(sources, "EufyKit"))
    names = sorted(official | set(sdk) | set(bro))
    rows, used_names = [], set()
    for n in names:
        cid = sdk.get(n, bro.get(n))
        mark_e = "yes" if cid is not None and cid in used else ""
        if mark_e:
            used_names.add(n)
        rows.append((cid if cid is not None else 1 << 30, n,
                     "yes" if n in official else "", "yes" if n in sdk else "",
                     "yes" if n in bro else "", mark_e))
    rows.sort()
    with open(os.path.join(new, "coverage.txt"), "w") as f:
        f.write("id\tname\tofficial\teufy-sdk\tbropat\teufynized\n")
        for cid, n, o, s, b, e in rows:
            f.write(f"{'?' if cid == 1 << 30 else cid}\t{n}\t{o}\t{s}\t{b}\t{e}\n")
    official_cmd = {n for n in official if n.startswith("CMD_")}
    unknown = sorted(n for n in official_cmd if n not in sdk and n not in bro)
    out += [
        f"- P2P command names in official app: {len(official_cmd)} "
        f"(eufy-sdk catalog {len(sdk)}, bropat {len(bro)}, used by Eufynized {len(used_names)})",
        f"- official names with no known id in either library: {len(unknown)}",
    ]

    # --- models and device types ---------------------------------------------
    off_models = load(os.path.join(new, "models.txt"), True)
    ours = eufynized_models(sources)
    out.append(f"- model codes in official app: {len(off_models)}; named in Eufynized sources: {len(ours)}")
    dtypes = {}
    for line in open(os.path.join(new, "device-types.txt")):
        parts = line.rstrip("\n").split("\t")
        if parts[0] == "deviceTypeMapping" and parts[1].isdigit():
            dtypes[int(parts[1])] = parts[2]
    sdk_types = set(read_catalog(os.path.join(upstream, "mega-yfue__eufy-sdk", "device_types.txt")).values())
    missing = sorted(t for t in dtypes if t not in sdk_types)
    out.append(f"- device_type numbers in official app: {len(dtypes)}; not in eufy-sdk DeviceType: {len(missing)}"
               + (f" ({', '.join(f'{t}={dtypes[t]}' for t in missing[:25])}{' …' if len(missing) > 25 else ''})"
                  if missing else ""))
    print("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
