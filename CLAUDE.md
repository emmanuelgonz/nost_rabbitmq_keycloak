# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Deployment configuration (Docker Compose + reverse proxy + broker/IAM config) for the RabbitMQ event broker of the Novel Observing Strategies Testbed (NOS-T), fronted by Keycloak as an OAuth 2.0 / OpenID Connect provider with two-factor authentication. There is no application source code here and no build/lint/test tooling — the deliverables are compose files and config that wire together published container images (plus two sibling repos built from source).

## Two deployment modes — do not conflate them

- **`docker-compose.yml`** — the real production stack for `nost.smce.nasa.gov` (NASA SMCE). Full TLS via Let's Encrypt, Keycloak realm **`NOS-T`**, and the whole NOS-T front end (`nost-sos`, `nost-monitor-frontend`, `nost-monitor-backend`). This is what `conf/keycloak/rabbitmq.conf`, `nginx.conf`, and `vhost/` support.
- **`rabbitmq-docker-compose.yml`** — a standalone, no-auth, no-TLS RabbitMQ (`admin`/`admin`) with MQTT + web-MQTT plugins and the websocket TCP relay. Useful for quick local broker testing, unrelated to Keycloak.
- **`README.md`** — a step-by-step *tutorial* for a local-host variant based on `rabbitmq/rabbitmq-oauth2-tutorial`. It uses realm **`test`**, `localhost`, and `make start-keycloak` / `make start-rabbitmq` from that upstream repo — **none of those `make` targets exist in this repo.** When reasoning about the actual deployment, trust `docker-compose.yml` and `conf/`, not the README's realm/host/command details.

## Deploy the production stack

Requires (all gitignored, must exist before `up`): `.env` (`KEYCLOAK_ADMIN`, `KEYCLOAK_ADMIN_PASSWORD`, plus vars consumed by `nost-sos`), `conf/keycloak/import/*.json` (Keycloak realm export, imported via `--import-realm`), `conf/keycloak/advanced.config` (mounted read-only into RabbitMQ), and the `certs/`+`acme/` dirs (populated by acme-companion). It also builds two sibling repos that must be checked out next to this one: `../nost-monitor-frontend/` and `../nost-monitor-backend/`.

```bash
docker compose up -d --build      # bring up the full stack
docker compose logs -f rabbitmq keycloak
./clean.sh                        # DESTRUCTIVE: stops+removes ALL docker containers on the host, prunes images/networks
```

## Architecture

Request flow: **nginx-proxy** (`nginxproxy/nginx-proxy`) terminates 80/443 and auto-generates vhost config by reading `VIRTUAL_HOST`/`VIRTUAL_PORT` labels off each container via the Docker socket. **acme-companion** watches `LETSENCRYPT_HOST` and provisions/renews certs into the shared `certs/` volume. Per-path routing (`/sos/`, `/api/`, `/`) is injected through `vhost/nost.smce.nasa.gov_location` (nginx-proxy's per-host `location` snippet mechanism). The standalone `nginx.conf` encodes the same routing as a self-contained server block but is **not** what nginx-proxy uses — treat it as reference/alternative.

Auth flow: a browser hitting the RabbitMQ management UI is redirected to Keycloak, completes password + OTP, and returns with a JWT that RabbitMQ validates and mines for permissions. RabbitMQ runs `rabbit_auth_backend_oauth2` as its only auth backend (`conf/enabled_plugins`, `conf/keycloak/rabbitmq.conf`).

Permissions live entirely in Keycloak roles/scopes, encoded as RabbitMQ topic-permission strings:
- `rabbitmq.tag:administrator` → management UI access
- `rabbitmq.{configure,read,write}:<vhost>/<exchange>/<routingkey>` → resource access; the NOS-T deployment narrows these to the `nost` exchange (e.g. `rabbitmq.write:*/nost/*`)

### Issuer gotcha (the subtle, load-bearing detail)

In `conf/keycloak/rabbitmq.conf` the two Keycloak URLs are intentionally different:
- `management.oauth_provider_url = https://nost.smce.nasa.gov:8443/realms/NOS-T` — **public**, used by the browser.
- `auth_oauth2.issuer = https://keycloak:8443/realms/NOS-T` — **internal Docker DNS**, used by RabbitMQ server-to-server for token validation.

Both point at the same realm but via different network paths; changing one without the other breaks either the login redirect or token validation. `ssl_options` / `auth_oauth2.https.peer_verification` are set to `verify_none` because the internal hostname won't match the public cert.

### Ports

Keycloak `8080` (HTTP admin) / `8443` (HTTPS). RabbitMQ `5672` AMQP, `5671` AMQPS, `15672`/`15671` management (HTTP/HTTPS), `5552` stream. `rabbitmq_tcp_relay` (`cloudamqp/websocket-tcp-relay`) exposes `15670`, TLS-wrapping AMQP over WebSockets for browser clients. All services share the `rabbitmq_net` bridge network.

## Conventions when editing

- Config files (`rabbitmq.conf`, `advanced.config`) are bind-mounted read-only; a change requires restarting the RabbitMQ container, not a rebuild.
- Never commit secrets or certs — `certs/`, `acme/`, `conf/keycloak/import/*.json`, and `.env` are gitignored for that reason.
- The Keycloak realm is provisioned by importing `conf/keycloak/import/*.json` at startup; realm/client/scope changes made in the admin UI are not persisted back to the repo unless re-exported into that file.
