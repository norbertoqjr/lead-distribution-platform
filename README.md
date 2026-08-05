# Lead Distribution Platform

Full-stack exam project: one public lead form, one distribution, many brokers. Leads are captured with their IP, deduplicated by email, and assigned to the eligible broker with the highest deficit against its target percentage share.

## Docs

| Doc | What's in it |
|---|---|
| [docs/SPEC.md](docs/SPEC.md) | Full requirements, distribution algorithm, validation rules, fail conditions, test cases |
| [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) | VPS layout, env vars, PM2 commands, deployment checklist |

## Stack

Next.js (TypeScript) frontend · Express (TypeScript) backend · MySQL via ORM · PM2 on the VPS.

The two apps ship as **separate public repositories**, per the exam requirements. This directory holds the shared planning docs.

## Assignment algorithm

For each broker that is active, in the distribution, under its daily cap, and currently open in its own timezone on a working day:

```
targetAfterLead = (totalSentToday + 1) * brokerPercentage / 100
deficit         = targetAfterLead - brokerSentToday
```

Highest deficit wins; ties go to the broker with fewer leads sent today. If nobody is eligible, the lead is saved as `unsent` and the admin can assign it manually.

## Status

Planning. No application code yet.

## Security note

The exam lists "real secrets committed to GitHub" as an automatic fail. Only `.env.example` files with placeholder values are ever committed; real values exist solely in `.env` files created on the server.
