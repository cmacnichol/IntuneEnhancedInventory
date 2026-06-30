<#
.SYNOPSIS
Collect custom device inventory and upload to Log Analytics for further processing.

.DESCRIPTION
This script will collect device hardware and / or app inventory and upload this to a Log Analytics Workspace. This allows you to easily search in device hardware and installed apps inventory.
The script is meant to be runned on a daily schedule either via Proactive Remediations (RECOMMENDED) in Intune or manually added as local schedule task on your Windows Computer.

.EXAMPLE
Invoke-CustomInventoryWithAzureFunction.ps1 (Required to run as System or Administrator)

.PARAMETER
Note the following variables
$RandomiseCollectionInt - if this is true the randomizer to spread load over X minutes is enabled
$RandomizeMinutes - the number of minutes to randomize load over. Max 50 minutes to avoid PR timeouts

.NOTES
FileName:    Invoke-CustomInventory.ps1
Author:      Jan Ketil Skanke
Contributor: Sandy Zeng / Maurice Daly
Contact:     @JankeSkanke
Created:     2021-01-02
Updated:     2026-06-27

Version history:
0.9.0 - (2021 - 01 - 02) Script created
1.0.0 - (2021 - 01 - 02) Script polished cleaned up.
1.0.1 - (2021 - 04 - 05) Added NetworkAdapter array and fixed typo
2.0 - (2021 - 08 - 29) Moved secrets out of code - now running via Azure Function
2.0.1 (2021-09-01) Removed all location information for privacy reasons
2.1 - (2021-09-08) Added section to cater for BIOS release version information, for HP, Dell and Lenovo and general bugfixes
2.1.1 - (2021-21-10) Added MACAddress to the inventory for each NIC.
3.0.0 - (2022-22-02) Azure Function updated - Requires version 1.1 of Azure Function LogCollectorAPI for more dynamic log collecting
3.0.1 - (2022-15-09) Updated to support CloudPC (Different method to find AzureAD DeviceID for verification) and fixed output error from script (Thanks to @gwblok)
3.5.0 - (2022-14-10) Azure Function updated - Requires version 1.2 Updated output logic to be more dynamic. Fixed a bug in the randomizer function and disabled inventory collection during provisioning day.
3.6.0 - (2026-06-26) Added Lenovo Dock inventory collection with local cache, status, and usage logs.
3.7.0 - (2026-06-27) Added Lenovo dock firmware normalization, optional monitor metadata, and Lenovo device health inventory.
#>

#region initialize
# Define your azure function URL:
# Example 'https://<appname>.azurewebsites.net/api/<functioname>'

$AzureFunctionURL = ""

# Enable TLS 1.2 support
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
#Control if you want to collect App or Device Inventory or both (True = Collect)
$CollectAppInventory = $true
$CollectDeviceInventory = $true
# $CollectCustomInventory = $true *SAMPLE*
$DryRun = $false

#Set Log Analytics Log Name
$AppLogName = "AppInventory"
$DeviceLogName = "DeviceInventory"
# $CustomLogName = "CustomInventory" *SAMPLE*
$Date=(Get-Date)

#region Lenovo inventory settings
$CollectLenovoDockInventory = $true
$CollectLenovoDeviceHealthInventory = $true
$LenovoDockInventoryLogName = "LenovoDockInventory"
$LenovoDockStatusLogName = "LenovoDockStatus"
$LenovoDockUsageLogName = "LenovoDockUsage"
$LenovoDeviceHealthLogName = "LenovoDeviceHealth"
$LenovoDockCachePath = "C:\ProgramData\IntuneEnhancedInventory\LenovoDockInventory.json"
#endregion Lenovo inventory settings

# Enable or disable randomized running time to avoid azure function to be overloaded in larger environments
# Set to true only if needed
$RandomiseCollectionInt = $false
# Time to randomize over, max 50 minutes to avoid PR timeout.
$RandomizeMinutes = 30

#endregion initialize

#region functions
#region common functions
# Function to get Azure AD DeviceID
function Get-AzureADDeviceID {
    <#
    .SYNOPSIS
        Get the Azure AD device ID from the local device.

    .DESCRIPTION
        Get the Azure AD device ID from the local device.

    .NOTES
        Author:      Nickolaj Andersen
        Contact:     @NickolajA
        Created:     2021-05-26
        Updated:     2021-05-26

        Version history:
        1.0.0 - (2021-05-26) Function created
		1.0.1 - (2022-15.09) Updated to support CloudPC (Different method to find AzureAD DeviceID)
    #>
	Process {
		# Define Cloud Domain Join information registry path
		$AzureADJoinInfoRegistryKeyPath = "HKLM:\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\JoinInfo"

		# Retrieve the child key name that is the thumbprint of the machine certificate containing the device identifier guid
		$AzureADJoinInfoKey = Get-ChildItem -Path $AzureADJoinInfoRegistryKeyPath -ErrorAction SilentlyContinue | Select-Object -ExpandProperty "PSChildName"
		if ($null -ne $AzureADJoinInfoKey) {
			# Retrieve the machine certificate based on thumbprint from registry key

            if ($null -ne $AzureADJoinInfoKey) {
                # Match key data against GUID regex
                if ([guid]::TryParse($AzureADJoinInfoKey, $([ref][guid]::Empty))) {
                    $AzureADJoinCertificate = Get-ChildItem -Path "Cert:\LocalMachine\My" -Recurse | Where-Object { $PSItem.Subject -like "CN=$($AzureADJoinInfoKey)" }
                }
                else {
                    $AzureADJoinCertificate = Get-ChildItem -Path "Cert:\LocalMachine\My" -Recurse | Where-Object { $PSItem.Thumbprint -eq $AzureADJoinInfoKey }
                }
            }
			if ($null -ne $AzureADJoinCertificate) {
				# Determine the device identifier from the subject name
				$AzureADDeviceID = ($AzureADJoinCertificate | Select-Object -ExpandProperty "Subject") -replace "CN=", ""
				# Handle return value
				return $AzureADDeviceID
			}
		}
	}
} #endfunction
function Get-AzureADJoinDate {
    <#
    .SYNOPSIS
        Get the Azure AD Join Date from the local device.

    .DESCRIPTION
        Get the Azure AD Join Date from the local device.

    .NOTES
        Author:      Jan Ketil Skanke (and Nickolaj Andersen)
        Contact:     @JankeSkanke
        Created:     2021-05-26
        Updated:     2021-05-26

        Version history:
        1.0.0 - (2021-05-26) Function created
		1.0.1 - (2022-15.09) Updated to support CloudPC (Different method to find AzureAD DeviceID)
    #>
	Process {
		# Define Cloud Domain Join information registry path
		$AzureADJoinInfoRegistryKeyPath = "HKLM:\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\JoinInfo"

		# Retrieve the child key name that is the thumbprint of the machine certificate containing the device identifier guid
		$AzureADJoinInfoKey = Get-ChildItem -Path $AzureADJoinInfoRegistryKeyPath -ErrorAction SilentlyContinue | Select-Object -ExpandProperty "PSChildName"
		if ($null -ne $AzureADJoinInfoKey) {
			# Retrieve the machine certificate based on thumbprint from registry key

            if ($null -ne $AzureADJoinInfoKey) {
                # Match key data against GUID regex
                if ([guid]::TryParse($AzureADJoinInfoKey, $([ref][guid]::Empty))) {
                    $AzureADJoinCertificate = Get-ChildItem -Path "Cert:\LocalMachine\My" -Recurse | Where-Object { $PSItem.Subject -like "CN=$($AzureADJoinInfoKey)" }
                }
                else {
                    $AzureADJoinCertificate = Get-ChildItem -Path "Cert:\LocalMachine\My" -Recurse | Where-Object { $PSItem.Thumbprint -eq $AzureADJoinInfoKey }
                }
            }
		if ($null -ne $AzureADJoinCertificate) {
				# Determine the device identifier from the subject name
				$AzureADJoinDate = ($AzureADJoinCertificate | Select-Object -ExpandProperty "NotBefore")
				# Handle return value
				return $AzureADJoinDate
			}
		}
	}
} #endfunction
#Function to get AzureAD TenantID
function Get-AzureADTenantID {
	# Cloud Join information registry path
	$AzureADTenantInfoRegistryKeyPath = "HKLM:\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\TenantInfo"
	# Retrieve the child key name that is the tenant id for AzureAD
	$AzureADTenantID = Get-ChildItem -Path $AzureADTenantInfoRegistryKeyPath -ErrorAction SilentlyContinue | Select-Object -ExpandProperty "PSChildName"
	return $AzureADTenantID
}
# Function to get all Installed Application
function Get-InstalledApplication() {
	param (
		[string]$UserSid
	)

	$CreatedHKUDrive = $false
	try {
		if ($null -eq (Get-PSDrive -Name "HKU" -ErrorAction SilentlyContinue)) {
			New-PSDrive -PSProvider Registry -Name "HKU" -Root HKEY_USERS | Out-Null
			$CreatedHKUDrive = $true
		}
		$regpath = @("HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*")
		if (-not ([string]::IsNullOrEmpty($UserSid))) {
			$regpath += "HKU:\$UserSid\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
		}
		if (-not ([IntPtr]::Size -eq 4)) {
			$regpath += "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
			if (-not ([string]::IsNullOrEmpty($UserSid))) {
				$regpath += "HKU:\$UserSid\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
			}
		}
		$propertyNames = 'DisplayName', 'DisplayVersion', 'Publisher', 'UninstallString', 'InstallDate'
		$Apps = Get-ItemProperty $regpath -Name $propertyNames -ErrorAction SilentlyContinue | . { process { if ($_.DisplayName) { $_ } } } | Select-Object DisplayName, DisplayVersion, Publisher, UninstallString, InstallDate, PSPath | Sort-Object DisplayName
	}
	finally {
		if ($CreatedHKUDrive) {
			Remove-PSDrive -Name "HKU" | Out-Null
		}
	}
	Return $Apps
}
function Get-SanitizedErrorMessage {
	param (
		[string]$Message
	)

	if ([string]::IsNullOrWhiteSpace($Message)) {
		return ""
	}

	return (($Message -replace "[\r\n]+", " ").Trim())
}
#endregion common functions

