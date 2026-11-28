"""Reassembles NOHUT_FLUTTER_SHOT chunks from a flutter test log into PNGs."""
import base64, re, sys, pathlib
log, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)
parts = {}
for line in log.read_text(errors="replace").splitlines():
    m = re.search(r"NOHUT_FLUTTER_SHOT (\S+) (\d+)/(\d+) (\S+)", line)
    if m:
        parts.setdefault(m[1], {})[int(m[2])] = (int(m[3]), m[4])
for name, chunks in parts.items():
    total = next(iter(chunks.values()))[0]
    if len(chunks) != total:
        print(f"::warning::{name}: {len(chunks)}/{total} chunks"); continue
    (out / f"flutter-{name}.png").write_bytes(base64.b64decode("".join(chunks[i][1] for i in range(total))))
    print("saved", name)
