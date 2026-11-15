# Requested POS changes

The public QR menu and its repository are not modified.

| # | Request | Implementation |
|---|---|---|
|1|Remove daily last-receipt dashboard metric|Removed; daily IDs/history remain intact|
|2|Remove pending-print dashboard metric|Removed|
|3|Make all orders practical|Direct search/status/source filters, history filter, account dialog|
|4|Remove daily cash opening/closing|Removed from production manager navigation/payment page; historical cash records retained|
|5|Remove print queue section|Removed from sidebar and page routing; payment print failures can be reviewed in printer settings|
|6|Redesign reports|Summary cards, hourly chart, date/source filters, separate receipts and product views, CSV exports|
|7|Redesign settings|Separate General, Menu, Printer, inPOS and Backup tabs|
|8|Open table account directly|Account dialog with items, add/edit/remove, move, service, payment and close actions|
|9|No automatic order/addition printing|Migration enforces on-payment receipt policy before the print worker starts. Kitchen queue creation is suppressed for migrated runtime|
|10|Remove staff product images|Only the original logo remains; product rows are text and quick actions|
|11|Less scrolling, practical phone UI|Fixed-height screens, separate menu/cart/orders, search/categories, quantity counters, merged identical variants|
|12|Add/edit/remove existing items|Revision-checked actions and audit history; reductions below paid/allocated amounts rejected|
|13|Move same order to another table|Stable ID, items/payments preserved; occupied destinations rejected without merging|
|14|Staff payment/close/ready/delivered|Active staff required; explicit cash/terminal confirmation and receipt choice; unpaid close rejected|
|15|Sound + visible manager notification|Persisted event IDs, one-time alerts and clickable order banner; sound toggle|
|16|inPOS m530 automatic card integration|Typed adapter and durable payment coordinator: approve/decline/cancel/unknown, reference-based inquiry, no automatic resubmission. Production gateway unavailable until official vendor SDK/app ID/authorized pairing is supplied. Current Kart action records only operator-confirmed physical-terminal payment|

Legacy print/cash/report panel classes remain for compatibility and regression coverage; production manager routes use the new screens. Existing restaurant records are preserved. Phone commands use the same SQLite transaction/idempotency mechanism as order submissions. An uncertain network response is retried with the same request ID. Editing/removing records retains audit history.

Physical inPOS pairing, bank acceptance and XP-237B paper output require on-site hardware verification. The optional application print is a non-fiscal account summary; the m530's fiscal documents are separate.
