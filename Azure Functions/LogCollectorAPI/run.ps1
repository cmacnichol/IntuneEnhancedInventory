# Intune Enhanced Inventory 
# Version 1.4
# Created and maintained by @JankeSkanke 
# Requires minimum version  3.5.0 of the Enhanced Inventory Proactive Remediations Script
# Updated 01.Jul.2026 by Christopher Macnichol
#
# Version history:
# 1.0.0 - Initial release
# 1.2.0 - (14.Oct.2022) Log Collector API updates
# 1.3.0 - (01.Jul.2026) Modernized managed identity Graph authentication, device lookup,
#         token caching, retry handling, and structured error responses. Updated by Christopher Macnichol.
# 1.4.0 - (01.Jul.2026) Request validation, tenant GUID checks, exact log name matching,
#         token cache invalidation on 401, Graph count query, Retry-After support, telemetry,
#         configuration parsing improvements, Log Analytics error handling, structured error
#         responses, aggregate ingestion status, empty payload detection, alternate payload
#         access, timestamp parameter cleanup, and device ID redaction. Updated by
#         Christopher Macnichol.

using namespace System.Net
# Input bindings are passed in via param block.
param($Request)

#region functions
function Write-TelemetryEvent {
    <#
    .SYNOPSIS
        Emits a structured telemetry event for Application Insights log queries.

    .NOTES
        Updated:     01.Jul.2026 by Christopher Macnichol
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$EventName,

        [hashtable]$Properties = @{}
    )

    $telemetryPayload = [ordered]@{
        telemetryEvent = $EventName
        timestampUtc   = (Get-Date).ToUniversalTime().ToString('o')
    }

    foreach ($key in $Properties.Keys) {
        $telemetryPayload[$key] = $Properties[$key]
    }

    Write-Information ($telemetryPayload | ConvertTo-Json -Compress)
}#end function

function Test-GuidString {
    <#
    .SYNOPSIS
        Validates that a value is a non-empty GUID string.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    return $Value -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
}#end function

function Get-LogPayloadKeys {
    <#
    .SYNOPSIS
        Returns log payload property names from hashtable or PSCustomObject input.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $LogPayloads
    )

    if ($LogPayloads -is [System.Collections.IDictionary]) {
        return @($LogPayloads.Keys)
    }

    return @($LogPayloads.PSObject.Properties.Name)
}#end function

function Get-LogPayloadValue {
    <#
    .SYNOPSIS
        Returns a named log payload from hashtable or PSCustomObject input.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $LogPayloads,

        [Parameter(Mandatory = $true)]
        [string]$LogName
    )

    if ($LogPayloads -is [System.Collections.IDictionary]) {
        if ($LogPayloads.Contains($LogName)) {
            return $LogPayloads[$LogName]
        }

        return $null
    }

    return $LogPayloads.PSObject.Properties[$LogName].Value
}#end function

function Test-LogPayloadHasContent {
    <#
    .SYNOPSIS
        Determines whether a log payload contains useful data before serialization.
    #>
    param(
        [AllowNull()]
        $Payload
    )

    if ($null -eq $Payload) {
        return $false
    }

    if ($Payload -is [string]) {
        return -not [string]::IsNullOrWhiteSpace($Payload)
    }

    if ($Payload -is [System.Collections.IDictionary]) {
        return $Payload.Count -gt 0
    }

    if ($Payload -is [System.Collections.IEnumerable]) {
        return @($Payload).Count -gt 0
    }

    if ($Payload -is [pscustomobject]) {
        return @($Payload.PSObject.Properties).Count -gt 0
    }

    return $true
}#end function

function Get-LogSafeDeviceId {
    <#
    .SYNOPSIS
        Returns a redacted device identifier for logs and telemetry.
    #>
    param(
        [AllowNull()]
        [string]$DeviceId
    )

    if ([string]::IsNullOrWhiteSpace($DeviceId) -or $DeviceId.Length -lt 13) {
        return '<redacted>'
    }

    return '{0}...{1}' -f $DeviceId.Substring(0, 8), $DeviceId.Substring($DeviceId.Length - 4)
}#end function

