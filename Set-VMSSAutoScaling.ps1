<#
    Author: RubenFr
    Creation Date: 1/10/2022
    
    Comments:
    Runs everyday in azure automation account.
    This runbook activate autoscaling to all the VMSS that didn't configured it (Manual).
#>


Function Connect-Azure {
    Connect-AzAccount `
      -Identity `
      -AccountId "USER MANAGED IDENTITY CLIENT ID"
}


Function Get-VMSSNotAutoScaled {
    $autoScaleSettings = Get-AzResourceGroup |
    % {
        Get-AzAutoscaleSetting `
            -ResourceGroupName $_.ResourceGroupName `
            -WarningAction Ignore |
        Select-Object Enabled, Name, TargetResourceUri
    }

    Write-Warning "Found $($autoScaleSettings.Count) AutoScale settings:"
    Write-Warning $($autoScaleSettings | ConvertTo-Json)

    $needAutoScale = Get-AzVmss | 
    Where-Object { 
        $_.Id -notin $autoScaleSettings.TargetResourceUri 
    }

    return $needAutoScale
}

##############################################
##############	 Main	######################
##############################################

Connect-Azure

$subs = Get-AzSubscription | ? { $_.State -eq 'Enabled' } | Sort-Object Name

foreach ($sub in $subs) {
    "`n$($sub.Name)"
    Set-AzContext -SubscriptionId $sub.Id | Out-Null

    $notScaledVmss = Get-VMSSNotAutoScaled
    "Found $($notScaledVmss.count) VMSS to Autoscale"

    foreach ($vmss in $notScaledVmss) {
        
        $ruleScaleOut = New-AzAutoscaleRule `
            -MetricName "Percentage CPU" `
            -MetricResourceId $vmss.Id `
            -TimeGrain 00:01:00 `
            -MetricStatistic "Average" `
            -TimeWindow 00:10:00 `
            -Operator "GreaterThan" `
            -Threshold 70 `
            -ScaleActionDirection "Increase" `
            -ScaleActionScaleType "ChangeCount" `
            -ScaleActionValue 1 `
            -ScaleActionCooldown 00:05:00

        $ruleScaleIn = New-AzAutoscaleRule `
            -MetricName "Percentage CPU" `
            -MetricResourceId $vmss.Id `
            -TimeGrain 00:01:00 `
            -MetricStatistic "Average" `
            -TimeWindow 00:10:00 `
            -Operator "LessThan" `
            -Threshold 20 `
            -ScaleActionDirection "Decrease" `
            -ScaleActionScaleType "ChangeCount" `
            -ScaleActionValue 1 `
            -ScaleActionCooldown 00:05:00

        $scaleProfile = New-AzAutoscaleProfile `
            -DefaultCapacity $([math]::Max(1, $vmss.Sku.Capacity)) `
            -MinimumCapacity $([math]::Max(1, $vmss.Sku.Capacity)) `    # This keeps the current number of instances as the minimum
            -MaximumCapacity $([math]::Max(10, $vmss.Sku.Capacity)) `
            -Rule $ruleScaleOut, $ruleScaleIn `
            -Name "$($vmss.Name)-autoscaleprofile"

    }  try {
        Add-AzAutoscaleSetting `
            -Location $vmss.Location `
            -Name "$($vmss.Name)-autoscale" `
            -ResourceGroup $vmss.ResourceGroupName `
            -TargetResourceId $vmss.Id `
            -AutoscaleProfile $scaleProfile `
            -WarningAction Ignore `
            -ErrorAction Stop |
        Out-Null

        "Autoscalled $($vmss.Name) (RG: $($vmss.ResourceGroupName))"
    }
    catch {
        Write-Error "Error while adding autoscaling to $($vmss.Name) (RG: $($vmss.ResourceGroupName)):"
        Write-Error $_
    }
}
