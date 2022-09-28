<#
    Runbook: Export-UsageReport
    Creator: Ruben Fratty
    
    Comments: Get all the usage details of a specific day (by default one day ago) and 
    upload the results to a storage account.
#>

Function Get-HeaderAccessToken {
    $azContext = Get-AzContext
    $azProfile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile
    $profileClient = New-Object -TypeName Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient -ArgumentList ($azProfile)
    $token = $profileClient.AcquireAccessToken($azContext.Tenant.Id)
    return @{
        'Content-Type'  = 'application/json'
        'Authorization' = 'Bearer ' + $token.AccessToken
    }
}

Function Invoke-Get ($url, $headers) {
    try {
        $response = Invoke-RestMethod `
            -Method Get `
            -Uri $url `
            -Headers $headers
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__

        if ( $statusCode -ne 429 ) {
            Write-Error "StatusCode:" $statusCode 
            Write-Error "StatusDescription:" $_.Exception.Response.ReasonPhrase
            return $usage
        }

        do {
            # Spleep 30 seconds
            Write-Warning "Sleeping 30 seconds..."
            Start-Sleep -Seconds 30

            try {
                $response = Invoke-RestMethod `
                    -Method Get `
                    -Uri $url `
                    -Headers $headers
                $statusCode = 200
            }
            catch {
                $statusCode = $_.Exception.Response.StatusCode.value__
            }
        }
        while ( $statusCode -eq 429 )
    }
    return $response
}

# Function Get-Usage ($date) {
#     $usages = @()
#     $subs = Get-AzSubscription | ? {$_.State -eq "Enabled" -and $_.Name -ne "Azure Pass - Sponsorship"} | Sort Name
    
#     foreach ($sub in $subs) {
#         Set-AzContext -SubscriptionId $sub.Id | Out-Null
#         $usage = Get-AzConsumptionUsageDetail `
#             -StartDate $date `
#             -EndDate $date `
#             -IncludeMeterDetails `
#             -IncludeAdditionalProperties
        
#         $usages += $usage
#         Write-Verbose "$($sub.Name) ($($sub.Id)) -> Found $($usage.count)" -Verbose
#     }
#     return $usages
# }

Function Get-Usage ($date) {
    $scope = "providers/Microsoft.Management/managementGroups/yatzma-root-mg"
    $headers = Get-HeaderAccessToken
    $apiversion = "2021-10-01";
    $filter = "properties/usageStart eq '$($date)' and properties/usageEnd eq '$($date)'"
    $url = "https://management.azure.com/$scope/providers/Microsoft.Consumption/usageDetails?api-version=$($apiversion)&`$filter=$filter"
    $usage = @()

    $response = Invoke-Get $url $headers
    $usage += $response.value
    Write-Warning "Found $($usage.Count) events"

    while ( $response.nextLink ) {
        $nextLink = $response.nextLink
        $response = Invoke-Get $nextLink $headers
        $usage += $response.value
        Write-Warning "Found $($usage.Count) events"
        
    }
    return $usage
}

# Function Main {
#     $yesterday = Get-Date (Get-Date).AddDays(-3) -Format "yyyy-MM-dd"
#     $usage = Get-Usage -date $yesterday
#     Write-Output $usage.Count
# }

Function Main {
    $yesterday = Get-Date (Get-Date).AddDays(-1) -Format "yyyy-MM-dd"
    $tempdir = "c:\temp\"
    $filename = "click-usage-$($yesterday).json"
    $storageAccountSubId = "69d34344-d7b7-4dc2-aefa-fda3c77fb570"
    $storageAccountRG = "Finops-resources-RG"
    $storageAccountName = "finopsresourcesstorage"
    $containerName = "click-daily-consumption-usage"

    # Connect To Azure
    Connect-AzAccount `
        -Identity `
        -AccountId (Get-AutomationVariable -Name "BudgetsMI") `
        -Subscription $storageAccountSubId

    #azure automation temp folder
    Write-Output "Starting getting Usage..."
    $localfile = $tempdir + $filename
    $usages = Get-Usage -date $yesterday
    Write-Output "Finished! Found in total $($usages.Count) events." -Verbose
    
    # Output the results to the local file
    $usages | ConvertTo-Json | Out-File $localfile

    # Set Context
    Set-AzContext -SubscriptionId $storageAccountSubId | Out-Null

    # Get Storage Account
    $StorageAccount = Get-AzStorageAccount `
        -ResourceGroupName $storageAccountRG `
        -Name $storageAccountName
    $Context = $StorageAccount.Context

    # upload a file to the default account (inferred) access tier
    $Blob = @{
        File             = $localfile
        Container        = $ContainerName
        Blob             = $filename
        Context          = $Context
        StandardBlobTier = 'Hot'
    }
    Write-Output "Uploading $filename to $ContainerName" -Verbose
    Set-AzStorageBlobContent @Blob
}

Main
