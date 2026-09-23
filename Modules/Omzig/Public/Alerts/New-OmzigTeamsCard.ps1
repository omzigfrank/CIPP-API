function New-OmzigTeamsCard {
    <#
    .SYNOPSIS
    Builds a Teams message carrying an Adaptive Card, in the shape Teams Workflows
    webhooks accept.
    .DESCRIPTION
    Teams retired the Office 365 connector webhooks that took a bare { text = ... }
    body. A Workflows "post to a chat/channel when a webhook request is received"
    flow needs a message with an Adaptive Card attachment, which is what this returns.
    Pure function: no network, so it is unit-testable and safe to call anywhere.
    .PARAMETER Facts
    Ordered name/value pairs rendered as a FactSet. Values are converted to strings.
    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Title,
        [ValidateSet('P1', 'Critical', 'Warning', 'Good', 'Test', 'Info')]
        [string]$Severity = 'Info',
        [string]$Summary,
        [System.Collections.IDictionary]$Facts,
        [string]$LinkText,
        [string]$LinkUrl
    )

    # Adaptive Card text colours are semantic, so Teams themes them for light and dark.
    $Color = switch ($Severity) {
        { $_ -in 'P1', 'Critical' } { 'attention' }
        'Warning' { 'warning' }
        'Good' { 'good' }
        default { 'accent' }
    }

    $Body = [System.Collections.Generic.List[object]]::new()
    $Body.Add(@{
            type   = 'TextBlock'
            text   = $Title
            weight = 'bolder'
            size   = 'medium'
            color  = $Color
            wrap   = $true
        })
    if ($Summary) {
        $Body.Add(@{ type = 'TextBlock'; text = $Summary; wrap = $true })
    }
    if ($Facts -and $Facts.Count -gt 0) {
        $Body.Add(@{
                type  = 'FactSet'
                facts = @(foreach ($Key in $Facts.Keys) { @{ title = [string]$Key; value = [string]$Facts[$Key] } })
            })
    }

    $Card = [ordered]@{
        '$schema' = 'http://adaptivecards.io/schemas/adaptive-card.json'
        type      = 'AdaptiveCard'
        version   = '1.4'
        body      = @($Body)
        msteams   = @{ width = 'Full' }
    }
    if ($LinkUrl) {
        $Card.actions = @(@{ type = 'Action.OpenUrl'; title = $(if ($LinkText) { $LinkText } else { 'Open' }); url = $LinkUrl })
    }

    return @{
        type        = 'message'
        attachments = @(@{
                contentType = 'application/vnd.microsoft.card.adaptive'
                contentUrl  = $null
                content     = $Card
            })
    }
}
