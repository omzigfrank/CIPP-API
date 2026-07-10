function Find-OmzigAutotaskIntegrationUser {
    <#
    .SYNOPSIS
    Probes Autotask for an existing Omzig integration API user (§17 item 3).

    .DESCRIPTION
    Per the confirmed configuration, the build must FIRST look for an existing
    API user (Security Level "API User (system)" whose Integration Vendor is
    tagged Omzig*) and reuse it. Only if none exists is a new dedicated user
    (omzig-portal@omzig.it, Integration Vendor "Omzig Portal") provisioned —
    that provisioning is a manual Admin step in Autotask; this function tells
    the operator which path applies.

    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding()]
    param()

    # licenseType 3 = API User in Autotask resource records.
    $Response = Invoke-OmzigAutotaskRequest -Method POST -Endpoint 'Resources/query' -Body @{
        filter = @(
            @{ op = 'eq'; field = 'licenseType'; value = 3 }
            @{ op = 'eq'; field = 'isActive'; value = $true }
        )
    }

    $Candidates = @($Response.items | Where-Object {
            $_.userName -like '*omzig*' -or $_.email -like '*omzig*' -or $_.firstName -eq 'Omzig'
        })

    [PSCustomObject]@{
        Found          = ($Candidates.Count -gt 0)
        Candidates     = $Candidates
        Recommendation = if ($Candidates.Count -gt 0) {
            "Reuse existing integration user '$($Candidates[0].userName)'. Store its secret in Key Vault as AUTOTASK_SECRET."
        } else {
            'No Omzig integration user found. Provision omzig-portal@omzig.it (Security Level: API User (system), Integration Vendor: Omzig Portal) per Appendix A, then store credentials in Key Vault.'
        }
    }
}
