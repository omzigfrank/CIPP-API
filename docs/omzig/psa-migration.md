# PSA Migration Path — Autotask → HaloPSA

Spec §7.14. Autotask is the primary PSA; HaloPSA ships as a contract-compliant
stub so a future migration is a **config change, not a rewrite**.

## How the abstraction works

Every PSA touchpoint in the portal goes through the adapter factory:

```powershell
$Psa = Get-OmzigPsaClient          # provider from PSA_PROVIDER env var
& $Psa.NewTicket $TicketObject     # identical call shape on every provider
```

The contract (`Get-OmzigPsaContract`) covers tickets, companies, contacts,
contracts, time entries, resources, and configuration items. The factory
throws at construction time if an adapter is missing any operation, and the
Pester suite verifies both adapters against the contract on every PR.

## Adapter status

| Adapter | Status |
|---|---|
| `autotask` | Production. Zone discovery via `zoneInformation` (never hard-coded), Omzig Portal tracking identifier, rate-limit-aware retries with jitter. |
| `halo` | Shipped stub. Signatures final; every operation throws `NotImplementedException` with guidance until wired against a Halo sandbox. Not reachable from production surfaces. |

## Migration runbook (when Frank decides to switch)

1. Wire the `halo` adapter bodies in
   `Modules/Omzig/Public/Psa/Get-OmzigPsaClient.ps1` against a HaloPSA
   sandbox (the upstream `CippExtensions` Halo functions are a reference for
   auth and ticket shapes). Integration tests must pass against the sandbox.
2. Store Halo credentials in Key Vault (`HALO_CLIENT_ID`, `HALO_CLIENT_SECRET`,
   `HALO_AUTH_URL`, `HALO_TENANT`) and extend `Test-OmzigPreflight` so the
   blocking checks follow the active provider.
3. Run the data-mapping wizard to map Autotask company/contract/ticket IDs in
   `omzig_tenants.psa` to their Halo equivalents.
4. Flip `PSA_PROVIDER=halo` on the Function App (stage first, then prod).
5. The portal continues without code changes. Roll back by flipping the
   variable back — the Autotask adapter and mappings stay intact.
