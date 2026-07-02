# Intune Enhanced Inventory
# LogCollectorAPI health endpoint
# Version 1.4
# Updated 01.Jul.2026 by Christopher Macnichol

using namespace System.Net
param($Request)

$requiredSettings = @(
    'TenantID',
    'WorkspaceID',
    'SharedKey'
)

$missingSettings = @(
    foreach ($settingName in $requiredSettings) {
        if ([string]::IsNullOrWhiteSpace([string](Get-Item -Path "env:$settingName" -ErrorAction SilentlyContinue).Value)) {
            $settingName
        }
    }
)

$managedIdentityAvailable = (
    (-not [string]::IsNullOrWhiteSpace($env:IDENTITY_ENDPOINT) -and -not [string]::IsNullOrWhiteSpace($env:IDENTITY_HEADER)) -or
    (-not [string]::IsNullOrWhiteSpace($env:MSI_ENDPOINT) -and -not [string]::IsNullOrWhiteSpace($env:MSI_SECRET))
)

$statusCode = [HttpStatusCode]::OK
$status = 'healthy'

if ($missingSettings.Count -gt 0 -or -not $managedIdentityAvailable) {
    $statusCode = [HttpStatusCode]::ServiceUnavailable
    $status = 'unhealthy'
}

$body = [PSCustomObject]@{
    status = $status
    timestampUtc = (Get-Date).ToUniversalTime().ToString('o')
    requiredSettingsPresent = ($missingSettings.Count -eq 0)
    missingSettings = $missingSettings
    managedIdentityAvailable = $managedIdentityAvailable
} | ConvertTo-Json -Depth 4

Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = $statusCode
    Body = $body
})
