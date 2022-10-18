<#
    Runbook: Export-UsageReport2Blob.ps1
    Creator: RubenFr
    
    Comments: 
    Get all the subscriptions' usage details of a specific day (by default two days ago) and upload the results to a storage account.
    Run every day
    Consumption Usage can take from 24h to 48h to update. So if you run the script to get data from less than 42h you might get partial results.
#>

Import-Module Az.Accounts
Import-Module Az.Storage


Function Connect-Azure {
	try {
		Connect-AzAccount `
			-Identity `
			-AccountId "MANAGED INDENTITY CLIENT ID" `
			-Subscription $storageAccountSubId
		| Out-Null
	}
	catch {
		Write-Error "Error while connecting to Azure..."
		Connect-Azure
	}
}


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
            Write-Error "StatusCode: $statusCode" 
            Write-Error "StatusDescription: $_.Exception.Response.ReasonPhrase"
            # return $usage
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


Function Get-Usage ($SubscriptionId, $Date) {
    $scope = "subscriptions/$subscriptionId"
    $headers = Get-HeaderAccessToken
    $apiversion = "2021-10-01";
    $filter = "properties/usageStart eq '$($date)' and properties/usageEnd eq '$($date)'"
    $expand = "properties/additionalInfo"
    $url = "https://management.azure.com/$scope/providers/Microsoft.Consumption/usageDetails?api-version=$($apiversion)&`$filter=$filter&`$expand=$expand"
    $usage = @()

    $response = Invoke-Get $url $headers
    $usage += $response.value

    while ( $response.nextLink ) {
        $nextLink = $response.nextLink
        $response = Invoke-Get $nextLink $headers
        $usage += $response.value        
    }
    
    return $usage
}

########################################
########## MAIN ########################
########################################
Write-Output "Starting - $(Get-Date)`n"

$yesterday = Get-Date (Get-Date).AddDays(-2) -Format "yyyy-MM-dd"
$tempdir = "c:\temp\"
$filename = "report-usage-$($yesterday).json"
$storageAccountSubId = "SUBSCRIPTION ID OF THE STORAGE ACCOUNT"
$storageAccountRG = "RESOURCE GROUP OF THE STORAGE ACCOUNT"
$storageAccountName = "NAME OF THE STORAGE ACCOUNT"
$containerName = "CONTAINER NAME OF THE STORAGE ACCOUNT"

# Connect To Azure
Connect-Azure

#azure automation temp folder
Write-Output "Starting getting Usage for $date..."
$localfile = $tempdir + $filename

$consumption_usage = @()
Get-AzSubscription | ? { $_.State -eq 'Enabled' -and $_.Name -ne "Azure Pass - Sponsorship" } | Sort-Object Name | 
% {
    $usage = Get-Usage -SubscriptionId $_.Id -Date $date
    $consumption_usage += $usage
	
	$properties = $usage.properties
    Write-Output "$($_.Name) -> Usage = $($usage.count) events; Cost = $(($properties | Measure-Object cost -Sum).Sum)`$"
}
Write-Output "Finished! Found in total $($consumption_usage.Count) events." -Verbose

# Output the results to the local file
$consumption_usage | ConvertTo-Json | Out-File $localfile

# Starting uploading results to blob
Write-Output "`nUploading $filename to $containerName..."

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
    Container        = $containerName
    Blob             = $filename
    Context          = $Context
    StandardBlobTier = 'Cool'
}

try {
	Set-AzStorageBlobContent @Blob -ErrorAction Stop | Out-Null
	Write-Output "File $filename successfuly uploaded to $containerName!"
}
catch {
    Write-Warning "Error while uploading $filename to $containerName."
}

Write-Output "`nFinished - $(Get-Date)`n"
