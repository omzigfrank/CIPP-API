function Get-CIPPKeyVaultName {
    <#
    .FUNCTIONALITY
    Internal
    #>
    if ($env:KEYVAULT_NAME) {
        return $env:KEYVAULT_NAME
    }

    if ($env:WEBSITE_DEPLOYMENT_ID) {
        return ($env:WEBSITE_DEPLOYMENT_ID -split '-')[0]
    }

    return $null
}
