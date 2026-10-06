# CIPP container migration plan (CIPP NG)

**Status:** proposal, 2026-10-06. Needs the owner decisions in [§9](#9-decisions-needed-from-frank) before Phase 1 starts.
**Hard deadline:** from **1 January 2027** the Function App deployment receives no CIPP updates
(upstream `docs/.gitbook/includes/ng-note.md`). **Target cutover: week of 16 November 2026**, leaving
six weeks of buffer.

Until the cutover, nothing changes for operators. Health check 21 warns if upstream stops feeding our
current forks before the deadline.

## 1. Summary

Upstream CIPP 11.0 replaced the Azure Functions backend and the Static Web App frontend with one Linux
container per instance. That container runs **Craft**, CyberDrain's own ASP.NET Core host
(`CyberDrain/Craft`, AGPL-3.0), which runs CIPP's PowerShell modules in-process on PowerShell 7.4.
Upstream's migration script would delete our live app and deploy stock CIPP, so the whole omzig.ai
overlay would disappear ([§3](#3-why-we-will-not-run-upstreams-migration-script)).

Instead we will:
1. Fork the new monorepo (`CyberDrain/CIPP`) and port our overlay into it.
2. Build **our own image** in GitHub Actions.
3. Prove it in a throwaway staging resource group.
4. Cut over during a planned evening window, keeping the current Flex app and Static Web App as a
   one-step rollback for two weeks.

Storage, Key Vault, credentials, SSO and the `management.omzig.it` hostname all stay.

- **Effort:** about 10-14 working days of engineering, most of which Claude can do.
- **Frank's time:** the decisions below, the Cloudflare DNS change, and about two hours present for
  the cutover.
- **Running cost:** about **$27/month today** to about **$50/month** on the recommended plan.

## 2. What changes

| | Today | After migration |
| --- | --- | --- |
| Backend | Azure Functions host on Flex Consumption `cippwemix-flex` (4 GB) | Craft in a Linux container Web App `cippwemix` |
| Frontend | Static Web App `cipp-swa-wemix` | Served by the same container (no Static Web App) |
| Background work | Durable Functions, queue triggers, `CIPPTimer` | Craft scheduler (`backend/Config/CIPPTimers.json`), orchestrator bridge (`CippOrchestrator*` tables), queue bridge |
| Our code | Two forks of the `KelvinTegelaar` mirrors | One fork of the `CyberDrain/CIPP` monorepo (`frontend/`, `backend/`) |
| Deploy | Zip deploy to Flex (`master_cippd47d2.yml`) + Static Web App workflow | Our image built in Actions → `ghcr.io/omzigfrank/cipp` → Web App set to the new tag |
| Sign-in | Static Web App auth, Easy Auth on Flex | App Service Easy Auth, configured by the container at start-up from the SSO secrets in the vault |
| Storage and Key Vault | `cippstgwemix`, `cippwemix` (access policies) | **Unchanged** |
| Logs | App Insights `appi-cipp-wemix` → `law-cipp-wemix` | App Service diagnostic logs → `law-cipp-wemix`. App Insights wiring in Craft is unverified. |
| Runspace tuning | `PSWorkerInProcConcurrencyUpperBound` (ignored on Flex), HTTP concurrency 12, thread-pool floor, 5-minute warm-up | Fixed Craft pools: HTTP 6 + background 8 on B2/B3/P1v3. Always-on, so no warm-up. Workers recycle every 250 calls. |
| Cost | ~$27/month (Flex $25) | B3 ~$49/month (see [§9](#9-decisions-needed-from-frank)) |

Things that already meet upstream's prerequisites:
- CIPP's `SSOMigration` status is **`secrets_stored`**, and the vault holds `SSOAppId`,
  `SSOAppSecret` and `SSOMultiTenant`.
- `CIPP-SSO` already has the redirect URI `https://management.omzig.it/.auth/login/aad/callback`.
- Frank is Owner on the subscription, which the managed-identity role assignment needs.

## 3. Why we will not run upstream's migration script

`Invoke-CippMigration.ps1` is written for a stock install. In our resource group it would:

- **Delete things we still need, before the new app exists.** It deletes every non-container site,
  their plans, every App Insights component and every file share, then deploys the template. That
  includes `cippwemix-flex`. The outage starts when it unlinks the Static Web App backend and lasts
  until the manual DNS, certificate and SSO steps are done.
- **Deploy stock CIPP** (`ghcr.io/cyberdrain/cipp:latest`). The sentinels, Update Center, quote
  engine, tenant view, GDAP bundles and branding would all be gone.
- **Pick the "first" storage account, vault and Static Web App.** We have two storage accounts. If it
  picks `cippflextest09222235`, the new app points at the wrong data.
- **Replace all resource-group tags** and remove the Static Web App's custom domain without adding it
  to the new app.

We reuse its Bicep template (`deployment/cipp-migration.bicep`) with our own image and parameters, and
do the destructive steps ourselves, in a reversible order.

## 4. Target design

- **Web App name `cippwemix`, in resource group `CIPP`.** The name must equal the Key Vault name:
  Craft's SSO setup finds the vault from `WEBSITE_SITE_NAME` only, and `CIPP_KV_NAME` covers CIPP's
  own lookups but not Craft's. App Service names are global, so the **stopped Function App
  `cippwemix` must be deleted first** (Phase 0). Its default hostname, `cippwemix.azurewebsites.net`,
  is the stale `CIPPURL` that still sits in CIPP's config, so that link starts working again.
- **Plan: Linux B3** (4 vCPU, 7 GB) recommended. Upstream's default is B2 (2 vCPU, 3.5 GB). Our
  portal and background work now share one instance with 14 runspaces, and a Flex HTTP server reached
  3.9 GB on 2026-10-05. The image caps the .NET heap at 3 GB, so B3's extra memory is headroom for
  native memory and the OS. Resize after a week of data.
- **Image:** `ghcr.io/omzigfrank/cipp:<upstream version>-omzig.<build>` (for example `11.0.2-omzig.1`),
  public, like both forks already are.
  - Craft's hourly update check reads the image's version label anonymously, so the image must stay
    public.
  - The Web App is set to an **exact tag**, not `:latest`. Updates then happen only when our pipeline
    deploys, never as a surprise restart.
  - `CRAFT_BASE` is pinned to a Craft version tag.
- **App settings:**
  - Required by the template: `AzureWebJobsStorage` (key-based, as today) and `WEBSITE_RESOURCE_GROUP`.
  - Ours: `CIPP_KV_NAME=cippwemix` (harmless, and covers CIPP's own lookups) and `OMZIG_PORTAL_URL`.
  - `App__Worker__*` only if the Phase 2 load test says so.
- **Identity and access:** a system-assigned identity, a Key Vault access policy (secrets: all) and
  Contributor on the site itself, as in the template. Deploys use a GitHub OIDC identity with Website
  Contributor on the site, as today; there is no stored secret.
- **Health and resilience:** health check path `/api/setup/health`; auto-heal after 5 HTTP 500s in 10
  minutes, as in the template; always-on.
- **Observability:** diagnostic settings send the container and HTTP logs to `law-cipp-wemix`, and
  the health check queries those tables.
- **Domain:** Cloudflare CNAME `management` → `cippwemix.azurewebsites.net`, plus the `asuid.management`
  TXT record, kept after cutover to prevent subdomain takeover. App Service managed certificate.

## 5. Porting the overlay

**API overlay (83 paths):**

| Overlay piece | Today | In the monorepo fork |
| --- | --- | --- |
| `Modules/Omzig` (53 files, 177 Pester tests) | Loaded by our `profile.ps1` patch | `backend/Modules/Omzig`, copied in by `build/Dockerfile.release`. Its manifest exports `'*'`, which blocks auto-loading, so either list explicit `FunctionsToExport` or add Omzig to `App__Worker__HttpModules` / `BgModules`. |
| 6 Omzig HTTP endpoints | `Modules/CIPPHTTP/.../HTTP Functions/Omzig` | Same path under `backend/`. Built into CIPPHTTP, so routing, permissions and the role editor work with no config. |
| 2 timers | `OmzigSentinelTimer`, `OmzigGdapSentinelTimer` (`function.json`) | Two rows in `backend/Config/CIPPTimers.json`: `Receive-OmzigSentinelTimer` at `0 */5 * * * *` and `Receive-OmzigGdapSentinelTimer` at `0 0 13 * * *`. Both functions are already defined the way Craft's scheduler finds them (`^function Name {`). |
| `profile.ps1` patches | Module list, storage mapping | Dropped: no `profile.ps1` in Craft. |
| Flex-only code | `Set-OmzigThreadPoolFloor`, `Invoke-OmzigPortalWarmup` | Removed, along with the warm-up call in the sentinel tick and the `logic-cipp-keep-warm` Logic App. |
| Update Center | 9 functions, 2 endpoints, page, 2 workflows | Retire or rework ([§9](#9-decisions-needed-from-frank) decision 5). |
| Ops tooling | `omzig-ops/`, health-check workflow | Moves to the new repo. The health check is rewritten for a container Web App ([Phase 3](#phase-3--ops-tooling-weeks-3-4-2-3-days-overlaps-phase-2)). |

**Frontend overlay (101 paths):** 43 of our own (`src/omzig/*`, the four `pages/omzig` pages, logos)
and 58 rebranded upstream files (theme, layouts, setup screens). They move under `frontend/` and are
built into the image. `yarn.lock` is regenerated with yarn 1.22, Node 22.22.

**Conflict surface after the port:**
- `backend/Config/CIPPTimers.json` (our two rows)
- `build/Dockerfile.release` (the Omzig copy line)
- the 58 rebranded frontend files

Keep every edit to an upstream file small and marked `omzig.ai overlay`, as today. Upstream changes
the timers file often, so expect a conflict there at most syncs.

## 6. Phases

### Phase 0 — Decide and prepare (this week, about 1 day)
- [ ] Owner decisions in [§9](#9-decisions-needed-from-frank).
- [ ] **Retire the stopped pre-Flex apps.** Flex has been the only live backend since 2026-09-22 and
      is the rollback target now. Remove these:
  - [ ] `cippwemix` and `cippwemix-proc`, their Y1 plan `CIPP-srv-wemix`, and their file shares
        `cippwemix` and `cippwemix-proc`. This frees the `cippwemix` name.
  - [ ] the `deploy` job in `master_cippd47d2.yml`.
  - [ ] their Key Vault access policies and the Contributor and Key Vault role assignments for both
        identities.
- [ ] Raise `cippstgwemix` minimum TLS from 1.0 to 1.2.
- [ ] Confirm Linux B3 can be created in East US 2 (B1/B2 could on 2026-09-22).

**Gate:** decisions recorded in this file.

### Phase 1 — New fork and our image (weeks 1-2, 3-4 days)
- [ ] Fork `CyberDrain/CIPP` as `omzigfrank/CIPP-NG` (public), with pull[bot] following `main`.
- [ ] Port the overlay ([§5](#5-porting-the-overlay)); adapt Omzig QC (PSScriptAnalyzer + Pester) to
      `backend/` paths.
- [ ] Add workflow `omzig-image.yml`, which builds `build/Dockerfile.release` with our version and
      pushes to GHCR. Copy upstream's `release-container.yml`; it already publishes to
      `ghcr.io/${{ github.repository }}`.
- [ ] Local smoke test with upstream's compose file and Azurite:
  - the container starts and `/api/setup/health` returns 200;
  - the Omzig endpoints are routed and appear in `function-permissions.json`;
  - both Omzig timers are scheduled.

**Gate:** the image builds in CI, Pester is green, and the smoke test passes.

### Phase 2 — Staging (weeks 2-3, 2-3 days)
- [ ] Resource group `rg-cipp-ng-staging` with its own storage account and its own Key Vault, and
      **no client credentials**. The Web App is named after that vault and runs our image.
- [ ] Restore a CIPP backup taken from production (configuration only), so pages show real settings.
- [ ] Verify:
  - [ ] sign-in through a staging SSO app, and roles from `allowedUsers`;
  - [ ] every overlay page and endpoint, and the branding;
  - [ ] both sentinel timers fire on schedule (Graph calls fail without credentials; that is
        expected and logged);
  - [ ] version reporting, and the update check against our GHCR tag;
  - [ ] the 10-call dashboard burst test, idle and back to back;
  - [ ] memory and CPU on B3;
  - [ ] a restart, and auto-heal;
  - [ ] logs arriving in `law-cipp-wemix`.
- [ ] **Never** give staging production credentials or production storage. It would run every timer
      a second time against client tenants, overwrite `CIPPURL` and re-register the Partner Center
      webhook.

**Gate:** checklist green, then delete the staging resource group.

### Phase 3 — Ops tooling (weeks 3-4, 2-3 days, overlaps Phase 2)
- [ ] **Rewrite the health check for a container Web App:**
  - **Replace:**
    - 2 (Function App state) → Web App and container state;
    - 10 and 14 (deploy age, deployed version) → image tag vs `APP_VERSION`;
    - 15 (background work) → `CippOrchestrator*` progress;
    - 16 (job-hub wipe loop) → `InstanceHealth` rows and container restarts;
    - 20 (Flex memory) → plan memory.
  - **Drop:** 19 (warm-up) and 21 (mirror check: after the move we track the monorepo directly).
  - **Keep:** 1, 3-7, 11, 17 and 18 as they are. 8 and 9 are re-pointed at `omzigfrank/CIPP-NG`
    and `CyberDrain/CIPP`; 12 and 13 at the Web App and its log tables.
- [ ] Re-scope the deploy identity (OIDC) to Website Contributor on the new site.
- [ ] Rewrite the runbook sections on architecture, deploys, the outage playbook and rollback. The
      sentinel alerting (Teams card, email, PSA) is unchanged.

**Gate:** the health check runs green against staging.

### Phase 4 — Cutover (week of 16 November, weekday evening; 2-hour window, about 20-40 minutes down)

**Two days before:**
- [ ] Lower the Cloudflare TTL on `management.omzig.it` to 60 seconds.
- [ ] Deploy the plan and the Web App `cippwemix` **stopped**, with our image tag, app settings,
      identity, vault access policy and diagnostic settings. Use our template variant, without the
      resource-group tag resource.
- [ ] Add the `asuid.management` TXT record with the app's domain verification ID, then try to
      pre-bind the hostname. If App Service refuses while the Static Web App holds it, bind during
      the window.
- [ ] Write `allowedUsers` rows for the two Static Web App users (both superadmin).
- [ ] Take a CIPP backup. Record the Flex deploy SHA. Announce the window.

**In the window:**
1. Check that no long orchestrations are running, then **stop `cippwemix-flex`**. The outage starts
   here.
2. **Start `cippwemix`.** Wait for `/api/setup/health` to return 200 on `cippwemix.azurewebsites.net`.
   Check the start-up logs: vault found, Easy Auth configured, timers loaded.
3. **Move the domain:**
   1. Remove `management.omzig.it` from the Static Web App.
   2. Point the Cloudflare CNAME at `cippwemix.azurewebsites.net`.
   3. Add the domain to the Web App, with a managed certificate and an SNI binding.
4. **Sign in.** If needed, run CIPP → Advanced → Authentication → SSO → Refresh Sign-in URLs.
5. **Run the verification list:**
   - dashboard, tenant list, and one read in a client tenant;
   - every overlay page;
   - the container page shows our image and version;
   - the first sentinel tick, within 5 minutes;
   - one CIPP timer orchestration completes.

**Rollback** (any failed verification, or the decision of whoever is running the cutover), about 15
minutes:
1. Stop `cippwemix` and remove the domain from it.
2. Point the CNAME back at `green-mud-075932c0f.4.azurestaticapps.net` and re-add the domain to the
   Static Web App.
3. Start `cippwemix-flex`.

The data is shared, so nothing needs restoring.

**After:**
- [ ] Run the health check.
- [ ] Confirm the Partner Center webhook. Craft re-registers it at start-up when automated onboarding
      is on.
- [ ] Restore the DNS TTL.

### Phase 5 — Hypercare, then decommission (2 weeks after cutover)
- [ ] Run the health check daily for the first week. Compare request latency and failures with the
      Flex baseline (p50 about 0.4 s, no failed requests).
- [ ] After 14 stable days, delete:
  - `cippwemix-flex`, `ASP-CIPP-7270` and `cippflextest09222235`;
  - `cipp-swa-wemix` and `logic-cipp-keep-warm`;
  - `appi-cipp-wemix`, if the Log Analytics tables cover the health checks;
  - the old identities' role assignments and Key Vault policies.
- [ ] Archive `omzigfrank/CIPP` and `omzigfrank/CIPP-API` (read-only).
- [ ] Update the runbook and the `/cipp` skill.

## 7. Risks

| Risk | Mitigation |
| --- | --- |
| Craft is new: 11.0.0 shipped 2026-09-25, with two hotfixes since | Staging first, cut over no earlier than mid-November, pin the Craft base tag, keep the rollback for 14 days |
| Overlay doesn't load in Craft: the module manifest's `'*'` exports, the background allow-list `CRAFT_ALLOWED_MODULES` | Phase 1 smoke test checks every endpoint and timer; explicit exports |
| Memory on one shared instance (14 runspaces, 3 GB heap cap) | B3, load test in staging, `App__Worker__*` pool sizes if needed, Craft recycles workers every 250 calls |
| Domain move takes longer than planned (certificate issuance) | Pre-stage the TXT record and try pre-binding; 60-second TTL; rollback is a CNAME change |
| Orchestrations in flight at cutover are lost (Durable Functions state isn't carried over) | Cut over in a quiet evening hour; the timers start the next runs |
| Health checks go blind (App Insights not wired in Craft, unverified) | Diagnostic settings to Log Analytics; health-check rewrite in Phase 3 before cutover |
| Distroless image: no shell to exec into | Rely on logs; reproduce locally with compose |
| Upstream changes `CIPPTimers.json` or `Dockerfile.release` often | Keep our edits to a few marked lines; weekly health check plus `--repo`-fixed sync alerts |
| Staging accidentally touches production | Separate resource group, storage and vault; no production credentials, by rule |

## 8. Effort and cost

| | Estimate |
| --- | --- |
| Phase 0 | 1 day |
| Phase 1 | 3-4 days |
| Phase 2 | 2-3 days |
| Phase 3 | 2-3 days |
| Phase 4 | half a day, plus the window |
| Phase 5 | a few hours over 2 weeks |
| Running cost (East US 2, Linux, pay-as-you-go) | B2 ~$25, **B3 ~$49**, P0v3 ~$57 (4 GB), P1v3 ~$113/month; plus storage ~$1.30 and log ingestion. Flex today: ~$25. |

## 9. Decisions needed from Frank

1. **Go ahead, and the cutover window.** Recommended: a weekday evening in the week of 16 November.
2. **Plan size.** Recommended **B3**. B2 is upstream's default but tight for us. P1v3 adds deployment
   slots and autoscale at 2.3 times the price.
3. **Public image on GHCR.** Recommended yes: both forks are already public, and Craft's update check
   needs it. The alternative is a private registry, which costs Craft's update check (our pipeline
   handles deploys anyway).
4. **New fork `omzigfrank/CIPP-NG`,** archiving the two current forks after cutover. Recommended yes.
5. **Update Center.** Recommended: **retire it**. Updates become pull[bot] sync PR → our image build
   → deploy of an exact tag, with Craft's container page showing the running version. The
   alternative is porting it to the single-repo, image-based flow, about 1-2 extra days.
6. **Delete the stopped `cippwemix` / `cippwemix-proc` apps now** (Phase 0). Required to free the
   name. Recommended yes.
7. **Who changes Cloudflare DNS** during the window: Frank, or a scoped Cloudflare API token for
   automation.

## 10. To verify during Phases 1-2

- App Insights in Craft. Otherwise confirm which App Service log tables carry what the health checks
  need.
- Whether `11.0.2-omzig.1`-style versions satisfy Craft's semver parsing, its update check and the
  `cachehttppermissions` cache.
- Craft's sign-in path: its docs describe built-in OIDC, but its auth middleware says it relies on
  Easy Auth only.
- Whether App Service accepts `management.omzig.it` while the Static Web App still holds it.
- Pool sizes and memory on B3 under the burst test.

## Sources

- Upstream: `CyberDrain/CIPP@main` (v11.0.2):
  - `build/Dockerfile.release`
  - `backend/Config/CIPPTimers.json`
  - `deployment/cipp-migration.bicep`
  - `deployment/Invoke-CippMigration.ps1`
  - `.github/workflows/release-container.yml`
  - `docs/.gitbook/includes/ng-note.md`
- Craft: `CyberDrain/Craft@main`:
  - `Services/SchedulerService.cs`
  - `PowerShellDispatchEndpoint.cs`
  - `CraftAuthMiddleware.cs`
  - `SetupService.cs`
  - `appsettings.Production.json`
- [Migrating Self-Hosted to the New Infrastructure](https://docs.cipp.app/setup/maintaining-cipp/migrating-to-the-new-infrastructure)
- Our environment, inventoried 2026-10-06: resource group `CIPP`, Key Vault `cippwemix`, `SSOMigration`
  table, cost management (30 days), Cloudflare DNS for `omzig.it`.
