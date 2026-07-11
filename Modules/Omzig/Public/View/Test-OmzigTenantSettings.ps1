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

    # Audit #13: baa must be a real boolean — it drives the HIPAA/BAA posture
    # (§17 item 11 defaults it on). Reject a non-boolean so a malformed payload
    # can't quietly coerce it off.
    if (& $HasProperty $Settings 'baa') {
        $Baa = & $GetValue $Settings 'baa'
        if ($null -ne $Baa -and $Baa -isnot [bool]) {
            $Errors.Add('baa must be a boolean (true/false).')
        }
    }

    # Audit #13: psa.companyId / rmm.siteId are concatenated into outbound
    # Autotask/Datto API paths downstream, so constrain their shape here —
    # Autotask company ids are integers, Datto site UIDs are GUIDs. This blocks
    # path/parameter injection (e.g. extra query params, path traversal) before
    # the value is ever stored.
    if (& $HasProperty $Settings 'psa') {
        $Psa = & $GetValue $Settings 'psa'
        if ($null -ne $Psa -and (& $HasProperty $Psa 'companyId')) {
            $CompanyId = & $GetValue $Psa 'companyId'
            if (![string]::IsNullOrEmpty([string]$CompanyId) -and [string]$CompanyId -notmatch '^\d{1,19}$') {
                $Errors.Add('psa.companyId must be a numeric Autotask company id.')
            }
        }
    }
    if (& $HasProperty $Settings 'rmm') {
        $Rmm = & $GetValue $Settings 'rmm'
        if ($null -ne $Rmm -and (& $HasProperty $Rmm 'siteId')) {
            $SiteId = & $GetValue $Rmm 'siteId'
            if (![string]::IsNullOrEmpty([string]$SiteId) -and [string]$SiteId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
                $Errors.Add('rmm.siteId must be a Datto site UID (GUID).')
            }
        }
    }

    [PSCustomObject]@{
        IsValid = ($Errors.Count -eq 0)
        Errors  = @($Errors)
    }
}
