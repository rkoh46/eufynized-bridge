#!/usr/bin/env python3
"""Check the reference libraries for new releases and Eufynized-relevant commits.

Uses the signed-in `gh` CLI (read-only GitHub API calls). For each repo it:
  - lists releases and commits since the last check on the default branch and
    on integration branches (beta-*, develop, next, release/*), plus other
    recently pushed non-dependabot branches;
  - flags commits that touch P2P/PPPP, level-2 crypto, live stream, PTZ,
    talkback, device types or security, by commit message and changed paths;
  - snapshots the repo's P2P command catalog and DeviceType enum as text so the
    next run can diff them.

Usage: eufy_upstream.py STATE_DIR REPORT_MD
  STATE_DIR  docs/eufy-baselines/upstream (state.json + per-repo catalogs)
  REPORT_MD  markdown report to write
"""
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys

REPOS = {
    "mega-yfue/eufy-sdk": {
        "commands": "src/transport/p2p/commands.ts",
        "device_types": "src/model/device-types.ts",
    },
    "bropat/eufy-security-client": {
        "commands": "src/p2p/types.ts",
        "device_types": "src/http/types.ts",
    },
}
FIRST_RUN_DAYS = 60
MAX_COMMITS = 80
INTEGRATION = re.compile(r"^(beta[-/]|develop$|next$|release/)")

# Topics matched against the commit title/body.
TOPICS = {
    "p2p/pppp": r"\bp2p\b|pppp|ppcs|\bxzyh\b|udp|datagram|lookup|relay",
    "level2-crypto": r"level.?2|ecdh|ecies|encrypt|decrypt|cipher|\baes\b|\brsa\b|gcm|key.?exchange|handshake",
    "live-stream": r"\blive\b|stream|\bvideo\b|h\.?26[45]|hevc|keyframe|annex.?b|jitter|\brtc\b|webrtc",
    "ptz": r"\bptz\b|pan.?tilt|rotate|preset|zoom",
    "talkback": r"talkback|talk.?back|\baac\b|adts|microphone|two.?way",
    "device-types": r"device.?type|\bT8[0-9A-Z]{3}\b|homebase|\bhb3\b|indoor cam|solocam|eufycam",
    "security": r"\bsecurity fix|\bcve\b|vulnerab|leak|sanitiz|redact|\btls\b|certificate|password",
    "events/clips": r"\bevent|\bclip|recording|playback|download|thumbnail",
}
# Topics matched against changed source paths (more specific than the title).
PATH_TOPICS = {
    "p2p/pppp": r"(^|/)p2p/",
    "level2-crypto": r"crypto|cipher|ecies|level2",
    "live-stream": r"live|video|stream|(^|/)rtc/|annexb|fmp4",
    "ptz": r"pan-tilt|ptz",
    "talkback": r"talkback|adts|audio",
    "device-types": r"device-types|classify|registry|device-family",
    "events/clips": r"recording|event|media-download|thumbnail|push/",
}
NOISE = re.compile(r"^(chore\(deps|build\(deps|bump |merge pull request .*dependabot)", re.I)


def gh(*args, raw=False):
    cmd = ["gh", "api"]
    if raw:
        cmd += ["-H", "Accept: application/vnd.github.raw"]
    cmd += list(args)
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"gh api {' '.join(args)}: {r.stderr.strip()}")
    return r.stdout if raw else json.loads(r.stdout or "null")


def name_key(name):
    """Branch names are stored hashed: some (e.g. "...-password") trip secret scanners."""
    return hashlib.sha256(name.encode()).hexdigest()[:12]


def topics_for(text):
    return [t for t, rx in TOPICS.items() if re.search(rx, text, re.I)]


def path_topics(paths):
    return [t for t, rx in PATH_TOPICS.items() if any(re.search(rx, p, re.I) for p in paths)]


