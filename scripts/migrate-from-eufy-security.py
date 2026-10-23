#!/usr/bin/env python3
# Kept for reference: what moved the Pi from the eufy_security integration to Eufynized on 2026-10-22.
# One-time switch of the old eufy entities to Eufynized's (run with Home Assistant Core stopped).
import json, shutil, yaml, re
C = "/opt/ha/config"
STAMP = "bak-2026-10-22-eufynized-entities"
files = [f"{C}/.storage/core.entity_registry", f"{C}/.storage/lovelace.lovelace", f"{C}/automations.yaml", f"{C}/configuration.yaml"]
for f in files:
    shutil.copy2(f, f"{f}.{STAMP}")

prefixes = ["front360", "driveway", "backyard", "back_laundry", "living_room", "kids_room", "kodi_cam"]
claimed = {"alarm_control_panel.eufy_home_base"}
for p in prefixes:
    claimed |= {f"camera.{p}", f"image.{p}_event_image"}
    claimed |= {f"binary_sensor.{p}_{k}_detected" for k in ("motion", "person", "pet", "vehicle", "crying", "sound")}

# 1. Free the entity IDs the new entities take over (the old eufy integration is disabled; its other entities stay).
reg = json.load(open(files[0]))
before = len(reg["data"]["entities"])
reg["data"]["entities"] = [e for e in reg["data"]["entities"] if not (e["platform"] == "eufy_security" and e["entity_id"] in claimed)]
deleted = reg["data"].get("deleted_entities", [])
reg["data"]["deleted_entities"] = [e for e in deleted if e.get("entity_id") not in claimed]
json.dump(reg, open(files[0], "w"), indent=2)
print("registry: freed", before - len(reg["data"]["entities"]), "entity IDs")

# 2. configuration.yaml: keep the old names.
conf = open(files[3]).read()
block = ("eufynized:\n  entity_names:\n    T8162T0000000001: backyard   # Front door, named backyard by the old integration\n"
         "  alarm_entity_name: eufy_home_base\n")
conf, n = re.subn(r"^eufynized:\n(?:[ \t]+.*\n)*", block, conf, flags=re.M)
open(files[3], "w").write(conf)
print("configuration.yaml: eufynized block", "updated" if n else "NOT FOUND")

# 3. Automations: time for the full-resolution picture; drop the old notification-switch condition.
autos = yaml.safe_load(open(files[2]))
for a in autos:
    if a.get("id") in ("1766632114499", "1767240390713"):   # AI person alerts: Front Door, Driveway
        for step in a["actions"]:
            if "delay" in step and step["delay"].get("seconds") == 5:
                step["delay"]["seconds"] = 10
                print("automation", a["alias"], ": first delay 5 → 10 s")
                break
    if a.get("id") == "kids_room_crying_alert":
        a["conditions"] = [c for c in a.get("conditions", []) if c.get("entity_id") != "switch.kids_room_notification_crying_detected"]
        print("automation", a["alias"], ": removed the old notification-switch condition")
yaml.safe_dump(autos, open(files[2], "w"), sort_keys=False, allow_unicode=True, width=1000)

# 4. Dashboard: the Cameras view becomes the Security Camera card; drop the old guard-mode select tile.
lv = json.load(open(files[1]))
for view in lv["data"]["config"]["views"]:
    if view.get("path") == "cameras":
        old = len(view.get("sections", []))
        view["sections"] = [{"type": "grid", "column_span": 4, "cards": [
            {"type": "heading", "heading": "Security Camera", "heading_style": "title", "icon": "mdi:cctv"},
            {"type": "custom:eufynized-card", "view": "multiview", "grid_options": {"columns": "full"}},
        ]}]
        view["max_columns"] = 4
        print(f"dashboard: Cameras view {old} sections → Security Camera card")
    for section in view.get("sections", []):
        cards = section.get("cards", [])
        kept = [c for c in cards if c.get("entity") != "select.eufy_home_base_guard_mode"]
        if len(kept) != len(cards):
            section["cards"] = kept
            print("dashboard: removed the old guard-mode select tile from", view.get("title"))
json.dump(lv, open(files[1], "w"), indent=2)

# What still refers to old eufy entities that Eufynized doesn't provide.
eufy = {e["entity_id"] for e in json.load(open(f"{files[0]}.{STAMP}"))["data"]["entities"] if e["platform"] == "eufy_security"} - claimed
left = sorted({m for m in re.findall(r"[a-z_]+\.[a-z0-9_]+", json.dumps(lv) + open(files[2]).read() + open(f"{C}/scripts.yaml").read()) if m in eufy})
print("still referring to old eufy entities:", ", ".join(left) or "nothing")
