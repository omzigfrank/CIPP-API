function Get-OmzigPsaClient {
    <#
    .SYNOPSIS
    PSA adapter factory (§7.14). Autotask is the production adapter; HaloPSA
    ships as a contract-compliant stub so a future migration is
    PSA_PROVIDER=halo plus the data-mapping wizard — no code changes.

    .DESCRIPTION
    Returns a client object whose members match Get-OmzigPsaContract exactly.
    Each member is a scriptblock; callers use:

        $Psa = Get-OmzigPsaClient
        & $Psa.NewTicket -CompanyId 123 -Title 'Break-glass sign-in detected' -Priority 'P1'

    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('autotask', 'halo')]
        [string]$Provider = (Get-OmzigConfig).PsaProvider
    )

    switch ($Provider) {
        'autotask' {
            $Client = [PSCustomObject]@{
                Provider              = 'autotask'
                GetCompanies          = { param($Filter) Invoke-OmzigAutotaskRequest -Method POST -Endpoint 'Companies/query' -Body @{ filter = @(if ($Filter) { $Filter } else { @{ op = 'gte'; field = 'id'; value = 0 } }) } }
                GetCompany            = { param($CompanyId) Invoke-OmzigAutotaskRequest -Endpoint "Companies/$CompanyId" }
                GetContacts           = { param($CompanyId) Invoke-OmzigAutotaskRequest -Method POST -Endpoint 'Contacts/query' -Body @{ filter = @(@{ op = 'eq'; field = 'companyID'; value = $CompanyId }) } }
                NewContact            = { param($Contact) Invoke-OmzigAutotaskRequest -Method POST -Endpoint 'Contacts' -Body $Contact }
                GetTickets            = { param($CompanyId) Invoke-OmzigAutotaskRequest -Method POST -Endpoint 'Tickets/query' -Body @{ filter = @(@{ op = 'eq'; field = 'companyID'; value = $CompanyId }) } }
                GetTicket             = { param($TicketId) Invoke-OmzigAutotaskRequest -Endpoint "Tickets/$TicketId" }
                NewTicket             = { param($Ticket) Invoke-OmzigAutotaskRequest -Method POST -Endpoint 'Tickets' -Body $Ticket }
                UpdateTicket          = { param($TicketId, $Patch) Invoke-OmzigAutotaskRequest -Method PATCH -Endpoint 'Tickets' -Body (@{ id = $TicketId } + $Patch) }
                GetContracts          = { param($CompanyId) Invoke-OmzigAutotaskRequest -Method POST -Endpoint 'Contracts/query' -Body @{ filter = @(@{ op = 'eq'; field = 'companyID'; value = $CompanyId }) } }
                NewTimeEntry          = { param($TimeEntry) Invoke-OmzigAutotaskRequest -Method POST -Endpoint 'TimeEntries' -Body $TimeEntry }
                GetResources          = { Invoke-OmzigAutotaskRequest -Method POST -Endpoint 'Resources/query' -Body @{ filter = @(@{ op = 'eq'; field = 'isActive'; value = $true }) } }
                GetConfigurationItems = { param($CompanyId) Invoke-OmzigAutotaskRequest -Method POST -Endpoint 'ConfigurationItems/query' -Body @{ filter = @(@{ op = 'eq'; field = 'companyID'; value = $CompanyId }) } }
            }
        }
        'halo' {
            # §7.14: contract-compliant stub. Signatures are final; bodies are
            # wired against a Halo sandbox before this adapter is promoted.
            $NotWired = {
                throw [System.NotImplementedException]::new(
                    'HaloPSA adapter is a shipped stub (spec §7.14). Set PSA_PROVIDER=autotask, or complete the Halo sandbox wiring in Modules/Omzig/Public/Psa before switching.')
            }
            $Client = [PSCustomObject]@{
                Provider              = 'halo'
                GetCompanies          = $NotWired
                GetCompany            = $NotWired
                GetContacts           = $NotWired
                NewContact            = $NotWired
                GetTickets            = $NotWired
                GetTicket             = $NotWired
                NewTicket             = $NotWired
                UpdateTicket          = $NotWired
                GetContracts          = $NotWired
                NewTimeEntry          = $NotWired
                GetResources          = $NotWired
                GetConfigurationItems = $NotWired
            }
        }
    }

    # Contract enforcement: an adapter missing an operation is a build bug.
    $Missing = Get-OmzigPsaContract | Where-Object { $_ -notin $Client.PSObject.Properties.Name }
    if ($Missing) {
        throw "PSA adapter '$Provider' violates IPsaClient contract — missing: $($Missing -join ', ')"
    }
    return $Client
}
