#!/usr/bin/env python3
"""Emit (or check) the SQL rows of nohut_private.operation_catalogue from
docs/contracts/v1/permissions.json — the single permission contract.

  python3 tools/permission_catalogue_sql.py            # print VALUES rows
  python3 tools/permission_catalogue_sql.py --check F  # F = JSON from the DB
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
contract = json.loads((ROOT / "docs/contracts/v1/permissions.json").read_text(encoding="utf-8"))


def q(s):
    return "'" + s.replace("'", "''") + "'"


def arr(xs):
    return "array[" + ",".join(q(x) for x in xs) + "]::text[]" if xs else "'{}'::text[]"


if len(sys.argv) == 3 and sys.argv[1] == "--check":
    db = {r["operation_id"]: r for r in json.loads(Path(sys.argv[2]).read_text())}
    ok = True
    for o in contract["operations"]:
        r = db.pop(o["id"], None)
        want = (o["section"], o["sensitivity"], sorted(o["clients"]), sorted(o["defaults"]))
        got = r and (r["section"], r["sensitivity"], sorted(r["clients"]), sorted(r["default_roles"]))
        if want != got:
            ok = False
            print(f"DRIFT {o['id']}: contract={want} db={got}")
    for extra in db:
        ok = False
        print(f"DRIFT {extra}: in database, not in contract")
    print("catalogue matches contract" if ok else "catalogue drift")
    sys.exit(0 if ok else 1)

rows = [
    f"  ({q(o['id'])}, {q(o['section'])}, {q(o['sensitivity'])}, {arr(o['clients'])}, {arr(o['defaults'])})"
    for o in contract["operations"]
]
print(",\n".join(rows))
