<#
    Runbook: Export-UsageReport2Blob.ps1
    Creator: RubenFr
    
    Comments: 
    Get all the usage details of a specific day (by default one day ago) and upload the results to a storage account.
    Run every day
#>

Import-Module Az.Accounts
Import-Module Az.Storage


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
            # Sleep 30 seconds
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


Function Get-Usage ($date) {
    $scope = "THE SCOPE YOU WANT TO GET THE USAGE"
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

############################
######### Main #############
############################

$yesterday = Get-Date (Get-Date).AddDays(-1) -Format "yyyy-MM-dd"
$tempdir = "c:\temp\"
$filename = "report-usage-$($yesterday).json"
$storageAccountSubId = "SUBSCRIPTION ID OF THE STORAGE ACCOUNT"
$storageAccountRG = "RESOURCE GROUP OF THE STORAGE ACCOUNT"
$storageAccountName = "NAME OF THE STORAGE ACCOUNT"
$containerName = "CONTAINER NAME OF THE STORAGE ACCOUNT"

# Connect To Azure
Connect-AzAccount `
    -Identity `
    -AccountId "ID OF THE AUTOMATION ACCOUNT" `
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