def parse_enum(src, name):
    """Return {NAME: int} for `export enum NAME {` or `export const NAME = {`."""
    m = re.search(r"export\s+(?:const\s+)?(?:enum\s+%s\s*\{|%s\s*=\s*\{)" % (name, name), src)
    if not m:
        return {}
    body, depth, i = [], 1, m.end()
    while i < len(src) and depth:
        c = src[i]
        depth += c == "{"
        depth -= c == "}"
        body.append(c)
        i += 1
    out = {}
    for k, v in re.findall(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*[:=]\s*(-?(?:0x[0-9a-fA-F]+|\d+))\s*,?",
                           "".join(body), re.M):
        out[k] = int(v, 0)
    return out


def write_catalog(path, table):
    with open(path, "w") as f:
        for k, v in sorted(table.items(), key=lambda kv: (kv[1], kv[0])):
            f.write(f"{v}\t{k}\n")


def read_catalog(path):
    if not os.path.exists(path):
        return {}
    out = {}
    with open(path) as f:
        for line in f:
            v, k = line.rstrip("\n").split("\t")
            out[k] = int(v)
    return out


def catalog_diff(old, new):
    added = sorted(set(new) - set(old), key=lambda k: new[k])
    removed = sorted(set(old) - set(new), key=lambda k: old[k])
    changed = sorted(k for k in set(old) & set(new) if old[k] != new[k])
    return added, removed, changed


def report_commits(repo, label, commits, md, total=None):
    """Append the Eufynized-relevant subset of `commits` (oldest first) to md."""
    relevant = []
    for c in commits:
        msg = c["commit"]["message"]
        title = msg.splitlines()[0]
        if NOISE.search(title) or len(c.get("parents", [])) > 1:
            continue
        detail = gh(f"repos/{repo}/commits/{c['sha']}")
        paths = [f["filename"] for f in detail.get("files", [])]
        src_paths = [p for p in paths if not re.search(r"(^|/)(test|tests|__tests__|docs?)/|\.test\.|\.spec\.|\.md$", p)]
        t = sorted(set(topics_for(msg) + path_topics(src_paths)))
        if t and src_paths:
            relevant.append((c, title, t, src_paths))
    shown = f"{len(commits)}" + (f" (latest {len(commits)} of {total})" if total and total > len(commits) else "")
    md.append(f"- commits on {label}: {shown}, relevant to Eufynized: {len(relevant)}")
    for c, title, t, paths in relevant:
        date = c["commit"]["committer"]["date"][:10]
        md.append(f"  - `{c['sha'][:7]}` {date} {title[:120]} — _{', '.join(t)}_")
        md.append(f"    - files: {', '.join(paths[:8])}{' …' if len(paths) > 8 else ''}")


