# omzig-ops — operating the Omzig CIPP instance

Everything needed to keep <https://management.omzig.it> healthy. Start with the
runbook; the scripts do the work.

| File | What it is |
| --- | --- |
| [ONBOARDING.md](ONBOARDING.md) | **Start here if CIPP is new to you.** Nothing to competent in ~30 minutes. |
| [CIPP-Monthly-Maintenance-Runbook.md](CIPP-Monthly-Maintenance-Runbook.md) | The document. Architecture, access, monthly pass, failure modes, escalation. |
| [Invoke-CippHealthCheck.ps1](Invoke-CippHealthCheck.ps1) | 13 read-only checks. Exit `0` green, `1` warnings, `2` critical. Safe any time. |
| [Invoke-CippSecretRotation.ps1](Invoke-CippSecretRotation.ps1) | Fixes `AADSTS7000222`. Verifies the new secret before storing it. `-WhatIf` supported. |
| [skills/cipp-monthly-maintenance](skills/cipp-monthly-maintenance) | Claude Code skill — `/cipp-monthly-maintenance` drives the whole pass. |

## First run

```bash
git clone https://github.com/omzigfrank/CIPP-API.git
cd CIPP-API
az login
pwsh -File "./omzig-ops/Invoke-CippHealthCheck.ps1"
```

To get the Claude skill, copy `omzig-ops/skills/cipp-monthly-maintenance` into
`.claude/skills/` in whatever directory you work from, then type
`/cipp-monthly-maintenance`.

## Who can do what

Access is by Entra group — never assigned to individuals, so joining and leaving
the team is one membership change.

| Group | Members | Azure | Key Vault | Can rotate the SAM secret? |
| --- | --- | --- | --- | --- |
| `CIPP-Azure-Operators` | Courtney, Eric, Tony | Reader on RG `CIPP` | secret `get`, `list` | No |
| `CIPP-Azure-Admins` | Frank, Courtney | Contributor on RG `CIPP` | secret `get`, `list`, `set` | Yes |

Operators can run every check in the health script, including the live token
test. They cannot change or delete anything.

**Rotation no longer needs Global Administrator.** Frank and Courtney are
registered owners of the `CIPP-SAM` app registration, and an app owner can manage
its credentials with no directory role at all. That is deliberate: it removes the
temptation to use a Global Admin account for routine work.

## If both admins are unavailable

1. Any Global Administrator can add themselves to `CIPP-Azure-Admins` and to the
   `CIPP-SAM` owners list, then follow the runbook normally.
2. Azure resource access may additionally need the *Access management for Azure
   resources* toggle on the subscription (Entra → Properties), because the
   subscription has only one human Owner.
3. Do **not** delete or disable `CIPPServiceAccount@omzig.it`. It was created
   alongside `CIPP-SAM` and is very likely the account that minted the SAM
   refresh token — removing it would probably cut CIPP off from every customer
   tenant. See the runbook's security notes.

## House rules

- Rotate credentials **in Key Vault**, never in an app setting. Every credential
  app setting is a Key Vault reference; changing one breaks that.
- Never paste a secret into a file, a commit, a ticket or a chat. Both scripts are
  written to avoid ever printing one — keep it that way.
- Log every pass in Autotask: date, who, version before/after, findings fixed,
  findings deferred and why.
- Anything touching GDAP, tenant onboarding, standards, or a customer tenant is
  Frank's call, not an operator's.
