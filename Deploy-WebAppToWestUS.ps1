<#
    .SYNOPSIS
        Disaster recovery for Azure Web App and SQL database.
    
    .DESCRIPTION
        This script automates the disaster recovery (DR) process of a web app and SQL. It provisions the necessary resources and
        deploys code using Azure DevOps pipelines, and fails the SQL database over to the West US region.  For best results, it is recommended 
        to set this up as a PowerShell Runbook in an Azure Automation Account. 
    
    .EXAMPLE
        .\Deploy-WebAppToWestUS.ps1
     
    .INPUTS
        NA
        
    .OUTPUTS
        NA
    
    .NOTES
        NAME: Deploy-WebAppToWestUS.ps1
        AUTHOR: Edward Bernard, DevOps Engineer
        CREATED: 11/30/2020
        LASTEDIT: 12/11/2020
        VERSION: 1.5.0 - Formatting changes applied.
        
        #Requires Az PowerShell module to be present in the automation account workspace.
      
    .LINK
        https://docs.microsoft.com/en-us/powershell/azure/install-az-ps?view=azps-2.7.0#install-the-azure-powershell-module-1
        https://docs.microsoft.com/en-us/rest/api/azure/devops/release/releases/create?view=azure-devops-rest-6.0
#>

#region Automation account login
# Get Azure Automation runas account and log on to Azure.
filter timestamp {"[$(Get-Date -Format G)]: $_"}

Write-Output "Authenticating with Automation Runas account..." | timestamp
$connection = Get-AutomationConnection -Name "AzureRunAsConnection"
$subscriptionId = "Your Azure sub ID goes here"

# Wrap authentication in retry logic for transient network failures.
$logonAttempt = 0
while(!($connectionResult) -and ($logonAttempt -le 5))
{
    $LogonAttempt++
    $connectionResult = Connect-AzAccount -ServicePrincipal -Tenant $connection.TenantID `
                            -ApplicationID $connection.ApplicationID `
                            -CertificateThumbprint $connection.CertificateThumbprint
 
    Set-AzContext -SubscriptionId $subscriptionId   
    Start-Sleep -Seconds 30
}

Write-Output "Authenticated with Automation Run As Account." | timestamp
#endregion

#region Define functions.
function New-WebAppResourcesWestUS {
    param (
        $org = "Your Azure DevOps orgnization name goes here",
        $project = "Your Azure DevOps project name goes here",
        $url = "https://vsrm.dev.azure.com/$org/$project/_apis/release/releases?api-version=6.1-preview.8",
        $PAT = "Your Azure DevOps PAT goes here",
        $base64AuthInfo = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(":$($PAT)")),
        $body = '{
            "definitionId": "Your release pipeline ID goes here"
        }'
    )

    filter timestamp {"[$(Get-Date -Format G)]: $_"}
    
    Write-Output "Provisioning resources in West US..." | timestamp
 
    # Create a new ADO pipeline release.
    $releaseInfo = Invoke-RestMethod -Uri $url -Headers @{Authorization = ("Basic {0}" -f $base64AuthInfo)} `
        -Method POST -Body $body -ContentType "application/json"
 
    # Get release and environment IDs.
    $releaseId = $releaseInfo.id
    $environmentIds = $releaseInfo.environments | Select-Object id
 
    # Trigger ADO pipeline stage to provision resources ($environmentIds[x] array).
    $envUrl = "https://vsrm.dev.azure.com/$org/$project/_apis/Release/releases/$($releaseId)/environments/$($environmentIds[x].id)?api-version=6.1-preview.7"
 
    $envBody = '{
        "status": "inProgress",
        "comment": "null"
    }'
 
    Invoke-RestMethod -Uri $envUrl -Headers @{Authorization = ("Basic {0}" -f $base64AuthInfo)} -Method PATCH `
        -Body $envBody -ContentType "application/json"
}

