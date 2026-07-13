# Incident 2026-07-13 — canary auth code broke Graph tokens for all tenants

## Summary

On **2026-07-11 02:37 UTC**, an Update Center beta test installed
`KelvinTegelaar/CIPP-API@dev` (canary) into `master` (merge `cb9626f62`),
which auto-deployed to the production Function App `cippwemix`. The canary
branch's rewritten Graph token layer (`CIPPTokenCache` shared token cache,
SAM certificate assertion work) caused fleet-wide
`AADSTS700003` ("Device object was not found in the tenant directory")
token failures for every managed tenant.

Timeline (UTC):

| When | What |
| --- | --- |
| 07-10 evening | Upstream sync deployed v10.6.0 stable — no errors |
| 07-11 02:46 | Canary (dev branch) deployed to prod |
| 07-11 04:00 | First `AADSTS700003` ever logged |
| 07-11 → 07-13 | ~3,700–3,900 failures per daily tenant sweep |
| 07-13 19:54 | Revert `db90d6ff1` pushed to `master` |
| 07-13 19:56 | Prod redeployed on upstream **v10.6.0 stable** + ŌMZIG overlay |

The PR-gate for non-stable channels (audit fix #1, `097af0eb8`) was added
two hours *after* the canary install, so it could not prevent it; it does
prevent a recurrence.

## ⚠️ Standing hazard: the reverted merge

`db90d6ff1` is a **merge revert**. The reverted upstream `dev` commits
(tip `8e421bfba`) remain *ancestors* of `master`. When upstream ships those
same commits in a future stable release, a plain merge will **silently skip
them** — git treats them as already applied and intentionally reverted. The
result would be a half-old tree that looks like a successful update.

**Required action before installing any upstream release that contains the
dev token-cache work:**

1. `git revert db90d6ff1` on `master` (revert of the revert), so the dev
   changes are re-applied.
2. Run the stable-channel install as normal.
3. Verify Graph tokens across tenants (watch the `Tenants` table
   `GraphErrorCount` / `LastGraphError` and `CippLogs` for `AADSTS700003`).

The `omzig-update-install` workflow enforces this: it refuses to merge an
upstream ref that contains `8e421bfba` while the revert is still in effect,
and points here instead of producing a silent half-merge.
