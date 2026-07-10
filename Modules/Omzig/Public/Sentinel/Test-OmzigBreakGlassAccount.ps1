function Test-OmzigBreakGlassAccount {
    <#
    .SYNOPSIS
    Decides whether a user principal is one of the tenant's break-glass
    accounts (§17 item 12).

    .DESCRIPTION
    Convention per the FamilyOffice-M365-Security-Handoff-Template:
    bg01@<initialDomain> and bg02@<initialDomain>, plus the Entra extension
    attribute omzig:breakglass=true. Either signal counts — naming drift on
    older tenants must not silence the sentinel.

    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UserPrincipalName,
        [string]$InitialDomain,
        $ExtensionAttributes
    )

    $Local = ($UserPrincipalName -split '@')[0].ToLower()
    $Domain = ($UserPrincipalName -split '@')[-1].ToLower()

    $NameMatch = $Local -in @('bg01', 'bg02') -and (
        [string]::IsNullOrEmpty($InitialDomain) -or $Domain -eq $InitialDomain.ToLower()
    )

    $AttributeMatch = $false
    if ($null -ne $ExtensionAttributes) {
        $AttributeMatch = @($ExtensionAttributes.PSObject.Properties |
                Where-Object { $_.Name -like '*breakglass*' -or $_.Value -eq 'omzig:breakglass=true' }).Count -gt 0 -or
            ($ExtensionAttributes -is [string] -and $ExtensionAttributes -match 'omzig:breakglass=true')
    }

    return ($NameMatch -or $AttributeMatch)
}
