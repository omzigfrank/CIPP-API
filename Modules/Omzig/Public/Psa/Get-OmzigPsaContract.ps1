function Get-OmzigPsaContract {
    <#
    .SYNOPSIS
    The IPsaClient contract (§7.14) — the operation set every PSA adapter must
    implement so switching PSA_PROVIDER=autotask|halo is a config change, not
    a rewrite.

    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding()]
    param()

    @(
        'GetCompanies'
        'GetCompany'
        'GetContacts'
        'NewContact'
        'GetTickets'
        'GetTicket'
        'NewTicket'
        'UpdateTicket'
        'GetContracts'
        'NewTimeEntry'
        'GetResources'
        'GetConfigurationItems'
    )
}
