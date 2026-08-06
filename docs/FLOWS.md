# System flows

Diagrams for the lead distribution platform. Source is Mermaid, which GitHub
renders inline — no build step needed to read this page.

To export SVGs (for a submission PDF or slides):

```bash
npm run docs:diagrams     # writes docs/diagrams/*.svg
```

---

## 1. Deployment topology

Only the frontend port is public. The API listens on loopback, so the private
port is unreachable from the internet even though both processes share a host.

```mermaid
flowchart LR
    visitor([Visitor])
    admin([Admin])

    subgraph vps["VPS"]
        web["Next.js<br/>public port"]
        api["NestJS<br/>127.0.0.1 private port"]
        db[("MySQL<br/>127.0.0.1:3306")]
    end

    visitor -->|"public form"| web
    admin -->|"admin area"| web
    web -->|"server-side fetch<br/>BACKEND_URL"| api
    api -->|"TypeORM"| db

    style web fill:#eaf0fe,stroke:#1f56d6,color:#12181f
    style api fill:#e2f5ec,stroke:#12694a,color:#12181f
    style db fill:#fdf0dc,stroke:#8a5300,color:#12181f
```

The browser never talks to the API directly. `BACKEND_URL` has no
`NEXT_PUBLIC_` prefix, so it is not inlined into the client bundle.

---

## 2. Admin setup order

The order is enforced, not merely suggested: a distribution cannot exist
without a form.

```mermaid
flowchart TD
    login["Log in"] --> brokers["Create brokers<br/>timezone, hours, working days, daily cap"]
    brokers --> form{"Form exists?"}
    form -->|"no"| createForm["Create the one form<br/>name + slug"]
    form -->|"yes"| blockedForm["Blocked:<br/>only one form allowed"]
    createForm --> dist{"Form exists?"}
    dist -->|"no"| oops["Oops, please create a form first."]
    dist -->|"yes"| createDist["Create the one distribution<br/>auto-attached to the form"]
    createDist --> settings["Select brokers,<br/>set percentage per broker"]
    settings --> share["Share the public URL<br/>/{slug}"]

    style oops fill:#fdeceb,stroke:#a5231c,color:#12181f
    style blockedForm fill:#fdeceb,stroke:#a5231c,color:#12181f
    style share fill:#e2f5ec,stroke:#12694a,color:#12181f
```

---

## 3. Lead submission and distribution

The core flow. Every terminal state is a stored lead — nothing is silently
dropped.

```mermaid
flowchart TD
    submit["Visitor submits /{slug}"] --> capture["Save lead<br/>name, phone, form, timestamp, IP"]
    capture --> normalize["Normalize email<br/>trim + lowercase"]
    normalize --> dupe{"Email already<br/>assigned to a broker?"}

    dupe -->|"yes"| markDupe["status = duplicate<br/>never reassigned"]
    dupe -->|"no"| hasDist{"Distribution<br/>exists?"}

    hasDist -->|"no"| markUnsent1["status = unsent"]
    hasDist -->|"yes"| filter["Filter brokers"]

    filter --> eligible{"Any eligible<br/>broker?"}
    eligible -->|"no"| markUnsent2["status = unsent<br/>awaits manual assign"]
    eligible -->|"yes"| deficit["Compute deficit<br/>per eligible broker"]

    deficit --> select["Select highest deficit<br/>tie-break: fewer sent today"]
    select --> assign["Assign broker<br/>status = sent, set assignedAt"]

    markUnsent2 -.->|"admin action"| manual["Manual assign<br/>status = sent"]

    style markDupe fill:#fdf0dc,stroke:#8a5300,color:#12181f
    style markUnsent1 fill:#fdf0dc,stroke:#8a5300,color:#12181f
    style markUnsent2 fill:#fdf0dc,stroke:#8a5300,color:#12181f
    style assign fill:#e2f5ec,stroke:#12694a,color:#12181f
    style manual fill:#e2f5ec,stroke:#12694a,color:#12181f
```

Steps from the duplicate check through assignment run in one transaction, so
two simultaneous submissions cannot both read the same `sentToday` counts and
push a broker past its cap.

---

## 4. Broker eligibility

Every check is evaluated in the **broker's own timezone**, never the server's.
A broker failing any check is excluded from the deficit calculation entirely —
not merely ranked lower.

