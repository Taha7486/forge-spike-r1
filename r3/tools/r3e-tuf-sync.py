#!/usr/bin/env python3
"""R3e item 4: copy the Sigstore public-good TUF repository to a local directory (a mirror's content).
Usage: r3e-tuf-sync.py <outdir> [upstream]    Layout written (flat, for a ConfigMap): root-N.json, timestamp.json, snapshot-V.json, targets-V.json, t-<sha256>.<name>
Checks done here: every target file's sha256 and length against the signed targets.json (integrity of the copy). The TUF SIGNATURES are not verified here:
the client (Kyverno) verifies them against its trusted root, so a mirror does not need to be trusted. Prints the expiry of each metadata file."""
import hashlib, json, os, sys, urllib.request, urllib.error
out = sys.argv[1]; up = (sys.argv[2] if len(sys.argv) > 2 else "https://tuf-repo-cdn.sigstore.dev").rstrip("/")
os.makedirs(out, exist_ok=True)
def get(path):
    with urllib.request.urlopen(f"{up}/{path}", timeout=60) as r: return r.read()
def put(name, data): open(os.path.join(out, name), "wb").write(data)
n = 1
while True:
    try: put(f"root-{n}.json", get(f"{n}.root.json")); n += 1
    except urllib.error.HTTPError as e:
        if e.code in (403, 404): break
        raise
last_root = n - 1
ts = get("timestamp.json"); put("timestamp.json", ts); tsj = json.loads(ts)["signed"]
sv = tsj["meta"]["snapshot.json"]["version"]; snap = get(f"{sv}.snapshot.json"); put(f"snapshot-{sv}.json", snap); sj = json.loads(snap)["signed"]
tv = sj["meta"]["targets.json"]["version"]; tg = get(f"{tv}.targets.json"); put(f"targets-{tv}.json", tg); tj = json.loads(tg)["signed"]
files = 0
for name, meta in tj["targets"].items():
    h = meta["hashes"]["sha256"]; data = get(f"targets/{h}.{name}")
    assert len(data) == meta["length"] and hashlib.sha256(data).hexdigest() == h, f"integrity check failed for {name}"
    put(f"t-{h}.{name}", data); files += 1
json.dump({"root_versions": last_root, "timestamp_version": tsj["version"], "snapshot_version": sv, "targets_version": tv,
           "timestamp_expires": tsj["expires"], "snapshot_expires": sj["expires"], "targets_expires": tj["expires"], "target_files": files},
          open(os.path.join(out, "SYNC.json"), "w"), indent=1)
print(f"synced {last_root} roots, timestamp v{tsj['version']} (expires {tsj['expires']}), snapshot v{sv} (expires {sj['expires']}), targets v{tv} (expires {tj['expires']}), {files} target files")
