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

## Still open after this

- **AMQP resource permissions** flow through realm **roles** → the `extra_scope` claim (`auth_oauth2.additional_scopes_key = extra_scope`). Realm roles + user role assignments are a separate partial-import gap to close before publish/consume works.
- **Exchange naming:** the realm's resource scopes target a **`sos`** exchange (`rabbitmq.*:*/sos*/sos*`), not `nost`. Confirm which exchange this deployment is meant to authorize.

## Reference

Exact definitions were extracted from the working realm export:
`realm-export_2026-07-27_nost_personal.json` (science_cloud_keycloak). The `rabbitmq.*` client scopes are mapper-less; the three protocol mappers above live on the `rabbitmq-client-code` client.
