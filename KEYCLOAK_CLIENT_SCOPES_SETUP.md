# Keycloak Client Scopes Setup (NASA-Hosted NOS-T Realm)

**Purpose:** Manually recreate the `rabbitmq.*` client scopes and the `rabbitmq-client-code` mappers in the NASA Science Cloud Keycloak (realm `NOS-T`, `https://auth.sciencecloud.nasa.gov`), using the **admin console only**.

**Why this is needed:** Keycloak's **Partial Import cannot import client scopes** — it only handles clients, roles, users, groups, and identity providers. A partial import therefore creates the `rabbitmq-client-code` client but silently drops its `rabbitmq.*` client scopes, producing this error at RabbitMQ login:

```
ErrorResponse: Invalid scopes: openid profile rabbitmq.tag:administrator
```

The error comes from Keycloak rejecting the authorization request, because the requested scope `rabbitmq.tag:administrator` doesn't exist as a client scope in the realm. `openid` and `profile` are built-in; the custom `rabbitmq.*` scope is the one that must be created.

> Ensure the realm selector (top-left) shows **NOS-T**, not `master`, throughout.

---

## Part A — Create the client scopes

The immediate login error needs only the first scope (`rabbitmq.tag:administrator`); create the rest for a complete realm. Repeat these steps once per scope.

1. Left sidebar → **Client scopes**.
2. Click **Create client scope** (top-right).
3. Fill in:
   - **Name**: the exact scope string, including the colon and any `*` / `/`, no trailing spaces.
   - **Description**: leave blank.
   - **Type**: **Default**.
   - **Protocol**: **OpenID Connect**.
   - **Display on consent screen**: On (harmless either way).
   - **Include in token scope**: **On** ← critical. This puts the scope name into the access token's `scope` claim, which is what RabbitMQ reads for permissions.
4. Click **Save**.

Scopes to create (all identical in form — none have mappers):

| # | Scope name |
|---|---|
| 1 | `rabbitmq.tag:administrator` |
| 2 | `rabbitmq.tag:management` |
| 3 | `rabbitmq.read:*/*/*` |
| 4 | `rabbitmq.write:*/*/*` |
| 5 | `rabbitmq.configure:*/*/*` |
| 6 | `rabbitmq.read:*/sos*/sos*` |
| 7 | `rabbitmq.write:*/sos*/sos*` |
| 8 | `rabbitmq.configure:*/sos*/sos*` |

---

## Part B — Attach the tag scopes to the client

Only the two **tag** scopes attach to `rabbitmq-client-code` (matching the realm export; the read/write/configure scopes exist in the realm but are not bound to this login client).

1. Left sidebar → **Clients**.
2. Click **rabbitmq-client-code**.
3. Open the **Client scopes** tab (sub-tabs run along the top of the client page).
4. Click **Add client scope**.
5. Tick **`rabbitmq.tag:administrator`** and **`rabbitmq.tag:management`**.
6. Click **Add**, and choose **Default** from the dropdown.

> If Type was set to Default in Part A, these may already be listed — just confirm they appear as **Default**.

---

## Part C — Verify (or create) the three client mappers

Login needs `rabbitmq.tag:administrator`; token *validation* right after login needs `aud: rabbitmq`, and identity/roles need `user_name` and `extra_scope`. These come from three mappers on the client. A partial import that created the client may have brought them over — check first.

