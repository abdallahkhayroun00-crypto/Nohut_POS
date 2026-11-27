# Background push for Android (task N4): evaluation only

**Owner:** Claude · **Date:** 2026-11-27 · **Spec:** §23.5 · **Status:** evaluation. Nothing was provisioned, and no Firebase project or credential was created.

## What works today without any new service
- **Windows POS:** durable notification history (Ayarlar › Bildirimler › Bildirim geçmişi), the existing sounds, and the online order alarm.
- **Local Personel and Yönetici browser apps (LAN):**
  - the bell polls `/api/notifications` every 15 s while the page is open, filtered by the user's permissions;
  - read state is kept per user;
  - foreground only, which is what §23.5 promises for an iPhone over plain HTTP.
- **Cloud (outside the restaurant):** Supabase Realtime can carry the same event contract once Codex's cloud read RPCs (#39) land. No new account or credential is needed.

## Firebase Cloud Messaging + `flutter_local_notifications` (Android background and lock screen)
| Question | Finding |
|---|---|
| Cost | FCM is free with no message quota. `flutter_local_notifications` is an open-source package. |
| What it needs | A new Firebase project, an Android app registration, `google-services.json` in the APK build, and a server key or service account for sending. A server key cannot sit in the Windows POS and be safe there. Sending belongs in a Supabase Edge Function with the key held as a Supabase secret. |
| Privacy | Payloads go through Google. Following §23.5, send **title only** (no body) and a category/eventId. The app then fetches details over its authenticated session. |
| Token lifecycle | Store tokens per (user, device). Delete a token on logout, device revocation, deactivation or loss of the category permission. This plugs into `nohut_private.devices` (A2). |
| iPhone | Not covered. Background push needs APNs. Web Push needs HTTPS, Home Screen install and permission, which is a separate check. |

## Recommendation
1. Keep the foreground LAN bell and history (done) and add Supabase Realtime for the cloud apps (N3, after #39).
2. Use FCM only for Android background and lock-screen alerts, with title-only payloads sent from an Edge Function.
3. **Owner approval needed** before creating the Firebase project and its credentials. Per the owner's rule, nothing is created until then.
