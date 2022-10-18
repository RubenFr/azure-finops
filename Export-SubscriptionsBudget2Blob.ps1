<#
    Runbook: Export-SubscriptionsBudget2Blob.ps1
    Creator: RubenFr
    
    Comments:
    Get all the budgets and current spend of a subscription/mg and upload the results to a storage account.
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


Function Invoke-PostRequest ( $Url, $Body ) {
    $headers = Get-HeaderAccessToken
    try {
        $response = Invoke-RestMethod `
            -Method Post `
            -Uri $url `
            -Headers $headers `
            -Body $body
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__

        do {
            if ( $statusCode -ne 429 ) {
                Write-Warning "Error during request: $url"
                Write-Warning "StatusDescription: $($_.Exception.Response.ReasonPhrase)"
                return $null
            }

            # Spleep 30 seconds
            Write-Warning "Sleeping 30 seconds..."
            Start-Sleep -Seconds 30

            try {
                $response = Invoke-RestMethod `
                    -Method Post `
                    -Uri $url `
                    -Headers $headers `
                    -Body $body
                $statusCode = 200
            }
            catch {
                $statusCode = $_.Exception.Response.StatusCode.value__
            }
        }
        while ( $statusCode -ne 200 )
    }
    return $response
}


Function Add-ExtendedBudget ( $Scope, $Budget ) {
    $apiversion = "2021-10-01"
    $url = "https://management.azure.com/$scope/providers/Microsoft.CostManagement/forecast?api-version=$($apiversion)"
    $body = @{
        "type"                    = "Usage";
        "timeframe"               = "MonthToDate";
        "dataset"                 = @{
            "granularity" = "Daily";
            "aggregation" = @{
                "totalCost" = @{
                    "name"     = "Cost";
                    "function" = "Sum"
                }
            }
        };
        "includeActualCost"       = $true;
        "includeFreshPartialCost" = $true
    } | ConvertTo-Json -Depth 10

    $response = Invoke-PostRequest -Url $url -Body $body
    $cost_index = [array]::indexof($response.properties.columns.name, "Cost")
    $type_index = [array]::indexof($response.properties.columns.name, "CostStatus")

    $cost, $forecast = 0, 0
    $response.properties.rows | ? { $_[$type_index] -eq "Actual" } | % { $cost += $_[$cost_index] }
    $response.properties.rows | % { $forecast += $_[$cost_index] }

    $budget.properties | Add-Member -MemberType NoteProperty -Name extendedCost -Value @{'currentCost' = $cost; 'currentForecast' = $forecast }
    return $budget
}

Function Get-Budgets ( $Scope ) {
    
    $apiversion = "2021-10-01"
    $url = "https://management.azure.com/$scope/providers/Microsoft.Consumption/budgets?api-version=$($apiversion)"
    $budgets = @()

    $response = Invoke-GetRequest $url
    $budgets += $response.value

    while ( $response.nextLink ) {
        $nextLink = $response.nextLink
        $response = Invoke-Get $nextLink $headers
        $budgets += $response.value
    }

    $extendedBudgets = @()
    if ($budgets.Count -eq 0) {
        $budgets = @(
            @{
                "id"         = "/$scope/providers/Microsoft.Consumption/budgets/no-budget";
                "name"       = "none";
                "type"       = "Microsoft.Consumption/budgets";
                "properties" = @{
                    "timeGrain" = "none";
                    "amount"    = 0;
                    "category"  = "Cost";
                }
            }
        )
    }

    $budgets | ForEach-Object {
        $extendedBudgets += Add-ExtendedBudget -Scope $scope -Budget $_
    }
    return $extendedBudgets
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
Get-AzSubscription | ? { $_.State -eq 'Enabled' -and $_.Name -ne "Azure Pass - Sponsorship" } | Sort-Object Name | 
% {
    $budget = Get-Budgets -scope "subscriptions/$($_.Id)" -Extend
    $sub_budgets += $budget
    Write-Output "$($_.Name) -> Budget = $($budget.properties.amount)`$; Cost = $($budget.properties.extendedCost.currentCost)`$; Forecast = $($budget.properties.extendedCost.currentForecast)`$"
}
Write-Output "Finished! Found in total $($sub_budgets.Count) events.`n"

# Output the results to the local file
$budgets = $department_budgets + $sub_budgets
$filename = "click-budgets-$($yesterday).json"
$localfile = $tempdir + $filename
$budgets | ConvertTo-Json -Depth 10 | Out-File $localfile

# Starting uploading results to blob
Write-Output "Uploading $filename to $containerName..."

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
