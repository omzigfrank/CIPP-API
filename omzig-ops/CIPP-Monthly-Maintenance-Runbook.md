# CIPP Monthly Maintenance Runbook

**Owner:** Frank Diaz · **Audience:** Omzig engineers with CIPP admin
**Last verified against the live instance:** 2026-08-12

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
                                              │ GitHub Action
                                              ▼
                              cippwemix        (Function App — HTTP API)
                              cippwemix-proc   (Function App — timers/queues/orchestrators)

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
| API function app | `cippwemix` |
| Processor function app | `cippwemix-proc` (`CIPP_PROCESSOR=true`) |
| Static Web App | `cipp-swa-wemix` → `management.omzig.it` |
| Key Vault | `cippwemix` |
| Storage | `cippstgwemix` |
| Logs | `law-cipp-wemix` / `appi-cipp-wemix` |
| SAM app registration | **CIPP-SAM** — `a60c5cc5-707b-4152-8881-b60e25cf1a34` |

### The one architectural fact that matters

**Key Vault `cippwemix` is the single source of truth for every CIPP credential.**
All four credential app settings on `cippwemix` are Key Vault *references*, not literals:

```
ApplicationSecret = @Microsoft.KeyVault(VaultName=cippwemix;SecretName=applicationsecret)
RefreshToken      = @Microsoft.KeyVault(VaultName=cippwemix;SecretName=refreshtoken)
ApplicationId     = @Microsoft.KeyVault(VaultName=cippwemix;SecretName=applicationid)
TenantId          = @Microsoft.KeyVault(VaultName=cippwemix;SecretName=tenantid)
```

`cippwemix-proc` carries no credential settings at all — CIPP derives the vault name from
the site name at runtime and reads it with the app's managed identity.

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

Operators can run every one of the 13 checks, including the live token test.
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

> **Status: awaiting Frank's one-time sign-off.** Until he confirms this table, the
> old behaviour stands and operators ask first. The point of writing it down is
> that he approves the *rules* once instead of being called per incident.

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
see section 7. Once the sync PR merges, the GitHub Action deploys automatically; confirm
with:

```bash
az rest --method GET --url "https://management.azure.com/subscriptions/48019666-dd78-439e-9890-030ab5156f23/resourceGroups/CIPP/providers/Microsoft.Web/sites/cippwemix/deployments?api-version=2022-03-01" --query "value[0].properties.{time:end_time,active:active,msg:message}"
```

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
az functionapp start -g CIPP -n cippwemix
az functionapp start -g CIPP -n cippwemix-proc
```

### Key Vault reference not resolving

Check the managed identity still has vault access, then restart. References cache for up
to 24h, so a restart is how you force re-resolution:

```bash
az functionapp restart -g CIPP -n cippwemix
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

### Open hardening items

| Item | Status | Fix |
| --- | --- | --- |
| `cippwemix` HTTPS-only | ~~off~~ **enabled 2026-08-12** | — |
| Key Vault purge protection | off | Owner decision — irreversible once enabled |
| Key Vault authorization | access policies, not RBAC | Migrate to RBAC when convenient |
| Key Vault public network access | Enabled | Acceptable while the apps are not VNet-integrated |

---

## 9. Running it with Claude

The whole pass is wrapped in a Claude Code skill, so a tech does not have to remember any
of this:

```
/cipp-monthly-maintenance
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
| 2026-08-12 | Frank + Claude | **Rebrand:** applied omzig.ai brand sheet v1 across the frontend (86 files) and swept the retired mark from the API overlay (28 files). Retired the `#3088C8` palette and the all-caps macron mark; Space Grotesk + Calibri; live-text wordmark; icons regenerated. Fixed three contrast defects found by measuring: white-on-Electric primary labels, a focus ring that would have failed on white, and footer opacity that had one line at 2.95:1 (below AA). Verified with a real Node 22.22.0 production build (exit 0, 1244-file export, retired mark absent from all built output). Frontend `7fdf9a10`, API `9baec3911`. See §10. |
| 2026-08-12 | Frank + Claude | **Outage fixed:** rotated the expired CIPP-SAM secret (`AADSTS7000222`, expired 2026-07-22), verified end-to-end. **Upgraded 10.7.5/10.7.3 → 10.8.3** on both forks and both Azure targets; resolved all 6 sync conflicts (§7); both deploy Actions succeeded; post-upgrade health check all green. **Credential cleanup:** deleted 23 unused CIPP-SAM secrets (22 `CIPPInstall` + 1 expired), keeping the in-use secret and `CIPP-SAM-Secret` as a spare; re-verified auth after. Enabled HTTPS-only on `cippwemix`. Set `SSOAppSecret` expiry metadata to match CIPP-SSO's real credential (2028-06-15). Added `CIPP_KV_NAME=kv-omzig-cipp-dev` to `func-omzig-cipp-dev`. Registered the scheduled monthly check (1st of month, 09:00 local). Established this runbook, `Invoke-CippHealthCheck.ps1`, `Invoke-CippSecretRotation.ps1`, and the `/cipp-monthly-maintenance` skill. **Found still open:** the backend `Omzig Upstream Sync` workflow has `TARGET_BRANCH: main` but the repo's default branch is `master`, so it has failed every run since ≥2026-07-13. |
