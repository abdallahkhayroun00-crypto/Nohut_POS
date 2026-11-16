# Ordering QR campaigns

Desktop and employee phones show **Kampanyalar** first. The existing QR synchronizer supplies campaign titles, prices, dates and item descriptions at startup and every ten minutes. Offline operation uses the last synchronized catalog. No QR menu content is modified.

Campaign products are derived views with stable reserved negative IDs. They are not inserted into the normal menu. Known source labels resolve to real catalog products; the approved `Eker Ayran` bundle component means `Küçük Ayran` (170ml). A single dessert promotion resolves to its existing title. Unresolved, disabled, future or expired offers are unavailable. New recipes with different names must resolve to real catalog entries before they can be sold.

Each sold line keeps the campaign's base price and one component slot for each individual item. Two wraps have independent ingredient removals, notes and signed adjustments. The price is campaign base plus parent adjustment plus component adjustments; component retail prices are never added to the bundle total. Quantity multiplies the entire customized combo. Use separate lines for differently customized combos.

The server re-resolves new phone submissions against the current catalog, ignores client prices and component names, validates slots and quantities and retains normal revision/idempotency checks. Desktop drafts reject changed prices. Historical order edits use the stored recipe and price snapshot even after the promotion ends. Existing payment/allocation guards prevent reductions below paid or allocated amounts.

Customer receipts, kitchen tickets and previews include component details. Campaigns remain one priced line for split bills and reports. No automatic substitution price rules or bank-terminal activation are introduced.

Coverage includes source prices, recipes, dates, unavailable components, separate wrap notes, extras multiplied once, split payment, stale drafts, historical edits, forged prices/slots and phone retry. Browser workflows exercise component dialogs and conflict preservation at 320, 390, 768 and 1280 pixels.
