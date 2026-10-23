#!/usr/bin/env python3
"""Build a protocol-relevant inventory of the installed official eufy app.

Static inspection only. Reads Info.plists, bundled JSON/plist configs, the
string tables of the (unencrypted) frameworks, Objective-C class and selector
names, and the string tables of the bundled React Native Hermes bytecode. It
never runs, attaches to or hooks the app, and never touches the Keychain.

Key material is never written out: certificates, public keys, PPCS init
strings and other key-like constants are recorded only as a short SHA-256
fingerprint plus length, which is enough to notice when one changes.

Usage: eufy_inventory.py APP_BUNDLE OUT_DIR
  APP_BUNDLE  the inner .app (e.g. /Applications/BatteryCam.app/Wrapper/BatteryCam.app)
  OUT_DIR     directory to write the inventory files into (created if needed)
"""
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys
import tempfile
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hbc_strings  # noqa: E402

# Frameworks that carry eufy's own P2P, crypto, player and device logic.
# Everything else is still scanned for command names, API paths and hosts.
CORE_FRAMEWORKS = [
    "BC_P2PClient", "BC_Security", "BCMega_Player", "BC_VideoSDK", "BC_MediaLib",
    "BCPDTSecurity", "AudioStreamKit", "MegaEufyEventFramework", "EufyComponents",
    "ThingP2PSDK", "ThingP2pFileTransSDK", "ThingVideoCodecSDK", "ZXMQTT",
    "ZXMoblie", "ZXBLEService",
]
CONFIG_JSON = [
    "security_device_configuration.json", "device_configuration.json",
    "ecosystem_configuration.json", "MenuListJson.json",
    "oneclick_network_config.json",
]
# Crypto strings and ObjC selectors are only collected from these (the P2P,
# media and crypto stacks); elsewhere they are mostly third-party noise.
CRYPTO_FRAMEWORKS = [
    "BC_P2PClient", "BC_Security", "BCMega_Player", "BC_VideoSDK", "BC_MediaLib",
    "AudioStreamKit", "ThingP2PSDK",
]
KEY_FILES = re.compile(r"(cerficate|certificate|\.der$|\.pem$|\.crt$|PubKey|\.cer$|thingcfg$)", re.I)

ASCII_RUN = re.compile(rb"[\x20-\x7e]{5,}")
CMD_RE = re.compile(r"\b((?:APP_|P2P_)?CMD_[A-Z0-9_]{3,})")
# Sub-commands carried inside the 1700/1350 wrappers (PTZ presets, zoom, cruise, ...).
SUBCMD_RE = re.compile(r"(?<![A-Z0-9_])((?:DUAL_)?COMMAND_[A-Z0-9_]{4,})")
# API paths such as v1/app/get_devs_list, /v2/passport/login, app/ota/get_rom_version
PATH_RE = re.compile(r"(?<![A-Za-z0-9_.])/?((?:v\d{1,2}|app|passport|api|hub|station|device|mqtt|ota)"
                     r"/[a-z0-9_\-]+(?:/[a-z0-9_\-{}]+)*)")
PATH_FIRST_OK = re.compile(r"^(v\d{1,2}|app|passport)/")
HOST_RE = re.compile(r"\b((?:[a-z0-9\-]+\.)+(?:eufylife|eufy|anker|ankercloud|ankerdata|anker-in|"
                     r"soundcore|oceanwing|thingclips|tuyaus|tuyaeu|tuyacn|tuyain|tuya|wgine|"
                     r"thingsmart|eufyhome)\.(?:com|cn|eu|us|net|io|co\.jp|jp))\b", re.I)
MODEL_RE = re.compile(r"^T[0-9][0-9A-Z]{3}[A-Z0-9]{0,2}$")
PPCS_INIT_RE = re.compile(r"^[A-P]{40,}$")
CRYPTO_RE = re.compile(r"(ecdh|ecc|secp|prime256|aes|rsa|hmac|sha256|sha1|md5|pkcs|x509|"
                       r"cipher|crypt|nonce|level2|level_2|encry|decry|p2p_?key|session_?key|"
                       r"private_?key|public_?key|sign(?:ature)?|curve25519|chacha)", re.I)
