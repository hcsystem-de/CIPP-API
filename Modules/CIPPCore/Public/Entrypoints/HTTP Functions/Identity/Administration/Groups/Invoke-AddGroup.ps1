using namespace System.Net

Function Invoke-AddGroup {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        Identity.Group.ReadWrite
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = $TriggerMetadata.FunctionName
    Write-LogMessage -user $request.headers.'x-ms-client-principal' -API $APINAME -message 'Accessed this API' -Sev 'Debug'

    $groupobj = $Request.body
    $SelectedTenants = $request.body.tenantfilter.value ? $request.body.tenantfilter.value : $request.body.tenantfilter
    if ('AllTenants' -in $SelectedTenants) { $SelectedTenants = (Get-Tenants).defaultDomainName }

    # Write to the Azure Functions log stream.
    Write-Host 'PowerShell HTTP trigger function processed a request.'
    $results = foreach ($tenant in $SelectedTenants) {
        try {
            $email = if ($groupobj.primDomain.value) { "$($groupobj.username)@$($groupobj.primDomain.value)" } else { "$($groupobj.username)@$($tenant)" }
            if ($groupobj.groupType -in 'Generic', 'azurerole', 'dynamic', 'm365') {

                $BodyToship = [pscustomobject] @{
                    'displayName'      = $groupobj.Displayname
                    'description'      = $groupobj.Description
                    'mailNickname'     = $groupobj.username
                    mailEnabled        = [bool]$false
                    securityEnabled    = [bool]$true
                    isAssignableToRole = [bool]($groupobj | Where-Object -Property groupType -EQ 'AzureRole')
                }
                if ($groupobj.membershipRules) {
                    $BodyToship | Add-Member -NotePropertyName 'membershipRule' -NotePropertyValue ($groupobj.membershipRules)
                    $BodyToship | Add-Member -NotePropertyName 'groupTypes' -NotePropertyValue @('DynamicMembership')
                    $BodyToship | Add-Member -NotePropertyName 'membershipRuleProcessingState' -NotePropertyValue 'On'
                }
                if ($groupobj.groupType -eq 'm365') {
                    $BodyToship | Add-Member -NotePropertyName 'groupTypes' -NotePropertyValue @('Unified')
                }
                if ($groupobj.owners -AND $groupobj.groupType -in 'generic', 'azurerole', 'security') {
                    $BodyToship | Add-Member -NotePropertyName 'owners@odata.bind' -NotePropertyValue (($groupobj.AddOwner) | ForEach-Object { "https://graph.microsoft.com/v1.0/users/$($_.value)" })
                    $bodytoship.'owners@odata.bind' = @($bodytoship.'owners@odata.bind')
                }
                if ($groupobj.members -AND $groupobj.groupType -in 'generic', 'azurerole', 'security') {
                    $BodyToship | Add-Member -NotePropertyName 'members@odata.bind' -NotePropertyValue (($groupobj.AddMember) | ForEach-Object { "https://graph.microsoft.com/v1.0/users/$($_.value)" })
                    $BodyToship.'members@odata.bind' = @($BodyToship.'members@odata.bind')
                }
                $GraphRequest = New-GraphPostRequest -uri 'https://graph.microsoft.com/beta/groups' -tenantid $tenant -type POST -body (ConvertTo-Json -InputObject $BodyToship -Depth 10) -verbose
            } else {
                if ($groupobj.groupType -eq 'dynamicdistribution') {
                    $Params = @{
                        Name               = $groupobj.Displayname
                        RecipientFilter    = $groupobj.membershipRules
                        PrimarySmtpAddress = $email
                    }
                    $GraphRequest = New-ExoRequest -tenantid $tenant -cmdlet 'New-DynamicDistributionGroup' -cmdParams $params
                } else {
                    $Params = @{
                        Name                               = $groupobj.Displayname
                        Alias                              = $groupobj.username
                        Description                        = $groupobj.Description
                        PrimarySmtpAddress                 = $email
                        Type                               = $groupobj.groupType
                        RequireSenderAuthenticationEnabled = [bool]!$groupobj.AllowExternal
                    }
                    $GraphRequest = New-ExoRequest -tenantid $tenant -cmdlet 'New-DistributionGroup' -cmdParams $params
                }
                #$GraphRequest = New-ExoRequest -tenantid $tenant -cmdlet 'New-DistributionGroup' -cmdParams $params
                # At some point add logic to use AddOwner/AddMember for New-DistributionGroup, but idk how we're going to brr that - rvdwegen
            }
            "Successfully created group $($groupobj.displayname) for $($tenant)"
            Write-LogMessage -user $request.headers.'x-ms-client-principal' -API $APINAME -tenant $tenant -message "Created group $($groupobj.displayname) with id $($GraphRequest.id)" -Sev 'Info'

        } catch {
            Write-LogMessage -user $request.headers.'x-ms-client-principal' -API $APINAME -tenant $tenant -message "Group creation API failed. $($_.Exception.Message)" -Sev 'Error'
            "Failed to create group. $($groupobj.displayname) for $($tenant) $($_.Exception.Message)"
        }
    }
    $body = [pscustomobject]@{'Results' = @($results) }

    # Associate values to output bindings by calling 'Push-OutputBinding'.
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::OK
            Body       = $Body
        })

}
