# Manual Mesai projection — PR #39, synthetic tested, not deployed

The existing atomic `shifts` core event consumes Claude's `workforce.dart`
records. Manual attendance stays separate from planned Vardiya. Nothing in
cloud ingestion creates attendance or approves it.

In addition to existing `pos`/`remote` shifts, `source=manual` retains exact
break minutes, note, creation/update timestamps and void facts. Manual spans
must be closed, positive, at most 16 hours and longer than their break.
Void requires its retained reason/time and matching final audit entry.
Legacy clock records without the additive fields retain zero break/default
metadata. Historical employee identity/label and creation facts are immutable.

Corrections retain explicit before/after break minutes alongside intervals,
actor mapping, reason and timestamp. Identities are existing shift IDs and
append-only correction ordinals. Rewritten/omitted history, broken chains,
unaudited edits and undoing a void abort the complete transaction before ACK.
Existing actor/tenant mapping and private FORCE RLS remain in force.

Claude's older `correctShift` audit omits break fields. Zero-break history
remains compatible; nonzero historical breaks are never guessed. A request
on #44 asks Claude to include unchanged break minutes in exceptional manual
corrections. This is a pending source-handler integration dependency, not a
reason to recreate that business handler.

Authorized weekly payroll reads, planned schedules and weekly submission
snapshots remain separate unfinished QA-09/O-03 work. Gün Sonu Raporu continues
to omit staffHours.