function Deploy-WebAppCodeWestUS {
    param (
        $org = "Your Azure DevOps organization name goes here",
        $project = "Your Azure DevOps project name goes here",
        $url = "https://vsrm.dev.azure.com/$org/$project/_apis/release/releases?api-version=6.1-preview.8",
        $PAT = "Your Azure DevOps PAT goes here",
        $base64AuthInfo = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(":$($PAT)")),
        $body = '{
            "definitionId": "Your release pipeline ID goes here"
        }'
    )
    
    filter timestamp {"[$(Get-Date -Format G)]: $_"}
    
    Write-Output "Deploying web app code to resources in West US..." | timestamp

    # Create a new ADO pipeline release.
    $releaseInfo = Invoke-RestMethod -Uri $url -Headers @{Authorization = ("Basic {0}" -f $base64AuthInfo)} `
    -Method POST -Body $body -ContentType "application/json"

    # Get release and environment IDs.
    $releaseId = $releaseInfo.id
    $environmentIds = $releaseInfo.environments | Select-Object id
 
    # Trigger pipeline stage to deploy code ($environmentIds[x] array).
    $envUrl = "https://vsrm.dev.azure.com/$org/$project/_apis/Release/releases/$($releaseId)/environments/$($environmentIds[x].id)?api-version=6.1-preview.7"
 
    $envBody = '{
        "status": "inProgress",
        "comment": "null"
    }'
 
    Invoke-RestMethod -Uri $envUrl -Headers @{Authorization = ("Basic {0}" -f $base64AuthInfo)} -Method PATCH `
        -Body $envBody -ContentType "application/json"
}

function Switch-SqlDBWestUS {
    param (
        $subscriptionId = "Your Azure subscription ID goes here",
        $databaseName = "Your Azure SQL database name goes here",
        $primaryResourceGroupName = "Your primary Azure SQL resource group name goes here", # Set resource group and name for primary server
        $primaryServerName = "Your primary Azure SQL database server name goes here",
        $secondaryResourceGroupName = "Your secondary Azure SQL resource group name goes here", # Set resource group and name for secondary server
        $secondaryServerName = "Your secondary Azure SQL database server name goes here"
    )
    filter timestamp {"[$(Get-Date -Format G)]: $_"}
    
    Write-Output "Authenticating with Automation Runas account..." | timestamp
    $connection = Get-AutomationConnection -Name "AzureRunAsConnection"

    # Wrap authentication in retry logic for transient network failures.
    $logonAttempt = 0
    while(!($connectionResult) -and ($logonAttempt -le 5))
    {
        $LogonAttempt++
        $connectionResult = Connect-AzAccount -ServicePrincipal -Tenant $connection.TenantID `
                                -ApplicationID $connection.ApplicationID `
                                -CertificateThumbprint $connection.CertificateThumbprint
 
        Set-AzContext -SubscriptionId $subscriptionId    
        Start-Sleep -Seconds 30
    }
    
    Write-Output "Authenticated with Automation Run As Account." | timestamp
    
    # Initiate failover.
    Write-Output "Switching over to SQL database replica in West US..." | timestamp
    $database = Get-AzSqlDatabase -DatabaseName $databaseName -ResourceGroupName $secondaryResourceGroupName `
        -ServerName $secondaryServerName
    $database | Set-AzSqlDatabaseSecondary -PartnerResourceGroupName $primaryResourceGroupName -Failover

    # Monitor Geo-Replication config and health AFTER failover.
    $database = Get-AzSqlDatabase -DatabaseName $databaseName -ResourceGroupName $secondaryResourceGroupName `
        -ServerName $secondaryServerName
    $database | Get-AzSqlDatabaseReplicationLink -PartnerResourceGroupName $primaryResourceGroupName `
        -PartnerServerName $primaryServerName
}
#endregion

#region Work section.
Write-Output "Starting disaster recovery of RMS to West US region." | timestamp

New-WebAppResourcesWestUS
Start-Sleep -Seconds 300

Deploy-WebAppCodeWestUS
Start-Sleep -Seconds 240

Switch-SqlDBWestUS

Write-Output "Disaster recovery of RMS to West US region complete." | timestamp
#endregion