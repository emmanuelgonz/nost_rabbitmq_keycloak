# Migrating NOS-T RabbitMQ to NASA-Hosted Keycloak

**Status:** Proposal / pre-implementation
**Prepared:** 2026-07-14
**Scope:** Production stack (`docker-compose.yml`) for `nost.smce.nasa.gov`
**Author:** Emmanuel Gonzalez

---

## 1. Current Setup and How It Works

The production stack authenticates all RabbitMQ access through a **self-hosted Keycloak container** that we provision, run, and maintain inside our own Docker Compose deployment. Keycloak serves as the OAuth 2.0 / OpenID Connect (OIDC) provider and enforces two-factor authentication (2FA) via one-time passwords (OTP), satisfying the NASA Science Managed Cloud Environment (SMCE) 2FA requirement. RabbitMQ trusts no local users; its only authentication backend is `rabbit_auth_backend_oauth2`.

### Authentication flow

A browser reaching the RabbitMQ management UI is redirected to Keycloak, completes password plus OTP, and returns with a signed JSON Web Token (JWT). RabbitMQ validates that token against Keycloak and reads the user's permissions directly out of its scopes. The flow depends on three artifacts:

1. **The realm** — `NOS-T`, self-provisioned by importing `conf/keycloak/import/*.json` at container startup (`--import-realm`).
2. **The clients, scopes, and roles** — all defined inside that realm, including the OTP required action.
3. **The permission vocabulary** — Keycloak scopes encoded as RabbitMQ topic-permission strings: `rabbitmq.tag:administrator` for management-UI access, and `rabbitmq.{configure,read,write}:<vhost>/<exchange>/<routingkey>` for resource access, narrowed in this deployment to the `nost` exchange (e.g. `rabbitmq.write:*/nost/*`).

### The token: what login issues and how it is used

Successful login yields a **signed JSON Web Token (JWT) access token**, issued by Keycloak under the OAuth 2.0 / OIDC standard, alongside a companion **refresh token**. The access token is a self-contained, cryptographically signed credential — RabbitMQ needs no callback to Keycloak to trust a presented token, only Keycloak's public signing keys. Its payload carries the claims RabbitMQ depends on: (i) the identity, via the `user_name` claim named in `auth_oauth2.preferred_username_claims.1`; (ii) the audience (`aud`), which must include `rabbitmq`, matching `auth_oauth2.resource_server_id`; (iii) the permission scopes, such as `rabbitmq.tag:administrator` and `rabbitmq.write:*/nost/*`, plus any listed under the `extra_scope` key; and (iv) the issuer (`iss`) and expiry (`exp`).

The token is presented differently at the two access surfaces, but validated the same way:

- **Management UI (browser).** After the Authorization Code flow completes, the browser holds the access token and sends it as a bearer credential on each request to the management plugin. RabbitMQ reads `rabbitmq.tag:administrator` from the token to grant UI access.
- **AMQP clients (e.g. Pika).** The client obtains a token from Keycloak — by client-credentials grant, or by direct-access grant with username, password, and OTP — then presents that **token string as the AMQP password** when opening the connection. There is no separate broker password; the JWT *is* the credential.

On every presentation, RabbitMQ validates the token locally before honoring it: (i) it verifies the signature against Keycloak's published signing keys, fetched from the JWKS endpoint that OIDC discovery advertises at `auth_oauth2.issuer`; (ii) it checks that `iss`, `aud`, and `exp` are valid; and (iii) it translates the `rabbitmq.*` scopes into concrete configure, read, and write permissions on the `nost` exchange. No user record exists inside RabbitMQ — identity and authorization live entirely in the token.

Access tokens are deliberately short-lived, which matters most for AMQP. Because a connection cannot outlive the token that opened it, **long-lived AMQP connections must refresh the token before it expires** — the client uses the refresh token to obtain a new access token and updates it on the live connection (the sample clients refresh roughly every 55 seconds). The management UI refreshes transparently in the browser. This refresh dependency is why the token-lifespan and refresh policy in NASA's realm (Section 2b, item 8) is a required input, not a detail.

### The dual-URL subtlety

`conf/keycloak/rabbitmq.conf` intentionally holds two different Keycloak URLs, because the browser and the RabbitMQ server reach Keycloak over different network paths:

| Setting | Value | Used by |
|---------|-------|---------|
| `management.oauth_provider_url` | `https://nost.smce.nasa.gov:8443/realms/NOS-T` | The **browser** — public redirect for login |
| `auth_oauth2.issuer` | `https://keycloak:8443/realms/NOS-T` | **RabbitMQ server** — internal Docker DNS for token validation |

Both point at the same realm. Because RabbitMQ validates tokens against an internal hostname that will not match the public certificate, `auth_oauth2.https.peer_verification` and `ssl_options.verify` are set to `verify_none`. This internal-DNS arrangement exists **only** because RabbitMQ and Keycloak share the `rabbitmq_net` bridge network — a coupling that disappears once Keycloak moves off-box.

### What we own today

Running our own Keycloak means we control the realm end to end: we self-provision clients, scopes, roles, and users by editing and re-importing the realm export. The cost is that we also own patching, availability, secrets (`KEYCLOAK_ADMIN` / `KEYCLOAK_ADMIN_PASSWORD`), and TLS for the Keycloak container (issued through nginx-proxy + acme-companion on port 8443).

---

## 2. Changes Required to Migrate

The dependency is narrower than it appears. In tracked configuration, **RabbitMQ is the only consumer of Keycloak**, and it consumes it purely over standard OIDC (issuer discovery + JWKS). Nothing requires Keycloak to be a container we own. The migration is therefore mostly a configuration swap on our side, gated by realm-configuration items that only NASA can provide.