#region lenovo functions
function ConvertTo-LenovoNullableBool {
	param (
		[object]$Value
	)

	if ($null -eq $Value) {
		return $null
	}
	if ($Value -is [bool]) {
		return [bool]$Value
	}
	$StringValue = "$Value".Trim()
	if ($StringValue -match '^(True|False)$') {
		return [System.Convert]::ToBoolean($StringValue)
	}

	return $null
}
function ConvertTo-LenovoNumber {
	param (
		[object]$Value
	)

	if ($null -eq $Value) {
		return $null
	}

	$Match = [regex]::Match("$Value", '[-+]?\d+(\.\d+)?')
	if (-not $Match.Success) {
		return $null
	}

	return [double]$Match.Value
}
function ConvertTo-LenovoInteger {
	param (
		[object]$Value
	)

	$Number = ConvertTo-LenovoNumber -Value $Value
	if ($null -eq $Number) {
		return $null
	}

	return [int]$Number
}
function Get-LenovoFirmwareVersionNormalized {
	param (
		[string]$Version
	)

	if ([string]::IsNullOrWhiteSpace($Version)) {
		return ""
	}

	return (($Version.Trim() -replace '^[vV]\s*', '').Trim())
}
function Get-LenovoFirmwareUpdateAvailable {
	param (
		[string]$FWVersionNormalized,
		[string]$AvailableFWVersionNormalized,
		[object]$LatestFirmwareFlag
	)

	$LatestFirmwareFlagValue = ConvertTo-LenovoNullableBool -Value $LatestFirmwareFlag
	if ($null -ne $LatestFirmwareFlagValue) {
		return (-not $LatestFirmwareFlagValue)
	}
	if ([string]::IsNullOrWhiteSpace($AvailableFWVersionNormalized)) {
		return $null
	}
	if ([string]::IsNullOrWhiteSpace($FWVersionNormalized)) {
		return $null
	}

	return ($FWVersionNormalized -ne $AvailableFWVersionNormalized)
}
function Get-StringSHA256Hash {
	param (
		[string]$Value
	)

	if ([string]::IsNullOrWhiteSpace($Value)) {
		return ""
	}

	$Sha256 = [System.Security.Cryptography.SHA256]::Create()
	try {
		$Bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
		return (($Sha256.ComputeHash($Bytes) | ForEach-Object { $_.ToString("x2") }) -join "")
	}
	finally {
		$Sha256.Dispose()
	}
}
function Get-LenovoJoinedPropertyValue {
	param (
		[array]$Items,
		[string]$PropertyName
	)

	$Values = @($Items | ForEach-Object {
		if ($null -ne $_.PSObject.Properties[$PropertyName]) {
			"$($_.PSObject.Properties[$PropertyName].Value)"
		}
	} | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)

	return ($Values -join ",")
}
function Test-LenovoDockObjectMatch {
	param (
		[object]$Dock,
		[object]$RelatedObject
	)

	if (($null -eq $Dock) -or ($null -eq $RelatedObject)) {
		return $false
	}

	$DockId = "$($Dock.DockId)"
	$SerialNumber = "$($Dock.SerialNumber)"
	$MACAddress = "$($Dock.MACAddress)"

	if ((-not [string]::IsNullOrWhiteSpace($DockId)) -and ($DockId -eq "$($RelatedObject.DockId)")) {
		return $true
	}
	if ((-not [string]::IsNullOrWhiteSpace($SerialNumber)) -and ($SerialNumber -eq "$($RelatedObject.SerialNumber)")) {
		return $true
	}
	if ((-not [string]::IsNullOrWhiteSpace($MACAddress)) -and ($MACAddress -eq "$($RelatedObject.MACAddress)")) {
		return $true
	}

	return $false
}
function Find-LenovoDockRelatedObject {
	param (
		[array]$RelatedObjects,
		[object]$Dock
	)

	return @($RelatedObjects) | Where-Object { Test-LenovoDockObjectMatch -Dock $Dock -RelatedObject $_ } | Select-Object -First 1
}
function Get-LenovoDockRelatedMatch {
	param (
		[array]$RelatedObjects,
		[object]$Dock
	)

	return @($RelatedObjects) | Where-Object { Test-LenovoDockObjectMatch -Dock $Dock -RelatedObject $_ }
}
function Get-LenovoDockFirmwareState {
	param (
		[object]$Dock,
		[object]$DockInfo
	)

	$FWVersion = "$($Dock.FWVersion)"
	if (($null -ne $DockInfo) -and (-not [string]::IsNullOrWhiteSpace("$($DockInfo.FWVersion)"))) {
		$FWVersion = "$($DockInfo.FWVersion)"
	}

	$AvailableFWVersion = "$($Dock.AvailableFWVersion)"
	if (($null -ne $DockInfo) -and (-not [string]::IsNullOrWhiteSpace("$($DockInfo.AvailableFWVersion)"))) {
		$AvailableFWVersion = "$($DockInfo.AvailableFWVersion)"
	}

	$FWVersionNormalized = Get-LenovoFirmwareVersionNormalized -Version $FWVersion
	$AvailableFWVersionNormalized = Get-LenovoFirmwareVersionNormalized -Version $AvailableFWVersion
	$LatestFirmwareFlag = if ($null -ne $DockInfo) { ConvertTo-LenovoNullableBool -Value $DockInfo.LatestFirmwareFlag } else { $null }
	$FirmwareUpdateAvailable = Get-LenovoFirmwareUpdateAvailable -FWVersionNormalized $FWVersionNormalized -AvailableFWVersionNormalized $AvailableFWVersionNormalized -LatestFirmwareFlag $LatestFirmwareFlag

	return [PSCustomObject]@{
		FWVersion = "$FWVersion"
		AvailableFWVersion = "$AvailableFWVersion"
		FWVersionNormalized = "$FWVersionNormalized"
		AvailableFWVersionNormalized = "$AvailableFWVersionNormalized"
		LatestFirmwareFlag = $LatestFirmwareFlag
		FirmwareUpdateAvailable = $FirmwareUpdateAvailable
		FirmwareLastUpdateOn = if ($null -ne $DockInfo) { "$($DockInfo.LastUpdateOn)" } else { "" }
		FirmwareInventoryDate = if ($null -ne $DockInfo) { "$($DockInfo.Date)" } else { "" }
	}
}
function Get-LenovoDockMonitorSummary {
	param (
		[array]$DisplayDevices
	)

	$Displays = @($DisplayDevices)
	$EDIDHashes = @($Displays | ForEach-Object { Get-StringSHA256Hash -Value "$($_.MonitorEDID)" } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)

	return [PSCustomObject]@{
		MonitorConnected = ($Displays.Count -gt 0)
		MonitorCount = $Displays.Count
		MonitorManufacturer = Get-LenovoJoinedPropertyValue -Items $Displays -PropertyName "MonitorMFGName"
		MonitorModel = Get-LenovoJoinedPropertyValue -Items $Displays -PropertyName "MonitorModelName"
		MonitorDeviceID = Get-LenovoJoinedPropertyValue -Items $Displays -PropertyName "DeviceID"
		MonitorEDIDHash = ($EDIDHashes -join ",")
	}
}
function Get-LenovoDockDevice {
	$Result = [PSCustomObject]@{
		Docks = @()
		DockManagerEvents = @()
		CollectionStatus = "Success"
		CollectionMessage = ""
	}

	try {
		$Docks = @(Get-CimInstance -Namespace "root\Lenovo\Dock_Manager" -Query "SELECT * FROM DockDevice" -ErrorAction Stop)
		if ($Docks.Count -eq 0) {
			$Result.CollectionStatus = "NoDockConnected"
			$Result.CollectionMessage = "No Lenovo dock returned by DockDevice."
		}
		else {
			$DockInfos = @()
			$DisplayDevices = @()
			$OptionalMessages = @()

			try {
				$DockInfos = @(Get-CimInstance -Namespace "root\Lenovo\Dock_Manager" -ClassName DockInfo -ErrorAction Stop)
			}
			catch {
				$OptionalMessages += "DockInfo lookup failed: $(Get-SanitizedErrorMessage -Message $_.Exception.Message)"
			}
			try {
				$DisplayDevices = @(Get-CimInstance -Namespace "root\Lenovo\Dock_Manager" -ClassName DockDeviceDisplayPort -ErrorAction Stop)
			}
			catch {
				$OptionalMessages += "Dock display lookup failed: $(Get-SanitizedErrorMessage -Message $_.Exception.Message)"
			}
			try {
				$Result.DockManagerEvents = @(Get-CimInstance -Namespace "root\Lenovo\Dock_Manager" -ClassName DockManager -ErrorAction Stop)
			}
			catch {
				$OptionalMessages += "DockManager event lookup failed: $(Get-SanitizedErrorMessage -Message $_.Exception.Message)"
			}

			if ($OptionalMessages.Count -gt 0) {
				$Result.CollectionMessage = ($OptionalMessages -join " ")
			}

			$Result.Docks = @($Docks | ForEach-Object {
				$Dock = $_
				$DockInfo = Find-LenovoDockRelatedObject -RelatedObjects $DockInfos -Dock $Dock
				$DockDisplayDevices = @(Get-LenovoDockRelatedMatch -RelatedObjects $DisplayDevices -Dock $Dock)
				$FirmwareState = Get-LenovoDockFirmwareState -Dock $Dock -DockInfo $DockInfo
				$MonitorSummary = Get-LenovoDockMonitorSummary -DisplayDevices $DockDisplayDevices

				[PSCustomObject]@{
					DockId = "$($Dock.DockId)"
					SerialNumber = "$($Dock.SerialNumber)"
					MACAddress = "$($Dock.MACAddress)"
					MachineType = "$($Dock.MachineType)"
					InstanceId = "$($Dock.InstanceId)"
					FWVersion = "$($FirmwareState.FWVersion)"
					AvailableFWVersion = "$($FirmwareState.AvailableFWVersion)"
					FWVersionNormalized = "$($FirmwareState.FWVersionNormalized)"
					AvailableFWVersionNormalized = "$($FirmwareState.AvailableFWVersionNormalized)"
					LatestFirmwareFlag = $FirmwareState.LatestFirmwareFlag
					FirmwareUpdateAvailable = $FirmwareState.FirmwareUpdateAvailable
					FirmwareLastUpdateOn = "$($FirmwareState.FirmwareLastUpdateOn)"
					FirmwareInventoryDate = "$($FirmwareState.FirmwareInventoryDate)"
					MonitorConnected = [bool]$MonitorSummary.MonitorConnected
					MonitorCount = [int]$MonitorSummary.MonitorCount
					MonitorManufacturer = "$($MonitorSummary.MonitorManufacturer)"
					MonitorModel = "$($MonitorSummary.MonitorModel)"
					MonitorDeviceID = "$($MonitorSummary.MonitorDeviceID)"
					MonitorEDIDHash = "$($MonitorSummary.MonitorEDIDHash)"
				}
			})
		}
	}
	catch {
		$Result.CollectionStatus = "Error"
		$Result.CollectionMessage = Get-SanitizedErrorMessage -Message $_.Exception.Message
	}

	return $Result
}
function Initialize-LenovoDockCache {
	param (
		[string]$AzureADDeviceID,
		[string]$ComputerName,
		[string]$ManagedDeviceName,
		[string]$ManagedDeviceID
	)

	return [PSCustomObject]@{
		AzureADDeviceID = "$AzureADDeviceID"
		ComputerName = "$ComputerName"
		ManagedDeviceName = "$ManagedDeviceName"
		ManagedDeviceID = "$ManagedDeviceID"
		LastUpdated = $null
		KnownDocks = @()
	}
}
function Get-LenovoDockCache {
	param (
		[string]$Path,
		[string]$AzureADDeviceID,
		[string]$ComputerName,
		[string]$ManagedDeviceName,
		[string]$ManagedDeviceID
	)

	if (Test-Path -LiteralPath $Path) {
		try {
			$Cache = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
			if ($null -eq $Cache.KnownDocks) {
				$Cache | Add-Member -MemberType NoteProperty -Name "KnownDocks" -Value @() -Force
			}
			$Cache.KnownDocks = @($Cache.KnownDocks)
			foreach ($KnownDock in @($Cache.KnownDocks)) {
				if ($null -ne $KnownDock.PSObject.Properties["ProcessId"]) {
					$KnownDock.PSObject.Properties.Remove("ProcessId")
				}
			}
		}
		catch {
			$Cache = Initialize-LenovoDockCache -AzureADDeviceID $AzureADDeviceID -ComputerName $ComputerName -ManagedDeviceName $ManagedDeviceName -ManagedDeviceID $ManagedDeviceID
		}
	}
	else {
		$Cache = Initialize-LenovoDockCache -AzureADDeviceID $AzureADDeviceID -ComputerName $ComputerName -ManagedDeviceName $ManagedDeviceName -ManagedDeviceID $ManagedDeviceID
	}

	$Cache.AzureADDeviceID = "$AzureADDeviceID"
	$Cache.ComputerName = "$ComputerName"
	$Cache.ManagedDeviceName = "$ManagedDeviceName"
	$Cache.ManagedDeviceID = "$ManagedDeviceID"
	return $Cache
}
function Save-LenovoDockCache {
	param (
		[string]$Path,
		[object]$Cache
	)

	$CacheDirectory = Split-Path -Path $Path -Parent
	if (-not (Test-Path -LiteralPath $CacheDirectory)) {
		New-Item -Path $CacheDirectory -ItemType Directory -Force | Out-Null
	}
	$Cache | ConvertTo-Json -Depth 9 | Set-Content -LiteralPath $Path -Encoding UTF8 -Force
}
function Get-LenovoPrimaryDock {
	param (
		[array]$KnownDocks
	)

	return @($KnownDocks) | Sort-Object @{Expression = {[int]$_.SeenCount}; Descending = $true}, @{Expression = {[datetime]$_.LastSeen}; Descending = $true} | Select-Object -First 1
}
function Find-LenovoCachedDock {
	param (
		[array]$KnownDocks,
		[object]$Dock
	)

	$DockId = "$($Dock.DockId)"
	$SerialNumber = "$($Dock.SerialNumber)"
	$MACAddress = "$($Dock.MACAddress)"

	if (-not [string]::IsNullOrWhiteSpace($DockId)) {
		$Match = @($KnownDocks) | Where-Object { $_.DockId -eq $DockId } | Select-Object -First 1
		if ($null -ne $Match) { return $Match }
	}
	if (-not [string]::IsNullOrWhiteSpace($SerialNumber)) {
		$Match = @($KnownDocks) | Where-Object { $_.SerialNumber -eq $SerialNumber } | Select-Object -First 1
		if ($null -ne $Match) { return $Match }
	}
	if (-not [string]::IsNullOrWhiteSpace($MACAddress)) {
		$Match = @($KnownDocks) | Where-Object { $_.MACAddress -eq $MACAddress } | Select-Object -First 1
		if ($null -ne $Match) { return $Match }
	}

	return $null
}
function Sync-LenovoDockCache {
	param (
		[object]$Cache,
		[array]$ConnectedDocks,
		[string]$AzureADDeviceID,
		[string]$ComputerName,
		[string]$ManagedDeviceName,
		[string]$ManagedDeviceID
	)

	$Now = (Get-Date).ToUniversalTime().ToString("o")
	$UsageEvents = @()
	$KnownDocks = @($Cache.KnownDocks)
	$PreviousPrimaryDock = Get-LenovoPrimaryDock -KnownDocks $KnownDocks
	$PreviousPrimaryDockId = $PreviousPrimaryDock.DockId

	foreach ($Dock in @($ConnectedDocks)) {
		$CachedDock = Find-LenovoCachedDock -KnownDocks $KnownDocks -Dock $Dock
		$IsNewDock = $false

		if ($null -eq $CachedDock) {
			$IsNewDock = $true
			$CachedDock = [PSCustomObject]@{
				DockId = "$($Dock.DockId)"
				SerialNumber = "$($Dock.SerialNumber)"
				MACAddress = "$($Dock.MACAddress)"
				MachineType = "$($Dock.MachineType)"
				FWVersion = "$($Dock.FWVersion)"
				AvailableFWVersion = "$($Dock.AvailableFWVersion)"
				FWVersionNormalized = "$($Dock.FWVersionNormalized)"
				AvailableFWVersionNormalized = "$($Dock.AvailableFWVersionNormalized)"
				LatestFirmwareFlag = $Dock.LatestFirmwareFlag
				FirmwareUpdateAvailable = $Dock.FirmwareUpdateAvailable
				FirmwareLastUpdateOn = "$($Dock.FirmwareLastUpdateOn)"
				FirmwareInventoryDate = "$($Dock.FirmwareInventoryDate)"
				FirstSeen = $Now
				LastSeen = $Now
				SeenCount = 0
				IsPrimaryDock = $false
			}
			$KnownDocks += $CachedDock
		}
		if ($null -ne $CachedDock.PSObject.Properties["ProcessId"]) {
			$CachedDock.PSObject.Properties.Remove("ProcessId")
		}

		$CachedDock.DockId = "$($Dock.DockId)"
		$CachedDock.SerialNumber = "$($Dock.SerialNumber)"
		$CachedDock.MACAddress = "$($Dock.MACAddress)"
		$CachedDock.MachineType = "$($Dock.MachineType)"
		$CachedDock.FWVersion = "$($Dock.FWVersion)"
		$CachedDock.AvailableFWVersion = "$($Dock.AvailableFWVersion)"
		$CachedDock.FWVersionNormalized = "$($Dock.FWVersionNormalized)"
		$CachedDock.AvailableFWVersionNormalized = "$($Dock.AvailableFWVersionNormalized)"
		$CachedDock.LatestFirmwareFlag = $Dock.LatestFirmwareFlag
		$CachedDock.FirmwareUpdateAvailable = $Dock.FirmwareUpdateAvailable
		$CachedDock.FirmwareLastUpdateOn = "$($Dock.FirmwareLastUpdateOn)"
		$CachedDock.FirmwareInventoryDate = "$($Dock.FirmwareInventoryDate)"
		$CachedDock.LastSeen = $Now
		$CachedDock.SeenCount = [int]$CachedDock.SeenCount + 1

		if ($IsNewDock) {
			$UsageEvents += [PSCustomObject]@{
				AzureADDeviceID = "$AzureADDeviceID"
				ComputerName = "$ComputerName"
				ManagedDeviceName = "$ManagedDeviceName"
				ManagedDeviceID = "$ManagedDeviceID"
				DockId = "$($CachedDock.DockId)"
				SerialNumber = "$($CachedDock.SerialNumber)"
				MACAddress = "$($CachedDock.MACAddress)"
				EventType = "NewDockSeen"
				PreviousPrimaryDockId = "$PreviousPrimaryDockId"
				IsPrimaryDock = $false
				FirstSeen = "$($CachedDock.FirstSeen)"
				LastSeen = "$($CachedDock.LastSeen)"
				SeenCount = [int]$CachedDock.SeenCount
				InventoryDate = $Now
			}
		}

		if ((-not [string]::IsNullOrWhiteSpace($PreviousPrimaryDockId)) -and ($CachedDock.DockId -ne $PreviousPrimaryDockId)) {
			$UsageEvents += [PSCustomObject]@{
				AzureADDeviceID = "$AzureADDeviceID"
				ComputerName = "$ComputerName"
				ManagedDeviceName = "$ManagedDeviceName"
				ManagedDeviceID = "$ManagedDeviceID"
				DockId = "$($CachedDock.DockId)"
				SerialNumber = "$($CachedDock.SerialNumber)"
				MACAddress = "$($CachedDock.MACAddress)"
				EventType = "DifferentDockSeen"
				PreviousPrimaryDockId = "$PreviousPrimaryDockId"
				IsPrimaryDock = $false
				FirstSeen = "$($CachedDock.FirstSeen)"
				LastSeen = "$($CachedDock.LastSeen)"
				SeenCount = [int]$CachedDock.SeenCount
				InventoryDate = $Now
			}
		}
	}

	$NewPrimaryDock = Get-LenovoPrimaryDock -KnownDocks $KnownDocks
	foreach ($KnownDock in @($KnownDocks)) {
		$KnownDock.IsPrimaryDock = ($KnownDock.DockId -eq $NewPrimaryDock.DockId)
	}

	if (($null -ne $NewPrimaryDock) -and ($NewPrimaryDock.DockId -ne $PreviousPrimaryDockId)) {
		$UsageEvents += [PSCustomObject]@{
			AzureADDeviceID = "$AzureADDeviceID"
			ComputerName = "$ComputerName"
			ManagedDeviceName = "$ManagedDeviceName"
			ManagedDeviceID = "$ManagedDeviceID"
			DockId = "$($NewPrimaryDock.DockId)"
			SerialNumber = "$($NewPrimaryDock.SerialNumber)"
			MACAddress = "$($NewPrimaryDock.MACAddress)"
			EventType = "PrimaryDockChanged"
			PreviousPrimaryDockId = "$PreviousPrimaryDockId"
			IsPrimaryDock = $true
			FirstSeen = "$($NewPrimaryDock.FirstSeen)"
			LastSeen = "$($NewPrimaryDock.LastSeen)"
			SeenCount = [int]$NewPrimaryDock.SeenCount
			InventoryDate = $Now
		}
	}

	$Cache.KnownDocks = @($KnownDocks)
	$Cache.LastUpdated = $Now

	return [PSCustomObject]@{
		Cache = $Cache
		UsageEvents = @($UsageEvents)
		PrimaryDock = $NewPrimaryDock
		InventoryDate = $Now
	}
}
function Get-LenovoLatestDateString {
	param (
		[array]$Items,
		[string]$PropertyName
	)

	$DateItems = @($Items | ForEach-Object {
		$RawValue = ""
		if ($null -ne $_.PSObject.Properties[$PropertyName]) {
			$RawValue = "$($_.PSObject.Properties[$PropertyName].Value)"
		}
		if (-not [string]::IsNullOrWhiteSpace($RawValue)) {
			$ParsedDate = [datetime]::MinValue
			if ([datetime]::TryParse($RawValue, [ref]$ParsedDate)) {
				[PSCustomObject]@{
					RawValue = $RawValue
					ParsedDate = $ParsedDate
				}
			}
		}
	})

	return "$(($DateItems | Sort-Object ParsedDate -Descending | Select-Object -First 1).RawValue)"
}
function Get-LenovoWarrantyEntitlementSummary {
	param (
		[array]$WarrantyElements
	)

	$Entitlements = @($WarrantyElements | ForEach-Object {
		$Parts = @("$($_.ID)", "$($_.Name)", "$($_.Type)", "$($_.End)") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
		($Parts -join "|")
	} | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)

	return ($Entitlements -join ";")
}
function Get-LenovoDeviceHealthInventory {
	param (
		[string]$AzureADDeviceID,
		[string]$ComputerName,
		[string]$ManagedDeviceName,
		[string]$ManagedDeviceID
	)

	$InventoryDate = (Get-Date).ToUniversalTime().ToString("o")
	$CollectionMessages = @()
	$LenovoProviderAvailable = $false

	$WarrantyCollectionStatus = "NotCollected"
	$BatteryCollectionStatus = "NotCollected"
	$OdometerCollectionStatus = "NotCollected"

	$WarrantyInformation = $null
	$WarrantyElements = @()
	$Battery = $null
	$Odometer = $null

	try {
		$WarrantyInformation = Get-CimInstance -Namespace "root\Lenovo" -ClassName Lenovo_WarrantyInformation -ErrorAction Stop | Select-Object -First 1
		$WarrantyCollectionStatus = if ($null -ne $WarrantyInformation) { "Success" } else { "NoData" }
		$LenovoProviderAvailable = $true
	}
	catch {
		$WarrantyCollectionStatus = "Error"
		$CollectionMessages += "WarrantyInformation lookup failed: $(Get-SanitizedErrorMessage -Message $_.Exception.Message)"
	}
	try {
		$WarrantyElements = @(Get-CimInstance -Namespace "root\Lenovo" -ClassName Lenovo_WarrantyElement -ErrorAction Stop)
		if (($WarrantyCollectionStatus -eq "Success") -and ($WarrantyElements.Count -eq 0)) {
			$WarrantyCollectionStatus = "Partial"
		}
		$LenovoProviderAvailable = $true
	}
	catch {
		if ($WarrantyCollectionStatus -eq "Success") {
			$WarrantyCollectionStatus = "Partial"
		}
		$CollectionMessages += "WarrantyElement lookup failed: $(Get-SanitizedErrorMessage -Message $_.Exception.Message)"
	}
	try {
		$Battery = Get-CimInstance -Namespace "root\Lenovo" -ClassName Lenovo_Battery -ErrorAction Stop | Select-Object -First 1
		$BatteryCollectionStatus = if ($null -ne $Battery) { "Success" } else { "NoData" }
		$LenovoProviderAvailable = $true
	}
	catch {
		$BatteryCollectionStatus = "Error"
		$CollectionMessages += "Battery lookup failed: $(Get-SanitizedErrorMessage -Message $_.Exception.Message)"
	}
	try {
		$Odometer = Get-CimInstance -Namespace "root\Lenovo" -ClassName Lenovo_Odometer -ErrorAction Stop | Select-Object -First 1
		$OdometerCollectionStatus = if ($null -ne $Odometer) { "Success" } else { "NoData" }
		$LenovoProviderAvailable = $true
	}
	catch {
		$OdometerCollectionStatus = "Error"
		$CollectionMessages += "Odometer lookup failed: $(Get-SanitizedErrorMessage -Message $_.Exception.Message)"
	}

	$PremierSupportElements = @($WarrantyElements | Where-Object { "$($_.Name)" -like "*Premier*" })
	$BatteryWarrantyElements = @($WarrantyElements | Where-Object { "$($_.Name)" -like "*Battery*" })
	$BatteryDesignCapacity = ConvertTo-LenovoNumber -Value $Battery.DesignCapacity
	$BatteryFullChargeCapacity = ConvertTo-LenovoNumber -Value $Battery.FullChargeCapacity
	$BatteryCapacityPercent = $null
	if (($null -ne $BatteryDesignCapacity) -and ($BatteryDesignCapacity -gt 0) -and ($null -ne $BatteryFullChargeCapacity)) {
		$BatteryCapacityPercent = [Math]::Round(($BatteryFullChargeCapacity / $BatteryDesignCapacity) * 100, 2)
	}

	return [PSCustomObject]@{
		AzureADDeviceID = "$AzureADDeviceID"
		ComputerName = "$ComputerName"
		ManagedDeviceName = "$ManagedDeviceName"
		ManagedDeviceID = "$ManagedDeviceID"
		LenovoProviderAvailable = [bool]$LenovoProviderAvailable
		WarrantyCollectionStatus = "$WarrantyCollectionStatus"
		BatteryCollectionStatus = "$BatteryCollectionStatus"
		OdometerCollectionStatus = "$OdometerCollectionStatus"
		CollectionMessage = "$($CollectionMessages -join ' ')"
		WarrantySerialNumber = "$($WarrantyInformation.SerialNumber)"
		WarrantyProduct = "$($WarrantyInformation.Product)"
		WarrantyStartDate = "$($WarrantyInformation.StartDate)"
		WarrantyEndDate = "$($WarrantyInformation.EndDate)"
		WarrantyLastUpdateTime = "$($WarrantyInformation.LastUpdateTime)"
		WarrantyEntitlementCount = @($WarrantyElements).Count
		WarrantyEntitlements = "$(Get-LenovoWarrantyEntitlementSummary -WarrantyElements $WarrantyElements)"
		PremierSupportEndDate = "$(Get-LenovoLatestDateString -Items $PremierSupportElements -PropertyName 'End')"
		BatteryWarrantyEndDate = "$(Get-LenovoLatestDateString -Items $BatteryWarrantyElements -PropertyName 'End')"
		BatteryHealth = "$($Battery.BatteryHealth)"
		BatteryCondition = "$($Battery.Condition)"
		BatteryCycleCount = ConvertTo-LenovoInteger -Value $Battery.CycleCount
		BatteryDesignCapacity = "$($Battery.DesignCapacity)"
		BatteryFullChargeCapacity = "$($Battery.FullChargeCapacity)"
		BatteryCapacityPercent = $BatteryCapacityPercent
		BatteryFirstUseDate = "$($Battery.FirstUseDate)"
		BatteryManufactureDate = "$($Battery.ManufactureDate)"
		BatteryManufacturer = "$($Battery.Manufacturer)"
		BatteryFRUPartNumber = "$($Battery.FRUPartNumber)"
		BatteryFirmwareVersion = "$($Battery.FirmwareVersion)"
		OdometerSystemID = "$($Odometer.SystemID)"
		OdometerBatteryCycles = "$($Odometer.Battery_cycles)"
		OdometerCPUUptime = ConvertTo-LenovoInteger -Value $Odometer.CPU_Uptime
		OdometerThermalEvents = ConvertTo-LenovoInteger -Value $Odometer.Thermal_events
		OdometerShockEvents = ConvertTo-LenovoInteger -Value $Odometer.Shock_events
		OdometerSSDReadWriteCount = "$($Odometer.SSD_Read_Write_count)"
		InventoryDate = $InventoryDate
	}
}
#endregion lenovo functions
#endregion functions