function New-ErrorResponse {
    <#
    .SYNOPSIS
        Builds a consistent error response body for non-success HTTP responses.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Code,

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [string[]]$Details = @()
    )

    $response = [ordered]@{
        status  = 'error'
        code    = $Code
        message = $Message
    }

    if ($Details.Count -gt 0) {
        $response.details = $Details
    }

    return [PSCustomObject]$response
}#end function

function Test-InventoryRequestBody {
    <#
    .SYNOPSIS
        Validates inbound request body shape and required fields.

    .NOTES
        Updated:     01.Jul.2026 by Christopher Macnichol
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $RequestBody
    )

    $validationErrors = New-Object System.Collections.ArrayList

    if ($null -eq $RequestBody) {
        [void]$validationErrors.Add('Request body is missing.')
        return ,@($validationErrors)
    }

    if ([string]::IsNullOrWhiteSpace($RequestBody.AzureADTenantID)) {
        [void]$validationErrors.Add('AzureADTenantID is required.')
    }
    elseif (-not (Test-GuidString -Value $RequestBody.AzureADTenantID)) {
        [void]$validationErrors.Add('AzureADTenantID must be a valid GUID.')
    }

    if ([string]::IsNullOrWhiteSpace($RequestBody.AzureADDeviceID)) {
        [void]$validationErrors.Add('AzureADDeviceID is required.')
    }
    elseif (-not (Test-GuidString -Value $RequestBody.AzureADDeviceID)) {
        [void]$validationErrors.Add('AzureADDeviceID must be a valid GUID.')
    }

    if ($null -eq $RequestBody.LogPayloads) {
        [void]$validationErrors.Add('LogPayloads is required.')
    }
    else {
        $logKeys = Get-LogPayloadKeys -LogPayloads $RequestBody.LogPayloads
        if ($logKeys.Count -eq 0) {
            [void]$validationErrors.Add('LogPayloads must contain at least one log entry.')
        }
    }

    return ,@($validationErrors)
}#end function

