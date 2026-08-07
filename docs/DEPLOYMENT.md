# Deployment

Deployment runs through GitHub Actions. Pushing to `main` in either app repo
lints, tests and builds it, then deploys over SSH and restarts it under PM2.

**Configuration lives on the VPS, not in GitHub.** Each app reads a `.env` file
created once by hand on the server. The workflow only ever reads it, never
writes it, so the database password, JWT secret and admin login never leave the
machine. GitHub holds SSH access and nothing else.

That is safe across redeploys because `.env` is gitignored and the deploy step
uses `git reset --hard`, which leaves untracked files alone. There is
deliberately no `git clean` in either workflow.

> This document uses placeholders only. Committing real hosts, passwords, or
> connection strings is an automatic fail condition (see [SPEC.md](SPEC.md) §18).

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

## Repository secrets

Three per repo, all connection details:

| Secret | Value |
|---|---|
| `VPS_HOST` | Server IP |
| `VPS_USER` | Username |
| `VPS_SSH_KEY` | private half of the deploy key created below |

Ports, MySQL credentials, `JWT_SECRET` and the admin login are **not** stored in
GitHub. They live only in the `.env` files on the VPS.

The account password is not needed by CI. Keep it for manual SSH; it does not
belong in GitHub under this design.

---

## One-time bootstrap

Everything here is no-sudo, and only needs doing once per server.

### 1. Runtime

```bash
ssh <user>@<host>

curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
. ~/.nvm/nvm.sh && nvm install 20 && nvm alias default 20
npm i -g pm2
mkdir -p ~/apps

node -v && pm2 -v      # expect v20.x
```

Node 20 or newer is required: NestJS 11 will not run on 18.

### 2. Deploy key

Generate locally and install the public half on the VPS. Actions authenticates
with this key rather than the account password, so CI access can be revoked by
deleting one line from `authorized_keys`.

```bash
ssh-keygen -t ed25519 -f ~/.ssh/lds_deploy -N "" -C "github-actions-lds"
ssh-copy-id -i ~/.ssh/lds_deploy.pub <user>@<host>
ssh -i ~/.ssh/lds_deploy <user>@<host> 'echo key works'
```

The **private** key becomes the `VPS_SSH_KEY` secret in both repos.

### 3. Clone both repos

The workflow expects the checkouts to exist, because `.env` has to be in place
before the first deploy runs.

```bash
cd ~/apps
git clone https://github.com/norbertoqjr/lead-distribution-api.git lds-api
git clone https://github.com/norbertoqjr/lead-distribution-web.git lds-web
```

### 4. Write the env files

These two files are the authoritative production configuration. Substitute the
values from the credentials sheet.

`~/apps/lds-api/.env`

```
NODE_ENV=production
PORT=<backend private port>
HOST=127.0.0.1
DATABASE_URL=mysql://<mysql user>:<mysql password>@127.0.0.1:<mysql port>/<mysql database>
JWT_SECRET=<openssl rand -hex 32, a NEW value>
JWT_EXPIRES_IN=7d
SESSION_COOKIE_NAME=lds_session
CORS_ORIGIN=http://<server ip>:<frontend public port>
ADMIN_EMAIL=<login you will submit for review>
ADMIN_PASSWORD=<password you will submit for review>
TRUST_PROXY=false
```

`~/apps/lds-web/.env`

```
NODE_ENV=production
PORT=<frontend public port>
BACKEND_URL=http://127.0.0.1:<backend private port>
SESSION_COOKIE_NAME=lds_session
NEXT_PUBLIC_SITE_URL=http://<server ip>:<frontend public port>
```

```bash
chmod 600 ~/apps/lds-api/.env ~/apps/lds-web/.env
```

Three things that break the deployment if wrong:

- **`HOST=127.0.0.1`** in the API env is what keeps the backend off the public
  interface. `0.0.0.0` violates the exam's port requirement.
- **`SESSION_COOKIE_NAME` must be identical** in both files, or sign-in fails:
  the web proxy reads back the cookie the API set.
- **MySQL is always `127.0.0.1`.** The sheet's port is used; a remote host never
  is.

Keep a copy of both files somewhere safe off the server. They exist nowhere
else, so a wiped VPS means reconstructing them by hand.

---

## What a deploy does

Both workflows share a shape: a `verify` job that must pass before `deploy`
runs, so a red build never reaches the VPS.

1. `npm ci`, `npm run lint`, `npm test`, `npm run build` on a runner
2. SSH to the VPS with the deploy key
3. `git fetch && git reset --hard origin/main` — untracked `.env` untouched
4. **Refuse to continue if `.env` is missing or missing a required key.** The
   API otherwise dies on config validation at boot and PM2 restart-loops, which
   reads as a mysterious outage rather than a missing file
5. Source `.env`, so the health probe uses the server's own port
6. `npm ci --include=dev` — the build and migrations run through the Nest CLI,
   `ts-node` and the TypeORM CLI, all devDependencies. `--include=dev` is not
   redundant: step 5 exported `NODE_ENV=production`, and npm omits
   devDependencies on its own when it sees that
7. `npm run build`
8. API only: `npm run db:migrate` then `npm run db:seed`. The seed upserts the
   admin, so it is idempotent and doubles as a password reset
9. `pm2 restart <name> --update-env`, falling back to `pm2 start` on first run
10. `pm2 save`, so the process list survives a reboot
11. Probe the app and print the listening sockets

The web deploy sources `.env` before calling PM2 for a specific reason: its
start script is `next start -p ${PORT:-8192}`, and the shell expands `${PORT}`
before Next loads any env file. Leaving it to `.env` alone would silently serve
on 8192 whatever is configured.

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

Changing a configuration value means editing `.env` on the server and
restarting, since nothing regenerates it:

```bash
nano ~/apps/lds-api/.env
pm2 restart lds-api --update-env
```

## Verification

On the VPS, the port requirement is the easiest thing to get wrong:

```bash
ss -tlnp | grep -E '<public>|<private>'
```

The public port must show `0.0.0.0`; the private port must show `127.0.0.1`.
If the private port shows `0.0.0.0`, `HOST` is wrong in `~/apps/lds-api/.env`.

Confirm the env files survived a redeploy — the property this design rests on:

```bash
ls -l ~/apps/lds-api/.env ~/apps/lds-web/.env
```

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
- [ ] Both `.env` files exist on the server, `chmod 600`, and absent from both repos
- [ ] A copy of both `.env` files kept somewhere off the server
- [ ] `.env.example` committed with placeholder values only
- [ ] Migrations run; admin user seeded
- [ ] `pm2 save` run; app survives `pm2 kill && pm2 resurrect`
- [ ] Public form URL loads without a session
- [ ] Admin routes redirect to login without a session
