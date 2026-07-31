# Redeploy — NOS-T Monitor Stack (EC2)

Full teardown → cache clear → rebuild cycle for the production stack on the AWS EC2 host, run from the `nost_rabbitmq_keycloak/` deployment directory.

**Golden rule:** never delete `certs/` or `acme/`. They hold the Let's Encrypt certificates; wiping them forces re-issuance against production rate limits. Every step below leaves them (and the gitignored `.env` files) untouched.

The frontend and backend are built from sibling checkouts referenced by `docker-compose.yml`:
`../nost-monitor-frontend/` and `../nost-monitor-backend/`.

## Step 0 — Check for local edits

```bash
cd ~/nost_rabbitmq_keycloak
git status
```
If any tracked file (e.g. a temporary `ports:` mapping in `docker-compose.yml`) shows local changes you don't want, `git stash` or revert them first. `.env` files are gitignored and safe.

## Step 1 — Shut the stack down

```bash
docker compose down --remove-orphans
```
Removes this stack's containers + network (and any orphan like `nost-sos`). Bind mounts (`certs/`, `acme/`, `.env`) remain.

## Step 2 — Update all three repos to `main`

```bash
cd ~/nost_rabbitmq_keycloak   && git checkout main && git pull
cd ../nost-monitor-backend    && git checkout main && git pull
cd ../nost-monitor-frontend   && git checkout main && git pull
cd ~/nost_rabbitmq_keycloak
```
Sanity-check the key fixes are in the build contexts:
```bash
grep -n "_KEYCLOAK_AUTHORITY" ../nost-monitor-backend/src/app/auth.py       # backend auth hardening
grep -c "checkLoginIframe: false" ../nost-monitor-frontend/src/js/login.js  # should print 3
```

## Step 3 — Clear Docker cache

```bash
docker system prune -af
```
Removes stopped containers, unused images, and all build cache. Does **not** touch bind mounts, so `certs/`/`acme/`/`.env` are safe. (For build cache only: `docker builder prune -f`.)

## Step 4 — Rebuild and start

```bash
docker compose up -d --build --force-recreate --remove-orphans
```
`--build` recompiles the frontend and backend from the freshly-pulled `main`; base images (nginx-proxy, acme-companion, rabbitmq, relay) re-pull automatically.

## Step 5 — Verify

```bash
docker compose ps
# expect: nginx-proxy, nginx-proxy-acme, rabbitmq, rabbitmq_tcp_relay,
#         nost-monitor-frontend, nost-monitor-backend
docker compose logs --tail=50 nginx-proxy nginx-proxy-acme   # certs served, no re-issuance
docker compose logs --tail=50 rabbitmq                       # broker up, oauth2 backend loaded
```
Functional checks (also re-confirm the backend hardening):
```bash
curl -sk -o /dev/null -w "%{http_code}\n" https://nost.smce.nasa.gov/api/docs          # 404 (docs disabled)
curl -sk -o /dev/null -w "%{http_code}\n" https://nost.smce.nasa.gov/api/status/nost   # 401 (auth required)
```
Then in the browser: load `https://nost.smce.nasa.gov/`, log in, and run **Initialize** to confirm the full chain (login → broker → backend) end to end.

## Notes

- **Brief downtime** between Step 1 and Step 4 while the stack rebuilds.
- Frontend changes not showing → browser cache; hard-refresh (Ctrl/Cmd+Shift+R).
- `keycloak` and `nost-sos` are intentionally absent from `docker compose ps` (self-hosted Keycloak removed; `nost-sos` commented out in the merged config).
