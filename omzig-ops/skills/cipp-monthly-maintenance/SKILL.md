---
name: cipp-monthly-maintenance
description: Run monthly maintenance on the Omzig self-hosted CIPP instance (management.omzig.it) — health check, version verification against KelvinTegelaar upstream, SAM secret rotation, and upstream-sync conflict triage. Use when someone asks to check CIPP health, verify the CIPP version, fix a CIPP login/token error, rotate the CIPP-SAM secret, resolve "AADSTS7000222", "invalid_client", "Could not get token", or "Error Loading data" in CIPP, update CIPP, or run CIPP monthly maintenance.
---

# CIPP Monthly Maintenance

You are maintaining Omzig's self-hosted CIPP at **https://management.omzig.it**. It is the
control plane for every managed customer tenant. A mistake here affects all clients at once,
so this skill is deliberately conservative about what you may change without asking.

Read `omzig-ops/CIPP-Monthly-Maintenance-Runbook.md` (relative to the Dev working directory)
before acting. It holds the architecture, the current known issues, and the fix procedures.
This file tells you how to *drive* that runbook; the runbook is the source of truth for the
details, and you keep it current.

## Instance facts

| Thing | Value |
| --- | --- |
| Subscription | `48019666-dd78-439e-9890-030ab5156f23` |
| Resource group | `CIPP` (eastus2) |
| API / processor apps | `cippwemix` / `cippwemix-proc` |
| Key Vault | `cippwemix` — **single source of truth for all credentials** |
| SAM app registration | `a60c5cc5-707b-4152-8881-b60e25cf1a34` (CIPP-SAM) |
| Forks | `omzigfrank/CIPP-API` (master), `omzigfrank/CIPP` (main) |
| Upstream | `KelvinTegelaar/CIPP-API` (master), `KelvinTegelaar/CIPP` (main) |

Every CIPP credential app setting is a Key Vault *reference*. **Rotate in the vault, never
in an app setting.** A restart makes the app pick up the new version.

## Procedure

### 1. Health check first, always

```bash
pwsh -File "./omzig-ops/Invoke-CippHealthCheck.ps1"
```

Read-only. Exit `0` green, `1` warnings, `2` critical. If it cannot run (`az login` missing,
no Key Vault access), fix access before anything else — do not work around it by guessing.

### 2. Report before you fix

Show the user the findings table and say plainly what is broken, what is merely aging, and
what you intend to do. Do not bury a critical finding under a wall of OK rows.

### 3. Apply fixes, in this order

Work criticals before warnings. Consult the runbook section for each finding.

**You may do these without asking:**

- Run the health check
- Rotate the SAM client secret — `pwsh -File "./omzig-ops/Invoke-CippSecretRotation.ps1"`
- Restart `cippwemix` / `cippwemix-proc`
- Set `httpsOnly=true`, raise min TLS
- Add expiry metadata to a Key Vault secret
- Clone the forks and test-merge locally to enumerate sync conflicts
- Read logs, versions, deployment history

**Get explicit approval from Frank first:**

- Deleting any app-registration credential (irreversible, values unrecoverable)
- Merging a sync PR or pushing to either fork — this deploys to production
- Enabling Key Vault purge protection (irreversible)
- Anything touching GDAP, tenant onboarding, or CIPP standards
- Anything that reaches into a customer tenant

**Escalate to Frank without acting:**

- The SAM refresh token has expired — needs an interactive wizard run, not a script
- A merge conflict you cannot confidently classify
- Any finding the runbook does not cover

### 4. Version verification

Versions live in the repos, not Azure: `version_latest.txt` (backend) and
`public/version.json` (frontend). The health check compares fork against upstream. When
behind, the cause is nearly always a conflicted `pull[bot]` sync PR — enumerate the
conflicts locally (runbook §6), classify each against the resolution policy, and present
Frank a plan. **Never merge without approval.** Upgrade backend and frontend together.

### 5. Close out

- Summarize: version before/after, findings fixed, findings deferred and why.
- Append a row to the runbook change log (§9) — date, who, what.
- If you learned something durable about this instance, update the runbook itself.

## Rules

- **Never print, log, or write a secret value.** Both scripts are built to avoid it; keep it
  that way. Never paste a credential into a chat message or a file.
- **Verify, do not assume.** A green restart is not proof. The token test in the health
  check is the proof. After any auth fix, re-run the health check.
- **Distinguish leading from lagging indicators.** Historical auth errors in Log Analytics
  are not evidence of a current outage — the health check already compares them against the
  last rotation time. Do not rotate a healthy secret because of yesterday's errors.
- **The vault is the source of truth.** If you find a literal credential in an app setting,
  that is a finding to report, not something to work around.
- Prefer the scripts over ad-hoc `az` commands. If a script is wrong, fix the script — that
  is how the next person benefits.
