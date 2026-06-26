# IntuneEnhancedInventory
Repository for the Intune Custom Inventory solution by MSEndpointmgr.com

> IMPORTANT! 
> Version 1.2 requires use of version 3.5.0 of the Invoke-CustomInventoryAzureFunction.ps1 to be used in Proactive Remediations
> This version of the Azure Function will work for any custom log you want to send securely to Log Analytics

### Version History 
Full changelog can be found here: [Changelog](https://github.com/MSEndpointMgr/IntuneEnhancedInventory/blob/main/CHANGELOG.MD)
#### Latest Version for the Azure Function 
* 1.2 - Released 15.10.2022 

#### Latest Version history for the Proactive Remediation Script
* 3.5 - Released 15.10.2022

# Update ONLY
* To perform an update use this deploy button and enter information from your current deployment-

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FMSEndpointMgr%2FIntuneEnhancedInventory%2Fmain%2FDeploy%2FUpdate%2FUpdateSecuredEnhancedInventory.json)

# Installation 
## Option 1 (legacy and not maintained) 
Use the simple proactive remediation that sends data direct to Log Analytics Workspace with secrets in code. 
Read the blogpost: 
[https://msendpointmgr.com/2021/04/12/enhance-intune-inventory-data-with-proactive-remediations-and-log-analytics/](https://msendpointmgr.com/2021/04/12/enhance-intune-inventory-data-with-proactive-remediations-and-log-analytics/)

## Option 2 (strongly recommended)
Use the new and updated proactive remediation that sends data through a Azure Function App to keep secret out of code and secure that only approved and known clients can send data to your log workspace. 

1. Deploy Azure Function using our template.  
[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FMSEndpointMgr%2FIntuneEnhancedInventory%2Fmain%2FDeploy%2FSecuredEnhancedInventory.json) 
3. Set API Permissions for MSI to graph with Add-MSIGraphPermissions.ps1 
4. Deploy the Invoke-CustomInventoryAzureFunction.ps1 Proactive remediation after you added your Azure Function URL to the script. 
Read the blogpost: 
[https://msendpointmgr.com/2022/01/17/securing-intune-enhanced-inventory-with-azure-function/ ](https://msendpointmgr.com/2022/01/17/securing-intune-enhanced-inventory-with-azure-function/)

## Azure Function permissions and authentication

The Azure Function is used as a trusted ingestion broker between Intune-managed devices and Log Analytics. Devices do not receive the Log Analytics workspace shared key. Instead, devices send inventory data to the Function App, and the Function App validates the request before forwarding accepted logs to Log Analytics.

### Runtime permissions used by the Function App

The Function App uses a system-assigned managed identity. That identity needs the following permissions:

| Permission | Where it is granted | What it is used for |
| --- | --- | --- |
| `Device.Read.All` | Microsoft Graph application permission on the Function App managed identity | Allows the Function to query Microsoft Graph for the incoming Azure AD device ID. The Function checks that the device exists in the tenant and that `accountEnabled` is `true` before it accepts and forwards the inventory payload. |
| Key Vault secret `get` | Key Vault access policy for the Function App managed identity | Allows the Function App to resolve the `WorkspaceID` and `SharedKey` app settings from Key Vault references. These values are required to send data to the Log Analytics HTTP Data Collector API. |
| Key Vault secret `list` | Key Vault access policy for the Function App managed identity | Included by the deployment template with the Key Vault access policy. The Function only references named secrets, so `get` is the permission required for runtime secret retrieval. |

The Function does not use a signed-in user when it calls Microsoft Graph. It obtains a token for `https://graph.microsoft.com` from the Azure Functions managed identity endpoint, then calls `/devices` with a filter for the submitted `AzureADDeviceID`.

The Function also does not use an Azure RBAC role on the Log Analytics workspace at runtime. It sends data to the Log Analytics HTTP Data Collector API by signing each request with the workspace shared key stored in Key Vault.

### Setup permissions used by Add-MSIGraphPermissions.ps1

`Add-MSIGraphPermissions.ps1` is an administrative setup script. The delegated permissions requested by this script are used by the administrator running the script, not by the Azure Function at runtime.

| Permission | Who uses it | What it is used for |
| --- | --- | --- |
| `Application.Read.All` | Administrator running `Add-MSIGraphPermissions.ps1` | Allows the script to read service principals, including the Function App managed identity service principal and the Microsoft Graph service principal. |
| `AppRoleAssignment.ReadWrite.All` | Administrator running `Add-MSIGraphPermissions.ps1` | Allows the script to create the app role assignment that grants `Device.Read.All` to the Function App managed identity. After this assignment is created, the Function does not need `AppRoleAssignment.ReadWrite.All`. |
| `Device.Read.All` | Function App managed identity | This is the permission being assigned by the setup script. It is used later by the Function during request validation. |

### Authentication workflow

1. The Intune proactive remediation script runs on the device and collects inventory data.
2. The script reads the local Azure AD tenant ID and Azure AD device ID, then posts them with `LogPayloads` to the Azure Function URL.
3. The HTTP trigger receives the request. The trigger is anonymous, so the Function performs its own validation before forwarding any data.
4. The Function compares the submitted tenant ID with the configured `TenantID` app setting.
5. If the tenant ID matches, the Function uses its managed identity to request a Microsoft Graph access token.
6. The Function queries Microsoft Graph for the submitted Azure AD device ID.
7. The Function accepts the payload only when the device exists in the tenant and the device object is enabled.
8. The Function reads the Log Analytics workspace ID and shared key from Key Vault-backed app settings.
9. The Function signs the Log Analytics ingestion request with the shared key and sends each allowed log payload to the workspace.

### Example code for adding a custom log
```powershell 
$LogPayLoad = New-Object -TypeName PSObject 
$LogPayLoad | Add-Member -NotePropertyMembers @{$LogName1 = $Logdata1}
$LogPayLoad | Add-Member -NotePropertyMembers @{$LogName2 = $Logdata2}
# Construct main payload to send to LogCollectorAPI
$MainPayLoad = [PSCustomObject]@{
	AzureADTenantID = $AzureADTenantID
	AzureADDeviceID = $AzureADDeviceID
	LogPayloads = $LogPayLoad
}
...