function Get-AllowedLogNamesFromEnvironment {
    <#
    .SYNOPSIS
        Parses AllowedLogNames from Azure Functions app settings.

    .NOTES
        Updated:     01.Jul.2026 by Christopher Macnichol
    #>
    [CmdletBinding()]
    param()

    $rawValue = $env:AllowedLogNames

    if ($null -eq $rawValue -or [string]::IsNullOrWhiteSpace([string]$rawValue)) {
        return @()
    }

    if ($rawValue -is [System.Array]) {
        return @(
            $rawValue |
                ForEach-Object { $_.ToString().Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
    }

    return @(
        $rawValue.ToString().Split(',') |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}#end function

function Clear-GraphTokenCache {
    <#
    .SYNOPSIS
        Clears the cached Microsoft Graph access token.
    #>
    $Script:GraphTokenCache = $null
}#end function

function Get-GraphAccessToken {
    <#
    .SYNOPSIS
        Retrieve a Microsoft Graph access token using the Function App managed identity.

    .DESCRIPTION
        Uses the current IDENTITY_ENDPOINT token API (2019-08-01) with legacy MSI fallback.
        Caches the token in script scope until five minutes before expiry.

    .NOTES
        Author:      Nickolaj Andersen
        Contact:     @NickolajA
        Created:     2021-06-07
        Updated:     01.Jul.2026 by Christopher Macnichol

        Version history:
        1.0.0 - (2021-06-07) Function created as Get-AuthToken
        1.1.0 - (01.Jul.2026) Renamed to Get-GraphAccessToken; modern IDENTITY_ENDPOINT,
                token caching, and legacy MSI fallback. Updated by Christopher Macnichol.
        1.2.0 - (01.Jul.2026) Force refresh support and invariant expires_on parsing.
                Updated by Christopher Macnichol.
    #>
    [CmdletBinding()]
    param(
        [ValidateNotNullOrEmpty()]
        [string]$Resource = 'https://graph.microsoft.com/',

        [switch]$ForceRefresh
    )

    Process {
        $refreshThreshold = (Get-Date).ToUniversalTime().AddMinutes(5)
        if (-not $ForceRefresh -and $Script:GraphTokenCache -and $Script:GraphTokenCache.ExpiresOn -gt $refreshThreshold) {
            Write-Information "Using cached Graph access token (expires $($Script:GraphTokenCache.ExpiresOn.ToString('u')))"
            Write-TelemetryEvent -EventName 'GraphTokenAcquired' -Properties @{
                tokenSource = $Script:GraphTokenCache.Source
                cacheHit    = $true
            }
            return $Script:GraphTokenCache
        }

        $tokenSource = $null
        if ($env:IDENTITY_ENDPOINT -and $env:IDENTITY_HEADER) {
            $tokenSource = 'IDENTITY_ENDPOINT'
            $tokenUri = '{0}?resource={1}&api-version=2019-08-01' -f $env:IDENTITY_ENDPOINT, [uri]::EscapeDataString($Resource)
            Write-Information 'Acquiring Graph access token via IDENTITY_ENDPOINT (api-version 2019-08-01)'
            $response = Invoke-RestMethod -Method Get -Uri $tokenUri -Headers @{
                'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER
            } -UseBasicParsing
        }
        elseif ($env:MSI_ENDPOINT -and $env:MSI_SECRET) {
            $tokenSource = 'MSI_ENDPOINT'
            Write-Warning 'Using legacy MSI_ENDPOINT token API; migrate to IDENTITY_ENDPOINT when possible.'
            $tokenUri = '{0}?resource={1}&api-version=2017-09-01' -f $env:MSI_ENDPOINT, [uri]::EscapeDataString($Resource)
            $response = Invoke-RestMethod -Method Get -Uri $tokenUri -Headers @{
                Secret = $env:MSI_SECRET
            } -UseBasicParsing
        }
        else {
            throw 'Managed identity environment variables are not available. Enable system-assigned managed identity on the Function App.'
        }

        if ([string]::IsNullOrWhiteSpace($response.access_token)) {
            throw 'Managed identity token response did not include access_token.'
        }

        $expiresOn = [datetimeoffset]::Parse(
            $response.expires_on,
            [Globalization.CultureInfo]::InvariantCulture
        ).UtcDateTime

        $Script:GraphTokenCache = [PSCustomObject]@{
            Authorization = "Bearer $($response.access_token)"
            ExpiresOn     = $expiresOn
            Source        = $tokenSource
        }

        Write-Information "Graph access token acquired (expires $($Script:GraphTokenCache.ExpiresOn.ToString('u')))"
        Write-TelemetryEvent -EventName 'GraphTokenAcquired' -Properties @{
            tokenSource = $tokenSource
            cacheHit    = $false
            forceRefresh = [bool]$ForceRefresh
        }

        return $Script:GraphTokenCache
    }
}#end function

function Get-HttpStatusCodeFromError {
    <#
    .SYNOPSIS
        Extracts an HTTP status code from a web request exception.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $ErrorRecord
    )

    if ($ErrorRecord.Exception.Response) {
        return [int]$ErrorRecord.Exception.Response.StatusCode
    }

    return $null
}#end function

function Get-RetryAfterSecondsFromError {
    <#
    .SYNOPSIS
        Reads the Retry-After response header from a web request exception.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $ErrorRecord
    )

    $response = $ErrorRecord.Exception.Response
    if (-not $response -or -not $response.Headers) {
        return $null
    }

    $retryAfterValue = $null
    if ($response.Headers['Retry-After']) {
        $retryAfterValue = $response.Headers['Retry-After'].ToString()
    }
    elseif ($response.Headers.RetryAfter) {
        $retryAfterValue = $response.Headers.RetryAfter.ToString()
    }

    if ([string]::IsNullOrWhiteSpace($retryAfterValue)) {
        return $null
    }

    $retryAfterSeconds = 0
    if ([int]::TryParse($retryAfterValue, [ref]$retryAfterSeconds)) {
        return [Math]::Max(1, $retryAfterSeconds)
    }

    $retryAfterDate = [datetime]::MinValue
    if ([datetime]::TryParse($retryAfterValue, [ref]$retryAfterDate)) {
        $secondsUntilRetry = ($retryAfterDate.ToUniversalTime() - (Get-Date).ToUniversalTime()).TotalSeconds
        return [Math]::Max(1, [int][Math]::Ceiling($secondsUntilRetry))
    }

    return $null
}#end function

function Invoke-GraphRequestWithRetry {
    <#
    .SYNOPSIS
        Invokes a Microsoft Graph REST request with retry for transient failures.

    .NOTES
        Updated:     01.Jul.2026 by Christopher Macnichol
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers,

        [hashtable]$AdditionalHeaders = @{},

        [ValidateRange(1, 10)]
        [int]$MaxRetries = 3
    )

    Process {
        $requestHeaders = @{}
        foreach ($headerKey in $Headers.Keys) {
            $requestHeaders[$headerKey] = $Headers[$headerKey]
        }
        foreach ($headerKey in $AdditionalHeaders.Keys) {
            $requestHeaders[$headerKey] = $AdditionalHeaders[$headerKey]
        }

        for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
            try {
                return Invoke-RestMethod -Method Get -Uri $Uri -Headers $requestHeaders -ContentType 'application/json' -ErrorAction Stop
            }
            catch {
                $statusCode = Get-HttpStatusCodeFromError -ErrorRecord $_

                if ($statusCode -in 429, 503 -and $attempt -lt $MaxRetries) {
                    $retryAfterSeconds = Get-RetryAfterSecondsFromError -ErrorRecord $_
                    $delaySeconds = if ($null -ne $retryAfterSeconds) {
                        $retryAfterSeconds
                    }
                    else {
                        [math]::Pow(2, $attempt)
                    }

                    Write-Warning "Graph request returned HTTP $statusCode (attempt $attempt of $MaxRetries). Retrying in $delaySeconds second(s)."
                    Write-TelemetryEvent -EventName 'GraphRequestRetry' -Properties @{
                        statusCode   = $statusCode
                        attempt      = $attempt
                        delaySeconds = $delaySeconds
                        uri          = '<redacted>'
                    }
                    Start-Sleep -Seconds $delaySeconds
                    continue
                }

                throw
            }
        }
    }
}#end function

