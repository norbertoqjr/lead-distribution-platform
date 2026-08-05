# Deployment

> This document uses placeholders only. Committing real hosts, passwords, or connection strings is an automatic fail condition (see [SPEC.md](SPEC.md) §18).

## Target

| Item | Value |
|---|---|
| Host | VPS provided by the interviewer |
| SSH user | provided by the interviewer (password auth) |
| Frontend port | **public** — the only port exposed to the internet |
| Backend port | **private** — reachable only from the VPS itself |
| Database | MySQL 3306, dedicated DB + user |
| Process manager | PM2 (no sudo required) |

Constraint: use **only** the assigned ports. Nothing else may be bound publicly.

## Wiring

```
internet ──▶ :<FRONTEND_PORT>  Next.js  ──▶ http://127.0.0.1:<BACKEND_PORT>  Express ──▶ MySQL :3306
```

The backend base URL must be a **server-side** env var in Next.js (no `NEXT_PUBLIC_` prefix) so the private port is never leaked to the browser. Browser-originated calls go through Next.js route handlers / server actions that proxy to the backend.

## Environment variables

### Backend (`.env.example`)

```
NODE_ENV=production
PORT=<backend private port>
DATABASE_URL=mysql://<user>:<password>@127.0.0.1:3306/<database>
JWT_SECRET=<random 32+ byte string>
SESSION_COOKIE_NAME=lds_session
CORS_ORIGIN=http://<host>:<frontend port>
```

### Frontend (`.env.example`)

```
NODE_ENV=production
PORT=<frontend public port>
BACKEND_URL=http://127.0.0.1:<backend private port>
```

## First deploy

```bash
ssh <user>@<host>

# backend
git clone <backend repo> ~/apps/lds-api && cd ~/apps/lds-api
npm ci
cp .env.example .env && $EDITOR .env      # fill in real values
npm run build
npm run db:migrate                        # create tables
npm run db:seed                           # create the admin user
pm2 start dist/main.js --name lds-api

# frontend
git clone <frontend repo> ~/apps/lds-web && cd ~/apps/lds-web
npm ci
cp .env.example .env && $EDITOR .env
npm run build
pm2 start npm --name lds-web -- start

pm2 save                                  # survive reboot
```

`pm2 save` is what makes the app come back after a VPS restart — test case 18 depends on it. If PM2 startup hooks need sudo, verify recovery by killing and re-resurrecting: `pm2 kill && pm2 resurrect`.

## Redeploy

```bash
cd ~/apps/lds-api && git pull && npm ci && npm run build && npm run db:migrate && pm2 restart lds-api
cd ~/apps/lds-web && git pull && npm ci && npm run build && pm2 restart lds-web
```

## Operations

```bash
pm2 list                 # status
pm2 logs lds-api         # backend logs
pm2 logs lds-web         # frontend logs
pm2 restart lds-web
pm2 monit                # live resource view
mysql -u <user> -p <database>
```

## Deployment checklist

- [ ] Frontend reachable on the assigned public port
- [ ] Backend **not** reachable from outside the VPS
- [ ] No `NEXT_PUBLIC_` var contains the backend URL, DB creds, or JWT secret
- [ ] `.env` files exist on the server and are absent from both repos
- [ ] `.env.example` committed with placeholder values only
- [ ] Migrations run; admin user seeded
- [ ] `pm2 save` run; app survives `pm2 kill && pm2 resurrect`
- [ ] Public form URL loads without a session
- [ ] Admin routes redirect to login without a session
