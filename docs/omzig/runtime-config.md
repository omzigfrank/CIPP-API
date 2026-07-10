# Isolated runtime configuration

The Omzig dev/stage/prod stacks (`func-omzig-cipp-dev`, etc.) diverge from upstream
CIPP's naming convention. Upstream assumes the Key Vault name is the first
hyphen-segment of `WEBSITE_DEPLOYMENT_ID` and that platform storage is provisioned
as a classic `AzureWebJobsStorage` connection string. Omzig uses identity-based
storage credentials and custom vault naming, so two environment variables bridge
this gap.

## Environment variables

**`KEYVAULT_NAME`** — Explicit Key Vault name. Read by `Get-CIPPKeyVaultName` and
used by auth/secret-CRUD functions. Falls back to upstream's `WEBSITE_DEPLOYMENT_ID`
derivation when unset; upstream and production deployments are unaffected.

**`CIPP_STORAGE_CONNECTION_STRING`** — Data-plane storage connection string for
the Omzig tenants table, audit container, and Cosmos seed. Left unset = upstream
behavior (identity-based storage without a pre-shared connection string). When set,
`profile.ps1` assigns it to `AzureWebJobsStorage` at worker startup so CIPP's
existing data-plane code reads it unchanged.

## Secret delivery and rotation

`CIPP_STORAGE_CONNECTION_STRING` is delivered as a Key Vault **reference** app
setting (`@Microsoft.KeyVault(SecretUri=...CippStorageConnectionString/)`), not
a plaintext value. The reference is versionless, so Key Vault secret rotation
propagates to the Function App automatically without redeployment. The raw
connection string never sits in plaintext site config.

The Bicep (CIPP repo, `deployment/omzig`) creates the `CippStorageConnectionString`
secret in Key Vault and wires the reference in the Function App config.

## Content share persistence

`WEBSITE_CONTENTAZUREFILECONNECTIONSTRING` remains a plain connection string because
Azure App Service requires it for the content share and does not support Key Vault
references. Rotating storage account keys requires:

1. Update the Key Vault secret (automatic on Bicep redeploy).
2. Manually update `WEBSITE_CONTENTAZUREFILECONNECTIONSTRING` in portal or Bicep
   (`siteConfig` section) to propagate the new key to the content share.
