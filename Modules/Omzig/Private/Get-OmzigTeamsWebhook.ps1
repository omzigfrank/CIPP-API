function Get-OmzigTeamsWebhook {
    <#
    .SYNOPSIS
    Returns the Teams Workflows webhook URL for Omzig alerts, or $null when none is set.
    .DESCRIPTION
    Resolution order: the OMZIG_TEAMS_WEBHOOK app setting (normally a Key Vault
    reference), then the Key Vault secret 'teams-alert-webhook' read at call time.
    The URL is a credential: anyone holding it can post to the chat. It is never
    logged or returned in any result object.
    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding()]
    param(
        [string]$SecretName = 'teams-alert-webhook'
    )
    if ($env:OMZIG_TEAMS_WEBHOOK -and $env:OMZIG_TEAMS_WEBHOOK -notlike '@Microsoft.KeyVault*') {
        return $env:OMZIG_TEAMS_WEBHOOK
    }
    try {
        $Value = Get-CippKeyVaultSecret -Name $SecretName -AsPlainText -ErrorAction Stop
        if ($Value -and $Value -like 'https://*') { return $Value }
    } catch {
        Write-Verbose "Teams webhook secret '$SecretName' not readable: $($_.Exception.Message)"
    }
    return $null
}
