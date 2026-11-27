# Payroll ledger projection — PR #39, synthetic tested, not deployed

Consumes Claude's `payroll.dart` through the existing atomic `typed_finance`
event. Windows remains the sole writer. Recording a payment never initiates a
bank transfer. No wage is computed from planned Vardiya.

`finance.payrollPayments` serializes to private `payroll_payments`: persistent
UUID mapped from the existing `pp_<requestId>` / `pr_<originalId>` source ID,
employee mapping, historical employee label, Monday week, payment day,
kind, method, exact cash/bank/total kuruş, reversal UUID, note, timestamp and
actor label. Originals precede reversals in imports. Original amounts and
attribution are immutable. A reversal must exactly negate one original in the
same tenant/employee/week/method, have a reason and cannot itself be reversed
or repeated. Corrections retain the original row. Legacy `weeklyPayroll`
and the new ledger cannot both represent the same employee/week.

`finance.payrollReviews` serializes to private `payroll_reviews`. Its stable
UUID maps employee/week/recorded timestamp; duplicate source identities fail
closed. Explicit Ödenmedi is an immutable acknowledgement with no monetary
movement; it cannot assert a financial paid status.

Both tables have FORCE RLS and no client-role table grants. Source employee
IDs resolve only through the tenant's existing employee mapping. Strict typed
fields, arithmetic/method checks and immutable-history completeness are
validated before transaction ACK. Lost ACK retries reuse the same identities.

The authorized payroll summary/read APIs are still pending. They must consume
Windows `payrollStatus` / `payrollWeek`, respect owner exclusion and employee
privacy, and preserve the distinction between review status and financial
status. Manual attendance extensions, plans and weekly submission history are
separate remaining QA-09 work; this ledger slice does not close O-03.
