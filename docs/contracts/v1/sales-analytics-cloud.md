# Cloud Sales Analytics Projection v1 (`SalesView`)

Status: **Implemented / Tested (pending independent cross-review)**.

## Purpose
Provides the cloud read projection for the Yönetici **Satışlar** tab (Android Yönetici & Yönetici PWA) backed by Windows-authoritative calculations from `flutter_desktop/lib/sales_view.dart` and `flutter_desktop/lib/demand_view.dart`.

## 1. Windows Agent Push RPC
- **RPC:** `public.nohut_agent_report_sales_analytics(p_token text, p_payload jsonb)`
- **Auth:** Active Windows agent opaque token (`nohut_private.authenticate_windows_agent(p_token)`).
- **Payload shape:**
  ```json
  {
    "range": "week" | "last4" | "month" | "today",
    "businessDay": "YYYY-MM-DD",
    "from": "YYYY-MM-DD",
    "to": "YYYY-MM-DD",
    "daily": [
      {
        "day": "YYYY-MM-DD",
        "cashCents": 150000,
        "cardCents": 250000,
        "otherCents": 0,
        "platformCents": 80000,
        "refundCents": 10000,
        "netCents": 390000,
        "orderCount": 42,
        "masaCount": 28,
        "gelalCount": 14,
        "onlineCount": 9
      }
    ],
    "topProducts": [
      { "name": "Falafel Dürüm", "category": "Dürümler", "qty": 35, "grossCents": 560000 }
    ],
    "heatmap": [[0, ... 24 ints], ... 7 rows (0=Pzt..6=Paz)],
    "platforms": [
      { "source": "Trendyol GO", "orders": 9, "grossCents": 80000 }
    ],
    "totals": { "netCents": 390000, "orderCount": 42, "averageCents": 9286 },
    "note": "Tahsilatlar kasadaki Masa ve Gel-Al ödemeleridir.",
    "calculatedAt": "2026-11-28T14:30:00Z",
    "sourceRevision": 10
  }
  ```
- **Guards:** Enforces 7×24 non-negative integer heatmap, `from <= to`, forbidden secret key rejection (`42501`), and monotonic `sourceRevision` (older revisions return `{"status":"stale_ignored"}`).

## 2. Authenticated Client Read RPC
- **RPC:** `public.nohut_sales_analytics_view(p_device_id uuid, p_client text, p_permission_version bigint, p_range text default 'week')`
- **Authorization:** Requires `nohut_private.authorize(..., 'sales.view', ...)` (`yonetici` / `windows`; denied for `personel` or missing grant).
- **Response (`200 OK`):**
  - When data exists: `{"status":"ok","sales":{...},"syncMeta":{"range":"week","hasData":true,"sourceRevision":10,"updatedAt":"..."}}`
  - When Windows has not pushed that range yet: `{"status":"ok","sales":null,"syncMeta":{"range":"week","hasData":false}}`
  - When unauthorized: `{"status":"forbidden","code":"..."}`