function Invoke-GraphRequestWithUnauthorizedRetry {
    <#
    .SYNOPSIS
        Invokes a Graph request and refreshes the token once on HTTP 401.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [hashtable]$AdditionalHeaders = @{}
    )

    Process {
        $auth = Get-GraphAccessToken
        $graphHeaders = @{
            Authorization = $auth.Authorization
        }

        try {
            return Invoke-GraphRequestWithRetry -Uri $Uri -Headers $graphHeaders -AdditionalHeaders $AdditionalHeaders
        }
        catch {
            $statusCode = Get-HttpStatusCodeFromError -ErrorRecord $_
            if ($statusCode -ne 401) {
                throw
            }

            Write-Warning 'Microsoft Graph returned HTTP 401. Clearing token cache and retrying once with a fresh token.'
            Write-TelemetryEvent -EventName 'GraphTokenCacheInvalidated' -Properties @{
                reason = 'HTTP401'
                uri    = '<redacted>'
            }

            Clear-GraphTokenCache
            $auth = Get-GraphAccessToken -ForceRefresh
            $graphHeaders = @{
                Authorization = $auth.Authorization
            }

            return Invoke-GraphRequestWithRetry -Uri $Uri -Headers $graphHeaders -AdditionalHeaders $AdditionalHeaders
        }
    }
}#end function

