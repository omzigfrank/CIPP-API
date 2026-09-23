# CIPP Monthly Maintenance Runbook

**Owner:** Frank Diaz · **Audience:** Omzig engineers with CIPP admin
**Last verified against the live instance:** 2026-09-22 (Flex Consumption cutover)

> **CIPP down right now? Go to [OUTAGE.md](OUTAGE.md).** It is a triage tree you
> are pre-authorised to work through end to end. This runbook is the reference —
> read it when you have time, not when the portal is red.

This runbook covers the self-hosted CIPP instance at **https://management.omzig.it**.
It is designed to be run *with Claude Code* — see [Running it with Claude](#running-it-with-claude).
Every command here has been executed against the live instance.

---

## 1. What you are maintaining

Two GitHub forks deploy into one Azure resource group. Nothing is installed from a
marketplace; every version bump comes through the forks.

```
KelvinTegelaar/CIPP-API ──pull[bot]──► omzigfrank/CIPP-API (master)
                                              │ GitHub Action (deploy-flex job, OIDC)
                                              ▼
                              cippwemix-flex   (Flex Consumption, Linux, 4 GB / 2 cores:
                                                HTTP API + timers + queues + orchestrators)

                              cippwemix        (retired 2026-09-22, Stopped — rollback target)
                              cippwemix-proc   (retired 2026-09-22, Stopped — rollback target)

KelvinTegelaar/CIPP ──────pull[bot]──► omzigfrank/CIPP (main)
                                              │ GitHub Action
                                              ▼
                              cipp-swa-wemix   (Static Web App → management.omzig.it)
```

| Thing | Value |
| --- | --- |
| Subscription | `48019666-dd78-439e-9890-030ab5156f23` — *2025-26 MCPP Subscription* |
| Tenant | `b7060bc5-9f4b-4c46-9639-1c408bf1d6f9` |
| Resource group | `CIPP` (eastus2) |
| Function app (API **and** background) | `cippwemix-flex` — Flex Consumption, 1 always-ready HTTP instance |
| Retired, Stopped (rollback only) | `cippwemix` (old API), `cippwemix-proc` (old processor, was stuck on 10.6.1) |
| Deploy identity | `CIPP-Deploy-GitHub-Flex` (`9a4e5dce-…`), OIDC, Website Contributor on `cippwemix-flex` only |
| Flex deployment packages | storage `cippflextest09222235` — named for the build test, now holds the live package; do not delete |
| Static Web App | `cipp-swa-wemix` → `management.omzig.it` |
| Key Vault | `cippwemix` |
| Storage | `cippstgwemix` |
| Logs | `law-cipp-wemix` / `appi-cipp-wemix` |
| SAM app registration | **CIPP-SAM** — `a60c5cc5-707b-4152-8881-b60e25cf1a34` |

### The one architectural fact that matters

**Key Vault `cippwemix` is the single source of truth for every CIPP credential.**
All four credential app settings on `cippwemix-flex` are Key Vault *references*, not literals:

```
ApplicationSecret = @Microsoft.KeyVault(VaultName=cippwemix;SecretName=applicationsecret)
RefreshToken      = @Microsoft.KeyVault(VaultName=cippwemix;SecretName=refreshtoken)
ApplicationId     = @Microsoft.KeyVault(VaultName=cippwemix;SecretName=applicationid)
TenantId          = @Microsoft.KeyVault(VaultName=cippwemix;SecretName=tenantid)
```

CIPP normally derives the vault name from the app name. `cippwemix-flex` is not the
vault's name, so the app carries `CIPP_KV_NAME=cippwemix`, which CIPP honours as an
explicit override. Remove it and every secret lookup points at a vault that does not exist.

Consequences:

- To rotate a credential you change **the vault**, never an app setting.
- References resolve to *latest* version, so a restart is enough to pick up a new value.
- If someone replaces a reference with a pasted literal, rotation silently stops working.
  The health check flags this.

---

## 2. Access you need

Assigned to Entra **groups**, never to individuals — joining or leaving the team
is a single membership change.

| Group | Members | Azure | Key Vault `cippwemix` | Rotate the SAM secret? |
| --- | --- | --- | --- | --- |
| `CIPP-Azure-Operators` | Courtney, Eric, Tony | Reader on RG `CIPP` | secret `get`, `list` | No |
| `CIPP-Azure-Admins` | Frank, Courtney | Contributor on RG `CIPP` | secret `get`, `list`, `set` | Yes |

Operators can run every one of the 17 checks, including the live token test.
They cannot change or delete anything — rotation and credential deletion need
the admins group.

The vault uses **access policies, not RBAC**, so adding someone means adding a
policy entry as well as a role assignment. Assign to the group, not the person.

**Rotation does not require Global Administrator.** Frank and Courtney are
registered owners of the `CIPP-SAM` app registration; an app owner can manage its
credentials with no directory role. Before 2026-08-12 the only path to rotating
the secret was Global Admin, which is why this changed.

Check before you start:

```bash
az login && az account set --subscription 48019666-dd78-439e-9890-030ab5156f23
```

### If both admins are unavailable

1. Any Global Administrator can add themselves to `CIPP-Azure-Admins` and to the
   `CIPP-SAM` owners list, then work the runbook normally.
2. Azure resource access may also need the *Access management for Azure
   resources* toggle (Entra → Properties) — the subscription has only one human
   Owner, so a GA cannot see resources by default.
3. Current Global Administrators: Frank, Courtney, `omzigadmin@omziginc.com`,
   `admin@omzig.onmicrosoft.com`.

### Security notes on `CIPPServiceAccount@omzig.it`

An **enabled user account** holding four directory roles — Global Administrator,
Privileged Role Administrator, User Administrator, Groups Administrator — and a
member of the M365 GDAP groups, so it carries privileged reach into every managed
customer tenant.

**Do not delete or disable it.** Created 2025-11-21, the same day as `CIPP-SAM`,
so it is very likely the account that minted the SAM refresh token. That token is
bound to the authorising user; removing the account would probably cut CIPP off
from every tenant at the next token exchange. Removing *roles* is safe; removing
the *account* is not.

Open questions as of 2026-08-12, needing the Entra portal (the CLI's Graph token
lacks the scopes): does it have MFA registered, and has it ever signed in?
Password-only auth on this account would be a serious standing exposure.
`Privileged Role Administrator` is redundant beside Global Administrator and is
the first role to remove.

---

## 3. Who decides what

Escalation is to a **role**, never to a person. The aim is that an operator can
resolve any known fault without phoning anyone.

| Role | Who | Reached for |
| --- | --- | --- |
| Operator | Courtney, Eric, Tony | Everything in OUTAGE.md and the monthly pass |
| Secondary | Courtney | A second opinion; anything needing a Global Admin |
| Owner | Frank | Business decisions and novel faults only |

### Pre-authorised — do not ask, just do it and log it

These are reversible or additive. Waiting for approval costs more than acting.

- Rotate the SAM client secret, including during an outage
- Start, restart, or roll back an app to a previous commit
- Re-enable a disabled Key Vault secret
- Set expiry metadata on a vault secret
- Merge an upstream sync PR that merges cleanly and passes the QC workflow
- Enable HTTPS-only or raise a TLS minimum
- Add a finding you solved to this runbook

### Two operators, not a manager

Irreversible but mechanical. The safeguard is a second pair of eyes, not seniority:
one operator proposes, another confirms in the ticket, then either may execute.

- Deleting an app-registration credential that is **not** the one in
  `applicationsecret` and **not** the designated spare
- Deleting a stale sync branch or closing a stale sync PR
- Resolving an upstream conflict in a file we have patched, where the resolution
  policy in §7 gives a clear case

### Owner decisions — genuinely Frank's

Not because they are hard, but because they change policy, cost, or blast radius.

- Anything touching GDAP, tenant onboarding, standards, or a client tenant
- Enabling Key Vault purge protection (irreversible once on)
- Granting a new person access, or widening a role
- Changing directory roles on `CIPPServiceAccount@omzig.it`
- A conflict that falls into §6 case 5 after a second operator has also looked

> **Approved by Frank Diaz, 2026-08-12. These tiers are in force.**
>
> Operators do not need per-incident approval for anything in the pre-authorised
> list, including rotating the secret during an outage. The two-operator tier
> replaces owner approval for work that is irreversible but mechanical.
>
> Recorded by Claude on Frank's instruction — the approval is his; this wording is
> the record of it, not the thing itself. Changing these tiers is an owner decision.

## 4. The monthly pass

Budget 20 minutes when everything is green, up to 90 when a sync PR is conflicted.

### Step 1 — Run the health check (read-only, always safe)

```bash
pwsh -File "./omzig-ops/Invoke-CippHealthCheck.ps1"
```

It prints one table of findings and sets an exit code: `0` all green, `1` warnings only,
`2` at least one critical. It checks 13 things, in rough order of how often they break:

1. Azure context and access
2. Both function apps are Running
3. Every Key Vault reference points at a secret that exists and is enabled
4. **A live token acquisition using the vault's current secret** ← this is the check that
   would have caught August's outage before a human saw it
5. CIPP-SAM secret + certificate expiry runway
6. Key Vault secret expiry metadata
7. SAM refresh-token age against the 90-day idle limit
8. Deployed version vs. KelvinTegelaar upstream (backend *and* frontend)
9. Upstream-sync PR status on both forks
10. Age of the last successful deployment
11. Stale / orphaned app-registration credentials
12. HTTPS-only and min-TLS on both apps
13. 24h auth-error count from Log Analytics, compared against the last rotation time

Then work the findings top-down. Sections 5–8 below are the fixes.

### What the unattended check does and does not cover

The scheduled workflow (`.github/workflows/omzig-cipp-healthcheck.yml`) runs as
`CIPP-HealthCheck-Reader`, which holds Reader on the resource group, secret
`get`/`list` on the vault, and **no directory access at all**.

That means it covers the live token test — the leading indicator for an outage —
but it **cannot read app-registration credentials**, so it does not check the SAM
secret or certificate expiry runway. Rather than skip those silently, it reports
them as WARN so a green run always means "checked and fine" rather than "could not
check". A clean report that quietly omits the most important check is how the
secret expired unnoticed in July.

Two ways to close the gap; the second needs a decision, not a code change:

- The **human monthly pass** covers it — an operator running the script
  interactively reads the credentials with their own permissions.
- Grant the automation Graph `Application.Read.All`. That is tenant-wide
  application read and needs admin consent, so it is Frank's call rather than an
  operator's.

### Step 2 — Close out

Log in the Autotask ticket: date, who ran it, version before/after, findings fixed,
findings deferred and why.

**Then clear the alert backlog.** Open every issue labelled `cipp-health` in
`omzigfrank/CIPP-API` and either fix it or write in it why not. An open CRITICAL is not
a record, it is the job: issue #68 (2026-09-01) correctly reported the frontend sync as
blocked and then sat untouched for three weeks while the frontend fell a full release
behind the API.

```bash
gh issue list -R omzigfrank/CIPP-API -l cipp-health --state open
```

---

## 5. Fix: expired SAM client secret (`AADSTS7000222`)

**Symptom.** Every CIPP page shows a red banner:

> Error Loading data: Could not get token: invalid_client:AADSTS7000222: The provided
> client secret keys for app '…' are expired.

**Blast radius.** Total. CIPP cannot reach any customer tenant.

**Fix.** One command:

```bash
pwsh -File "./omzig-ops/Invoke-CippSecretRotation.ps1"
```

It appends a new 24-month secret (existing credentials untouched, so nothing breaks
mid-flight), proves the new secret can mint a Graph token **before** writing it to the
vault, sets matching expiry metadata, restarts both apps, re-verifies from the vault, and
then prints the `az ad app credential delete` commands for the credentials you should
clean up. It never logs or persists the secret value. Add `-WhatIf` to preview.

**What this does *not* break:** rotating the client secret leaves the SAM refresh token
valid. No customer re-consent, no GDAP re-invite.

**Prevention.** The secret now carries expiry metadata in the vault, so check 6 warns 45
days out and check 4 fails the moment auth actually breaks.

---

## 6. Fix: version drift

Versions live in the repos, not in Azure:

- Backend: `version_latest.txt` at the fork root
- Frontend: `public/version.json`

```bash
# deployed
curl -s https://raw.githubusercontent.com/omzigfrank/CIPP-API/master/version_latest.txt
curl -s https://raw.githubusercontent.com/omzigfrank/CIPP/main/public/version.json
# upstream
curl -s https://raw.githubusercontent.com/KelvinTegelaar/CIPP-API/master/version_latest.txt
curl -s https://raw.githubusercontent.com/KelvinTegelaar/CIPP/main/public/version.json
```

If a version is behind, the cause is almost always a **conflicted `pull[bot]` sync PR** —
see section 7. Once the sync PR merges, the GitHub Action deploys automatically.

**The repo version is not proof of what is running.** For two months the repo said
10.10.3 while `cippwemix-proc` ran 10.6.1, because no workflow ever deployed it. The
health check's **Deployed version** line reads the version the app itself logs at
startup; that is the number to trust. Flex keeps no Kudu deployment history, so the old
`/deployments` query returns nothing for `cippwemix-flex`.

**Upgrade backend and frontend together.** They share a version line and the frontend
calls backend endpoints that may not exist in an older API.

---

## 7. Unblocking a conflicted sync PR

This is the work that actually keeps CIPP current, and the reason it falls behind.

Per the [Omzig Custom CIPP Build handoff spec](https://github.com/omzigfrank/CIPP-API) (handoff spec lives in OneDrive: `Dev/Omzig Custom CIPP Build — Handoff Spec.md`)
§11.4, Omzig customizations are supposed to live only in `Modules/Omzig/*` and
`src/omzig/*`. Overlay files never conflict. **Conflicts only ever appear where we patched
an upstream file** — so each conflict is a signal that a patch needs to become an overlay,
or be given back to upstream.

### Enumerate the conflicts locally

Windows needs long paths for the CIPP-API tree, hence `core.longpaths`:

```bash
git clone --filter=blob:none --no-checkout -c core.longpaths=true https://github.com/omzigfrank/CIPP-API.git
cd CIPP-API
git remote add upstream https://github.com/KelvinTegelaar/CIPP-API.git
git fetch upstream master --filter=blob:none
git checkout -b synctest origin/master
git merge --no-commit --no-ff upstream/master
git diff --name-only --diff-filter=U      # <- the conflict set
```

Same for the frontend with `omzigfrank/CIPP`, branch `main`, upstream branch `main`.

### Resolution policy, in priority order

1. **Upstream has implemented our patch.** Take upstream verbatim, delete our patch,
   move any configuration to the upstream mechanism. This is the best outcome — the
   conflict never returns.
2. **Upstream moved or refactored the file.** Take upstream's structure, then re-apply our
   branding on top of it. Do **not** keep our version of a refactored file: upstream's
   imports come in with the merge, so our old JSX will reference components that are no
   longer imported and the build breaks. If upstream left a redirect stub at the old path,
   keep the stub and rebrand at the *new* path.
3. **Pure branding on an upstream file.** Re-apply our side, keep upstream's structural
   changes. Then open a follow-up to move it into an overlay/theme file.
4. **A real feature overlay wedged into an upstream file.** Merge by hand, run the
   `omzig-qc` workflow, and open a ticket to extract it into `src/omzig/*`.
5. **You cannot tell.** Do not guess on the platform that runs every customer
   tenant — but do not stop either. Open the resolution as a PR with your reasoning,
   and get a second operator to look. Only if you both remain unsure does it become
   an owner decision.

**Before you classify, check whether the path still exists upstream.** A conflict that
looks like a feature collision is often just a file upstream relocated:

```bash
git log --oneline --follow -3 upstream/main -- <path>
git ls-tree -r --name-only upstream/main | grep <basename>
```

Then push the resolved merge to the fork's default branch; `pull[bot]`'s PR closes itself
and the deploy Action runs.

### The weekly sync automation, and why it wasn't saving us

`.github/workflows/omzig-upstream-sync.yml` is supposed to open the sync PR every Monday.
**In `omzigfrank/CIPP-API` it had failed on every single run since at least 2026-07-13**,
always at `actions/checkout@v4`, because the workflow declares:

```yaml
env:
  TARGET_BRANCH: main      # wrong for CIPP-API
```

The CIPP-API fork's default branch is **`master`**. The frontend fork's is `main`, and its
copy of the workflow is correct — the API repo's copy was templated from the frontend and
the branch name came along with it. So the automation intended to keep us on the release
train has never once run to completion on the backend.

Check it as part of the monthly pass — a workflow that fails silently is worse than no
workflow, because it looks like coverage:

```bash
curl -s "https://api.github.com/repos/omzigfrank/CIPP-API/actions/runs?per_page=100" \
  | python -c "import json,sys; [print(r['created_at'], r['conclusion']) for r in json.load(sys.stdin)['workflow_runs'] if r['name']=='Omzig Upstream Sync']"
```

Also note the workflow's header comment claims conflicts "should only ever surface in
profile.ps1" — that is stale. The real conflict surface is any upstream file we patched.

### 2026-09-22 — frontend 10.8.5 → 10.10.3, 9 conflicts

Upstream renamed most of the frontend from `.js` to `.jsx` between 10.8 and 10.10, so
**every branded upstream file conflicted at once**. None were hard; all were §7 case 2
(upstream restructured, re-apply branding) or case 3 (pure branding).

| File | Case | Resolution |
| --- | --- | --- |
| `src/layouts/top-nav.jsx` | 2 | Took upstream's layout: the logo now hides on phones in favour of the tenant chip. Kept our 112px wordmark in a 40px box, `ground="dark"`. Took upstream's mobile gutter fix over ours. |
| `src/layouts/side-nav.jsx` | 2 | Upstream moved `PaperProps` to `slotProps.paper` and `BANNER_HEIGHT_VAR` into `CHROME_TOP_OFFSET`. Re-applied the liquid-glass rail inside the new structure. |
| `src/layouts/mobile-nav.js` | 2 | **modify/delete:** upstream deleted it and added `mobile-nav.jsx`, which git did not detect as a rename. Deleted the `.js` (two twins would be ambiguous imports), ported the glass drawer and wordmark sizing into the `.jsx`, and removed the `CippSponsor` footer upstream added there, as it was already removed from the desktop rail. |
| `src/pages/_app.jsx` | 3 | `omzig.ai Portal` title, upstream's `viewport-fit=cover`. |
| `src/pages/_document.jsx` | 3 | Our light/dark `theme-color` pair, plus upstream's `mobile-web-app-capable`. |
| `SetupGatePage.jsx` | 3 | Upstream's `sx` layout, our `<Logo />` and "Welcome to omzig.ai". |
| `CippApiClientManagement.jsx` | 2 | Upstream moved the table from an `api` prop to local `data` (egress usage). Took it, retitled. |
| `CippUserManagement.jsx`, `cipp-users.jsx` | 3 | Upstream now titles a page to **match its tab label**. Titled `omzig.ai Users` and relabelled the tab in `authentication/tabOptions.json` to match. |

Also merged: upstream's own `azure-static-web-apps-red-stone-*.yml`. It deploys only on
pushes to `dev` using a secret this fork does not hold, so it is inert here. It was left
in place because deleting it would make a modify/delete conflict every time upstream
edits it.

**Check branding survived by counting, not by eye.** Compare `omzig` mentions per file
before and after, stripping the extension so a `.js`→`.jsx` rename is not reported as a
loss:

```bash
git grep -ic omzig origin/main -- src public | sed -E 's/^origin\/main://; s/\.jsx?:/:/' | sort > before
git grep -ic omzig -- src public | sed -E 's/\.jsx?:/:/' | sort > after
join -t: -a1 -e0 -o 0,1.2,2.2 before after | awk -F: '$2>$3'
```

**Why nobody heard about it:** `omzigfrank/CIPP` has **Issues disabled**, so its weekly
sync workflow cannot file the conflict alert it tries to file, and it fails a second time
on the label. The monthly health check in CIPP-API *did* catch it; see §4 Step 2.

### Current state as of 2026-08-12

> **Resolved and deployed 2026-08-12.** Both forks and both Azure targets are on 10.8.3;
> the health check reports all green. The record below is kept because these two conflicts
> illustrate the two cases you will keep meeting.

**Backend — `omzigfrank/CIPP-API` PR #60, 1 conflict.** Case 1 above:

`Modules/CIPPCore/Public/Get-CippKeyVaultName.ps1` — we added a `KEYVAULT_NAME` env
override; upstream has since shipped the same idea as `CIPP_KV_NAME`. **Take upstream and
delete our patch.** Where a stack's vault is not named after its site, set a `CIPP_KV_NAME`
app setting instead. (`Modules/Omzig/Public/Config/Get-OmzigConfig.ps1` also reads
`$env:KEYVAULT_NAME`, but that file is a clean overlay — leave it, and set both app
settings on the dev stacks during the transition.)

Production is unaffected either way: vault `cippwemix` is already named after site
`cippwemix`, so the name derives correctly with no override at all.

**Frontend — `omzigfrank/CIPP` PR #38, 5 conflicts.** All resolved 2026-08-12:

| File | Case | Resolution |
| --- | --- | --- |
| `public/manifest.json` | 3 | Kept Omzig branding; upstream changed nothing structural. |
| `src/pages/loading.js` | 2 | Upstream replaced the `Box`/`Container`/`CippImageCard` block with a new `CippAuthShell`. Took upstream's component, retitled for Omzig. Keeping our JSX would **not have compiled** — the old components are no longer imported. |
| `src/layouts/side-nav.js` | 2+3 | Kept the Omzig liquid-glass rail; took upstream's `height` calc, which now subtracts `BANNER_HEIGHT_VAR` as well as the top nav. |
| `super-admin/cipp-roles/index.js` | 2 | Upstream **moved** the page to `advanced/authentication/` and left a legacy redirect. Took the redirect. |
| `super-admin/sam-app-permissions.js` | 2 | Same relocation. Took the redirect. |

Omzig branding was re-applied at the two new `advanced/authentication/` locations —
`ŌMZIG Roles`, and the `Reset to ŌMZIG Defaults` dialog. **When upstream relocates a
branded page, remember to rebrand the new path**, or the branding silently disappears from
the live portal while the old URL still redirects correctly.

---

## 8. Fix: other findings

### Expired refresh token (90-day idle limit)

Not fixable by script. In CIPP: **Settings → CIPP-SAM Setup Wizard**, re-run the refresh
token step as a Global Admin in the partner tenant. Check 7 warns from 60 days.

### Function app stopped

```bash
az functionapp start -g CIPP -n cippwemix-flex
```

Only `cippwemix-flex`. The retired `cippwemix` and `cippwemix-proc` stay Stopped; see
OUTAGE.md G for the one situation in which they are started.

### Key Vault reference not resolving

Check the managed identity still has vault access, then restart. References cache for up
to 24h, so a restart is how you force re-resolution:

```bash
az functionapp restart -g CIPP -n cippwemix-flex
```

### Credential hygiene

CIPP-SAM currently carries **24 live client secrets**, mostly named `CIPPInstall` and
valid until 2028. Each is a full CSP-privileged credential for every managed tenant —
this is the largest standing risk on the instance. Keep the one in the vault plus at most
one rollback, delete the rest:

```bash
az ad app credential list --id a60c5cc5-707b-4152-8881-b60e25cf1a34 -o table
az ad app credential delete --id a60c5cc5-707b-4152-8881-b60e25cf1a34 --key-id <keyId>
```

Deletion is not reversible and the values cannot be recovered, so it takes **two
operators**: one proposes the list, another confirms in the ticket. Keep the
credential named in `applicationsecret` plus the designated spare; everything else
goes. Never do this during an outage — it fixes nothing.

### "CIPP is slow"

**Fixed 2026-09-22 by moving to Flex Consumption.** The old Y1 Consumption plan could not
keep a server warm: Azure replaced the API's server roughly every 64 minutes *even while
it was in use*, and each first request on a fresh server paid ~25s loading PowerShell and
CIPP's modules. A keep-warm ping would not have helped; measured over 7 days, 51 of 56
slow starts happened while the app was busy.

How `cippwemix-flex` is tuned, and why:

| Setting | Value | Why |
| --- | --- | --- |
| Instance memory | 4096 MB (2 cores) | The second core is what lets a page's burst of API calls run in parallel |
| Always ready | `http=1` | One server never goes cold; background work scales on demand |
| HTTP per-instance concurrency | 16 | A page's burst queues on the warm server instead of starting ~13s cold servers |
| `PSWorkerInProcConcurrencyUpperBound` | 4 | 2 runspaces per core. Flex does **not** allow `FUNCTIONS_WORKER_PROCESS_COUNT` |
| Maximum instances | 20 | Caps cost if background work spikes |
| `AzureFunctionsJobHost__functionTimeout` | 00:30:00 | Consumption killed long activities at 10 min; overridden without patching host.json |

Measured before the switch: a burst of 12 simultaneous requests against the old app
failed 7 of 36 with HTTP 500 after ~45s; the same test against Flex, 30 at once, all
completed under 0.18s. Cold start on Flex is ~13s against ~25s. Each new runspace pays
CIPP's ~9s module load once, the first time it is used.

Things that were tried and must not be repeated:

- **`PSWorkerInProcConcurrencyUpperBound=4` on Consumption (2026-09-21/22).** It hurt:
  processor p50 8.9s against 2.8–5.7s, because a Consumption instance has one core.
  It is fine on Flex's two cores; the difference is the hardware, not the setting.
- **PowerShell 7.6 (2026-09-21).** Every invocation failed; CIPP 10.10.3 does not run on
  it. 7.4 reaches end of life on **2026-11-10** and Flex offers 7.4 and 7.6 only, so this
  needs CyberDrain to ship 7.6 support. Watch their release notes from October.
- **Moving the Consumption app to Basic (B1) in place.** Azure does not support direct
  migration from Consumption to a Dedicated plan, only to Elastic Premium. App Service
  quota also has two layers (regional `Total VMs`, then per-SKU); the error names the one
  that blocked you.

### Break-glass alerting (live since 2026-09-23)

Every 5 minutes, the overlay's own `OmzigSentinelTimer` function reads the sign-in logs
of every client tenant, plus Omzig's partner tenant, for the emergency accounts
`bg01@<initial domain>` and `bg02@<initial domain>`. Any sign-in, **including a failed
attempt**, outside a declared incident window raises a P1:

| Channel | Where | Needs |
| --- | --- | --- |
| Logbook | CIPP → Logbook, API `OmzigAlert`, severity Critical | always on |
| Team chat | Adaptive Card in the ops group chat | Key Vault secret `teams-alert-webhook` (a Teams Workflows webhook URL) |
| Email | security@omzig.it (override with `OMZIG_ALERT_EMAIL`), sent by CIPP's own mailer | CIPP notifications working |
| PSA ticket | Autotask P1 | Autotask configured; skipped otherwise |

Expect the alert **5-10 minutes** after the sign-in: Microsoft writes sign-in logs a few
minutes late. Each sign-in alerts once (table `OmzigBreakGlassSeen`), however often it is read.

**Planned use, so nobody gets paged.** Declare an incident window first, in the tenant's
default domain:

```powershell
# from any machine with the CIPP storage connection (or ask Claude to do it)
Add-AzDataTableEntity -Context (New-AzDataTableContext -ConnectionString $conn -TableName OmzigIncidentWindows) -Entity @{
  PartitionKey = 'contoso.com'; RowKey = [guid]::NewGuid().ToString()
  Start = '2026-10-01T14:00:00Z'; End = '2026-10-01T16:00:00Z'; Reason = 'Autotask ticket 12345' }
```

**Prove the alert path works without touching a break-glass account.** Add a row
`PartitionKey=SelfTest, RowKey=Pending, RequestedBy=<you>` to the `OmzigSentinelState`
table. Within 5 minutes a clearly labelled TEST alert goes to the Logbook, the chat and
email; the row is removed; the per-channel result lands in `SelfTest/LastResult`.

**Blind spots are reported, not hidden.** Sign-in logs need Entra ID P1 or higher in the
customer tenant, and a GDAP role that can read them. Health check 17 lists the tenants the
sentinel cannot see; `OmzigSentinelState` holds each tenant's `LastResult`.

**Kill switch:** app setting `AzureWebJobs.OmzigSentinelTimer.Disabled=1` on
`cippwemix-flex`. Health check 17 then goes CRITICAL, deliberately.

### Known, harmless quirks since the Flex move

Found in post-cutover QC on 2026-09-22; none affects CIPP's work.

- **Settings → Backend "Launch" links.** CIPP builds two of them from the app name, so
  the Key Vault link points at `cippwemix-flex` (the vault is `cippwemix`) and the Static
  Web App link at `CIPP-SWA-wemix-flex` (it is `cipp-swa-wemix`). CIPP's real vault access
  uses `CIPP_KV_NAME` and works. Not patched: it is an upstream file, and patching it would
  conflict on every sync.
- **Advanced → Authentication → omzig.ai Users shows no users (HTTP 503).** Not a fault:
  CIPP logs `Endpoint ListCIPPUsers is disabled via feature flag: Super Admin`. That page
  needs the feature enabled in CIPP's settings.
- **The first request after every deploy or restart takes 8-13s** while the server loads
  CIPP; each extra runspace pays ~9s the first time it is used. Warm requests are ~0.1-0.3s.

### New app name? Seed its Version row

CIPP records its version with `Update-AzDataTableEntity`, which cannot create a row. A
brand-new app name therefore "detects" a version change on every start and wipes its own
job hub (`Clear-CippDurables`), so no orchestration ever completes. That blocked the first
Flex cutover. Seeding the row once fixes it permanently; the command is in OUTAGE.md H,
and health check 16 detects the loop.

### Open hardening items

| Item | Status | Fix |
| --- | --- | --- |
| `cippwemix-flex` HTTPS-only | **enabled 2026-09-22** (created without it; caught in QC) | — |
| `cippwemix-flex` basic-auth publishing | **off** (deploys use OIDC only) | — |
| Key Vault purge protection | off | Owner decision — irreversible once enabled |
| Key Vault authorization | access policies, not RBAC | Migrate to RBAC when convenient |
| Key Vault public network access | Enabled | Acceptable while the apps are not VNet-integrated |

---

## 9. Running it with Claude

The whole pass is wrapped in a Claude Code skill, so a tech does not have to remember any
of this:

```
/cipp
```

Claude runs the health check, explains each finding in plain language, and applies the
fixes it is allowed to apply. Run it from your clone of `omzigfrank/CIPP-API`.

**Claude may do without asking:** run the health check; rotate the SAM client secret;
restart the function apps; set HTTPS-only and TLS minimums; add expiry metadata to vault
secrets; enumerate sync-PR conflicts locally; report versions.

**Claude must get a second operator's confirmation first:** deleting any app-registration credential;
merging a sync PR or pushing to either fork; enabling Key Vault purge protection; any
change to GDAP, tenant onboarding, or CIPP standards; anything touching a customer tenant.

**Surface to a human, do not improvise:** the refresh token has expired (needs a Global Admin — Courtney or Frank; an access boundary, not an approval); a conflict falls
into case 4; the health check reports something this runbook does not cover.

### To schedule it

Ask Claude: *"schedule the CIPP monthly maintenance for the first Tuesday of each month at
9am ET."* Claude will register the recurring task. Or run the check unattended and keep the
artifact:

```bash
pwsh -File "./omzig-ops/Invoke-CippHealthCheck.ps1" -Json > "cipp-health-$(date +%Y-%m).json"
```

Exit code `2` is the signal to page someone.

---

## 10. Branding

The portal follows the **omzig.ai brand sheet v1** (August 2026), in
`05 Marketing/Media/omzig.ai/Omzig Branding Sheet.pdf`. Tokens live in the
overlay — `src/omzig/branding/palette.js` (JS) and `tokens.css` (CSS), which
mirror each other. Change colors there, never in a component.

Three things to know before touching brand colors:

- **The all-caps mark with a macron over the O (U+014C) is retired for trademark
  reasons.** Do not reintroduce it. Running prose uses `omzig.ai`.
- **Electric `#35B1FF` is not an AAA small-text color** — 7.80:1 on base Ink but
  6.11:1 on a raised panel. Text uses `#5FC0FF` on dark, `#084E88` on light.
- **Electric fails as a focus ring on white** (2.36:1, under the 3:1 WCAG 2.4.13
  floor), and white-on-Electric fails as button text. The focus ring and the
  primary fill are both mode-aware for this reason.

Ratios are documented inline in `palette.js` and were measured, not estimated.
If you change a token, re-measure — do not assume a neighbouring stop is safe.

Two items are pending a marketing decision, not a code change: the tagline's
brand colors are AA rather than AAA, and the supplied circle icon's ground is
`#1A2436` rather than the sheet's Ink.

## 11. Change log

| Date | Who | What |
| --- | --- | --- |
| 2026-09-23 | Frank + Claude | **Break-glass alerting made live.** The §7.5 sentinel existed but nothing ever ran it, so no break-glass sign-in alerted anyone; its Teams post also used the retired `{ text }` connector format, and the promised email leg was never written. Added the scheduled poller (every 5 min, all tenants + partner tenant, dedupe, incident windows, P1-licence and GDAP blind spots reported), `Send-OmzigAlert` (Logbook, Adaptive Card, email, P1 PSA), a self-test hook and health check 17. 16 new Pester tests; all 134 pass, and four deliberately broken builds each failed the intended test. Health-check workflow now posts every run to the ops chat and no longer files a monthly issue for the two checks its read-only identity cannot perform. Deleted the unused dev stack `rg-omzig-cipp-dev` (all 10 resources; its Cosmos DB held 0 bytes; the vault is soft-deleted until 2026-12-22). Issues enabled on `omzigfrank/CIPP` with the `upstream-sync` label. |
| 2026-09-22 | Frank + Claude | **Backend moved to Flex Consumption.** `cippwemix-flex` (Linux, 4 GB / 2 cores, 1 always-ready HTTP instance) now serves the portal and runs all background work; `cippwemix` and `cippwemix-proc` are Stopped rollback targets. Built next to production with no credentials and its own storage, load-tested (30 simultaneous requests all under 0.18s; the old app failed 7 of 36 with HTTP 500 under a burst of 12), then cut over. **The first cutover was rolled back** after ~20 minutes: CIPP cannot create its Version row for a new app name (`Update-AzDataTableEntity`), so every start wiped the job hub and no orchestration completed. Seeded the row, proved it on test storage, and cut over again at 23:36Z (site API unlinked for 13s); the 23:45Z cycle ran orchestrations and activities with zero errors. Also found: **`cippwemix-proc` had been running 10.6.1 since 2026-07-14** while the API ran 10.10.3, because no workflow deployed it. The single app removes that failure mode. Pipeline: new `deploy-flex` job with OIDC identity `CIPP-Deploy-GitHub-Flex` (no stored secret). Health check gained checks 14-16 (deployed version, background work actually executing, version-loop detector) and a retired-apps check; the rotation script now restarts only running apps. Flex had been created without HTTPS-only; fixed in QC. **Frontend 10.8.5 → 10.10.3** (PR #41, conflicted since 2026-08-21; issue #68 flagged it 2026-09-01 and it sat unactioned): resolved 9 conflicts from upstream's `.js`→`.jsx` rename, fixed four overlay pages broken by it, branded the sign-in screen. Reverted `PSWorkerInProcConcurrencyUpperBound=4` on Consumption (§8). Quota: B1/B2/S1/P0v3/P1v3/EP1/EP2 all creatable in East US 2 from 21:17Z. **Open:** issues are disabled on `omzigfrank/CIPP`; `omzigfrank` is the only collaborator on CIPP-API, so health issues notify nobody else; the dev stack's backend was last deployed 2026-07-11. |
| 2026-08-12 | Frank + Claude | **Rebrand:** applied omzig.ai brand sheet v1 across the frontend (86 files) and swept the retired mark from the API overlay (28 files). Retired the `#3088C8` palette and the all-caps macron mark; Space Grotesk + Calibri; live-text wordmark; icons regenerated. Fixed three contrast defects found by measuring: white-on-Electric primary labels, a focus ring that would have failed on white, and footer opacity that had one line at 2.95:1 (below AA). Verified with a real Node 22.22.0 production build (exit 0, 1244-file export, retired mark absent from all built output). Frontend `7fdf9a10`, API `9baec3911`. See §10. |
| 2026-08-12 | Frank + Claude | **Outage fixed:** rotated the expired CIPP-SAM secret (`AADSTS7000222`, expired 2026-07-22), verified end-to-end. **Upgraded 10.7.5/10.7.3 → 10.8.3** on both forks and both Azure targets; resolved all 6 sync conflicts (§7); both deploy Actions succeeded; post-upgrade health check all green. **Credential cleanup:** deleted 23 unused CIPP-SAM secrets (22 `CIPPInstall` + 1 expired), keeping the in-use secret and `CIPP-SAM-Secret` as a spare; re-verified auth after. Enabled HTTPS-only on `cippwemix`. Set `SSOAppSecret` expiry metadata to match CIPP-SSO's real credential (2028-06-15). Added `CIPP_KV_NAME=kv-omzig-cipp-dev` to `func-omzig-cipp-dev`. Registered the scheduled monthly check (1st of month, 09:00 local). Established this runbook, `Invoke-CippHealthCheck.ps1`, `Invoke-CippSecretRotation.ps1`, and the `/cipp` skill. **Found still open:** the backend `Omzig Upstream Sync` workflow has `TARGET_BRANCH: main` but the repo's default branch is `master`, so it has failed every run since ≥2026-07-13. |
