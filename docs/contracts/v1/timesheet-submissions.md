# Weekly Mesai snapshots — PR #39, synthetic tested, not deployed

Consumes Claude's `timesheetWeeks` core event and `submitWeek` handler. This
is communication, never an approval. No missing day becomes zero attendance.

The stable week ID is `tw_<local employee ID>_<Monday YYYY-MM-DD>`. The cloud
maps that employee within its tenant, keeps current submitted time/noWork/
minutes and every immutable submission ordinal. Nested entries retain shift
IDs, original intervals and exact break minutes. Each interval must match
current or retained audited Mesai for the same employee. Totals are validated
with the Windows integer-minute rule. Istanbul start dates determine the week.

Later edits to live Mesai do not rewrite earlier submissions. A new submission
appends another snapshot; explicit no-work retains prior history. Windows
`weekStatus` derives Taslak/Gönderildi/Değişti/Çalışma yok for future read APIs.
No financial paid status is stored here.

Atomic ingestion applies employees, shifts and then weekly snapshots before
ACK. Duplicate ACK recovery does not add another submission. Changed or
omitted prior snapshots/entry sets, duplicate IDs, wrong employee references,
invented intervals and inconsistent minutes abort the transaction. Tables
have FORCE RLS and no client-role read/write grants.

Planned Vardiya and authenticated employee-specific read APIs remain pending
QA-09/O-03 work. Daily reports continue to omit staffHours.
