import os, sys, zipfile, io
from pathlib import Path
A = Path(os.environ["A"])
tokens = {n: (A / "tok" / f"{n}.token").read_text().strip() for n in ("desktop", "ipad", "revoked")}
needles = {n: t.encode() for n, t in tokens.items()}
skip_dirs = {".venv", "node_modules", ".godot", ".git", "__pycache__", ".mypy_cache", ".ruff_cache", "test_sandboxes"}
def scan_bytes(data: bytes) -> list[str]:
    return [n for n, nd in needles.items() if nd in data]
def scan_tree(root: Path, label: str):
    files = hits = 0
    for d, dirs, fs in os.walk(root):
        dirs[:] = [x for x in dirs if x not in skip_dirs]
        for f in fs:
            p = Path(d) / f
            try:
                if p.is_symlink() or p.stat().st_size > 400_000_000: continue
                data = p.read_bytes()
            except OSError: continue
            files += 1
            h = scan_bytes(data)
            if p.suffix == ".zip":
                try:
                    z = zipfile.ZipFile(io.BytesIO(data))
                    for m in z.namelist():
                        h += scan_bytes(z.read(m))
                except Exception: pass
            if h:
                hits += 1; print(f"  HIT {label}: {p.relative_to(root)} ({','.join(sorted(set(h)))})")
    print(f"{label}: scanned {files} files, {hits} with a token")
G = Path("/Users/andrejvysny/workspace/godot")
for label, root in [("asset-studio repo (working tree)", G / "asset-studio"), ("godot-ipad repo (working tree)", G / "godot-ipad"), ("fantasy-game repo (working tree)", G / "fantasy-game"),
                    ("scratch git repo (tracked consumer)", A / "repo"), ("scratch clones (fresh checkouts + exports)", A / "clones"), ("scratch project pub", A / "pub"), ("scratch project pub2", A / "pub2"),
                    ("scratch consumer cons", A / "cons"), ("scratch consumer uidcons", A / "uidcons"), ("minimal consumer", A / "mc"), ("acceptance logs", A / "logs"), ("server instance dir (token store: hashes only)", A / "inst"), ("server library roots", A / "projects"),
                    ("iPad host test storage (device-local registry + exact cache; credentials.json is the expected 0600 holder)", A / "ipad_state")]:
    scan_tree(root, label)
# git objects of the scratch repo and a clone
import subprocess
for r in (A / "repo",):
    out = subprocess.run(["git", "-C", str(r), "log", "-p", "--all"], capture_output=True).stdout
    print("scratch repo git history (log -p --all):", "HIT " + str(scan_bytes(out)) if scan_bytes(out) else "0 tokens")
print('token files mode:', {n: oct((A / 'tok' / f'{n}.token').stat().st_mode & 0o777) for n in tokens})
print('device-local credentials.json mode:', oct((A / 'ipad_state/assetstudio/credentials.json').stat().st_mode & 0o777))
