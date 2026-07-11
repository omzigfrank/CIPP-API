function Invoke-ExecOmzigUpdates {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        CIPP.Core.ReadWrite
    .DESCRIPTION
        ŌMZIG Update Center actions. Access to the write actions is restricted
        to members of the configured Entra updater group (server-side,
        independent of CIPP roles — see Test-OmzigUpdateAuthorized); the coarse
        CIPP.Core.ReadWrite role is only a floor. Body.Action selects:
          SetUpdaterGroup — superadmin-only: designate the Entra security group
            whose members may trigger updates. Lockout-proof: a superadmin can
            always reconfigure the group even if not a member.
          SetSchedule — (updater group members) persist the auto-update
            schedule and mirror it to the fork repositories.
          InstallNow — (updater group members) dispatch the install workflow
            on both fork repositories for the requested channel.
        Both install/schedule paths require CIPP's GitHub integration; nothing
        here ever reads or returns the PAT itself.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = $Request.Params.CIPPEndpoint
    $Headers = $Request.Headers

    # Resolve the caller identity (UPN) and roles for authorization decisions.
    $CallerUpn = $null
    try {
        $CallerUpn = ([System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Headers.'x-ms-client-principal')) | ConvertFrom-Json).userDetails
    } catch {
        Write-Information "Invoke-ExecOmzigUpdates: could not decode client principal — $($_.Exception.Message)"
    }

    $AuthzDenied = $false
    try {
        $Action = $Request.Body.Action
        switch ($Action) {
            'SetUpdaterGroup' {
                # Bootstrap/config action — superadmin only, NOT group-gated, so
                # a superadmin can never lock themselves out of reconfiguring it.
                $Roles = Get-CIPPAccessRole -Request $Request
                if ($Roles -notcontains 'superadmin') {
                    $AuthzDenied = $true
                    throw 'Only a superadmin may change the ŌMZIG updater group.'
                }
                $GroupParams = @{ GroupId = [string]$Request.Body.groupId }
                if ($Request.Body.groupName) { $GroupParams.GroupName = [string]$Request.Body.groupName }
                $Result = Set-OmzigUpdaterGroup @GroupParams
                Write-LogMessage -headers $Headers -API $APIName -message "Omzig updater group set to '$($Result.GroupName)' ($($Result.GroupId)) by $CallerUpn" -Sev 'Alert'
            }
            'SetSchedule' {
                $Auth = Test-OmzigUpdateAuthorized -UserPrincipalName $CallerUpn
                if (-not $Auth.Authorized) { $AuthzDenied = $true; throw $Auth.Reason }
                $SetParams = @{
                    AutoUpdate = [bool]$Request.Body.autoUpdate
                    Channel    = [string]$Request.Body.channel
                    Mode       = [string]$Request.Body.mode
                }
                $Result = Set-OmzigUpdateSettings @SetParams
                Write-LogMessage -headers $Headers -API $APIName -message "Omzig update schedule set by ${CallerUpn}: AutoUpdate=$($SetParams.AutoUpdate), Channel=$($SetParams.Channel), Mode=$($SetParams.Mode), AppliedToGitHub=$($Result.AppliedToGitHub)" -Sev 'Info'
            }
            'InstallNow' {
                $Auth = Test-OmzigUpdateAuthorized -UserPrincipalName $CallerUpn
                if (-not $Auth.Authorized) { $AuthzDenied = $true; throw $Auth.Reason }
                $InstallParams = @{ Channel = [string]$Request.Body.channel }
                if ($Request.Body.mode) { $InstallParams.Mode = [string]$Request.Body.mode }
                $Result = Start-OmzigUpdateInstall @InstallParams
                Write-LogMessage -headers $Headers -API $APIName -message "Omzig update install dispatched by ${CallerUpn}: Channel=$($Result.Channel), Mode=$($Result.Mode)" -Sev 'Alert'
            }
            default {
                throw "Unknown Action '$Action'. Expected SetUpdaterGroup, SetSchedule or InstallNow."
            }
        }

        $StatusCode = [HttpStatusCode]::OK
        $Body = $Result
    } catch {
        $StatusCode = if ($AuthzDenied) { [HttpStatusCode]::Forbidden } else { [HttpStatusCode]::BadRequest }
        $Body = @{ Error = $_.Exception.Message }
    }

    return ([HttpResponseContext]@{
            StatusCode = $StatusCode
            Body       = $Body
        })
}
