# Requested POS changes

The public QR menu and its repository are not modified.

| # | Request | Implementation |
|---|---|---|
|1|Remove daily last-receipt and print-waiting dashboard metrics|Both removed; daily IDs/history remain intact|
|2|Make all orders practical|Direct search/status/source filters, history filter, account dialog|
|3|Remove daily cash opening/closing|Removed from production manager UI; historical cash records retained|
|4|Remove print queue section|Removed from sidebar and routing; failed requested receipts are reviewed in printer settings|
|5|Redesign reports|Summary cards, hourly chart, date/source filters, receipts/products views and CSV|
|6|Redesign settings|Separate General, Menu, Printer, inPOS and Backup tabs|
|7|Open table account directly|Dialog with items, add/edit/remove, move, service, payment and close actions|
|8|Print only at payment after asking|Migration enforces on-payment policy before printer starts; no automatic kitchen jobs for the migrated runtime|
|9|Remove staff product images|Only the original logo remains; product rows have text and quick actions|
|10|Less scrolling, practical phone UI|Fixed-height menu/cart/orders screens, search/categories, quantity counters and merged identical variants|
|11|Add/edit/remove existing items|Revision-checked actions and audit history; reductions below paid/allocated amounts rejected|
|12|Move same order to another table|Stable ID, items/payments preserved; occupied destinations rejected without merging|
|13|Staff payment and close|Active staff and explicit cash/terminal confirmation; receipt choice; unpaid close rejected|
|14|Staff ready/delivered status|Validated sequential service transitions shared with manager|
|15|Sound and visible manager alert|Persisted event IDs, one-time notification banner and configurable sound|
|16|inPOS m530 automatic card integration|Typed adapter and durable payment coordinator: approve/decline/cancel/unknown, reference inquiry and no automatic charge resubmission. Production gateway unavailable until official SDK, app ID and authorized pairing are supplied. Current Kart action records operator-confirmed physical-terminal payment|

Legacy print/cash/report panel classes remain for compatibility and regression coverage; production manager routes use the new screens. Existing restaurant records are preserved. Phone commands use the same SQLite transaction/idempotency mechanism as order submissions. An uncertain network response is retried with the same request ID. Editing/removing records retains audit history.

Physical inPOS pairing, bank acceptance and XP-237B paper output require on-site hardware verification. The optional application print is a non-fiscal account summary; the m530's fiscal documents are separate.