KEYLIKE_RE = re.compile(r"(-----BEGIN|^[A-Za-z0-9+/]{40,}={0,2}$|^[0-9a-fA-F]{32,}$)")


def fp(data):
    if isinstance(data, str):
        data = data.encode("utf-8", "surrogateescape")
    return hashlib.sha256(data).hexdigest()[:12]


def file_sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()[:12]


def ascii_strings(path):
    with open(path, "rb") as f:
        data = f.read()
    return [m.group().decode("ascii") for m in ASCII_RUN.finditer(data)]


def lenient_json(path):
    with open(path, encoding="utf-8") as f:
        s = f.read()
    s = re.sub(r",(\s*[\]}])", r"\1", s)
    return json.loads(s)


def read_plist(path):
    with open(path, "rb") as f:
        return plistlib.load(f)


def write_lines(out_dir, name, lines):
    with open(os.path.join(out_dir, name), "w", encoding="utf-8") as f:
        for line in lines:
            f.write(line + "\n")


def is_macho(path):
    try:
        with open(path, "rb") as f:
            magic = f.read(4)
    except OSError:
        return False
    return magic in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xce\xfa\xed\xfe")


def encrypted(path):
    out = subprocess.run(["otool", "-l", path], capture_output=True, text=True).stdout
    ids = re.findall(r"cryptid (\d+)", out)
    return bool(ids) and any(i != "0" for i in ids)


def objc_classes(path):
    out = subprocess.run(["nm", "-gU", path], capture_output=True, text=True).stdout
    return sorted({m for m in re.findall(r"_OBJC_CLASS_\$_(\S+)", out)})


def objc_selectors(path):
    out = subprocess.run(["otool", "-v", "-s", "__TEXT", "__objc_methname", path],
                         capture_output=True, text=True).stdout
    sels = set()
    for line in out.splitlines()[2:]:
        parts = line.split(None, 1)
        # The section also holds property type encodings ("T@\"NSString\",&,N"); skip those.
        if len(parts) == 2 and re.match(r"^[A-Za-z_][A-Za-z0-9_:]*$", parts[1].strip()):
            sels.add(parts[1].strip())
    return sorted(sels)


class Inventory:
    def __init__(self):
        self.commands = {}     # name -> set(source)
        self.subcommands = {}
        self.paths = {}
        self.hosts = {}
        self.models = {}
        self.crypto = {}       # line -> set(source)

    @staticmethod
    def _add(table, key, src):
        table.setdefault(key, set()).add(src)

    def scan(self, strings, src, crypto=False):
        for s in strings:
            for m in CMD_RE.findall(s):
                # "APP_CMD_START_REALTIME_MEDIA_payload" -> drop the dangling "_".
                self._add(self.commands, m.rstrip("_"), src)
            if "COMMAND_" in s:
                for m in SUBCMD_RE.findall(s):
                    self._add(self.subcommands, m.rstrip("_"), src)
            for m in HOST_RE.findall(s):
                self._add(self.hosts, m.lower(), src)
            if "/" in s and len(s) < 300:
                for m in PATH_RE.findall(s):
                    m = m.rstrip("/")
                    if PATH_FIRST_OK.match(m) and m.count("/") >= 1 and not m.endswith((".png", ".js")):
                        self._add(self.paths, m, src)
            if MODEL_RE.match(s):
                self._add(self.models, s, src)
            if crypto:
                if s.startswith(("-----BEGIN", "-----END")):
                    # PEM markers: fingerprint them too, so secret scanners stay quiet.
                    self._add(self.crypto, f"pem-marker len={len(s)} sha={fp(s)}", src)
                elif PPCS_INIT_RE.match(s):
                    self._add(self.crypto, f"ppcs-init-string len={len(s)} sha={fp(s)}", src)
                elif KEYLIKE_RE.search(s) and len(s) >= 32:
                    self._add(self.crypto, f"key-like-constant len={len(s)} sha={fp(s)}", src)
                elif CRYPTO_RE.search(s) and len(s) <= 120 and not s.startswith(("T@", "@\"")):
                    self._add(self.crypto, s, src)


def fmt_table(table):
    return [f"{k}\t{','.join(sorted(v))}" for k, v in sorted(table.items())]