function Send-LogAnalyticsData() {
    <#
   .SYNOPSIS
       Send log data to Azure Monitor by using the HTTP Data Collector API
   
   .DESCRIPTION
       Send log data to Azure Monitor by using the HTTP Data Collector API
   
   .NOTES
       Author:      Jan Ketil Skanke
       Contact:     @JankeSkanke
       Created:     2022-01-14
       Updated:     01.Jul.2026 by Christopher Macnichol
   
       Version history:
       1.0.0 - (2022-01-14) Function created
       1.1.0 - (01.Jul.2026) Added explicit TimeStampField parameter.
   #>
   param(
       [string]$sharedKey,
       [array]$body, 
       [string]$logType,
       [string]$CustomerId,
       [string]$TimeStampField = ''
   )
   #Defining method and datatypes
   $method = "POST"
   $contentType = "application/json"
   $resource = "/api/logs"
   $date = [DateTime]::UtcNow.ToString("r")
   $contentLength = $body.Length
   #Construct authorization signature
   $xHeaders = "x-ms-date:" + $date
   $stringToHash = $method + "`n" + $contentLength + "`n" + $contentType + "`n" + $xHeaders + "`n" + $resource
   $bytesToHash = [Text.Encoding]::UTF8.GetBytes($stringToHash)
   $keyBytes = [Convert]::FromBase64String($sharedKey)
   $sha256 = New-Object System.Security.Cryptography.HMACSHA256
   $sha256.Key = $keyBytes
   $calculatedHash = $sha256.ComputeHash($bytesToHash)
   $encodedHash = [Convert]::ToBase64String($calculatedHash)
   $signature = 'SharedKey {0}:{1}' -f $CustomerId, $encodedHash
   
   #Construct uri 
   $uri = "https://" + $CustomerId + ".ods.opinsights.azure.com" + $resource + "?api-version=2016-04-01"
   
   #validate that payload data does not exceed limits
   if ($body.Length -gt (31.9 *1024*1024)){
       throw("Upload payload is too big and exceed the 32Mb limit for a single upload. Please reduce the payload size. Current payload size is: " + ($body.Length/1024/1024).ToString("#.#") + "Mb")
   }
   $payloadsize = ("Upload payload size is " + ($body.Length/1024).ToString("#.#") + "Kb ")
   
   #Create authorization Header
   $headers = @{
       "Authorization"        = $signature;
       "Log-Type"             = $logType;
       "x-ms-date"            = $date;
       "time-generated-field" = $TimeStampField;
   }
   #Sending data to log analytics
   $response = Invoke-WebRequest -Uri $uri -Method $method -ContentType $contentType -Headers $headers -Body $body -UseBasicParsing
   $statusmessage = "$($response.StatusCode):$($payloadsize)"
   return $statusmessage 
}#end function
#endregion functions

Write-Information "LogCollectorAPI function received a request."
Write-TelemetryEvent -EventName 'FunctionInvocationStarted' -Properties @{
    functionName = 'LogCollectorAPI'
}

#region initialize

# Setting inital Status Code: 
$StatusCode = [HttpStatusCode]::OK
$JsonSerializationDepth = 20
$ResponseArray = New-Object -TypeName System.Collections.ArrayList
$ResponseBody = $ResponseArray
$HasIngestionFailures = $false

# Define variables from environment
$LogControll = $env:LogControl
# Get secrets from Keyvault
$CustomerId = $env:WorkspaceID
$SharedKey  = $env:SharedKey

# Get TenantID from my logged on MSI account for verification 
$TenantID = $env:TenantID
$AllowedLogNames = Get-AllowedLogNamesFromEnvironment

