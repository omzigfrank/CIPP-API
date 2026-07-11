function Test-OmzigUpdateAuthorized {
    <#
    .SYNOPSIS
    Is this caller allowed to trigger ŌMZIG update installs / schedule changes?

    .DESCRIPTION
    Authorization for the write actions of the Update Center is restricted to
    members of the configured Entra security group (Get-OmzigUpdaterGroup),
    resolved by transitive group membership against the CIPP home tenant —
    the same mechanism CIPP itself uses for group-based access
    (Test-CIPPAccessUserRole). This is enforced server-side and is independent
    of CIPP roles, so an editor/admin who is NOT in the group cannot install.

    Fails CLOSED: if no group is configured, or the membership lookup errors,
    or the principal has no resolvable UPN, the caller is NOT authorized.

    .PARAMETER UserPrincipalName
    The caller's UPN (from the decoded x-ms-client-principal). App-only
    principals (a GUID appId) will not resolve to a user group and are denied.

    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$UserPrincipalName
    )

    $Group = Get-OmzigUpdaterGroup
    if (-not $Group.Configured) {
        return [PSCustomObject]@{
            Authorized = $false
            GroupId    = $null
            Reason     = 'No updater group is configured. A superadmin must set the ŌMZIG updater group before updates can be triggered.'
        }
    }

    if ([string]::IsNullOrWhiteSpace($UserPrincipalName)) {
        return [PSCustomObject]@{
            Authorized = $false
            GroupId    = $Group.GroupId
            Reason     = 'Could not resolve the caller identity to check group membership.'
        }
    }

    try {
        $Uri = "https://graph.microsoft.com/beta/users/$UserPrincipalName/transitiveMemberOf?`$select=id"
        $Memberships = New-GraphGetRequest -uri $Uri -NoAuthCheck $true -AsApp $true |
            Where-Object { $_.'@odata.type' -eq '#microsoft.graph.group' }
        $IsMember = @($Memberships.id) -contains $Group.GroupId
    } catch {
        Write-Information "Test-OmzigUpdateAuthorized: membership lookup failed for $UserPrincipalName — $($_.Exception.Message)"
        return [PSCustomObject]@{
            Authorized = $false
            GroupId    = $Group.GroupId
            Reason     = 'Group membership could not be verified; access denied.'
        }
    }

    [PSCustomObject]@{
        Authorized = [bool]$IsMember
        GroupId    = $Group.GroupId
        Reason     = if ($IsMember) { 'Authorized: caller is a member of the updater group.' } else { 'Access denied: caller is not a member of the updater group.' }
    }
}
