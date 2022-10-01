<#
    Creator: RubenFr
    Creation Date: 1/10/2022
    
    https://docs.microsoft.com/en-us/rest/api/billing/2019-10-01-preview/role-assignments/put

    Add 'Enrollment reader' role to the principal with $objectID

    description : The enrollment reader role gives the user read-only permissions to an Enrollment and its departments and accounts.
    id          : /providers/Microsoft.Billing/billingAccounts/XXXXXXX/billingRoleDefinitions/24f8edb6-1668-4659-b5e2-40bb5f3a7d7e
    name        : 24f8edb6-1668-4659-b5e2-40bb5f3a7d7e
    permissions : {
        Microsoft.Billing/billingAccounts/read,
        Microsoft.Billing/billingAccounts/enrollmentPolicies/read,
        Microsoft.Billing/billingAccounts/enrollmentNotificationContacts/read,
        Microsoft.Billing/billingAccounts/departments/read,
        Microsoft.Billing/billingAccounts/enrollmentAccounts/read,
        Microsoft.Billing/billingAccounts/enrollmentAccounts/billingSubscriptions/read,
        Microsoft.Billing/billingAccounts/commitments/read
    }
    roleName    : Enrollment reader
    type        : Microsoft.Billing/billingAccounts/billingRoleDefinitions  
#>

# Connect to Azure
az login --allow-no-subscriptions

# Principal which receives the permission
$objectID = "PRINCIPAL OBJECT ID"

$billingAccount = "BILLING ACCOUNT"
$tenantID = "TENANT ID"
$assignmentName = "UNIQUE UUUI GENERATED"               # https://www.uuidgenerator.net/
$roleName = "24f8edb6-1668-4659-b5e2-40bb5f3a7d7e"      # Reader

$header = @{ "Content-Type" = "application/json" }
$header | ConvertTo-Json | Out-File -FilePath 'header.json'

$body = @{
    "properties" = @{
        "principalId"       = $objectID;
        "principalTenantId" = $tenantID;
        "roleDefinitionId"  = "/providers/Microsoft.Billing/billingAccounts/$($billingAccount)/billingRoleDefinitions/$($roleName)";
    }
}
$body | ConvertTo-Json | Out-File -FilePath 'body.json'

$uri = "https://management.azure.com/providers/Microsoft.Billing/billingAccounts/$($billingAccount)/billingRoleAssignments/$($assignmentName)?api-version=2019-10-01-preview"
az rest -m put -u $uri --headers "@header.json" -b "@body.json"

Remove-Item header.json
Remove-Item body.json
