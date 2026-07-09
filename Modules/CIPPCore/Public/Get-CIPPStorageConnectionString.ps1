function Get-CIPPStorageConnectionString {
    <#
    .FUNCTIONALITY
    Internal
    #>
    if ($env:CIPP_STORAGE_CONNECTION_STRING) {
        return $env:CIPP_STORAGE_CONNECTION_STRING
    }

    return $env:AzureWebJobsStorage
}
