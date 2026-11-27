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

Claude's `97bf0c2` (integrated via `bacae0a`) includes unchanged break minutes
in exceptional manual correction snapshots and rejects intervals no longer
than their break. Zero-break legacy history remains compatible; missing
historical nonzero breaks are never guessed. A separate follow-up asks Claude
to bump existing per-entity updatedAt tokens after a manager correction so a
stale employee form cannot overwrite it. That source-handler fix stays his.

Authorized weekly payroll reads, planned schedules and weekly submission
snapshots remain separate unfinished QA-09/O-03 work. Gün Sonu Raporu continues
to omit staffHours.
