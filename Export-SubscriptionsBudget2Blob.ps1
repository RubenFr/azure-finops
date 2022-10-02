<#
    Runbook: Export-SubscriptionsBudget2Blob.ps1
    Creator: RubenFr
    
    Comments:
    Get all the budgets and current spend of a subscription/mg and upload the results to a storage account.
#>

Import-Module Az.Accounts
Import-Module Az.Storage
$WarningPreference = 'Ignore'


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


Function Invoke-GetRequest ($url) {
    $headers = Get-HeaderAccessToken
    try {
        $response = Invoke-RestMethod `
            -Method Get `
            -Uri $url `
            -Headers $headers
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__

        if ( $statusCode -ne 429 ) {
            Write-Warning "Error during request: $url"
            Write-Warning "StatusDescription: $($_.Exception.Response.ReasonPhrase)"
            return $null
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


Function Get-Budgets ( $scope ) {
    $apiversion = "2021-10-01"
    $url = "https://management.azure.com/$scope/providers/Microsoft.Consumption/budgets?api-version=$($apiversion)"
    $budgets = @()

    $response = Invoke-GetRequest $url
    $budgets += $response.value
    # Write-Warning "Found $($budgets.Count) events"

    while ( $response.nextLink ) {
        $nextLink = $response.nextLink
        $response = Invoke-Get $nextLink $headers
        $budgets += $response.value
        # Write-Warning "Found $($budgets.Count) events"
        
    }
    return $budgets
}


########################################
########## MAIN ########################
########################################
  
$date = Get-Date -Format "yyyy-MM-dd"
$tempdir = "c:\temp\"
$storageAccountSubId = "SUBSCRIPTION ID OF THE STORAGE ACCOUNT"
$storageAccountRG = "RESOURCE GROUP OF THE STORAGE ACCOUNT"
$storageAccountName = "NAME OF THE STORAGE ACCOUNT"
$containerName = "CONTAINER NAME OF THE STORAGE ACCOUNT"

# Connect To Azure (managed Identity)
Connect-AzAccount `
    -Identity `
    -AccountId "CLIENT ID OF USER MANAGED IDENTITY" `
    -Subscription $storageAccountSubId
| Out-Null

# Subscriptions' Budgets
Write-Output "Starting getting Subscription's Budgets..."
$sub_budgets = @()
Get-AzSubscription | ? { $_.State -eq 'Enabled' -and $_.Name -ne "Azure Pass - Sponsorship" } | 
% {
    $sub_budgets += Get-Budgets -scope "subscriptions/$($_.Id)"
}
Write-Output "Finished! Found in total $($sub_budgets.Count) budgets.`n"

# Output the results to the local file
$filename = "budgets-$($date).json"
$localfile = $tempdir + $filename
$sub_budgets | ConvertTo-Json -Depth 10 | Out-File $localfile

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
Write-Output "Uploading $filename to $ContainerName"
Set-AzStorageBlobContent @Blob
