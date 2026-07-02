# Changelog for Intune Enhanced Inventory Solution 

## Unreleased

* Fixed Lenovo dock firmware update false positives by comparing normalized current and available firmware versions before falling back to `LatestFirmwareFlag`.
* Updated the Azure Function extension bundle range in `host.json` from deprecated 2.x to supported 4.x (`[4.0.0, 5.0.0)`).
* Rebuilt `Packages/LogCollectorAPI.zip` so the deployment package includes the updated Azure Function `host.json`.
* Moved Lenovo-specific README content under a new `Custom Inventory Script` section so the repository overview stays focused on the Azure Function inventory flow.
* Hardened the Log Collector API v1.4 reliability path with per-log Log Analytics error handling, structured error responses, aggregate ingestion status, stronger empty payload detection, alternate payload access, device ID redaction, and an `/api/health` endpoint.
* Documented deferred Log Collector API follow-ups for endpoint authentication, shared helper refactoring, and future DCR ingestion.
* Updated Azure Function profile guidance, README version requirements, and post-deployment health check setup instructions.
* Rebuilt `Packages/LogCollectorAPI.zip` so the deployment package includes the Log Collector API v1.4 reliability updates, profile guidance, and `/api/health` endpoint.

## Changelog for Log Collector API Azure Function

### 1.4
* Modernized managed identity Graph authentication with `IDENTITY_ENDPOINT`, token caching, retry handling, and legacy MSI fallback.
* Added request validation for tenant/device GUIDs and non-empty `LogPayloads`.
* Hardened log name control with exact allowed-name matching and improved allowed-log app setting parsing.
* Added Graph duplicate count telemetry, `Retry-After` handling, token cache invalidation on Graph `401`, and invariant token expiry parsing.
* Added structured telemetry, explicit JSON serialization depth, and redacted device IDs in logs and telemetry.
* Added per-log Log Analytics ingestion error handling with partial failure reporting via HTTP `207 Multi-Status`.
* Added structured error response bodies for validation, tenant/device, and Graph failure paths.
* Added `GET /api/health` for shallow configuration and managed identity availability checks.

### 1.2 
* Requires Proactive Remeditaion Script version 3.5
* Changed response logic in the function. Instead of returning a concated string, the function now returns a payload containing logname and status for each log as a separate entry. This makes it much easier to validate each log ingestion separated if you have many logs in the same PR Script. Fixes issues with the PR reporting wrongly. 
* Function now checks if the log you are sending is not empty. If the log is empty the function will not try to send data to Log Analytics and will return status 200 with a message about log empty. This fixes that the PR returns and error if you are collection for instance specific eventlog entries and the last 24 hours contains zero entries. 

### 1.1 
* Requires Proactive Remediation Script version 2.0 - up to and including version 3.0.x 
* Removed hardcoding for collecting only DeviceInventory or ApplicationInventory. The Azure Function can now handle any log as long as the data is sendt using the correct formatting. 

## Changelog for Inventory Collection Proactive remediation

### 3.7.0 - Requires Azure Function version 1.2
* Added Lenovo dock firmware normalization, firmware update status, and optional monitor metadata.
* Added `LenovoDeviceHealth` inventory for Lenovo warranty, battery, and odometer information.
* Removed `ProcessId` from Lenovo dock upload/cache data.

### 3.5.0 - Requires Azure Function version 1.2 
* Updated output logic in correspondace with new Azure Function returning a payload object instead of string. 
* Fixed a bug in the randomizer function, use the spread the load on the Azure Function over X minutes for larger environment.
* Adding 2 variables
* * Turn on / off randomizer function 
* * Set the timespan to randomize over 
* * Disabled inventory collection during provisioning day.

### 3.0.1 - Requires Azure Function version 1.1 
* Added support for CloudPC (Different method to find AzureAD DeviceID for verification) 

### 3.0.0 -  Requires Azure Function version 1.1 
* Added options to more easily add different custom logs and inventory by creating 1 main payload to be sent to Azure Function
* Added sample PR to show how to ingest your own custom data. 
* Generic bugfixes 

### 2.x - Requires Azure function 1.0 
* Added MACAddress to the inventory for each NIC. 
* Added section to cater for BIOS release version information, for HP, Dell and Lenovo and general bugfixes
* Removed all location gathering for privacy reasons 
* Moved secrets out of code - now running via Azure Function