### 2a. Repo-side changes (our responsibility)

| File / location | Change |
|-----------------|--------|
| `docker-compose.yml` (lines 41–60, the `keycloak:` service) | **Delete the entire service block.** Also remove the `conf/keycloak/import/` volume mount and the `KEYCLOAK_ADMIN` / `KEYCLOAK_ADMIN_PASSWORD` environment variables. We stop provisioning a realm entirely. |
| `conf/keycloak/rabbitmq.conf:10` (`management.oauth_provider_url`) | Repoint to NASA's public Keycloak URL and realm name. |
| `conf/keycloak/rabbitmq.conf:31` (`auth_oauth2.issuer`) | Replace the internal Docker-DNS host with NASA's **public** URL. It must match the `iss` claim in tokens NASA issues, exactly. Both URLs now collapse to a single public value. |
| `conf/keycloak/rabbitmq.conf:33` (`auth_oauth2.https.peer_verification`) and `ssl_options.verify` | Can flip back to real verification, since NASA's public certificate will match its own hostname. The `verify_none` was only needed to validate against an internal name behind a public cert. |
| `conf/keycloak/advanced.config` (referenced at compose line 77; absent from the working tree) | Inspect before migrating. If it pins a signing key or resource-server block, remove it — signing keys are discovered automatically from NASA's JWKS endpoint. |
| nginx-proxy / TLS | Removing the Keycloak container removes its `VIRTUAL_HOST` + Let's Encrypt cert path on port 8443. Confirm nothing else routed through it. |

### 2b. NASA-side prerequisites (the real gating factors)

For RabbitMQ to authenticate against NASA's Keycloak, their realm must expose the exact contract RabbitMQ expects. These items are the substance of the coordination:

1. **Realm identity** — the base Keycloak URL and realm name, which drive both `rabbitmq.conf` URLs verbatim.
2. **Management-UI client** — equivalent to today's `rabbitmq-client-code`, with redirect URIs pointing at our RabbitMQ host.
3. **Resource server and scopes** — `resource_server_id = rabbitmq`, plus the custom permission vocabulary (`rabbitmq.tag:administrator` and `rabbitmq.{configure,read,write}:*/nost/*`).
4. **Claim mappings** — the `extra_scope` additional-scopes key and the `user_name` preferred-username claim.
5. **Programmatic client** — a confidential client plus secret (equivalent to `producer`) for AMQP clients that authenticate without a browser.
6. **Two-factor authentication** — OTP configured as a required action in their realm.
7. **Network egress and trust** — routable HTTPS from our RabbitMQ container to their Keycloak for OIDC discovery and JWKS retrieval, and a trust path for the CA that signs their Keycloak certificate.
8. **Token and governance policy** — token lifespan and refresh behavior (long-lived AMQP connections require refresh), and a defined owner and turnaround for user/role provisioning going forward.

### 2c. Open items to resolve first

Three unknowns determine whether this is a one-line-per-field swap or a larger effort:

- **Custom scope names.** RabbitMQ's permission model rides on scope strings like `rabbitmq.write:*/nost/*`. If NASA's realm governance disallows arbitrary scope strings, we must map permissions through roles or client scopes instead — a materially larger change.
- **Front-end coupling.** `nost-sos`, `nost-monitor-frontend`, and `nost-monitor-backend` read configuration from gitignored `.env` files. If they also authenticate against Keycloak, their client configs and issuer URLs need the same migration; otherwise we fix RabbitMQ and break the front end.
- **`advanced.config` contents.** The file is mounted read-only into RabbitMQ but is absent from the working tree, so we cannot yet confirm whether it pins signing keys that OIDC discovery would supersede.

---

## 3. Timeline

The critical path runs through NASA's realm configuration, not our code. Repo-side changes are small and fast once the realm contract is known; the schedule below is expressed as effort and dependency rather than fixed dates, and assumes validation in a non-production environment before cutover.

| Phase | Work | Owner | Est. effort | Depends on |
|-------|------|-------|-------------|------------|
| **0. Alignment** | Confirm feasibility, agree on the realm contract (Section 2b), resolve the three open items | Joint | Meeting + follow-ups | — |
| **1. Realm provisioning** | NASA creates the realm, clients, scopes, roles, claim mappings, and OTP action; delivers URLs, client IDs, and the programmatic client secret | NASA | 1–2 weeks | Phase 0 |
| **2. Repo-side changes** | Edit `rabbitmq.conf`, remove the Keycloak service, review `advanced.config` (Section 2a) | Us | 0.5–1 day | Phase 1 |
| **3. Staging validation** | Validate browser login + OTP, token validation, AMQP publish/consume against the `nost` exchange, and egress/cert trust | Us (+ NASA for access issues) | 2–4 days | Phase 2 |
| **4. Front-end migration** | If front-end apps share Keycloak, migrate their `.env` client/issuer config | Us | 1–3 days | Phase 1; runs parallel to 3 |
| **5. Production cutover** | Deploy to `nost.smce.nasa.gov`, monitor logs, verify end-to-end | Us | 0.5 day + monitoring | Phases 3–4 |

**Estimated end-to-end:** roughly **2–4 weeks**, dominated by NASA's realm-provisioning turnaround in Phase 1. Our own implementation is on the order of **1 person-week**. The largest schedule risk is the custom-scope question in Section 2c; if permissions must be re-modeled through roles, add time to Phases 1–3.

**Recommended next step:** treat Phase 0 as a gate. Resolve the three open items and lock the realm contract before writing any code, so that Phase 2 becomes a mechanical, low-risk swap.