1. **Clients → rabbitmq-client-code → Client scopes** tab.
2. Click the top row named **rabbitmq-client-code-dedicated** (the client's dedicated scope).
3. Open its **Mappers** tab.
4. Confirm `aud`, `realm roles`, `username` exist. For any missing, click **Add mapper → By configuration** and create it:

**`aud`** — mapper type **Audience**
- Name: `aud`
- Included Custom Audience: `rabbitmq`
- Add to access token: **On**
- Add to ID token: Off

**`realm roles`** — mapper type **User Realm Role**
- Name: `realm roles`
- Multivalued: **On**
- Token Claim Name: `extra_scope`
- Claim JSON Type: **String**
- Add to access token: **On**
- Realm Role prefix: (blank)

**`username`** — mapper type **User Property**
- Name: `username`
- Property: `username`
- Token Claim Name: `user_name`
- Claim JSON Type: **String**
- Add to ID token: **On**, Add to access token: **On**, Add to userinfo: **On**

---

## Part D — Confirm the fix

1. **In-console (optional):** Clients → rabbitmq-client-code → **Client scopes** tab → **Evaluate** sub-tab → pick your user → **Generated access token**. Confirm `scope` contains `rabbitmq.tag:administrator`, `aud` contains `rabbitmq`, and `user_name` is set.
2. **Live:** go to `https://nost.smce.nasa.gov:15671/` → **Click here to log in**. The "Invalid scopes" error should be gone and you should reach the Keycloak login page.

No `rabbitmq.conf` change or container restart is required — this is entirely Keycloak-side. Keep `management.oauth_scopes = openid profile rabbitmq.tag:administrator` intact.

---

---

# Part 2 — AMQP resource permissions (publish/consume)

The login fix (Parts A–D) only grants the management UI. Actual AMQP read/write/configure permissions flow two ways, merged by RabbitMQ from the token:

1. **Client default scopes → `scope` claim** — each application authenticates as a Keycloak client whose RabbitMQ permissions are its default client scopes.
2. **Realm roles → `extra_scope` claim** — a human user's assigned realm roles (via the `realm roles` mapper) become permissions.

**Deployment decision (recorded):** reuse the **existing** permission definitions only — the **`sos`**-scoped scopes/roles and the **wildcard `*/*/*`** ("sudo", all exchanges). The `nost` exchange is authorized via the wildcard; **no `nost`-specific scopes or roles are created.** All eight client scopes already exist from Part A, so this part just attaches them to clients and assigns matching roles to users.

## Part E — Verify the realm roles exist

Partial import *does* support realm roles (unlike client scopes), so these may already be present. Realm roles → confirm each exists; create any missing via **Create role** (name only):

- `rabbitmq.tag:administrator`, `rabbitmq.tag:management`
- `rabbitmq.read:*/*/*`, `rabbitmq.write:*/*/*`, `rabbitmq.configure:*/*/*`
- `rabbitmq.read:*/sos*/sos*`, `rabbitmq.write:*/sos*/sos*`, `rabbitmq.configure:*/sos*/sos*`

## Part F — Attach resource scopes + mappers to application (service) clients

Each app's permissions come from its **default client scopes**, and each client needs the same three mappers as `rabbitmq-client-code`. Apply per client:

| Client | Attach these resource scopes (as Default) | Reach |
|--------|-------------------------------------------|-------|
| `nost_sos` | `read/write/configure:*/sos*/sos*` | sos only |
| `nost_sudo` | `read/write/configure:*/*/*` | all exchanges (incl. `nost`) |
| `mgt_api_client` | `tag:administrator`, `tag:management` | management API |

For **each** client:
1. Clients → select client → **Client scopes** tab → **Add client scope** → tick the rows above → **Add → Default**.
2. Clients → same client → **Client scopes** tab → click **`<client>-dedicated`** → **Mappers** tab → ensure `aud`, `realm roles`, `username` exist (Part C recipe); create any missing. `aud: rabbitmq` is required on every client, including service-account clients.

## Part G — Grant human users resource permissions

Human users get permissions from assigned **realm roles** (mapped into `extra_scope`). Per user:

1. Users → select user → **Role mapping** → **Assign role**.
2. Filter to **realm roles** and assign the set they need:
   - Management UI: `rabbitmq.tag:administrator`
   - All exchanges (incl. `nost`): `rabbitmq.{read,write,configure}:*/*/*`
   - sos only: `rabbitmq.{read,write,configure}:*/sos*/sos*`
3. Save. The `realm roles` mapper places these into `extra_scope`, which RabbitMQ merges with the `scope` claim.

## Verify AMQP access

Decode a token issued to the app client (or user) and confirm the permission appears in **`scope`** (client path) or **`extra_scope`** (role path), and `aud` contains `rabbitmq`. Then run a real publish/consume — the wildcard/sudo path for the `nost` exchange, the sos scopes for `sos`.

## Notes

- `nost` is authorized via the wildcard `*/*/*` (sudo), not a dedicated scope — intentional per the deployment decision above.
- Client scopes and realm roles share the same `rabbitmq.*` names by design; they feed the `scope` and `extra_scope` claims respectively.

---

# Part 3 — Troubleshooting & auth-flow notes

Realm-config gotchas encountered during the migration, with their fixes.

## Service-account (`client_credentials`) login fails: "service account does not exist"

**Symptom** — a service-account login (client ID + client secret, no username/password) fails at token retrieval:

```
401: {"error":"invalid_request",
      "error_description":"The associated service account for the client does not exist"}
```

Raised from `keycloak_openid.token(grant_type=["client_credentials"])` in `nost_tools/application.py`.

**Cause** — the `client_credentials` grant needs a **service-account user**. Partial import created the client but didn't provision its service-account user (Service Accounts came in disabled, or the user was never created). In the realm export the client is confidential with service accounts enabled (`publicClient=false`, `serviceAccountsEnabled=true`) — so this is a realm-config gap, not a code problem.

**Fix** (admin console, realm NOS-T):
1. **Clients → `<client>` (e.g. `nost_sudo`) → Settings**.
2. Under **Capability config**:
   - **Client authentication: On** (confidential — required for `client_credentials`).
   - **Authentication flows** → check **Service accounts roles**. Leave **Standard flow** unchecked (browser-only; unused by a headless service account); **Direct access grants** optional.
3. **Save** — this provisions the `service-account-<client>` user, which was the missing piece.
   - If it already looked enabled, toggle it **off → Save → on → Save** to force recreation of the service-account user.
4. **Credentials** tab → copy the **Client secret**; if it differs from `.env`, update `CLIENT_SECRET_KEY` to match (re-import can regenerate it).

**Verify:** Users → confirm `service-account-<client>` now exists; then Clients → client → **Client scopes → Evaluate → Generated access token** shows the `rabbitmq.*` scopes in `scope` and `aud` containing `rabbitmq`.

## Programmatic username/password logins should not require OTP

**Goal** — let username + password + client ID + client secret authenticate without an OTP prompt, while keeping 2FA on interactive (browser) logins.

**Key insight** — the two log-in paths run **separate authentication flows**: the management UI uses the **Browser** flow; username/password grants use the **Direct Grant** flow. Each has its own OTP step, so removing OTP from Direct Grant leaves Browser 2FA intact.

**Primary fix — disable OTP realm-wide on Direct Grant:**
1. **Authentication → Flows** tab.
2. Select the **direct grant** flow.
3. Find the **Direct Grant - Conditional OTP** sub-flow.
4. Set its requirement radio to **Disabled**.

**Surgical alternative — skip OTP only for specific clients:**
1. **Authentication → Flows → direct grant →** kebab menu → **Duplicate**; name it e.g. `direct grant no otp`.
2. In the copy, set **Direct Grant - Conditional OTP → Disabled**.
3. **Clients → `<client>` → Advanced** → **Authentication flow overrides** → set **Direct grant** to `direct grant no otp` → **Save**.

**Caveat — pending required actions:** disabling the flow step covers users who *have* OTP configured. Separately, a user with **"Configure OTP" as a pending required action** still fails with `invalid_grant: Account is not fully set up`. Clear it under Users → user → **Required actions**, or use a **service account** (`client_credentials`) for headless access — no user, so no OTP or required actions ever.

## Browser frontend AMQP connection refused: "ACCESS_REFUSED ... PLAIN (403)"

**Symptom** — after a successful Keycloak login, `nost-monitor-frontend` (and similarly `nost-sos`) fails to reach the broker:

```
Error during AMQP setup: AMQPError: connection closed: ACCESS_REFUSED -
Login was refused using authentication mechanism PLAIN. For details see the
broker logfile. (403)
```

**Cause** — the frontend presents the **browser-login client's user token as the AMQP password** (`new AMQPWebSocketClient(url, "/", "", accessToken)` in `main.js`). The web-login client (`sos_nodejs`, set via `DEFAULT_KEYCLOAK_WEB_LOGIN_CLIENT_ID`) has **none** of the mappers RabbitMQ needs — no `aud`→`rabbitmq`, no `realm roles`→`extra_scope`, no `username`→`user_name` (only default IP/ID/Host session mappers). So its token lacks `aud: rabbitmq` and carries the user's roles only in `realm_access.roles`, not the `extra_scope` claim RabbitMQ reads. Either gap yields a PLAIN `ACCESS_REFUSED`.

**Confirm** — `docker compose logs --tail=50 rabbitmq` names the exact reason (audience / issuer / permission / signature).

**Fix:**
1. Add the three mappers to `sos_nodejs` (Part C recipe): `aud` (Audience → `rabbitmq`), `realm roles` (User Realm Role → `extra_scope`), `username` (User Property → `user_name`).
2. Assign the **logged-in user** the rabbitmq realm roles the frontend needs. It declares an exchange, binds a queue, and consumes → **configure + read + write**: `rabbitmq.configure:*/*/*`, `rabbitmq.read:*/*/*`, `rabbitmq.write:*/*/*` (Users → user → Role mapping → Assign role). No management tag needed — it's an AMQP client, not the UI.
3. **Re-login** to mint a fresh token with the new claims, then reconnect.

**Caveat** — if the broker log points to `issuer` or `signature`/JWKS rather than audience/permission, that's a different problem (the issuer string or the `verify_peer` cert-trust change), not the mappers.

---

## Reference

Exact definitions were extracted from the working realm export:
`realm-export_2026-07-27_nost_personal.json` (science_cloud_keycloak). The `rabbitmq.*` client scopes are mapper-less; the three protocol mappers above live on the `rabbitmq-client-code` client.