def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    state_dir, report = sys.argv[1], sys.argv[2]
    os.makedirs(state_dir, exist_ok=True)
    state_path = os.path.join(state_dir, "state.json")
    state = json.load(open(state_path)) if os.path.exists(state_path) else {}
    now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
    md = [f"# Upstream check — {now.date().isoformat()}", ""]

    for repo, files in REPOS.items():
        prev = state.get(repo, {})
        meta = gh(f"repos/{repo}")
        branch = meta["default_branch"]
        head = gh(f"repos/{repo}/commits/{branch}")
        head_sha = head["sha"]
        md += [f"## {repo}", "",
               f"- default branch `{branch}` at `{head_sha[:7]}` "
               f"({head['commit']['committer']['date']}); last pushed {meta['pushed_at']}"]
        if meta.get("archived"):
            md.append("- **Repository is archived.**")

        # README deprecation / maintenance notices are worth surfacing.
        try:
            readme = gh(f"repos/{repo}/readme", raw=True)
            for line in readme.splitlines():
                if re.search(r"deprecat|no longer maintained|unmaintained|archiv", line, re.I):
                    md.append(f"- README notice: {line.strip()[:200]}")
                    break
        except RuntimeError:
            pass

        since = prev.get("checked_at") or (now - datetime.timedelta(days=FIRST_RUN_DAYS)).isoformat()
        releases = [r for r in gh(f"repos/{repo}/releases?per_page=20")
                    if (r.get("published_at") or "") > since]
        if releases:
            md.append("- new releases since last check:")
            for r in releases:
                body = (r.get("body") or "").strip().splitlines()
                hits = [l.strip() for l in body if topics_for(l)][:12]
                md.append(f"  - **{r['tag_name']}** ({r['published_at'][:10]}) {r['html_url']}")
                md += [f"    - {h[:180]}" for h in hits]
        else:
            md.append(f"- no new releases since {since[:10]}")

        if prev.get("sha") and prev["sha"] != head_sha:
            cmp_ = gh(f"repos/{repo}/compare/{prev['sha']}...{head_sha}")
            commits = cmp_.get("commits", [])[-MAX_COMMITS:]
        elif prev.get("sha") == head_sha:
            commits = []
        else:
            commits = gh(f"repos/{repo}/commits?sha={branch}&since={since}&per_page={MAX_COMMITS}")[::-1]

        report_commits(repo, f"`{branch}`", commits, md)

        # Branches with recent activity (feature work that may land later).
        try:
            branches = gh(f"repos/{repo}/branches?per_page=100")
            active = []
            for b in branches:
                name = b["name"]
                if name == branch or name.startswith("dependabot/"):
                    continue
                if b["commit"]["sha"] == prev.get("branches", {}).get(name_key(name)):
                    continue
                active.append(b)
            if active:
                md.append("- other branches new or moved since last check: " +
                          ", ".join(f"`{b['name']}`" for b in active[:20]))
            branch_state = {name_key(b["name"]): b["commit"]["sha"] for b in branches}
        except RuntimeError:
            branches, branch_state = [], prev.get("branches", {})

        # Integration branches (e.g. eufy-sdk's beta-0.5.0) carry most new work
        # long before it reaches the default branch, so report their commits too.
        for b in branches:
            name = b["name"]
            if name == branch or not INTEGRATION.match(name):
                continue
            old_sha = prev.get("branches", {}).get(name_key(name))
            if old_sha == b["commit"]["sha"]:
                md.append(f"- `{name}`: unchanged since last check")
                continue
            try:
                cmp_ = gh(f"repos/{repo}/compare/{old_sha or head_sha}...{b['commit']['sha']}")
            except RuntimeError:  # force-pushed: fall back to "ahead of default"
                cmp_ = gh(f"repos/{repo}/compare/{head_sha}...{b['commit']['sha']}")
            commits = cmp_.get("commits", [])
            since_what = "new since last check" if old_sha else f"{cmp_.get('ahead_by')} ahead of {branch}"
            label = f"`{name}` ({since_what})"
            report_commits(repo, label, commits[-MAX_COMMITS:], md, total=len(commits))

        # Command / device-type catalogs.
        slug = repo.replace("/", "__")
        rdir = os.path.join(state_dir, slug)
        os.makedirs(rdir, exist_ok=True)
        for kind, enum in (("commands", "CommandType"), ("device_types", "DeviceType")):
            try:
                src = gh(f"repos/{repo}/contents/{files[kind]}?ref={head_sha}", raw=True)
            except RuntimeError as e:
                md.append(f"- could not fetch {files[kind]}: {e}")
                continue
            table = parse_enum(src, enum)
            path = os.path.join(rdir, f"{kind}.txt")
            old = read_catalog(path)
            added, removed, changed = catalog_diff(old, table)
            write_catalog(path, table)
            line = f"- `{enum}` ({files[kind]}): {len(table)} entries"
            if old:
                line += f"; +{len(added)} / -{len(removed)} / changed {len(changed)}"
            md.append(line)
            if old:
                for k in added[:40]:
                    md.append(f"  - added `{k}` = {table[k]}")
                for k in removed[:20]:
                    md.append(f"  - removed `{k}` (was {old[k]})")
                for k in changed[:20]:
                    md.append(f"  - changed `{k}`: {old[k]} → {table[k]}")
        md.append("")

        state[repo] = {"sha": head_sha, "checked_at": now.isoformat(), "branches": branch_state}

    with open(state_path, "w") as f:
        json.dump(state, f, indent=2, sort_keys=True)
        f.write("\n")
    with open(report, "w") as f:
        f.write("\n".join(md) + "\n")
    print("\n".join(md))
    return 0


if __name__ == "__main__":
    sys.exit(main())
