# Nohut POS 0.5

The six main destinations are Genel Bakış, Masalar, Siparişler, Kasa & Ödemeler, Raporlar and Ayarlar. Siparişler contains the order list and online workflow. Ayarlar contains Personel and Bağlantı alongside the existing configuration tabs. Five table accounts and existing stored orders are retained.

The original Nohut logo, green/cream/gold palette, Barlow body font and Bree Serif headings remain bundled for offline use. The employee phone header uses the complete Nohut Falafel name. The public QR menu is not modified.

Receipt preview and spool output now use the same raster artwork, including the real monochrome logo, Turkish glyphs, currency, item wrapping and campaign component notes. Width defaults to 48 mm (384 dots) on the user's 56 mm roll. Artwork is not shrunk to a fixed label height.

## XP-237B setup

1. Verify the printer's physical mode using the Xprinter utility/self-test. Receipt mode and label mode are different. The application does not change printer firmware mode.
2. In Ayarlar → Yazıcı, select the exact physical Windows printer name and actual roll width. Printable width must be 30–48 mm. Start with 4 mm vertical safety margin and 18 mm logo.
3. Windows · Fiş görseli remains the default. It sends the shared image at actual size. Page-size or printable-area mismatches are reported instead of silently shrinking the receipt. Use the proper receipt driver and continuous variable-length stock.
4. ESC/POS · Fiş modu is an explicit option for a printer already configured in Receipt mode. It sends raster bands through the Windows RAW spooler and avoids label page-length limits. It preserves Turkish letters and the logo as pixels. Horizontal software offset is reset to zero in this mode; center the paper guides physically. No auto-cut command is sent to this tear-off printer.
5. Run Hizalama Testi Yazdır, then one short bill and one bill longer than 120 mm. Confirm the complete logo, item prices and Afiyet olsun footer. A spool acknowledgement confirms submission, not physical paper output.

Failed or ambiguous prints stay in Kontrol gerekli and are not automatically retried. Check the paper before manually retrying to avoid duplicate receipts.

References: https://www.xprintertech.com/desktop-label-printer-xp-237b ; https://www.xprintertech.com/download/xp-237b ; https://download4.epson.biz/sec_pubs/pos/reference_en/escpos/gs_lv_0.html ; https://learn.microsoft.com/en-us/windows/win32/printdocs/sending-data-directly-to-a-printer

Verification covers navigation, preview accessibility, full native artwork, raster band packing, invalid-printer failure, receipt spool syntax/native binding compilation, phone workflows at four widths and Windows release compilation. Paper output must still be verified on the restaurant's actual printer.
