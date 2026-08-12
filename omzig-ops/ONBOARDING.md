# You now help run CIPP

CIPP is the portal at <https://management.omzig.it>. It is how Omzig administers
every client's Microsoft 365 tenant. When CIPP is down, we cannot touch any client
tenant — so it matters more than its size suggests.

This page gets you from nothing to competent in about 30 minutes. Work through it
in order. You do not need to read the runbook first.

---

## Before you start

Ask Frank to confirm you are in one of these Entra groups. Nothing below works
without it.

| Group | What it lets you do |
| --- | --- |
| `CIPP-Azure-Operators` | Run every health check. Change nothing. |
| `CIPP-Azure-Admins` | The above, plus rotate the SAM secret during an outage. |

You also need Azure CLI, PowerShell 7, and git.

---

## 1. Get the tooling (5 min)

```bash
git clone https://github.com/omzigfrank/CIPP-API.git
cd CIPP-API
az login
az account set --subscription 48019666-dd78-439e-9890-030ab5156f23
```

Everything you need is in `omzig-ops/`.

## 2. Run the health check (5 min)

```bash
pwsh -File "./omzig-ops/Invoke-CippHealthCheck.ps1"
```

Read-only. Safe to run any time, as often as you like. It prints one table and
sets an exit code: `0` all green, `1` warnings, `2` something is critical.

**What normal looks like** — every row `OK` or `INFO`, ending in `All green.`
Versions should match between the two CIPP repos and upstream.

**If you see `Could not read ... token test skipped`**, you are not in the
operators group yet. Go back to *Before you start*.

## 3. Learn what a real failure looks like (10 min)

The failure that has actually taken CIPP down is an expired client secret. Every
page shows:

> Error Loading data: Could not get token: invalid_client:**AADSTS7000222**

It happened on 2026-07-22 and nobody noticed for three weeks. The fix is one
command, and only `CIPP-Azure-Admins` can run it:

```bash
pwsh -File "./omzig-ops/Invoke-CippSecretRotation.ps1" -WhatIf
```

**Run it with `-WhatIf` now.** It will show you exactly what it would do and
change nothing. Do this today, while it is calm — you do not want your first
attempt to be during an outage at 7am.

Drop `-WhatIf` only when CIPP is genuinely broken. The script proves the new
secret works *before* it stores it, so a failed rotation leaves you no worse off.

## 4. Know where the alarms go (5 min)

- **Monthly, automatically:** a workflow runs on the 1st and files a GitHub issue
  labelled `cipp-health` **only if something needs attention**. No issue means no
  findings. Watch that repo.
- **The gap you must know about:** the automated run cannot read app-registration
  credentials, so it does **not** check how long the SAM secret has left. It says
  so in its output rather than pretending. Catching an expiring secret is the job
  of the human monthly pass, which is why we still do one.

---

## The monthly pass

One person each month. 20 minutes if green, up to 90 if an upstream sync has
conflicted.

1. Run the health check.
2. Work the findings top-down, using the runbook section for each.
3. Log it in Autotask: date, who, version before/after, what you fixed, what you
   deferred and why.

The runbook is `omzig-ops/CIPP-Monthly-Maintenance-Runbook.md`. It is the
reference — architecture, every failure mode, escalation rules.

**You can also just ask Claude Code.** From the repo, copy
`omzig-ops/skills/cipp-monthly-maintenance` into `.claude/skills/`, then type
`/cipp-monthly-maintenance` and it will drive the pass with you, including the
judgement calls.

---

## Three things never to do

1. **Never change a credential in an app setting.** Every credential setting is a
   Key Vault reference. Change the vault; a restart picks it up. Pasting a literal
   value silently breaks all future rotation.
2. **Never delete an app-registration credential without Frank's sign-off.** Each
   one is a fully privileged credential for every client tenant, and deletion is
   irreversible.
3. **Never delete or disable `CIPPServiceAccount@omzig.it`.** It probably minted
   CIPP's refresh token, which is bound to the account that authorised it.
   Removing it would likely cut CIPP off from every client.

## Escalate to Frank, do not improvise

- The refresh token has expired (needs an interactive wizard, not a script)
- An upstream sync conflict you cannot confidently classify
- Anything touching GDAP, tenant onboarding, CIPP standards, or a client tenant
- Anything the runbook does not cover

## If Frank is unavailable

Courtney is in `CIPP-Azure-Admins` and is a `CIPP-SAM` owner, so she can rotate
the secret without any directory role. If neither is reachable, any Global
Administrator can add themselves to `CIPP-Azure-Admins` and to the `CIPP-SAM`
owners list, then follow the runbook. Full break-glass steps are in the runbook.

---

*Written 2026-08-12, after an expired secret took CIPP down for three weeks
unnoticed. Everything here exists so that cannot happen quietly again.*
