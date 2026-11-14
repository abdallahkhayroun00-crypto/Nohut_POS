# POS usability update

Based on the supplied 14 November 2026 audit, checked against upstream `f319ad0`.

| Area | Result |
| --- | --- |
| Staff open orders | Shows item quantities, individual notes, removed ingredients, date, service state and table shortcut; includes ready/source filters. |
| Phone refresh | Updates connection and order data without rebuilding cart inputs. Focus and text survive polling. |
| Phone cart | Independent product rows, category navigation, Turkish search, quantity buttons, customization, visible review and total. |
| Phone submissions | Stable success message; pending requests freeze editing and retry with the original request ID. Conflicts refresh data and preserve the draft for review, without automatically resubmitting. |
| Staff identity | Requires selecting a worker on each fresh page visit instead of silently restoring another worker's identity. Pending requests retain their original worker. |
| Windows composer | Independent rows allow the same product with different notes; basket stays visible across categories; search and edit/remove controls. |
| Occupied tables | Composer identifies occupied tables and existing daily ticket numbers. Adds to the displayed account; refuses submission if its account changed while the dialog was open. |
| Order selection | Source filters clear the old selection. Archived order rows and details include the business date. Save confirmation uses the same daily number as the ticket. |
| Payments | Validates positive amount, remaining balance and cash received. Review shows method and cash change; card registration requires explicitly confirming success on the separate bank terminal. |
| Refunds and cash close | Final refund review includes amount, method and reason. Cash close previews expected/count/difference and rejects a changed cash session. |
| Split bill | One menu assigns the remaining product share to a guest; precise partial-share editing remains available. Clearing shares requires confirmation. |
| Platform examples | Run in a separate in-memory sandbox. They do not save restaurant orders, payments or print jobs. Settings no longer queues example commands into production SQLite. |
| Reports | Today/7 days/30 days presets and a calendar range picker; historical filters and CSV exports remain available. |
| Print queue | Confirmation before manual requeue, including successful jobs; protects against queue state changing during confirmation. UTF-8 process errors remain readable. |
| Dashboard | Retains the already implemented Istanbul daily reset, with actual waiting/review-required print counts alongside open orders and occupied tables. |
| Floor plan | Readable compact table cards below 740px; table 5 includes balance; placement rejects overlapping tables, the wall and doorway. This is a layout aid, not a physical accessibility certification. |
| Branding and readability | Original colored QR-menu logo on Windows and phone, official green/cream colors, darker secondary labels, labeled drawer on small screens. |
| Offline first launch | Bundled 54-product snapshot from the official catalog, including Vegan Dürüm, Layali Lübnan and 1 Adet Falafel. Şambali remains stored and inactive. Existing stored menus and historical sales are not replaced by this snapshot. |

## Validation

- Existing accounting, SQLite concurrency, idempotency, catalog migration, product visibility, daily rollover and printer-failure tests.
- New widget workflows for independent notes, payment cancellation, cash-close cancellation, isolated platform examples, floor collisions and compact navigation with 150% text.
- Real Chromium UI tests at 320/390/768px with mocked HTTP responses, covering focus through polling, hidden products, categories, variants, success messages, conflicts and lost-response retry. These are not physical iPhone or restaurant Wi-Fi tests.
- Existing HTML POS regression suite remains part of CI.

## Remaining work outside this POS update

The audit also covers campaign posters, multilingual poster artwork, third-party opening hours/prices, customer-review source attribution and a broader brand positioning strategy. Those materials and accounts are not changed here. A dedicated kitchen display and authenticated staff roles remain separate features; this update does not add passwords or change the requested employee-selection flow.

The earlier midnight rollover, automatic public catalog synchronization and hidden-product protections are retained. A GitHub build does not update the restaurant's installed app. Back up SQLite and verify the new package on the restaurant laptop and XP-237B before use; no physical receipt output or bank transaction is claimed by these tests.
