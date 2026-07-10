function Test-OmzigTenantSettings {
    <#
    .SYNOPSIS
    Validates an Omzig tenant settings payload (§7.1 single-pane tenant view
    settings drawer) before it reaches Set-OmzigTenantRecord.

    .DESCRIPTION
    Factored out of the Invoke-ExecOmzigTenantSettings HTTP entrypoint so the
    validation rules are unit-testable without a $Request/$TriggerMetadata
    stand-in. Only omzigTier and vertical carry a closed value set (§14) —
    baa, psa and rmm are structural fields Set-OmzigTenantRecord merges as-is.

    .PARAMETER Settings
    Hashtable or PSCustomObject with any subset of: omzigTier, vertical, baa,
    psa, rmm. Fields not present are not validated (partial updates are
    allowed); a present omzigTier/vertical must be $null or a member of the
    allowed set.

    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Settings
    )

    $ValidTiers = @('core', 'edge', 'summit', 'pinnacle', 'core-plus', 'edge-plus', 'premium-plus')
    $ValidVerticals = @('healthcare', 'legal', 'wealth', 'cpa', 'title', 'hospitality', 'family-office', 'other')

    $HasProperty = {
        param($Obj, $Name)
        if ($Obj -is [hashtable]) { return $Obj.ContainsKey($Name) }
        return @($Obj.PSObject.Properties.Name) -contains $Name
    }
    $GetValue = {
        param($Obj, $Name)
        if ($Obj -is [hashtable]) { return $Obj[$Name] }
        return $Obj.$Name
    }

    $Errors = [System.Collections.Generic.List[string]]::new()

    if (& $HasProperty $Settings 'omzigTier') {
        $Tier = & $GetValue $Settings 'omzigTier'
        if ($null -ne $Tier -and $Tier -notin $ValidTiers) {
            $Errors.Add("omzigTier '$Tier' is invalid. Allowed: $($ValidTiers -join ', '), or null.")
        }
    }

    if (& $HasProperty $Settings 'vertical') {
        $Vertical = & $GetValue $Settings 'vertical'
        if ($null -ne $Vertical -and $Vertical -notin $ValidVerticals) {
            $Errors.Add("vertical '$Vertical' is invalid. Allowed: $($ValidVerticals -join ', ').")
        }
    }

    [PSCustomObject]@{
        IsValid = ($Errors.Count -eq 0)
        Errors  = @($Errors)
    }
}
