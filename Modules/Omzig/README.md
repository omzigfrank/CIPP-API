# omzig.ai Overlay — CIPP-API Module

All Omzig-specific backend logic lives in this module, per the overlay pattern
in the Omzig Custom CIPP Build spec (§11.4): never patch upstream CIPP modules.
Upstream touchpoints are carefully scoped:

- `profile.ps1` carries two marked omzig.ai overlay patches: (1) adds `Omzig` to the
  core module import list; (2) an environment shim that maps
  `CIPP_STORAGE_CONNECTION_STRING` onto `AzureWebJobsStorage` at startup so
  isolated deployments keep platform storage identity-based while upstream code
  reads `AzureWebJobsStorage` unchanged.
- A small, concentrated set of upstream CIPPCore/CippExtensions files is patched
  to derive the Key Vault name through the new `Get-CIPPKeyVaultName` helper
  (which prefers the `KEYVAULT_NAME` env var and falls back to upstream's
  `WEBSITE_DEPLOYMENT_ID` derivation). These are the auth/SSO/SAM-setup and
  secret-CRUD files only; pure storage call sites are NOT patched.

## Layout

| Path | Purpose | Spec |
|---|---|---|
| `Public/Config/Get-OmzigConfig.ps1` | Resolved portal configuration (env + confirmed defaults) | §17 |
| `Public/Config/Test-OmzigPreflight.ps1` | Deployment gate — halts on missing Pax8/Autotask/Datto secrets | §17 item 5 |
| `Public/Psa/Get-OmzigPsaContract.ps1` | The IPsaClient operation contract | §7.14 |
| `Public/Psa/Get-OmzigPsaClient.ps1` | Adapter factory (`PSA_PROVIDER=autotask\|halo`) with contract enforcement | §7.14 |
| `Public/Psa/Autotask/*` | Autotask REST client: zone discovery, retries, integration-user probe | Appendix A |
| `Public/Rmm/*` | Datto RMM v2 client, platform pinned to Vidal | §17 item 4, Appendix B |
| `Public/Sentinel/Invoke-OmzigBreakGlassSentinel.ps1` | P1 chain for break-glass sign-ins outside incident windows | §7.5, §17 item 12 |
| `Public/Sentinel/Invoke-OmzigBreakGlassPoll.ps1` | Scheduled poller: bg01/bg02 sign-ins from every tenant, dedupe, incident windows | §7.5 |
| `Public/Entrypoints/Receive-OmzigSentinelTimer.ps1` | Entrypoint for the overlay-owned `OmzigSentinelTimer` function (every 5 min) + self-test hook | §7.5 |
| `Public/Alerts/Send-OmzigAlert.ps1` | One alert → Logbook, Teams card, email, P1 PSA ticket; each channel best-effort | §7.5 |
| `Public/Alerts/New-OmzigTeamsCard.ps1` | Adaptive Card payload for Teams Workflows webhooks (the `{ text }` connector format is retired) | §7.5 |
| `Private/Get-OmzigTeamsWebhook.ps1` | Resolves the webhook from `OMZIG_TEAMS_WEBHOOK` or Key Vault `teams-alert-webhook` | §7.5 |

`OmzigSentinelTimer/function.json` at the repo root is the overlay's own timer function.
It exists because CIPP's timer list (`Config/CIPPTimers.json`) and its scheduled-task
module allow-list are upstream files: registering the sentinel in either would be a
patch that conflicts on every sync. A new function folder is pure overlay.
| `Public/Sentinel/Invoke-OmzigGdapExpirySentinel.ps1` | 60/30/7-day GDAP expiry + role drift findings | §7.6 |
| `Public/Pricing/*` | AIRA/AIDF/AID/MAIO floors, 70% margin gate, Frank-signed override tokens | §3 |
| `Public/Tenants/*` | `omzig_tenants` record CRUD — **baa defaults to true** | §14, §17 item 11 |
| `Public/Health/Get-OmzigClientHealthScore.ps1` | Client Health Score v1 (0–100 weighted composite) | §7.1 |
| `Tests/Omzig.Tests.ps1` | Pester suite (QC pass 2) | §13 |

## Conventions

- Functions follow upstream CIPP style: `Verb-OmzigNoun`, comment-based help,
  `.FUNCTIONALITY Internal`.
- Storage rides upstream `Get-CIPPTable` / `Add-CIPPAzDataTableEntity` so the
  overlay uses the same plumbing as the rest of CIPP-API. The §14 Cosmos
  containers are provisioned by the Bicep for workloads that need SQL queries
  (audit ledger, quotes); tenant records start in Table storage.
- Secrets are only ever read from environment/Key Vault at call time and are
  never included in returned objects or logs.
- Every write function supports `-WhatIf` (dry-run is the portal default,
  Appendix D).

## Running the tests

```powershell
Invoke-Pester ./Modules/Omzig/Tests
```

The suite is self-contained: external calls (`Invoke-RestMethod`, CIPP table
helpers) are mocked.