#region script
#region common
# ***** DO NOT EDIT IN THIS REGION *****
# Check if device is in "provisioning day" and skip inventory until next day if true
$JoinDate = Get-AzureADJoinDate
if ($null -ne $JoinDate) {
	$DelayDate = $JoinDate.AddDays(1)
	$CompareDate = ($Date - $DelayDate)
	if ($CompareDate.TotalDays -ge 0){
		# Randomize over X minutes to spread load on Azure Function if enabled
		if ($RandomiseCollectionInt -eq $true){
			Write-Output "Randomzing execution time"
			$RandomizerSeconds = $RandomizeMinutes * 60
			$ExecuteInSeconds = (Get-Random -Maximum $RandomizerSeconds -Minimum 1)
			Start-Sleep -Seconds $ExecuteInSeconds
		}
	}
	else {
		Write-Output "Device recently added, inventory not to be runned before $Delaydate"
		Exit 0
	}
}
else {
	Write-Output "Azure AD join date unavailable, skipping provisioning-day delay and continuing inventory collection"
}

#Get Common data for App and Device Inventory:
#Get Intune DeviceID and ManagedDeviceName
try {
	if (@(Get-ChildItem HKLM:SOFTWARE\Microsoft\Enrollments\ -Recurse -ErrorAction Stop | Where-Object { $_.PSChildName -eq 'MS DM Server' })) {
		$MSDMServerInfo = Get-ChildItem HKLM:SOFTWARE\Microsoft\Enrollments\ -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -eq 'MS DM Server'  }
		$ManagedDeviceInfo = Get-ItemProperty -LiteralPath "Registry::$($MSDMServerInfo)" -ErrorAction SilentlyContinue
	}
}
catch {
	$ManagedDeviceInfo = $null
	Write-Output "Managed device enrollment lookup failed: $($_.Exception.Message)"
}
$ManagedDeviceName = $ManagedDeviceInfo.EntDeviceName
$ManagedDeviceID = $ManagedDeviceInfo.EntDMID
$AzureADDeviceID = Get-AzureADDeviceID
try {
	$AzureADTenantID = Get-AzureADTenantID
}
catch {
	$AzureADTenantID = $null
	Write-Output "Azure AD tenant ID lookup failed: $($_.Exception.Message)"
}