```mermaid
flowchart LR
    start(["Broker"]) --> active{"Broker<br/>active?"}
    active -->|"no"| skip["Skip"]
    active -->|"yes"| inDist{"In distribution<br/>and active there?"}
    inDist -->|"no"| skip
    inDist -->|"yes"| day{"Today is a<br/>working day?"}
    day -->|"no"| skip
    day -->|"yes"| hours{"Now within<br/>open-close?"}
    hours -->|"no"| skip
    hours -->|"yes"| cap{"Under<br/>daily cap?"}
    cap -->|"no"| skip
    cap -->|"yes"| ok["Eligible"]

    style skip fill:#fdeceb,stroke:#a5231c,color:#12181f
    style ok fill:#e2f5ec,stroke:#12694a,color:#12181f
```

The daily counter resets at midnight in the broker's timezone, so a broker in
`Asia/Manila` rolls over at Manila midnight regardless of where the server is.

---

## 5. Deficit selection

```mermaid
flowchart TD
    A["totalSentToday = leads sent today<br/>across all brokers"] --> B["For each eligible broker:"]
    B --> C["targetAfterLead =<br/>(totalSentToday + 1) × percentage ÷ 100"]
    C --> D["deficit =<br/>targetAfterLead − brokerSentToday"]
    D --> E{"Highest deficit?"}
    E -->|"unique"| F["That broker receives the lead"]
    E -->|"tied"| G["Broker with fewer<br/>leads sent today"]

    style F fill:#e2f5ec,stroke:#12694a,color:#12181f
    style G fill:#e2f5ec,stroke:#12694a,color:#12181f
```

Worked example with `totalSentToday = 10`:

| Broker | Percentage | Sent today | Target after next | Deficit | Result |
|---|---|---|---|---|---|
| A | 50% | 4 | 5.5 | **+1.5** | Receives the lead |
| B | 30% | 3 | 3.3 | +0.3 | Behind, but less so |
| C | 20% | 3 | 2.2 | −0.8 | Already above target |

A negative deficit means the broker is ahead of its share, so it waits.

---

## 6. Lead status transitions

```mermaid
stateDiagram-v2
    [*] --> submitted: visitor submits

    submitted --> duplicate: email already assigned
    submitted --> unsent: no distribution
    submitted --> unsent: no eligible broker
    submitted --> sent: broker selected
    submitted --> failed: unexpected error

    unsent --> sent: admin assigns manually

    duplicate --> [*]
    sent --> [*]
    failed --> [*]

    note right of duplicate
        Terminal. A duplicate is never
        routed to a second broker.
    end note
```

`unsent` is the only non-terminal state — it is the queue the admin works
through on the leads page.

---

## 7. Data model

```mermaid
erDiagram
    USERS {
        int id PK
        string email UK
        string password_hash
    }
    BROKERS {
        int id PK
        string name
        bool is_active
        int daily_cap
        string timezone
        int open_minute
        int close_minute
        string working_days
    }
    FORMS {
        int id PK
        string name
        string slug UK
        bool singleton UK
    }
    DISTRIBUTIONS {
        int id PK
        int form_id FK
        bool singleton UK
        bool is_active
    }
    DISTRIBUTION_BROKERS {
        int id PK
        int distribution_id FK
        int broker_id FK
        decimal percentage
        bool is_active
    }
    LEADS {
        int id PK
        string name
        string email
        string phone
        string ip_address
        int form_id FK
        int distribution_id FK
        int broker_id FK
        enum status
        datetime assigned_at
    }

    FORMS ||--o| DISTRIBUTIONS : "has one"
    DISTRIBUTIONS ||--o{ DISTRIBUTION_BROKERS : "includes"
    BROKERS ||--o{ DISTRIBUTION_BROKERS : "participates in"
    FORMS ||--o{ LEADS : "collects"
    DISTRIBUTIONS ||--o{ LEADS : "routes"
    BROKERS ||--o{ LEADS : "receives"
```

The `singleton` columns on `forms` and `distributions` carry a UNIQUE index and
are always written as `true`. That is what makes "only one form" and "only one
distribution" a database guarantee rather than a service-layer hope — two
concurrent creates cannot both succeed.

---

## 8. Request authorization

```mermaid
flowchart TD
    req(["Request"]) --> public{"Route marked<br/>@Public()?"}
    public -->|"yes"| handle["Handler runs<br/>form fetch / lead submit"]
    public -->|"no"| jwt{"Valid session<br/>cookie?"}
    jwt -->|"no"| reject["401 Unauthorized"]
    jwt -->|"yes"| handle

    style reject fill:#fdeceb,stroke:#a5231c,color:#12181f
    style handle fill:#e2f5ec,stroke:#12694a,color:#12181f
```

The guard is global and routes opt **out**. Adding an endpoint without thinking
about auth leaves it protected, which is the safe default — the opposite
arrangement leaks a route every time someone forgets a decorator.
