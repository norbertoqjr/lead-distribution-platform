# Deployment

Deployment runs through GitHub Actions. Pushing to `main` in either app repo
lints, tests and builds it, then deploys over SSH and restarts it under PM2.

> This document uses placeholders only. Committing real hosts, passwords, or
> connection strings is an automatic fail condition (see [SPEC.md](SPEC.md) §18).
> The real values live in GitHub Secrets.

## Target

| Item | Value |
|---|---|
| Host | VPS provided by the interviewer |
| Frontend port | **public** — the only port exposed to the internet |
| Backend port | **private**, bound to `127.0.0.1` |
| Database | MySQL on the same host |
| Process manager | PM2, no sudo required |

Use **only** the two assigned ports. Nothing else may be bound publicly.

## Wiring

```
internet ──▶ :<PUBLIC>  Next.js  ──▶ http://127.0.0.1:<PRIVATE>  NestJS ──▶ MySQL
```

The browser never reaches the API directly. `BACKEND_URL` is server-side only
(no `NEXT_PUBLIC_` prefix), and client-side requests go to `/api/...` on the
public origin, where a route handler forwards them to the private port with the
session cookie attached.

---

## One-time bootstrap

The workflow needs Node, PM2 and its own key present before it can run.
Everything here is no-sudo.

```bash
ssh <user>@<host>

curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
. ~/.nvm/nvm.sh && nvm install 20 && nvm alias default 20
npm i -g pm2
mkdir -p ~/apps

node -v && pm2 -v      # expect v20.x
```

Node 20 or newer is required: NestJS 11 will not run on 18.

### Deploy key

Generate locally and install the public half on the VPS. Actions authenticates
with this key rather than the account password, so CI access can be revoked by
deleting one line from `authorized_keys`.

```bash
ssh-keygen -t ed25519 -f ~/.ssh/lds_deploy -N "" -C "github-actions-lds"
ssh-copy-id -i ~/.ssh/lds_deploy.pub <user>@<host>
ssh -i ~/.ssh/lds_deploy <user>@<host> 'echo key works'
```

The **private** key becomes the `VPS_SSH_KEY` secret.

---

## Repository secrets

Secrets mirror the credentials sheet field for field. The workflow composes the
derived values, so there is nothing to hand-assemble.

### Both repos

| Secret | Sheet field |
|---|---|
| `VPS_HOST` | Server IP |
| `VPS_USER` | Username |
| `VPS_PASSWORD` | Password — kept for manual SSH; the workflow does not use it |
| `VPS_SSH_KEY` | private half of the deploy key above |
| `WEB_PORT` | Frontend Public Port |
| `API_PORT` | Backend Private Port |

### API repo only

| Secret | Sheet field / value |
|---|---|
| `MYSQL_DATABASE` | MySQL Database |
| `MYSQL_USER` | MySQL User |
| `MYSQL_PASSWORD` | MySQL Password |
| `MYSQL_PORT` | MySQL Port |
| `JWT_SECRET` | `openssl rand -hex 32` — a **new** value, not the development one |
| `ADMIN_EMAIL` | the login submitted for review |
| `ADMIN_PASSWORD` | the password submitted for review |

### Composed at deploy time, never stored

```
DATABASE_URL         = mysql://$MYSQL_USER:$MYSQL_PASSWORD@127.0.0.1:$MYSQL_PORT/$MYSQL_DATABASE
CORS_ORIGIN          = http://$VPS_HOST:$WEB_PORT
BACKEND_URL          = http://127.0.0.1:$API_PORT
NEXT_PUBLIC_SITE_URL = http://$VPS_HOST:$WEB_PORT
HOST                 = 127.0.0.1   (hardcoded — keeps the backend unexposed)
SESSION_COOKIE_NAME  = lds_session (hardcoded, identical in both repos)
```

`SESSION_COOKIE_NAME` must match across repos or sign-in breaks: the web proxy
reads back the cookie the API set. Hardcoding it in both workflows stops them
drifting apart.

MySQL is always reached on `127.0.0.1`. The sheet's port is used; a remote host
never is.

---

## What a deploy does

Both workflows share a shape: a `verify` job that must pass before a `deploy`
job runs, so a red build never reaches the VPS.

1. `npm ci`, `npm run lint`, `npm test`, `npm run build` on a runner
2. SSH to the VPS with the deploy key
3. Clone into `~/apps/lds-api` or `~/apps/lds-web` on first run, otherwise
   `git fetch && git reset --hard origin/main`
4. Write `.env` from secrets, `chmod 600`
5. `npm ci` — **not** `--omit=dev`; `db:migrate` and `db:seed` run through
   `ts-node` and the TypeORM CLI, which are devDependencies
6. `npm run build`
7. API only: `npm run db:migrate` then `npm run db:seed`. The seed upserts the
   admin, so it is idempotent and doubles as a password reset
8. `pm2 restart <name> --update-env`, falling back to `pm2 start` on first run
9. `pm2 save`, so the process list survives a reboot
10. Probe the app and print the listening sockets

The web deploy sources `.env` into the shell before calling PM2. Its start
script is `next start -p ${PORT:-8192}`, and the shell expands `${PORT}` before
Next loads any env file — leaving it to `.env` alone would silently serve on
8192 whatever is configured.

Deploy order on a fresh server: **API first**, then web. The reverse leaves the
site up with every page erroring against a backend that is not running.

---

## Manual fallback

If Actions is unavailable, the same steps by hand:

```bash
ssh <user>@<host>
. ~/.nvm/nvm.sh

cd ~/apps/lds-api && git pull && npm ci && npm run build \
  && npm run db:migrate && pm2 restart lds-api --update-env

cd ~/apps/lds-web && git pull && npm ci && npm run build \
  && set -a && . ./.env && set +a && pm2 restart lds-web --update-env

pm2 save
```

## Operations

```bash
pm2 list                  # status
pm2 logs lds-api          # backend logs
pm2 logs lds-web          # frontend logs
pm2 logs lds-api --err --lines 100
pm2 monit                 # live resource view
mysql -u <user> -p <database>
```

## Verification

On the VPS, the port requirement is the easiest thing to get wrong:

```bash
ss -tlnp | grep -E '<public>|<private>'
```

The public port must show `0.0.0.0`; the private port must show `127.0.0.1`.
If the private port shows `0.0.0.0`, `HOST` is wrong in `api/.env`.

From elsewhere:

```bash
curl -I  http://<host>:<public>/                    # 200
curl -I  http://<host>:<private>/api/health         # must be REFUSED
curl -I  http://<host>:<public>/<form-slug>         # 200, no session
curl -sI http://<host>:<public>/dashboard           # 307 to /login
```

Restart survival, which the exam tests explicitly:

```bash
pm2 kill && pm2 resurrect && pm2 list    # both processes return
```

## Checklist

- [ ] Frontend reachable on the assigned public port
- [ ] Backend **not** reachable from outside the VPS
- [ ] No `NEXT_PUBLIC_` variable holds the backend URL, DB credentials or JWT secret
- [ ] `.env` files exist on the server and are absent from both repos
- [ ] `.env.example` committed with placeholder values only
- [ ] Migrations run; admin user seeded
- [ ] `pm2 save` run; app survives `pm2 kill && pm2 resurrect`
- [ ] Public form URL loads without a session
- [ ] Admin routes redirect to login without a session
