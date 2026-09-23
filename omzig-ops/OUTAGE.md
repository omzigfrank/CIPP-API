# CIPP is down — start here

You do not need permission to work through this page. Every step is something an
operator is expected to do. Work top to bottom and stop when the portal recovers.

If you are on the fence about whether to act: **acting is correct.** Every
procedure below is either read-only or reversible, and CIPP being down means we
cannot touch any client tenant.

---

## First 60 seconds

```bash
cd CIPP-API && az login
az account set --subscription 48019666-dd78-439e-9890-030ab5156f23
pwsh -File "./omzig-ops/Invoke-CippHealthCheck.ps1"
```

The check names the fault. Find your symptom below.

| What the check or portal says | Go to |
| --- | --- |
| `AADSTS7000222`, `invalid_client`, "client secret ... expired" | [A](#a-expired-client-secret) |
| `AADSTS70008`, `invalid_grant`, refresh-token errors | [B](#b-expired-refresh-token) |
| `cippwemix-flex` is not `Running` | [C](#c-function-app-stopped) |
| Key Vault reference missing/disabled | [D](#d-key-vault-reference-broken) |
| All green, but the portal is still broken | [E](#e-check-is-green-portal-is-not) |
| It broke right after a deploy | [F](#f-roll-back-a-bad-deploy) |
| `Retired app ... is Running` | Stop it now: `az functionapp stop -g CIPP -n <app>` — then read [G](#g-roll-back-to-the-old-consumption-apps) to see if someone half-rolled-back |
| `Version loop` CRITICAL, or `Background` shows timers but no work | [H](#h-version-loop--background-jobs-stall) |
| Flex itself is the problem and nothing above helps | [G](#g-roll-back-to-the-old-consumption-apps) |

**Since 2026-09-22 CIPP's backend is one app, `cippwemix-flex`** (Flex Consumption,
Linux). It serves the portal *and* runs the timers, queues and orchestrations. The old
`cippwemix` (API) and `cippwemix-proc` (processor) are **Stopped rollback targets.
Do not start them** except as part of G: a running old processor runs every job a
second time against client tenants.

---

## A. Expired client secret

**The most likely cause.** This is what took CIPP down on 2026-07-22.

Needs: membership of `CIPP-Azure-Admins`. Takes about two minutes.

```bash
pwsh -File "./omzig-ops/Invoke-CippSecretRotation.ps1"
```

It appends a new secret rather than replacing one, proves the secret works
*before* storing it, restarts `cippwemix-flex` (it skips any app that is not
Running, so the retired apps stay down), and re-verifies. If it fails partway the
vault is untouched, so you are no worse off. Re-run the health check afterwards.

**You do not need approval for this.** A rotation during an outage is the correct
action, and it is reversible in the sense that the old credential is left in place.

## B. Expired refresh token

CIPP's SAM refresh token dies after 90 days without use. No script can fix this —
it requires an interactive consent by a **Global Administrator** in the partner
tenant.

Who can do it: Courtney (`cwright@omzig.it`) or Frank. Both hold Global Admin.

In CIPP: **Settings → CIPP-SAM Setup Wizard**, and re-run the refresh-token step.
Sign in as the Global Admin when prompted.

> Confirm the exact menu path against the running portal — it moves between CIPP
> releases and has not been re-verified since 10.8.3. If the wizard is not where
> this says, look under Settings for "SAM Setup" or "Sign in with Microsoft".

The health check warns from 60 days, so this should never surprise you. If it
does, that warning was missed — say so in the ticket rather than quietly fixing it.

## C. Function app stopped

```bash
az functionapp start -g CIPP -n cippwemix-flex
# `az functionapp show` prints a BLANK state for Flex apps - read it through ARM instead:
az rest --method GET --url "https://management.azure.com/subscriptions/48019666-dd78-439e-9890-030ab5156f23/resourceGroups/CIPP/providers/Microsoft.Web/sites/cippwemix-flex?api-version=2024-04-01" --query properties.state -o tsv
```

Needs `CIPP-Azure-Admins`. If it stops again on its own, that is not a stopped app
— that is a crash, so go to E and read the logs.

Do **not** "fix" this by starting `cippwemix` or `cippwemix-proc`. The site is not
linked to them, so the portal stays down, and the old processor starts running jobs.

## D. Key Vault reference broken

The four credential settings on `cippwemix-flex` are Key Vault references. If one
points at a missing or disabled secret, CIPP cannot authenticate.

```bash
az keyvault secret list --vault-name cippwemix -o table
az functionapp config appsettings list -g CIPP -n cippwemix-flex \
  --query "[?starts_with(value,'@Microsoft.KeyVault')].{name:name,value:value}" -o table
# Azure's own verdict on each reference:
az rest --method GET --url "https://management.azure.com/subscriptions/48019666-dd78-439e-9890-030ab5156f23/resourceGroups/CIPP/providers/Microsoft.Web/sites/cippwemix-flex/config/configreferences/appsettings?api-version=2024-04-01" --query "value[].{name:name,status:properties.status}" -o table
```

- A secret is **disabled** → re-enable it:
  `az keyvault secret set-attributes --vault-name cippwemix --name <name> --enabled true`
- A secret is **missing** → for `applicationsecret`, go to A; for anything else,
  escalate with the evidence package at the bottom.
- References look right but still fail → the app lost its managed-identity access.
  Confirm `cippwemix-flex`'s identity (`ea16ffe4-7bfd-4c0e-bb03-901ca157cfec`) has
  `secrets: all` in the vault's access policies, then restart:
  `az functionapp restart -g CIPP -n cippwemix-flex`
- `CIPP_KV_NAME=cippwemix` must be set on `cippwemix-flex`. CIPP normally derives the
  vault name from the app name, and `cippwemix-flex` is not the vault's name.

**Never paste a literal secret into an app setting to "get it working."** It will
appear to fix the outage and silently break every future rotation.

## E. Check is green, portal is not

CIPP's backend is healthy, so the fault is the frontend, Entra sign-in, or the
browser session. In order:

1. Hard-reload, then try a private window. Rules out a stale bundle.
2. Did the frontend deploy recently, and did it succeed?
   `https://github.com/omzigfrank/CIPP/actions`
3. Read the API's own logs for the last hour:

```bash
az monitor app-insights query --app appi-cipp-wemix -g CIPP --analytics-query \
  "AppTraces | where TimeGenerated > ago(1h) | where SeverityLevel >= 3 | project TimeGenerated, Message | order by TimeGenerated desc | take 20" -o table
```

4. If sign-in itself fails, it is Entra, not CIPP: check the sign-in logs for the
   CIPP-SSO app in the Entra portal.

## F. Roll back a bad deploy

Both halves of CIPP deploy from a push to their fork. **Reverting the commit is
the rollback** — do not try to hand-edit anything in Azure.

```bash
# backend
git clone https://github.com/omzigfrank/CIPP-API.git && cd CIPP-API
git log --oneline -5                 # find the commit that broke it
git revert --no-edit <sha>
git push origin master               # the deploy Action runs automatically
```

Frontend is identical with `omzigfrank/CIPP` and branch `main`.

The backend push runs two jobs: `deploy-flex` (the live app, signed in by GitHub
OIDC with no stored secret) and `deploy` (keeps the stopped old app current as a
rollback target). Only `deploy-flex` matters for recovery.

Confirm which version is actually running: the health check's **Deployed version**
line reads it from the app's own startup log. Flex keeps no Kudu deployment history,
so the old `/deployments` query returns nothing for it.

A revert is safe and reviewable. Reverting a change you are unsure about is
better than leaving CIPP down while you find out.

## G. Roll back to the old Consumption apps

The emergency exit from Flex, used and verified on 2026-09-22 (about two minutes).
Use it only if Flex itself is broken and a revert (F) does not help. Needs
`CIPP-Azure-Admins`. In Git Bash, prefix `az rest` with `MSYS_NO_PATHCONV=1` or it
rewrites the `/subscriptions/...` URLs into Windows paths.

```bash
S=48019666-dd78-439e-9890-030ab5156f23
W=https://management.azure.com/subscriptions/$S/resourceGroups/CIPP/providers/Microsoft.Web
# 1. old API back up and reachable (it is locked to Deny while retired)
az functionapp start -g CIPP -n cippwemix
az functionapp config access-restriction set -g CIPP -n cippwemix --default-action Allow
# 2. point the site at it
az rest --method DELETE --url "$W/staticSites/cipp-swa-wemix/linkedBackends/cippwemix-flex?api-version=2023-12-01"
az rest --method PUT --url "$W/staticSites/cipp-swa-wemix/linkedBackends/cipp-swa-wemix?api-version=2023-12-01" \
  --body "{\"properties\":{\"backendResourceId\":\"/subscriptions/$S/resourceGroups/CIPP/providers/Microsoft.Web/sites/cippwemix\",\"region\":\"eastus2\"}}"
# 3. linking resets the unauthenticated action - put it back to Return401
#    (Portal: cippwemix > Authentication > "Unauthenticated requests" = HTTP 401)
# 4. background jobs: stop them on Flex FIRST, then start the old processor
az functionapp config appsettings set -g CIPP -n cippwemix-flex --settings \
  AzureWebJobs.CIPPTimer.Disabled=1 AzureWebJobs.CIPPActivityFunction.Disabled=1 \
  AzureWebJobs.CIPPOrchestrator.Disabled=1 AzureWebJobs.CIPPQueueTrigger.Disabled=1 -o none
az functionapp start -g CIPP -n cippwemix-proc
```

`az staticwebapp backends link` failed with `Not Found` during the 2026-09-22 cutover
while the ARM `PUT` above worked first time, which is why this uses ARM.

Order matters in step 4: two apps running background jobs at once means every job
runs twice.

This rollback relies on CIPP's **Offload functions** setting being **ON** (CIPP →
Settings → Backend/Features). With it on, the old Consumption API keeps its own
background triggers disabled and leaves the work to `cippwemix-proc`. Flex ignores the
setting, so nothing tells you it matters until the day you roll back: leave it on. Then run the health check with `-ApiApp cippwemix -ProcessorApp cippwemix-proc -RetiredApps @()`.

## H. Version loop / background jobs stall

Symptom: the health check shows `Version loop` CRITICAL, or `Background` shows timer
runs but no orchestration/activity work, and the logs show `Version has changed from
None` on every start, followed by `TableBeingDeleted` and listeners that were "unable to start".

Cause: CIPP records its version with `Update-AzDataTableEntity`, which can update a
row but never create one. For an app name the `Version` table has never seen, every
start concludes the version changed and wipes the app's own job hub. It happened on
the first Flex cutover and blocked all background work until the row was seeded.

Fix: seed the row CIPP is trying to write (use the version the app reports at startup):

```bash
CONN=$(az functionapp config appsettings list -g CIPP -n cippwemix-flex --query "[?name=='AzureWebJobsStorage'].value | [0]" -o tsv)
az storage entity insert --connection-string "$CONN" --table-name Version --if-exists replace \
  --entity PartitionKey=Version RowKey=cippwemix-flex Version=10.10.3 PSVersion=7.4.19
unset CONN
```

The next start is clean and CIPP keeps the row updated from then on. Any new app
name, such as a replacement app, needs this once.

---

## Irreversible things — the only genuine stop signs

Everything above is reversible. These are not, so they need a second person, not
a manager:

| Action | Rule |
| --- | --- |
| Delete an app-registration credential | Never during an outage. It fixes nothing and is unrecoverable. |
| Delete or disable `CIPPServiceAccount@omzig.it` | **Never.** It likely minted the refresh token; removing it cuts CIPP off from every client. |
| Enable Key Vault purge protection | Never during an outage. Irreversible once on. |
| Change GDAP, standards, or anything inside a client tenant | Not an outage action. |

## If you have worked through all of it and CIPP is still down

Now escalate — but escalate with evidence, so the next person starts where you
finished rather than at the top of this page.

```bash
pwsh -File "./omzig-ops/Invoke-CippHealthCheck.ps1" -Json > outage-$(date +%Y%m%d-%H%M).json
```

Include: that file, which sections you worked, what changed and when, the last
deployment time from F, and any error text verbatim.

Escalation order is the on-call rota in
[CIPP-Monthly-Maintenance-Runbook.md](CIPP-Monthly-Maintenance-Runbook.md) —
secondary first, Frank last. Reaching the end of this page without a fix is not a
failure; it means the fault is genuinely novel, and it should be added here once
solved so the next person does not need to escalate at all.