def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    app, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    inv = Inventory()

    # --- app identity -------------------------------------------------------
    info = read_plist(os.path.join(app, "Info.plist"))
    exe = os.path.join(app, info["CFBundleExecutable"])
    app_lines = [
        f"bundle_id\t{info.get('CFBundleIdentifier')}",
        f"display_name\t{info.get('CFBundleDisplayName')}",
        f"version\t{info.get('CFBundleShortVersionString')}",
        f"build\t{info.get('CFBundleVersion')}",
        f"minimum_os\t{info.get('MinimumOSVersion')}",
        f"main_executable_fairplay_encrypted\t{encrypted(exe)}",
    ]
    for key in ("NSAppTransportSecurity", "CFBundleURLTypes", "NSBonjourServices",
                "UIBackgroundModes", "NSLocalNetworkUsageDescription"):
        if key in info:
            app_lines.append(f"{key}\t{json.dumps(info[key], sort_keys=True)}")
    write_lines(out, "app.txt", app_lines)

    # --- frameworks and plugins ----------------------------------------------
    fw_lines, classes_lines, sel_lines, source_lines = [], [], [], []
    fw_dir = os.path.join(app, "Frameworks")
    binaries = []
    for name in sorted(os.listdir(fw_dir)):
        path = os.path.join(fw_dir, name)
        if name.endswith(".framework"):
            base = name[:-len(".framework")]
            binp = os.path.join(path, base)
            ver = "?"
            ip = os.path.join(path, "Info.plist")
            if os.path.exists(ip):
                ver = read_plist(ip).get("CFBundleShortVersionString", "?")
        elif name.endswith(".dylib"):
            base, binp, ver = name, path, "-"
        else:
            continue
        if not is_macho(binp):
            continue
        fw_lines.append(f"{base}\t{ver}\t{file_sha(binp)}")
        binaries.append((base, binp))
    plug_dir = os.path.join(app, "PlugIns")
    if os.path.isdir(plug_dir):
        for name in sorted(os.listdir(plug_dir)):
            ip = os.path.join(plug_dir, name, "Info.plist")
            if os.path.exists(ip):
                p = read_plist(ip)
                fw_lines.append(f"plugin:{name}\t{p.get('CFBundleIdentifier')}\t"
                                f"{json.dumps(p.get('NSExtension', {}).get('NSExtensionPointIdentifier'))}")
    write_lines(out, "frameworks.txt", fw_lines)

    for base, binp in binaries:
        inv.scan(ascii_strings(binp), base, crypto=base in CRYPTO_FRAMEWORKS)
        if base in CORE_FRAMEWORKS:
            classes_lines += [f"{base}\t{c}" for c in objc_classes(binp)]
        if base in CRYPTO_FRAMEWORKS:
            sel_lines += [f"{base}\t{s}" for s in objc_selectors(binp)]

    # --- React Native bundles (Hermes bytecode inside zips) -------------------
    rn_lines = []
    with tempfile.TemporaryDirectory() as tmp:
        for name in sorted(os.listdir(app)):
            if not (name.startswith("RN_") and name.endswith(".zip")):
                continue
            mod = name[:-4]
            with zipfile.ZipFile(os.path.join(app, name)) as z:
                for member in z.namelist():
                    if not member.endswith((".hbc", ".jsbundle", ".bundle.js")):
                        continue
                    data = z.read(member)
                    try:
                        ver, strings = hbc_strings.read_strings(data)
                        kind = f"hermes-v{ver}"
                    except ValueError:
                        strings = [m.group().decode() for m in ASCII_RUN.finditer(data)]
                        kind = "text"
                    rn_lines.append(f"{mod}/{member}\t{kind}\tstrings={len(strings)}\t{fp(data)}")
                    inv.scan(strings, mod)

    write_lines(out, "rn-bundles.txt", rn_lines)

    # --- bundled configuration -----------------------------------------------
    for cfg in CONFIG_JSON:
        p = os.path.join(app, cfg)
        if os.path.exists(p):
            source_lines.append(f"{cfg}\t{file_sha(p)}")
    sdc_path = os.path.join(app, "security_device_configuration.json")
    feat_lines = []
    if os.path.exists(sdc_path):
        sdc = lenient_json(sdc_path)
        for model, spec in sorted(sdc.items()):
            if not isinstance(spec, dict):
                continue
            if MODEL_RE.match(model):
                inv._add(inv.models, model, "security_device_configuration")
            feat_lines.append(f"{model}\tparent={spec.get('parent')}\textras={','.join(spec.get('extras') or [])}"
                              f"\texcludes={','.join(spec.get('excludes') or [])}")
            for fwver, feats in sorted((spec.get("versions") or {}).items()):
                for feat in feats:
                    subs = ",".join(sorted(feat.get("subDevices") or []))
                    feat_lines.append(f"{model}\t>={fwver}\t{feat.get('name')}\t{subs}")
            hubs = ((spec.get("ecosystem") or {}).get("businessConfig") or {}).get("supported_hub_pns")
            for hub in hubs or []:
                feat_lines.append(f"{model}\thub={hub.get('pn')}\thub_min={hub.get('hub_min_ver')}"
                                  f"\tdev_min={hub.get('dev_min_ver')}")
    dc_path = os.path.join(app, "device_configuration.json")
    if os.path.exists(dc_path):
        dc = lenient_json(dc_path)
        for model, spec in sorted(dc.items()):
            if isinstance(spec, dict):
                if MODEL_RE.match(model):
                    inv._add(inv.models, model, "device_configuration")
                feat_lines.append(f"dc:{model}\tparent={spec.get('parent')}"
                                  f"\textras={','.join(map(str, spec.get('extras') or []))}"
                                  f"\texcludes={','.join(map(str, spec.get('excludes') or []))}")
    write_lines(out, "device-features.txt", feat_lines)

    type_lines = []
    eco_path = os.path.join(app, "ecosystem_configuration.json")
    if os.path.exists(eco_path):
        eco = lenient_json(eco_path)
        mapping = eco.get("deviceTypeMapping") or {}
        items = mapping.items() if isinstance(mapping, dict) else enumerate(mapping)
        for dtype, pn in sorted(items, key=lambda kv: int(kv[0]) if str(kv[0]).isdigit() else 1 << 30):
            type_lines.append(f"deviceTypeMapping\t{dtype}\t{json.dumps(pn, ensure_ascii=False) if not isinstance(pn, str) else pn}")
        for item in eco.get("snMapping") or []:
            type_lines.append(f"snMapping\t{item.get('pattern')}\t{item.get('pn')}")
        for k in eco:
            if MODEL_RE.match(k):
                inv._add(inv.models, k, "ecosystem_configuration")
    write_lines(out, "device-types.txt", type_lines)

    rc_lines = []
    rc_path = os.path.join(app, "RemoteConfigDefaults.plist")
    if os.path.exists(rc_path):
        for k, v in sorted(read_plist(rc_path).items()):
            v = json.dumps(v, ensure_ascii=False) if not isinstance(v, str) else v
            v = v.replace("\n", " ")
            rc_lines.append(f"{k}\t{v if len(v) <= 160 else v[:160] + f'… (len={len(v)} sha={fp(v)})'}")
    write_lines(out, "remote-config.txt", rc_lines)

    # Certificates, public keys and other key material: fingerprints only.
    for root, _dirs, files in os.walk(app):
        if "/Frameworks/" in root + "/" or "/PlugIns/" in root + "/":
            continue
        for f in files:
            if KEY_FILES.search(f):
                p = os.path.join(root, f)
                rel = os.path.relpath(p, app)
                inv._add(inv.crypto, f"bundled-key-file {rel} len={os.path.getsize(p)} sha={file_sha(p)}", "bundle")

    write_lines(out, "p2p-commands.txt", fmt_table(inv.commands))
    write_lines(out, "sub-commands.txt", fmt_table(inv.subcommands))
    write_lines(out, "api-paths.txt", fmt_table(inv.paths))
    write_lines(out, "hosts.txt", fmt_table(inv.hosts))
    write_lines(out, "models.txt", fmt_table(inv.models))
    write_lines(out, "crypto.txt", fmt_table(inv.crypto))
    write_lines(out, "objc-classes.txt", sorted(classes_lines))
    write_lines(out, "objc-selectors.txt", sorted(sel_lines))
    write_lines(out, "config-files.txt", source_lines)

    summary = {n: sum(1 for _ in open(os.path.join(out, n), encoding="utf-8"))
               for n in sorted(os.listdir(out)) if n.endswith(".txt")}
    print(json.dumps(summary, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
