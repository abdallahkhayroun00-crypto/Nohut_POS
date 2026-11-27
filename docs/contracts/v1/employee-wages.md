# Employee wage projection — PR #39, synthetic tested, not deployed

Consumes Claude's PR #44 `payroll.dart` model. The existing atomic `employees`
core event now permits `payrollEligible`, `payType`, `payRateCents` and complete
`payHistory` entries (`effectiveFrom`, `payType`, `rateCents`, `setAt`, `setBy`).
No password, PIN verifier, session, credential or device data is included.

`employees.payroll_eligible` defaults true when absent. An explicit false or a
later true is preserved; this projection never infers owner identity from a
name or grants. Claude's authoritative owner-default handler owns that choice.

Tenant-specific `employee_source_ids` map local IDs. Historical rates have a
stable composite identity `(restaurant_id, employee_id, effective_from, set_at)`;
same identity with changed rate/type/actor, duplicate identities or omitted
prior history abort the entire transaction and ACK. Deactivation retains wage
history. Amounts are integer kuruş; dates and absolute timestamps are validated.

Private tables use FORCE RLS with no client-role read/write grants. This is
business data, never an authorization source. Employee-specific reads still
require authenticated session and permission filtering in the pending read API.

Remaining QA-09/O-03 scope includes payroll payment/reversal/review ledgers,
planned shifts, manual attendance metadata, weekly submission history, and
authorized Windows-calculated payroll summaries. Daily reports omit staffHours.