#Get Computer Info
try {
	$ComputerInfo = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
}
catch {
	$ComputerInfo = [PSCustomObject]@{}
	Write-Output "Computer system lookup failed: $($_.Exception.Message)"
}
$ComputerName = $ComputerInfo.Name
$ComputerManufacturer = $ComputerInfo.Manufacturer

if ($ComputerManufacturer -match "HP|Hewlett-Packard") {
	$ComputerManufacturer = "HP"
}
#endregion common

#region DEVICEINVENTORY
if ($CollectDeviceInventory) {

	# Get Windows Update Service Settings
	try {
		$DefaultAUService = (New-Object -ComObject "Microsoft.Update.ServiceManager").Services | Where-Object { $_.isDefaultAUService -eq $True } | Select-Object Name
	}
	catch {
		$DefaultAUService = $null
		Write-Output "Windows Update service lookup failed: $($_.Exception.Message)"
	}
	try {
		$AUMeteredNetwork = (Get-ItemProperty -Path HKLM:\Software\Microsoft\WindowsUpdate\UX\Settings\ -ErrorAction Stop).AllowAutoWindowsUpdateDownloadOverMeteredNetwork
	}
	catch {
		$AUMeteredNetwork = $null
		Write-Output "Windows Update metered-network lookup failed: $($_.Exception.Message)"
	}
	if ($AUMeteredNetwork -eq "0") {
		$AUMetered = "false"
	} else { $AUMetered = "true" }


	# Get Computer Inventory Information
	try {
		$ComputerOSInfo = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
	}
	catch {
		$ComputerOSInfo = [PSCustomObject]@{}
		Write-Output "Operating system lookup failed: $($_.Exception.Message)"
	}
	try {
		$ComputerBiosInfo = Get-CimInstance -ClassName Win32_Bios -ErrorAction Stop
	}
	catch {
		$ComputerBiosInfo = [PSCustomObject]@{}
		Write-Output "BIOS lookup failed: $($_.Exception.Message)"
	}
	$ComputerModel = $ComputerInfo.Model
	$ComputerLastBoot = $ComputerOSInfo.LastBootUpTime
	$ComputerUptime = [int](New-TimeSpan -Start $ComputerLastBoot -End $Date).Days
	$ComputerInstallDate = $ComputerOSInfo.InstallDate
	$DisplayVersion = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name DisplayVersion -ErrorAction SilentlyContinue).DisplayVersion
	if ([string]::IsNullOrEmpty($DisplayVersion)) {
		$ComputerWindowsVersion = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name ReleaseId).ReleaseId
	} else {
		$ComputerWindowsVersion = $DisplayVersion
	}
	$ComputerOSName = $ComputerOSInfo.Caption
	$ComputerSystemSkuNumber = $ComputerInfo.SystemSKUNumber
	$ComputerSerialNr = $ComputerBiosInfo.SerialNumber
	$ComputerBiosUUID = Get-CimInstance Win32_ComputerSystemProduct | Select-Object -ExpandProperty UUID
	$ComputerBiosVersion = $ComputerBiosInfo.SMBIOSBIOSVersion
	$ComputerBiosDate = $ComputerBiosInfo.ReleaseDate
	$ComputerFirmwareType = $env:firmware_type
	$PCSystemType = $ComputerInfo.PCSystemType
		switch ($PCSystemType){
			0 {$ComputerPCSystemType = "Unspecified"}
			1 {$ComputerPCSystemType = "Desktop"}
			2 {$ComputerPCSystemType = "Laptop"}
			3 {$ComputerPCSystemType = "Workstation"}
			4 {$ComputerPCSystemType = "EnterpriseServer"}
			5 {$ComputerPCSystemType = "SOHOServer"}
			6 {$ComputerPCSystemType = "AppliancePC"}
			7 {$ComputerPCSystemType = "PerformanceServer"}
			8 {$ComputerPCSystemType = "Maximum"}
			default {$ComputerPCSystemType = "Unspecified"}
		}
	$PCSystemTypeEx = $ComputerInfo.PCSystemTypeEx
		switch ($PCSystemTypeEx){
			0 {$ComputerPCSystemTypeEx = "Unspecified"}
			1 {$ComputerPCSystemTypeEx = "Desktop"}
			2 {$ComputerPCSystemTypeEx = "Laptop"}
			3 {$ComputerPCSystemTypeEx = "Workstation"}
			4 {$ComputerPCSystemTypeEx = "EnterpriseServer"}
			5 {$ComputerPCSystemTypeEx = "SOHOServer"}
			6 {$ComputerPCSystemTypeEx = "AppliancePC"}
			7 {$ComputerPCSystemTypeEx = "PerformanceServer"}
			8 {$ComputerPCSystemTypeEx = "Slate"}
			9 {$ComputerPCSystemTypeEx = "Maximum"}
			default {$ComputerPCSystemTypeEx = "Unspecified"}
		}

	$ComputerPhysicalMemory = [Math]::Round(($ComputerInfo.TotalPhysicalMemory / 1GB))
	$ComputerOSBuild = $ComputerOSInfo.BuildNumber
	$ComputerOSRevision = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name UBR).UBR
	$ComputerCPU = Get-CimInstance win32_processor | Select-Object Name, Manufacturer, NumberOfCores, NumberOfLogicalProcessors
	$ComputerProcessorManufacturer = $ComputerCPU.Manufacturer | Get-Unique
	$ComputerProcessorName = $ComputerCPU.Name | Get-Unique
	$ComputerNumberOfCores = $ComputerCPU.NumberOfCores | Get-Unique
	$ComputerNumberOfLogicalProcessors = $ComputerCPU.NumberOfLogicalProcessors | Get-Unique
	try {
		$ComputerSystemInformation = Get-CimInstance -ClassName MS_SystemInformation -NameSpace root\WMI -ErrorAction Stop
		$ComputerSystemSKU = $ComputerSystemInformation.SystemSku.Trim()
	}
	catch {
		$ComputerSystemInformation = $null
		$ComputerSystemSKU = $null
		Write-Output "System SKU lookup failed: $($_.Exception.Message)"
	}

	try {
		$TPMValues = Get-Tpm -ErrorAction SilentlyContinue | Select-Object -Property TPMReady, TPMPresent, TPMEnabled, TPMActivated, ManagedAuthLevel
	} catch {
		$TPMValues = $null
	}

	try {
		$ComputerTPMThumbprint = (Get-TpmEndorsementKeyInfo).AdditionalCertificates.Thumbprint
	} catch {
		$ComputerTPMThumbprint = $null
	}

	try {
		$BitLockerInfo = Get-BitLockerVolume -MountPoint $env:SystemDrive | Select-Object -Property *
	} catch {
		$BitLockerInfo = $null
	}

	$ComputerTPMReady = $TPMValues.TPMReady
	$ComputerTPMPresent = $TPMValues.TPMPresent
	$ComputerTPMEnabled = $TPMValues.TPMEnabled
	$ComputerTPMActivated = $TPMValues.TPMActivated

	$ComputerBitlockerCipher = $BitLockerInfo.EncryptionMethod
	$ComputerBitlockerStatus = $BitLockerInfo.VolumeStatus
	$ComputerBitlockerProtection = $BitLockerInfo.ProtectionStatus
	$ComputerDefaultAUService = $DefaultAUService.Name
	$ComputerAUMetered = $AUMetered

	# Get BIOS information
	# Determine manufacturer specific information
	try {
		switch -Wildcard ($ComputerManufacturer) {
			"*Microsoft*" {
				$ComputerManufacturer = "Microsoft"
				$ComputerModel = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop | Select-Object -ExpandProperty Model).Trim()
				$ComputerSystemSKU = Get-CimInstance -Namespace root\wmi -ClassName MS_SystemInformation -ErrorAction Stop | Select-Object -ExpandProperty SystemSKU
			}
			"*HP*" {
				$ComputerModel = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop | Select-Object -ExpandProperty Model).Trim()
				$ComputerSystemSKU = (Get-CimInstance -ClassName MS_SystemInformation -NameSpace root\WMI -ErrorAction Stop).BaseBoardProduct.Trim()

				# Obtain current BIOS release
				$CurrentBIOSProperties = (Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop | Select-Object -Property *)

				# Detect new versus old BIOS formats
				switch -wildcard ($($CurrentBIOSProperties.SMBIOSBIOSVersion)) {
					"*ver*" {
						if ($CurrentBIOSProperties.SMBIOSBIOSVersion -match '.F.\d+$') {
							$ComputerBiosVersion = ($CurrentBIOSProperties.SMBIOSBIOSVersion -split "Ver.")[1].Trim()
						} else {
							$ComputerBiosVersion = [System.Version]::Parse(($CurrentBIOSProperties.SMBIOSBIOSVersion).TrimStart($CurrentBIOSProperties.SMBIOSBIOSVersion.Split(".")[0]).TrimStart(".").Trim().Split(" ")[0])
						}
					}
					default {
						$ComputerBiosVersion = "$($CurrentBIOSProperties.SystemBiosMajorVersion).$($CurrentBIOSProperties.SystemBiosMinorVersion)"
					}
				}
			}
			"*Dell*" {
				$ComputerManufacturer = "Dell"
				$ComputerModel = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop | Select-Object -ExpandProperty Model).Trim()
				$ComputerSystemSKU = (Get-CimInstance -ClassName MS_SystemInformation -NameSpace root\WMI -ErrorAction Stop).SystemSku.Trim()

				# Obtain current BIOS release
				$ComputerBiosVersion = (Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop | Select-Object -ExpandProperty SMBIOSBIOSVersion).Trim()
			}
			"*Lenovo*" {
				$ComputerManufacturer = "Lenovo"
				$ComputerModel = (Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction Stop | Select-Object -ExpandProperty Version).Trim()
				$ComputerSystemSKU = ((Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop | Select-Object -ExpandProperty Model).SubString(0, 4)).Trim()

				# Obtain current BIOS release
				$CurrentBIOSProperties = (Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop | Select-Object -Property *)

				# Obtain current BIOS release
				#$ComputerBiosVersion = ((Get-CimInstance -ClassName Win32_BIOS | Select-Object -Property *).SMBIOSBIOSVersion).SubString(0, 8)
				$ComputerBiosVersion = "$($CurrentBIOSProperties.SystemBiosMajorVersion).$($CurrentBIOSProperties.SystemBiosMinorVersion)"
			}
		}
	}
	catch {
		Write-Output "Manufacturer-specific BIOS lookup failed: $($_.Exception.Message)"
	}

	#Get network adapters
	$NetWorkArray = @()

	try {
		$CurrentNetAdapters = Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' }
	}
	catch {
		$CurrentNetAdapters = @()
		Write-Output "Network adapter lookup failed: $($_.Exception.Message)"
	}

	foreach ($CurrentNetAdapter in $CurrentNetAdapters) {
		try {
			$IPConfiguration = Get-NetIPConfiguration -InterfaceIndex $CurrentNetAdapter[0].ifIndex -ErrorAction Stop
		}
		catch {
			$IPConfiguration = $null
			Write-Output "IP configuration lookup failed for interface $($CurrentNetAdapter.InterfaceAlias): $($_.Exception.Message)"
		}
		$ComputerNetInterfaceDescription = $CurrentNetAdapter.InterfaceDescription
		$ComputerNetProfileName = $IPConfiguration.NetProfile.Name
		$ComputerNetIPv4Adress = $IPConfiguration.IPv4Address.IPAddress
		$ComputerNetInterfaceAlias = $CurrentNetAdapter.InterfaceAlias
		$ComputerNetIPv4DefaultGateway = $IPConfiguration.IPv4DefaultGateway.NextHop
		$ComputerNetMacAddress = $CurrentNetAdapter.MacAddress

		$tempnetwork = New-Object -TypeName PSObject
		$tempnetwork | Add-Member -MemberType NoteProperty -Name "NetInterfaceDescription" -Value "$ComputerNetInterfaceDescription" -Force
		$tempnetwork | Add-Member -MemberType NoteProperty -Name "NetProfileName" -Value "$ComputerNetProfileName" -Force
		$tempnetwork | Add-Member -MemberType NoteProperty -Name "NetIPv4Adress" -Value "$ComputerNetIPv4Adress" -Force
		$tempnetwork | Add-Member -MemberType NoteProperty -Name "NetInterfaceAlias" -Value "$ComputerNetInterfaceAlias" -Force
		$tempnetwork | Add-Member -MemberType NoteProperty -Name "NetIPv4DefaultGateway" -Value "$ComputerNetIPv4DefaultGateway" -Force
		$tempnetwork | Add-Member -MemberType NoteProperty -Name "MacAddress" -Value "$ComputerNetMacAddress" -Force
		$NetWorkArray += $tempnetwork
	}
	[System.Collections.ArrayList]$NetWorkArrayList = $NetWorkArray

	# Get Disk Health
	$DiskArray = @()
	[System.Collections.ArrayList]$DiskHealthArrayList = $DiskArray
	try {
		$Disks = Get-PhysicalDisk -ErrorAction Stop | Where-Object { $_.BusType -match "NVMe|SATA|SAS|ATAPI|RAID" }
	}
	catch {
		$Disks = @()
		Write-Output "Physical disk lookup failed: $($_.Exception.Message)"
	}

	# Loop through each disk
	foreach ($Disk in ($Disks | Sort-Object DeviceID)) {
		try {
			# Obtain disk health information from current disk
			$DiskHealth = Get-PhysicalDisk -UniqueId $($Disk.UniqueId) -ErrorAction Stop | Get-StorageReliabilityCounter -ErrorAction Stop | Select-Object -Property Wear, ReadErrorsTotal, ReadErrorsUncorrected, WriteErrorsTotal, WriteErrorsUncorrected, Temperature, TemperatureMax

			# Obtain media type
			$DriveDetails = Get-PhysicalDisk -UniqueId $($Disk.UniqueId) -ErrorAction Stop | Select-Object MediaType, HealthStatus
			$DriveMediaType = $DriveDetails.MediaType
			$DriveHealthState = $DriveDetails.HealthStatus
			if (($null -ne $DiskHealth.Temperature) -and ($null -ne $DiskHealth.TemperatureMax)) {
				$DiskTempDelta = [int]$($DiskHealth.Temperature) - [int]$($DiskHealth.TemperatureMax)
			}
			else {
				$DiskTempDelta = $null
			}
		}
		catch {
			$DiskHealth = $null
			$DriveMediaType = $Disk.MediaType
			$DriveHealthState = $Disk.HealthStatus
			$DiskTempDelta = $null
			Write-Output "Disk reliability lookup failed for disk $($Disk.DeviceID): $($_.Exception.Message)"
		}

		# Create custom PSObject
		$DiskHealthState = new-object -TypeName PSObject
		$DiskWear = if ($null -ne $DiskHealth.Wear) { [int]($DiskHealth.Wear) } else { $null }
		$DiskReadErrorsTotal = if ($null -ne $DiskHealth.ReadErrorsTotal) { [int]($DiskHealth.ReadErrorsTotal) } else { $null }

		# Create disk entry
		$DiskHealthState | Add-Member -MemberType NoteProperty -Name "Disk Number" -Value $Disk.DeviceID
		$DiskHealthState | Add-Member -MemberType NoteProperty -Name "FriendlyName" -Value $($Disk.FriendlyName)
		$DiskHealthState | Add-Member -MemberType NoteProperty -Name "HealthStatus" -Value $DriveHealthState
		$DiskHealthState | Add-Member -MemberType NoteProperty -Name "MediaType" -Value $DriveMediaType
		$DiskHealthState | Add-Member -MemberType NoteProperty -Name "Disk Wear" -Value $DiskWear
		$DiskHealthState | Add-Member -MemberType NoteProperty -Name "Disk $($Disk.DeviceID) Read Errors" -Value $DiskReadErrorsTotal
		$DiskHealthState | Add-Member -MemberType NoteProperty -Name "Disk $($Disk.DeviceID) Temperature Delta" -Value $DiskTempDelta
		$DiskHealthState | Add-Member -MemberType NoteProperty -Name "Disk $($Disk.DeviceID) ReadErrorsUncorrected" -Value $($DiskHealth.ReadErrorsUncorrected)
		$DiskHealthState | Add-Member -MemberType NoteProperty -Name "Disk $($Disk.DeviceID) ReadErrorsTotal" -Value $($DiskHealth.ReadErrorsTotal)
		$DiskHealthState | Add-Member -MemberType NoteProperty -Name "Disk $($Disk.DeviceID) WriteErrorsUncorrected" -Value $($DiskHealth.WriteErrorsUncorrected)
		$DiskHealthState | Add-Member -MemberType NoteProperty -Name "Disk $($Disk.DeviceID) WriteErrorsTotal" -Value $($DiskHealth.WriteErrorsTotal)
		$DiskHealthState | Add-Member -MemberType NoteProperty -Name "ReadErrorsUncorrected" -Value $($DiskHealth.ReadErrorsUncorrected)
		$DiskHealthState | Add-Member -MemberType NoteProperty -Name "ReadErrorsTotal" -Value $($DiskHealth.ReadErrorsTotal)
		$DiskHealthState | Add-Member -MemberType NoteProperty -Name "WriteErrorsUncorrected" -Value $($DiskHealth.WriteErrorsUncorrected)
		$DiskHealthState | Add-Member -MemberType NoteProperty -Name "WriteErrorsTotal" -Value $($DiskHealth.WriteErrorsTotal)

		$DiskArray += $DiskHealthState
		[System.Collections.ArrayList]$DiskHealthArrayList = $DiskArray
	}


	# Create JSON to Upload to Log Analytics
	$Inventory = New-Object System.Object
	$Inventory | Add-Member -MemberType NoteProperty -Name "ManagedDeviceName" -Value "$ManagedDeviceName" -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "ManagedDeviceID" -Value "$ManagedDeviceID" -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "AzureADDeviceID" -Value "$AzureADDeviceID" -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "ComputerName" -Value "$ComputerName" -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "Model" -Value "$ComputerModel" -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "Manufacturer" -Value "$ComputerManufacturer" -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "PCSystemType" -Value "$ComputerPCSystemType" -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "PCSystemTypeEx" -Value "$ComputerPCSystemTypeEx" -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "ComputerUpTime" -Value "$ComputerUptime" -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "LastBoot" -Value "$ComputerLastBoot" -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "InstallDate" -Value "$ComputerInstallDate" -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "WindowsVersion" -Value "$ComputerWindowsVersion" -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "DefaultAUService" -Value "$ComputerDefaultAUService" -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "AUMetered" -Value "$ComputerAUMetered" -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "SystemSkuNumber" -Value "$ComputerSystemSkuNumber" -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "SerialNumber" -Value "$ComputerSerialNr" -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "SMBIOSUUID" -Value "$ComputerBiosUUID" -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "BiosVersion" -Value "$ComputerBiosVersion" -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "BiosDate" -Value "$ComputerBiosDate" -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "SystemSKU" -Value "$ComputerSystemSKU" -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "FirmwareType" -Value "$ComputerFirmwareType" -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "Memory" -Value "$ComputerPhysicalMemory" -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "OSBuild" -Value "$ComputerOSBuild" -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "OSRevision" -Value "$ComputerOSRevision" -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "OSName" -Value "$ComputerOSName" -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "CPUManufacturer" -Value "$ComputerProcessorManufacturer" -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "CPUName" -Value "$ComputerProcessorName" -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "CPUCores" -Value "$ComputerNumberOfCores" -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "CPULogical" -Value "$ComputerNumberOfLogicalProcessors" -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "TPMReady" -Value "$ComputerTPMReady" -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "TPMPresent" -Value "$ComputerTPMPresent" -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "TPMEnabled" -Value "$ComputerTPMEnabled" -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "TPMActived" -Value "$ComputerTPMActivated" -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "TPMThumbprint" -Value "$ComputerTPMThumbprint" -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "BitlockerCipher" -Value "$ComputerBitlockerCipher" -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "BitlockerVolumeStatus" -Value "$ComputerBitlockerStatus" -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "BitlockerProtectionStatus" -Value "$ComputerBitlockerProtection" -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "NetworkAdapters" -Value $NetWorkArrayList -Force
	$Inventory | Add-Member -MemberType NoteProperty -Name "DiskHealth" -Value $DiskHealthArrayList -Force


	$DeviceInventory = $Inventory

}
#endregion DEVICEINVENTORY

