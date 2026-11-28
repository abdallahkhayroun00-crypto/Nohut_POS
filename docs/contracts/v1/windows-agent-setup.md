# Windows scoped-agent setup (PR #39; synthetic-tested, not deployed)

Authentication is Claude's A1 contract from PR #42. The setup client consumes an already registered Windows device and a short-lived access token provider. It does not implement login, PIN, MFA or refresh-token storage.

All setup RPCs require `authenticated`, a verified JWT `sub/session_id/aal2`, `nohut_windows_owner_session(device)` and `authorize(..., 'windows', 'sync.cloud.configure', permission_version)`. Caller identity, restaurant and session cannot be supplied as parameters. Devices/sessions/users are locked through mutation and rechecked. Ordinary Personel/Yönetici devices cannot configure agents, including owner devices.

| RPC | Parameters | Result |
|---|---|---|
| `nohut_enroll_agent` | `p_device_id uuid`, `p_permission_version bigint`, `p_epoch uuid`, `p_request_id uuid`, `p_token_sha256 text` | `{status:'enrolled', agent_id, restaurant_id, authority_epoch, windows_device_id, expires_at, schema_version:1}`; an expired/revoked previous request returns `{status:'revoked'}` |
| `nohut_revoke_agent` | `p_device_id uuid`, `p_permission_version bigint`, `p_agent_id uuid` | `{status:'revoked', agent_id}`; repeat revocation is idempotent |

`WindowsAgentSetup` generates 32 random bytes and a UUID request ID, then durably stores the pending enrollment in current-user DPAPI **before** sending its token hash. The server stores only SHA-256, never plaintext. Retrying an exact request returns the same credential metadata. Reusing a request ID with changed context/hash is a conflict. Rotation uses a new request/token and revokes the prior credential once. Replaying an older request cannot rotate again. Revoked credentials cannot ingest or execute commands. A different Windows device requires a reconciled authority change.

`WindowsAgentSecrets` uses `WindowsVault` and a cross-process file lock. Pending setup cannot be loaded as active agent credentials. The previous credential stays in the vault while rotation is pending; after confirmed enrollment the new credential replaces it atomically. A failed/foreign/malformed response retains the pending request. No automatic retry generates a new token. Owner access/refresh credentials are never persisted here. After confirmed revocation the local token is removed. Authority/project changes are fenced for the first-sync/reconciliation workflow.

The runtime still needs Claude's Windows login/setup UI and the completed first-sync/legal/configuration gates. Main's A1 approval contract (`20261127201000`) now requires a single-use, tenant-bound ten-minute ticket for `nohut_register_windows_device`. The first ticket is issued by a trusted server/provisioning channel through `nohut_issue_windows_bootstrap`; further tickets require an approved Windows owner session through `nohut_issue_windows_approval`. Native and browser clients never receive a service-role key. `nohut_register_device(..., 'windows', ...)` always refuses. This verifies an approved installation, not the physical OS; HTTP/user-agent strings cannot prove that. Synthetic fixtures use the public ticket and registration APIs before agent setup.

Evidence: `agent_setup_test.sql`, `windows_owner_session_test.sql`, `windows_agent_setup_test.dart` (DPAPI on Windows), and `cloud_http_integration_test.dart`. The synthetic HTTP bridge uses actual independent PostgreSQL connections to check concurrent setup/session updates. No real service credentials, data or platform actions are used.