#Required empty variable for posting to Log Analytics
$TimeStampField = ''

#endregion initialize

#region script
$validationErrors = Test-InventoryRequestBody -RequestBody $Request.Body
if ($validationErrors.Count -gt 0) {
    foreach ($validationError in $validationErrors) {
        Write-Warning $validationError
    }

    Write-TelemetryEvent -EventName 'RequestValidationFailed' -Properties @{
        errorCount = $validationErrors.Count
        errors     = ($validationErrors -join '; ')
    }

    $StatusCode = [HttpStatusCode]::BadRequest
    $ResponseBody = New-ErrorResponse -Code 'InvalidRequest' -Message 'The inventory request body is invalid.' -Details $validationErrors
}
else {
    # Extracting and processing inbound parameters to variables for matching
    $MainPayLoad = $Request.Body.LogPayloads
    $InboundDeviceID = $Request.Body.AzureADDeviceID
    $InboundTenantID = $Request.Body.AzureADTenantID
    $LogSafeInboundDeviceID = Get-LogSafeDeviceId -DeviceId $InboundDeviceID

    $LogsReceived = New-Object -TypeName System.Collections.ArrayList
    foreach ($Key in (Get-LogPayloadKeys -LogPayloads $MainPayLoad)) {
        $LogsReceived.Add($Key) | Out-Null
    }

    Write-Information "Logs Received $($LogsReceived)"
    Write-Information "Inbound DeviceID $($LogSafeInboundDeviceID)"
    Write-Information "Inbound TenantID $($InboundTenantID)"
    Write-Information "Environment TenantID $TenantID"

    # Verify request comes from correct tenant
    if ($TenantID -ne $InboundTenantID) {
        Write-Warning "Tenant not allowed - Forbidden"
        Write-TelemetryEvent -EventName 'TenantValidationFailed' -Properties @{
            inboundTenantId = $InboundTenantID
        }
        $StatusCode = [HttpStatusCode]::Forbidden
        $ResponseBody = New-ErrorResponse -Code 'TenantNotAllowed' -Message 'The request tenant is not allowed.'
    }
    else {
        Write-Information "Request is comming from correct tenant"
        Write-TelemetryEvent -EventName 'RequestValidationSucceeded' -Properties @{
            logCount = $LogsReceived.Count
        }

        try {
            $deviceCountUri = "https://graph.microsoft.com/v1.0/devices?`$filter=deviceId eq '$($InboundDeviceID)'&`$count=true&`$top=0"
            $deviceCountResult = Invoke-GraphRequestWithUnauthorizedRetry -Uri $deviceCountUri -AdditionalHeaders @{
                ConsistencyLevel = 'eventual'
            }
            $deviceCount = [int]$deviceCountResult.'@odata.count'

            Write-Information "Graph device count query returned $deviceCount result(s) for deviceId $($LogSafeInboundDeviceID)"
            Write-TelemetryEvent -EventName 'GraphDeviceCountQuery' -Properties @{
                deviceCount = $deviceCount
                deviceId    = $LogSafeInboundDeviceID
            }

            if ($deviceCount -gt 1) {
                Write-Warning "Multiple Graph device records matched deviceId $($LogSafeInboundDeviceID); using the first result"
                Write-TelemetryEvent -EventName 'GraphDuplicateDeviceRecords' -Properties @{
                    deviceCount = $deviceCount
                    deviceId    = $LogSafeInboundDeviceID
                }
            }

            $deviceUri = "https://graph.microsoft.com/v1.0/devices?`$filter=deviceId eq '$($InboundDeviceID)'&`$select=deviceId,accountEnabled&`$top=1"
            $deviceResult = Invoke-GraphRequestWithUnauthorizedRetry -Uri $deviceUri
            $device = $deviceResult.value | Select-Object -First 1

            if ($null -eq $device -or $device.deviceId -ne $InboundDeviceID) {
                Write-Warning "Device not found in tenant - Forbidden"
                Write-TelemetryEvent -EventName 'DeviceValidationFailed' -Properties @{
                    reason   = 'NotFound'
                    deviceId = $LogSafeInboundDeviceID
                }
                $StatusCode = [HttpStatusCode]::Forbidden
                $ResponseBody = New-ErrorResponse -Code 'DeviceNotFound' -Message 'The Azure AD device was not found in the allowed tenant.'
            }
            elseif ($device.accountEnabled -ne $true) {
                Write-Warning "Device is not enabled - Forbidden"
                Write-TelemetryEvent -EventName 'DeviceValidationFailed' -Properties @{
                    reason   = 'Disabled'
                    deviceId = $LogSafeInboundDeviceID
                }
                $StatusCode = [HttpStatusCode]::Forbidden
                $ResponseBody = New-ErrorResponse -Code 'DeviceDisabled' -Message 'The Azure AD device is disabled.'
            }
            else {
                Write-Information "Request is coming from a valid device in Azure AD"
                Write-Information "DeviceID $($LogSafeInboundDeviceID)"
                Write-Information "DeviceEnabled: $($device.accountEnabled)"
                Write-Information "Requesting device is not disabled in Azure AD"
                Write-TelemetryEvent -EventName 'DeviceValidationSucceeded' -Properties @{
                    deviceId = $LogSafeInboundDeviceID
                }

                foreach ($LogName in $LogsReceived) {
                    Write-Information "Processing $($LogName)"
                    # Check if Log type control is enabled
                    if ($LogControll -eq "true") {
                        # Verify log name applicability
                        Write-Information "Log name control is enabled, verifying log name against allowed values"
                        Write-Information "Allowed log names: $($AllowedLogNames -join ', ')"
                        if ($AllowedLogNames -contains $LogName) {
                            Write-Information "Log $LogName Allowed"
                            [bool]$LogState = $true
                        }
                        else {
                            Write-Warning "Logname $LogName not allowed"
                            [bool]$LogState = $false
                        }
                    }
                    else {
                        Write-Information "Log control is not enabled, continue"
                        [bool]$LogState = $true
                    }
                    if ($LogState) {
                        $LogPayload = Get-LogPayloadValue -LogPayloads $MainPayLoad -LogName $LogName
                        # Verify if log has data before sending to Log Analytics
                        if (Test-LogPayloadHasContent -Payload $LogPayload) {
                            $Json = $LogPayload | ConvertTo-Json -Depth $JsonSerializationDepth
                            $LogSize = $Json.Length
                            Write-Information "Log $($LogName) has content. Size is $($Json.Length)"
                            $LogBody = ([System.Text.Encoding]::UTF8.GetBytes($Json))
                            # Sending logdata to Log Analytics
                            try {
                                $ResponseLogInventory = Send-LogAnalyticsData -customerId $CustomerId -sharedKey $SharedKey -body $LogBody -logType $LogName -TimeStampField $TimeStampField
                                Write-Information "$($LogName) Logs sent to LA $($ResponseLogInventory)"
                                Write-TelemetryEvent -EventName 'LogIngestionSucceeded' -Properties @{
                                    logName    = $LogName
                                    payloadSize = $LogSize
                                    response   = $ResponseLogInventory
                                }
                                $PSObject = [PSCustomObject]@{
                                    LogName = $LogName
                                    Response = $ResponseLogInventory
                                }
                            }
                            catch {
                                $logAnalyticsStatusCode = Get-HttpStatusCodeFromError -ErrorRecord $_
                                $failureMessage = if ($logAnalyticsStatusCode) {
                                    "Failed to send log to Log Analytics. HTTP $logAnalyticsStatusCode"
                                }
                                else {
                                    "Failed to send log to Log Analytics. $($_.Exception.Message)"
                                }

                                Write-Warning "$($LogName) $failureMessage"
                                Write-TelemetryEvent -EventName 'LogIngestionFailed' -Properties @{
                                    logName    = $LogName
                                    statusCode = $logAnalyticsStatusCode
                                    message    = $_.Exception.Message
                                }
                                $PSObject = [PSCustomObject]@{
                                    LogName = $LogName
                                    Response = $failureMessage
                                }
                                $HasIngestionFailures = $true
                            }

                            $ResponseArray.Add($PSObject) | Out-Null
                        }
                        else {
                            # Log is empty - return status 200 but with info about empty log
                            Write-Information "Log $($LogName) has no content."
                            Write-TelemetryEvent -EventName 'LogIngestionSkipped' -Properties @{
                                logName = $LogName
                                reason  = 'EmptyPayload'
                            }
                            $PSObject = [PSCustomObject]@{
                                LogName = $LogName
                                Response = "200:Log does not contain data"
                            }
                            $ResponseArray.Add($PSObject) | Out-Null
                        }
                    }
                    else {
                        Write-Warning "Log $($LogName) is not allowed"
                        Write-TelemetryEvent -EventName 'LogIngestionSkipped' -Properties @{
                            logName = $LogName
                            reason  = 'LogNameNotAllowed'
                        }
                        $PSObject = [PSCustomObject]@{
                            LogName = $LogName
                            Response = "Logtype is not allowed"
                        }
                        $ResponseArray.Add($PSObject) | Out-Null
                    }
                }
            }
        }
        catch {
            $graphStatusCode = Get-HttpStatusCodeFromError -ErrorRecord $_

            if ($graphStatusCode -in 401, 403) {
                Write-Warning "Microsoft Graph authorization failed (HTTP $graphStatusCode). Verify the Function App managed identity has the Device.Read.All application permission with admin consent."
                Write-TelemetryEvent -EventName 'GraphAuthorizationFailed' -Properties @{
                    statusCode = $graphStatusCode
                }
                $StatusCode = [HttpStatusCode]::Forbidden
                $ResponseBody = New-ErrorResponse -Code 'GraphAuthorizationFailed' -Message 'Microsoft Graph authorization failed. Verify the Function App managed identity has Device.Read.All application permission with admin consent.'
            }
            elseif ($graphStatusCode -in 429, 503) {
                Write-Warning "Microsoft Graph request failed after retries (HTTP $graphStatusCode)."
                Write-TelemetryEvent -EventName 'GraphRequestFailed' -Properties @{
                    statusCode = $graphStatusCode
                    reason     = 'RetriesExhausted'
                }
                $StatusCode = [HttpStatusCode]::ServiceUnavailable
                $ResponseBody = New-ErrorResponse -Code 'GraphRequestFailed' -Message 'Microsoft Graph request failed after retries.'
            }
            else {
                Write-Warning "Device verification failed: $($_.Exception.Message)"
                if ($_.ErrorDetails.Message) {
                    Write-Warning $_.ErrorDetails.Message
                }
                Write-TelemetryEvent -EventName 'DeviceVerificationFailed' -Properties @{
                    statusCode = $graphStatusCode
                    message    = $_.Exception.Message
                }
                $StatusCode = [HttpStatusCode]::ServiceUnavailable
                $ResponseBody = New-ErrorResponse -Code 'DeviceVerificationFailed' -Message 'Device verification failed.'
            }
        }
    }
}
#endregion script

if ($HasIngestionFailures) {
    $StatusCode = [HttpStatusCode]::MultiStatus
}

Write-TelemetryEvent -EventName 'FunctionInvocationCompleted' -Properties @{
    statusCode = [int]$StatusCode
    responseCount = @($ResponseArray).Count
}

$body = $ResponseBody | ConvertTo-Json -Depth $JsonSerializationDepth
# Associate values to output bindings by calling 'Push-OutputBinding'.
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = $StatusCode
    Body = $body
})