#region APPINVENTORY
if ($CollectAppInventory) {
	#$AppLog = "AppInventory"

	#Get SID of current interactive users
	$CurrentLoggedOnUser = (Get-CimInstance win32_computersystem).UserName
	if (-not ([string]::IsNullOrEmpty($CurrentLoggedOnUser))) {
		$AdObj = New-Object System.Security.Principal.NTAccount($CurrentLoggedOnUser)
		$strSID = $AdObj.Translate([System.Security.Principal.SecurityIdentifier])
		$UserSid = $strSID.Value
	} else {
		$UserSid = $null
	}

	#Get Apps for system and current user
	$MyApps = Get-InstalledApplication -UserSid $UserSid
	$UniqueApps = ($MyApps | Group-Object Displayname | Where-Object { $_.Count -eq 1 }).Group
	$DuplicatedApps = ($MyApps | Group-Object Displayname | Where-Object { $_.Count -gt 1 }).Group
	$NewestDuplicateApp = ($DuplicatedApps | Group-Object DisplayName) | ForEach-Object {
		$_.Group | Sort-Object `
			@{ Expression = { $ParsedVersion = $null; [version]::TryParse([string]$_.DisplayVersion, [ref]$ParsedVersion) }; Descending = $true },
			@{ Expression = { $ParsedVersion = $null; if ([version]::TryParse([string]$_.DisplayVersion, [ref]$ParsedVersion)) { $ParsedVersion } else { [version]"0.0" } }; Descending = $true },
			@{ Expression = { $_.DisplayVersion }; Descending = $true },
			@{ Expression = { $_.InstallDate }; Descending = $true },
			@{ Expression = { $_.PSPath }; Descending = $false } |
			Select-Object -First 1
	}
	$CleanAppList = $UniqueApps + $NewestDuplicateApp | Sort-Object DisplayName

	$AppArray = @()
	foreach ($App in $CleanAppList) {
		$tempapp = New-Object -TypeName PSObject
		$tempapp | Add-Member -MemberType NoteProperty -Name "ComputerName" -Value "$ComputerName" -Force
		$tempapp | Add-Member -MemberType NoteProperty -Name "ManagedDeviceName" -Value "$ManagedDeviceName" -Force
		$tempapp | Add-Member -MemberType NoteProperty -Name "ManagedDeviceID" -Value "$ManagedDeviceID" -Force
		$tempapp | Add-Member -MemberType NoteProperty -Name "AzureADDeviceID" -Value "$AzureADDeviceID" -Force
		$tempapp | Add-Member -MemberType NoteProperty -Name "AppName" -Value $App.DisplayName -Force
		$tempapp | Add-Member -MemberType NoteProperty -Name "AppVersion" -Value $App.DisplayVersion -Force
		$tempapp | Add-Member -MemberType NoteProperty -Name "AppInstallDate" -Value $App.InstallDate -Force -ErrorAction SilentlyContinue
		$tempapp | Add-Member -MemberType NoteProperty -Name "AppPublisher" -Value $App.Publisher -Force
		$tempapp | Add-Member -MemberType NoteProperty -Name "AppUninstallString" -Value $App.UninstallString -Force
		$tempapp | Add-Member -MemberType NoteProperty -Name "AppUninstallRegPath" -Value $app.PSPath.Split("::")[-1]
		$AppArray += $tempapp
	}

	$AppInventory = $AppArray
}
#endregion APPINVENTORY

#region LENOVODEVICEHEALTHINVENTORY
$LenovoDeviceHealthInventory = $null
if ($CollectLenovoDeviceHealthInventory -and ($ComputerManufacturer -like "*Lenovo*")) {
	$LenovoDeviceHealthInventory = Get-LenovoDeviceHealthInventory -AzureADDeviceID $AzureADDeviceID -ComputerName $ComputerName -ManagedDeviceName $ManagedDeviceName -ManagedDeviceID $ManagedDeviceID
}
#endregion LENOVODEVICEHEALTHINVENTORY

#region LENOVODOCKINVENTORY
$LenovoDockInventory = @()
$LenovoDockUsageInventory = @()
$LenovoDockStatusInventory = $null
if ($CollectLenovoDockInventory -and ($ComputerManufacturer -like "*Lenovo*")) {
	$LenovoDockQueryResult = Get-LenovoDockDevice
	$LenovoDockCache = Get-LenovoDockCache -Path $LenovoDockCachePath -AzureADDeviceID $AzureADDeviceID -ComputerName $ComputerName -ManagedDeviceName $ManagedDeviceName -ManagedDeviceID $ManagedDeviceID
	$LenovoDockInventoryDate = (Get-Date).ToUniversalTime().ToString("o")
	$ConnectedLenovoDocks = @($LenovoDockQueryResult.Docks)

	if ($LenovoDockQueryResult.CollectionStatus -eq "Success") {
		$LenovoDockCacheUpdate = Sync-LenovoDockCache -Cache $LenovoDockCache -ConnectedDocks $ConnectedLenovoDocks -AzureADDeviceID $AzureADDeviceID -ComputerName $ComputerName -ManagedDeviceName $ManagedDeviceName -ManagedDeviceID $ManagedDeviceID
		$LenovoDockCache = $LenovoDockCacheUpdate.Cache
		$LenovoDockUsageInventory = @($LenovoDockCacheUpdate.UsageEvents)
		$LenovoDockInventoryDate = $LenovoDockCacheUpdate.InventoryDate

		try {
			Save-LenovoDockCache -Path $LenovoDockCachePath -Cache $LenovoDockCache
		}
		catch {
			$LenovoDockQueryResult.CollectionStatus = "Warning"
			$LenovoDockQueryResult.CollectionMessage = "Dock data collected, but cache could not be saved: $((($_.Exception.Message) -replace "[\r\n]+", " ").Trim())"
		}

		foreach ($LenovoDock in $ConnectedLenovoDocks) {
			$CachedLenovoDock = Find-LenovoCachedDock -KnownDocks @($LenovoDockCache.KnownDocks) -Dock $LenovoDock
			$LenovoDockInventory += [PSCustomObject]@{
				AzureADDeviceID = "$AzureADDeviceID"
				ComputerName = "$ComputerName"
				ManagedDeviceName = "$ManagedDeviceName"
				ManagedDeviceID = "$ManagedDeviceID"
				DockId = "$($LenovoDock.DockId)"
				SerialNumber = "$($LenovoDock.SerialNumber)"
				MACAddress = "$($LenovoDock.MACAddress)"
				MachineType = "$($LenovoDock.MachineType)"
				FWVersion = "$($LenovoDock.FWVersion)"
				AvailableFWVersion = "$($LenovoDock.AvailableFWVersion)"
				FWVersionNormalized = "$($LenovoDock.FWVersionNormalized)"
				AvailableFWVersionNormalized = "$($LenovoDock.AvailableFWVersionNormalized)"
				LatestFirmwareFlag = $LenovoDock.LatestFirmwareFlag
				FirmwareUpdateAvailable = $LenovoDock.FirmwareUpdateAvailable
				FirmwareLastUpdateOn = "$($LenovoDock.FirmwareLastUpdateOn)"
				FirmwareInventoryDate = "$($LenovoDock.FirmwareInventoryDate)"
				MonitorConnected = [bool]$LenovoDock.MonitorConnected
				MonitorCount = [int]$LenovoDock.MonitorCount
				MonitorManufacturer = "$($LenovoDock.MonitorManufacturer)"
				MonitorModel = "$($LenovoDock.MonitorModel)"
				MonitorDeviceID = "$($LenovoDock.MonitorDeviceID)"
				MonitorEDIDHash = "$($LenovoDock.MonitorEDIDHash)"
				DockConnected = $true
				IsPrimaryDock = [bool]$CachedLenovoDock.IsPrimaryDock
				FirstSeen = "$($CachedLenovoDock.FirstSeen)"
				LastSeen = "$($CachedLenovoDock.LastSeen)"
				SeenCount = [int]$CachedLenovoDock.SeenCount
				InventoryDate = $LenovoDockInventoryDate
			}
		}
		foreach ($LenovoDockManagerEvent in @($LenovoDockQueryResult.DockManagerEvents)) {
			$LenovoDockUsageInventory += [PSCustomObject]@{
				AzureADDeviceID = "$AzureADDeviceID"
				ComputerName = "$ComputerName"
				ManagedDeviceName = "$ManagedDeviceName"
				ManagedDeviceID = "$ManagedDeviceID"
				DockId = "$($LenovoDockManagerEvent.DockId)"
				SerialNumber = "$($LenovoDockManagerEvent.SerialNumber)"
				MACAddress = "$($LenovoDockManagerEvent.MACAddress)"
				EventType = "FirmwareUpdateStatus"
				PreviousPrimaryDockId = ""
				IsPrimaryDock = $false
				FirstSeen = ""
				LastSeen = ""
				SeenCount = 0
				FWUpdateDate = "$($LenovoDockManagerEvent.FWUpdateDate)"
				UpdateStatus = "$($LenovoDockManagerEvent.UpdateStatus)"
				ErrorCode = "$($LenovoDockManagerEvent.ErrorCode)"
				OldVersion = "$($LenovoDockManagerEvent.OldVersion)"
				NewVersion = "$($LenovoDockManagerEvent.NewVersion)"
				InventoryDate = $LenovoDockInventoryDate
			}
		}
	}
	elseif ($LenovoDockQueryResult.CollectionStatus -eq "Error") {
		$LenovoDockUsageInventory += [PSCustomObject]@{
			AzureADDeviceID = "$AzureADDeviceID"
			ComputerName = "$ComputerName"
			ManagedDeviceName = "$ManagedDeviceName"
			ManagedDeviceID = "$ManagedDeviceID"
			DockId = ""
			SerialNumber = ""
			MACAddress = ""
			EventType = "CollectionError"
			PreviousPrimaryDockId = ""
			IsPrimaryDock = $false
			FirstSeen = ""
			LastSeen = ""
			SeenCount = 0
			InventoryDate = $LenovoDockInventoryDate
		}
	}

	$KnownLenovoDocks = @($LenovoDockCache.KnownDocks)
	$PrimaryLenovoDock = Get-LenovoPrimaryDock -KnownDocks $KnownLenovoDocks
	$LastKnownLenovoDock = $KnownLenovoDocks | Sort-Object @{Expression = {[datetime]$_.LastSeen}; Descending = $true} | Select-Object -First 1
	$ConnectedLenovoDockIds = @($ConnectedLenovoDocks | ForEach-Object { "$($_.DockId)" } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
	$ConnectedLenovoDockSerialNumbers = @($ConnectedLenovoDocks | ForEach-Object { "$($_.SerialNumber)" } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

	$LenovoDockStatusInventory = [PSCustomObject]@{
		AzureADDeviceID = "$AzureADDeviceID"
		ComputerName = "$ComputerName"
		ManagedDeviceName = "$ManagedDeviceName"
		ManagedDeviceID = "$ManagedDeviceID"
		DockConnected = ($ConnectedLenovoDocks.Count -gt 0)
		ConnectedDockId = ($ConnectedLenovoDockIds -join ",")
		ConnectedDockSerialNumber = ($ConnectedLenovoDockSerialNumbers -join ",")
		LastKnownDockId = "$($LastKnownLenovoDock.DockId)"
		LastKnownDockSerialNumber = "$($LastKnownLenovoDock.SerialNumber)"
		LastKnownDockLastSeen = "$($LastKnownLenovoDock.LastSeen)"
		PrimaryDockId = "$($PrimaryLenovoDock.DockId)"
		PrimaryDockSerialNumber = "$($PrimaryLenovoDock.SerialNumber)"
		KnownDockCount = $KnownLenovoDocks.Count
		CollectionStatus = "$($LenovoDockQueryResult.CollectionStatus)"
		CollectionMessage = "$($LenovoDockQueryResult.CollectionMessage)"
		InventoryDate = $LenovoDockInventoryDate
	}
}
#endregion LENOVODOCKINVENTORY

#region CUSTOMINVENTORY *SAMPLE*
<# Here you can add in code for other logs to extend with *SAMPLE
if ($CollectCustomInventory){
	Check SAMPLE-CustomLogInventory.ps1 in Github Repo
}
#>
#endregion CUSTOMINVENTORY

#region compose
# Start composing logdata
# If additional logs is collected, remember to add to main payload
$date = Get-Date -Format "dd-MM HH:mm"
$OutputMessage = "InventoryDate:$date "

$headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
$headers.Add("Content-Type", "application/json")

# Adding every log payload into PSObject for main payload - Additional logs can be added
$LogPayLoad = New-Object -TypeName PSObject
if ($CollectAppInventory) {
	$LogPayLoad | Add-Member -NotePropertyMembers @{$AppLogName = $AppInventory}
}
if ($CollectDeviceInventory) {
	$LogPayLoad | Add-Member -NotePropertyMembers @{$DeviceLogName = $DeviceInventory}
}
if ($CollectLenovoDeviceHealthInventory -and ($null -ne $LenovoDeviceHealthInventory)) {
	$LogPayLoad | Add-Member -NotePropertyMembers @{$LenovoDeviceHealthLogName = $LenovoDeviceHealthInventory}
}
if ($CollectLenovoDockInventory) {
	if (@($LenovoDockInventory).Count -gt 0) {
		$LogPayLoad | Add-Member -NotePropertyMembers @{$LenovoDockInventoryLogName = $LenovoDockInventory}
	}
	if ($null -ne $LenovoDockStatusInventory) {
		$LogPayLoad | Add-Member -NotePropertyMembers @{$LenovoDockStatusLogName = $LenovoDockStatusInventory}
	}
	if (@($LenovoDockUsageInventory).Count -gt 0) {
		$LogPayLoad | Add-Member -NotePropertyMembers @{$LenovoDockUsageLogName = $LenovoDockUsageInventory}
	}
}
<# *SAMPLE*
if ($CollectCustomInventory){
	$LogPayLoad | Add-Member -NotePropertyMember @{$CustomLogName = $CustomInventory}
}
#>

# Construct main payload to send to LogCollectorAPI
$MainPayLoad = [PSCustomObject]@{
	AzureADTenantID = $AzureADTenantID
	AzureADDeviceID = $AzureADDeviceID
	LogPayloads = $LogPayLoad
}
$MainPayLoadJson = $MainPayLoad| ConvertTo-Json -Depth 9

#endregion compose

#region dryrun
if ($DryRun -eq $true) {
	$GeneratedAt = Get-Date

	foreach ($LogPayloadProperty in $MainPayLoad.LogPayloads.PSObject.Properties) {
		$Payload = $LogPayloadProperty.Value
		$RecordCount = 0

		if ($null -ne $Payload) {
			if ($Payload -is [string] -and [string]::IsNullOrEmpty($Payload)) {
				$RecordCount = 0
			}
			elseif ($Payload -is [array]) {
				$RecordCount = $Payload.Count
			}
			else {
				$RecordCount = 1
			}
		}

		Write-Output ([PSCustomObject]@{
			DryRun = $true
			LogName = $LogPayloadProperty.Name
			AzureADTenantID = $MainPayLoad.AzureADTenantID
			AzureADDeviceID = $MainPayLoad.AzureADDeviceID
			RecordCount = $RecordCount
			Payload = $Payload
			PayloadJson = ConvertTo-Json -InputObject $Payload -Depth 20
			GeneratedAt = $GeneratedAt
		})
	}

	Exit 0
}
#endregion dryrun

#region ingestion
# NO NEED TO EDIT BELOW THIS LINE
# New in version 3.6.0 - Requires functionapp version 1.2
# Set default exit code to 0
$ExitCode = 0

# Attempt to send data to API
try {
	$ResponseInventory = Invoke-RestMethod $AzureFunctionURL -Method 'POST' -Headers $headers -Body $MainPayLoadJson
    foreach ($response in $ResponseInventory){
        if ($response.response -match "^200:"){
        $OutputMessage = $OutPutMessage + "OK: $($response.logname) $($response.response) "
        }
        else{
        $OutputMessage = $OutPutMessage + "FAIL: $($response.logname) $($response.response) "
        $ExitCode = 1
        }
    }
}
catch {
	$ResponseInventory = "Error Code: $($_.Exception.Response.StatusCode.value__)"
	$ResponseMessage = $_.Exception.Message
    $OutputMessage = $OutPutMessage + "Inventory:FAIL " + $ResponseInventory + $ResponseMessage
    $ExitCode = 1
}
# Exit script with correct output and code

Write-Output $OutputMessage
Exit $ExitCode
#endregion ingestion

#endregion script

