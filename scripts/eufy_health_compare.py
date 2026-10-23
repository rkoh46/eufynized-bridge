#!/usr/bin/env python3
"""Compare an eufynized-health report with the last good one and say what changed.

Usage: eufy_health_compare.py NEW.json [LAST_GOOD.json] [--features device-features.txt]
  --features  a baseline's device-features.txt: then a firmware update that crosses one of the official
              app's firmware gates (e.g. "T8030 >=4.2.0.5 live_support_thing") is called out by name.
Prints a markdown summary. Exit status: 0 healthy and nothing changed, 1 a stage failed,
3 healthy but firmware or the wire fingerprint changed (worth a look before it breaks).

The "wire fingerprint" is what the HomeBase and cameras showed us: codec, resolution, the set of
control frames (command:signCode), the camera settings types they report, and whether level-2,
gateway info and audio worked. A firmware update that changes the protocol usually moves one of these
before anything visibly breaks.
"""
import json
import sys

CAMERA_FIELDS = ["codec", "size", "level2", "gateway"]
CAMERA_SETS = ["controlFrames", "paramTypes"]


def load(path):
    with open(path) as f:
        return json.load(f)


def vkey(v):
    return tuple(int(x) if x.isdigit() else 0 for x in str(v).split("."))


def gates(path):
    """{model: [(version, feature, subdevices)]} from a baseline's device-features.txt."""
    out = {}
    for line in open(path, encoding="utf-8"):
        parts = line.rstrip("\n").split("\t")
        if len(parts) >= 3 and parts[1].startswith(">="):
            out.setdefault(parts[0], []).append((parts[1][2:], parts[2], parts[3] if len(parts) > 3 else ""))
    return out


def by_serial(items):
    return {i["serial"]: i for i in items or []}


def main():
    argv = sys.argv[1:]
    feature_file = None
    if "--features" in argv:
        i = argv.index("--features")
        feature_file = argv[i + 1] if i + 1 < len(argv) else None
        argv = argv[:i] + argv[i + 2:]
    if len(argv) not in (1, 2):
        print(__doc__, file=sys.stderr)
        return 2
    new = load(argv[0])
    old = load(argv[1]) if len(argv) == 2 else None
    known = gates(feature_file) if feature_file else {}
    our_models = {c.get("serial", "")[:5] for c in new.get("cameras", [])} | \
                 {d.get("serial", "")[:5] for d in (new.get("cloud") or {}).get("devices", [])}
    out, changes = [], []

    failed = [s for s in new.get("stages", []) if not s.get("ok")]
    offline = [c for c in new.get("cameras", []) if c.get("offline")]
    if offline:
        changes += [f"{c['name']} is {c.get('state', 'offline').lower()} (as its HomeBase reports) — check its power and network"
                    for c in offline]
    out.append(f"**{'BROKEN' if failed else 'Healthy'}** — {len(new.get('stages', []))} stages, "
               f"{len(failed)} failed ({new.get('startedAt')})")
    for s in failed:
        out.append(f"- FAIL {s['name']}: {s.get('detail', '')}")

    if old:
        # Firmware (only known when the run used --cloud; fall back to the last known value).
        of = {d["serial"]: d for d in (old.get("cloud") or {}).get("devices", [])}
        for d in (new.get("cloud") or {}).get("devices", []):
            prev = of.get(d["serial"])
            if prev is None:
                changes.append(f"new device on the account: {d['serial']} ({d.get('model')})")
                continue
            for k in ("firmware", "firmware2", "channel", "deviceType"):
                if prev.get(k) != d.get(k) and (prev.get(k) or d.get(k)):
                    changes.append(f"{d['serial']} {k}: {prev.get(k)} → {d.get(k)}")
            if prev.get("firmware") and d.get("firmware") and prev["firmware"] != d["firmware"]:
                lo, hi = vkey(prev["firmware"]), vkey(d["firmware"])
                for ver, feat, subs in known.get(d.get("model", "")[:5], []):
                    if lo < vkey(ver) <= hi:
                        mine = sorted(our_models & set(subs.split(","))) if subs else []
                        changes.append(f"{d['serial']} crossed the official app's firmware gate >={ver}: "
                                       f"**{feat}**" + (f" (for our {', '.join(mine)})" if mine else ""))
            added = sorted(set(d.get("paramTypes", [])) - set(prev.get("paramTypes", [])))
            removed = sorted(set(prev.get("paramTypes", [])) - set(d.get("paramTypes", [])))
            if added or removed:
                changes.append(f"{d['serial']} cloud settings types +{added} -{removed}")
        if new.get("cloud") and of:
            gone = set(of) - {d["serial"] for d in new["cloud"].get("devices", [])}
            changes += [f"device left the account: {s}" for s in sorted(gone)]

        oc = by_serial(old.get("cameras"))
        for serial, c in by_serial(new.get("cameras")).items():
            p = oc.get(serial)
            if not p:
                continue
            for k in CAMERA_FIELDS:
                if p.get(k) != c.get(k):
                    changes.append(f"{c['name']}: {k} {p.get(k)} → {c.get(k)}")
            for k in CAMERA_SETS:
                a, b = set(p.get(k, [])), set(c.get(k, []))
                # Control frames vary run to run (notifications); report only additions of new kinds.
                added = sorted(b - a)
                removed = sorted(a - b) if k == "paramTypes" else []
                if added or removed:
                    changes.append(f"{c['name']}: {k} +{added}" + (f" -{removed}" if removed else ""))
            if (p.get("audioFrames", 0) > 0) != (c.get("audioFrames", 0) > 0):
                changes.append(f"{c['name']}: audio {'stopped' if p.get('audioFrames') else 'started'}")
            pf, cf = p.get("firstFrameMs"), c.get("firstFrameMs")
            if pf and cf and cf > max(3 * pf, pf + 4000):
                changes.append(f"{c['name']}: first frame much slower ({pf} → {cf} ms)")

    if changes:
        out.append("")
        out.append("Changes since the last good run:")
        out += [f"- {c}" for c in changes]
    print("\n".join(out))
    if failed:
        return 1
    return 3 if changes else 0


if __name__ == "__main__":
    sys.exit(main())
