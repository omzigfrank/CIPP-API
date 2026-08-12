---
name: cipp
description: Operate Omzig's self-hosted CIPP at management.omzig.it — outage triage, the monthly maintenance pass, version checks against KelvinTegelaar upstream, SAM secret rotation, upstream-sync conflicts, and onboarding a new operator. Use when CIPP is down or erroring, when someone reports "Error Loading data", "Could not get token", "AADSTS7000222", "invalid_client", "AADSTS70008" or "invalid_grant" in CIPP, when asked to check CIPP health or version, rotate the CIPP-SAM secret, update CIPP, resolve a CIPP upstream sync conflict, run CIPP monthly maintenance, or bring a new person up to speed on CIPP.
---

# CIPP operations

CIPP is Omzig's control plane for every managed client tenant. When it is down, no
client tenant can be administered — so treat an outage as higher severity than the
instance's size suggests.

## First: work out which situation you are in

| Situation | Read this, then follow it | Notes |
| --- | --- | --- |
| **CIPP is down or erroring now** | `omzig-ops/OUTAGE.md` | A triage tree. Operators are pre-authorised for every step in it. |
| Monthly pass / drift check | `omzig-ops/CIPP-Monthly-Maintenance-Runbook.md` §4 | Start with the health check. |
| Someone is new to CIPP | `omzig-ops/ONBOARDING.md` | Four steps, ~30 min. |
| Upstream sync conflicted | Runbook §7 | Resolution policy by case. |
| Anything else | Runbook — it is the reference | If it is not covered, say so rather than improvising. |

**Do not answer from this file alone.** Read the relevant document before acting;
it carries the detail and it is kept current, whereas this file only routes.

## Preconditions — check before anything else

These scripts live in the CIPP-API repo and expect to run from a clone of it:

```bash
git rev-parse --show-toplevel   # must be a CIPP-API clone
ls omzig-ops/                   # must list OUTAGE.md, the runbook and both scripts
az account show                 # must be subscription 48019666-dd78-439e-9890-030ab5156f23
```

If `omzig-ops/` is not there, stop and say so — do not reconstruct the scripts from
memory or hunt for an older copy in OneDrive. Stale copies of the health check exist
in the wild and misreport permission errors as deleted resources.

## The health check is always the first move

```bash
pwsh -File "./omzig-ops/Invoke-CippHealthCheck.ps1"
```

Read-only, safe any time. Exit `0` green, `1` warnings, `2` critical. It names the
fault; the runbook section for that fault tells you what to do.

Two things about reading its output:

- **Its live token test is the leading indicator.** Historical auth errors in Log
  Analytics are lagging — the script already compares them against the last
  rotation time. Do not rotate a healthy secret because of yesterday's errors.
- **A green run is not automatically full coverage.** If it warns that credentials
  could not be read, SAM secret expiry was *not* checked. Say that plainly rather
  than reporting all-clear.

## Authority — what you may do without asking

Full table in runbook §3. In short:

**Pre-authorised, including during an outage — do it and log it:**
rotate the SAM client secret; start, restart or roll back an app; re-enable a
disabled Key Vault secret; set vault expiry metadata; merge an upstream sync PR
that merges cleanly and passes the QC workflow; enable HTTPS-only or raise a TLS
minimum.

**Needs a second operator (irreversible but mechanical):**
deleting an app-registration credential that is not in use; deleting a stale sync
branch; resolving a conflict in a file we patched where §7 gives a clear case.

**Owner decision — surface it, do not act:**
GDAP, tenant onboarding, standards, or anything inside a client tenant; Key Vault
purge protection; granting or widening access; directory roles on
`CIPPServiceAccount@omzig.it`; a conflict still unclassifiable after a second
operator has looked.

**Access boundary, not an approval:** the refresh-token fix needs a Global
Administrator. Courtney holds it. Route on capability, not on hierarchy.

## Hard rules

- **Rotate in Key Vault, never in an app setting.** All four credential settings are
  Key Vault references. Pasting a literal value appears to fix things and silently
  breaks every future rotation.
- **Never print, log, write or paste a secret value.** Both scripts are built to
  avoid it. Keep it that way — no exceptions for debugging.
- **Never delete or disable `CIPPServiceAccount@omzig.it`.** It very likely minted
  the SAM refresh token, which is bound to the authorising account; removing it
  would cut CIPP off from every client. Removing its *roles* is safe.
- **Verify, do not assume.** A restart is not proof. The token test is proof. After
  any auth fix, re-run the health check.
- **Prefer fixing the script over working around it.** If a check is wrong, that is
  a bug worth a commit, not something to note and move past.

## Closing out

- Log it in Autotask: date, who, version before/after, what was fixed, what was
  deferred and why.
- Append a row to the runbook change log (§11).
- **If you solved something the runbook does not cover, add it.** The point is that
  the next person does not have to escalate at all.
