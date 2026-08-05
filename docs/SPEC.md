# Lead Distribution Platform — Exam Spec

Source: Full Stack Developer Exam (Google Doc, provided by interviewer).
Duration: 3 days. Output: public GitHub repo + live VPS deployment.

## 1. Goal

A simple lead distribution platform with **one** public lead form, **one** distribution, and **many** brokers. The app captures lead IP addresses, prevents duplicate broker assignments, and assigns leads by broker percentage, timezone, open hours, working days, and daily cap.

## 2. Stack (mandated)

| Layer | Requirement |
|---|---|
| Frontend | Next.js application |
| Backend | Node.js (Express recommended) — using NestJS, which runs on the Express platform |
| Database | MySQL (already installed on the VPS) |
| DB access | Any ORM (no raw SQL sprawl) |
| Language | TypeScript, frontend and backend |
| Process mgmt | PM2 or another non-sudo Node process manager |

Two separate public GitHub repositories: frontend and backend.

## 3. Deliverables

- Public GitHub repo links (frontend + backend)
- Live VPS URL / IP
- Admin login credentials for review
- `README.md`: setup, env vars, deployment steps, test notes
- `.env.example` with **sample keys only**
- Clear git commit history

**Hard rule:** no real secrets, passwords, API keys, tokens, or VPS credentials in git.

## 4. Deployment

Deploy on the provided VPS with a setup that does not require sudo (PM2 recommended).

- Frontend binds the **provided public port** — use only that port.
- Backend binds the **provided private port**, not publicly exposed.
- Frontend must talk to the backend internally (e.g. `http://127.0.0.1:<backend port>`).

The README must explain: cloning, installing dependencies, setting env vars, setting up the database, running migrations / initializing tables, starting and restarting the app, checking logs, and accessing the deployed app.

See [DEPLOYMENT.md](DEPLOYMENT.md) for the deployment procedure.

## 5. Pages

- Login page
- Admin dashboard
- Brokers page
- Lead form page (admin-side form management)
- Distribution page + distribution detail page
- Leads page
- Broker detail/view page listing that broker's leads
- Manual assign for unsent leads
- Public form page at `/{slug}` — no login required

## 6. Scope limits (enforced, not just documented)

- Only one lead form may exist. If one exists, block creating another.
- Only one distribution may exist. If one exists, block creating another.
- A distribution cannot be created if no form exists.
- On creation, the distribution is automatically attached to the existing form.
- The admin only chooses which brokers are included in the distribution.
- Required message when creating a distribution before a form: **`Oops, please create a form first.`**

## 7. Lead form

Fields: form name, public URL slug, created date.

Example: a form named `lead-registration` is publicly reachable at `/lead-registration`.

On public submission the system must: save the lead, capture the visitor IP, check for a duplicate email, run distribution logic, and assign to an eligible broker if possible.

## 8. Distribution

Per broker in the distribution, the admin sets:

- Percentage (target share)
- Active/inactive **within the distribution**

The distribution detail page shows every lead that passed through: sent, duplicate, failed, and unsent — including which broker received each sent lead.

### Assignment rule — highest deficit

```
targetAfterLead = (totalSentToday + 1) * brokerPercentage / 100
deficit         = targetAfterLead - brokerSentToday
```

The eligible broker with the **highest deficit** receives the next lead. Ineligible brokers (closed, capped, inactive, outside working days) are excluded from the calculation entirely. Tie-break: fewer leads sent today.

Worked example (`totalSentToday = 10`):

| Broker | Percentage | Sent today | Target after next lead | Deficit | Result |
|---|---|---|---|---|---|
| A | 50% | 4 | 5.5 | +1.5 | Receives next lead |
| B | 30% | 3 | 3.3 | +0.3 | Behind, lower deficit |
| C | 20% | 3 | 2.2 | −0.8 | Already above target |

## 9. Broker

Many brokers. No endpoint/webhook URL needed — assignment is in-system only.

Fields: broker name, active/inactive status, daily cap, timezone, opening time, closing time, working days.

**Availability** is evaluated in the broker's own timezone. Example: `Asia/Manila`, 09:00–18:00, Mon–Fri → only receives leads in that window, Manila time.

**Daily cap** is also counted per the broker's timezone day. Cap reached → skip that broker and try the next eligible one. No broker available → lead is `unsent`.

## 10. Lead

Fields: name, email (normalized), phone, IP address, form name, assigned broker (nullable), status, created date/time.

Statuses: `sent`, `unsent`, `duplicate`, `failed`.

## 11. Distribution workflow

1. Save lead — name, email, phone, form name, created at, visitor IP.
2. Normalize email — `email.trim().toLowerCase()`.
3. Duplicate check — if the email was already assigned to any broker, mark `duplicate` and do **not** assign.
4. Form/distribution check — use the single distribution; if none exists, mark `unsent`.
5. Filter brokers — active, in the distribution, under daily cap, currently open in its timezone, within working days.
6. Compute deficit for each eligible broker.
7. Select highest deficit; tie-break on fewer sent today.
8. Assign and mark `sent`.
9. No eligible broker → mark `unsent`, surface on the distribution detail page.
10. Admin can manually assign any unsent lead to a broker.

## 12. Broker leads view

Per-broker page or modal with columns: lead name, email (normalized, visible), phone, IP address, form name, date received, status.

## 13. Leads page

All submitted leads with a clear status. Unsent leads offer manual assignment to a broker.

## 14. Validation rules

- Cannot create more than one form.
- Cannot create more than one distribution.
- Cannot create a distribution without a form; show `Oops, please create a form first.`
- Cannot assign a duplicate email to another broker.
- Lead IP must be stored **and** displayed.
- Broker timezone, opening/closing time, working days, and daily cap must affect assignment.

## 15. Auth

Admin area protected by login. Public form pages require no login.

## 16. Persistence

Users/admin account, brokers, one form, one distribution, distribution-broker settings, leads.

## 17. Code quality expectations

TypeScript throughout; clean readable code; no very large files; business logic separated from UI; server-side input validation; loading/empty/success/error states handled; no secrets exposed to the frontend; no `.env` or real credentials committed.

## 18. Automatic fail conditions

- No public GitHub repository submitted
- App does not run
- App not deployed on the VPS
- No login protection on the admin area
- More than one form can be created
- More than one distribution can be created
- Distribution can be created without a form
- Duplicate emails can be assigned to brokers
- Lead IP address not stored or shown
- Broker timezone / open hours / daily cap ignored
- Real secrets committed to GitHub

## 19. Test cases to verify before submitting

1. Login works.
2. Create multiple brokers.
3. Create one lead form.
4. Confirm a second form cannot be created.
5. Create a distribution before a form → `Oops, please create a form first.`
6. Create one distribution after the form exists.
7. Confirm a second distribution cannot be created.
8. Add brokers to the distribution with percentages.
9. Submit a lead from `/{formName}`.
10. Confirm the lead IP is saved.
11. Confirm the lead is assigned to an eligible broker.
12. Confirm the lead appears in the broker leads view with its IP.
13. Confirm the distribution detail page shows sent (with broker), duplicate, and unsent leads.
14. Resubmit the same email → `duplicate`.
15. Reach a broker's daily cap → broker is skipped.
16. Put a broker outside working hours → broker is skipped.
17. Manually assign an unsent lead.
18. Confirm the deployed app still works after a VPS restart.

## 20. Submission format

```
GitHub Repository (frontend, public):
GitHub Repository (backend, public):
Live App URL/IP:
Admin Email:
Admin Password:
Notes:
```
