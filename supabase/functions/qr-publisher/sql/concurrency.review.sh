#!/usr/bin/env bash
# Only invoked in disposable GitHub Actions PostgreSQL container.
set -euo pipefail
container=$1
db=$2
owner=$3
psql_ci() { docker exec -i "$container" psql -X -qAt -v ON_ERROR_STOP=1 -U "$owner" -d "$db" "$@"; }
psql_ci < supabase/functions/qr-publisher/sql/concurrency-fixture.review.sql
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# Session A holds the committed-claim transaction open. B starts while A
# still owns the repository-wide advisory transaction lock.
psql_ci > "$tmp/a" <<'SQL' &
begin;
select qr_concurrency_test.claim('A');
\echo CLAIM_HELD
select pg_sleep(4);
commit;
SQL
a_pid=$!
for i in $(seq 1 40); do
  if grep -qx CLAIM_HELD "$tmp/a"; then break; fi
  sleep 0.1
done
grep -qx CLAIM_HELD "$tmp/a"
psql_ci > "$tmp/b" <<'SQL' &
select qr_concurrency_test.claim('B');
SQL
b_pid=$!
# Verify actual overlap: the competing backend must wait on advisory lock.
blocked=false
for i in $(seq 1 20); do
  if [ "$(psql_ci -c "select exists(select 1 from pg_catalog.pg_locks where locktype='advisory' and classid=734981 and objid=1 and not granted)")" = t ]; then
    blocked=true
    break
  fi
  sleep 0.1
done
wait "$a_pid"
wait "$b_pid"
[ "$blocked" = true ]
grep -qx new "$tmp/a"
grep -qx busy "$tmp/b"
[ "$(psql_ci -c "select qr_concurrency_test.claim('A')")" = busy ]
# The other tenant's authorized recovery command cannot see A's receipt.
[ "$(psql_ci -c "select nohut_qr_edge.qr_publish_recover(b.token,b.reconcile_id,1,b.reconcile_hash,a.request_id,'inspect',null,null)->>'status' from qr_concurrency_test.fixture a,qr_concurrency_test.fixture b where a.label='A' and b.label='B'")" = not_found ]
# Finish A through the actual wrapper and then prove a B transaction
# rollback cannot leave a durable claim behind.
psql_ci <<'SQL'
select nohut_qr_edge.qr_publish_transition(f.token,f.request_id,1,f.envelope_hash,f.digest,r.fence,'no_change',null,null,null,f.revision,f.stamp,f.revision,f.draft_json)
from qr_concurrency_test.fixture f join nohut_private.qr_publish_receipts r on r.restaurant_id=f.restaurant and r.request_id=f.request_id where f.label='A';
begin;
select qr_concurrency_test.claim('B');
rollback;
SQL
[ "$(psql_ci -c "select qr_concurrency_test.claim('B')")" = new ]
[ "$(psql_ci -c "select count(*) from nohut_private.qr_publish_receipts where state<>'completed'")" = 1 ]
echo 'PASS: overlapping claims serialize, other tenant denied, rollback safe, exactly one unresolved claim'
