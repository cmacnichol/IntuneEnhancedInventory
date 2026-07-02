# Azure Functions profile.ps1
#
# This profile.ps1 will get executed every "cold start" of your Function App.
# "cold start" occurs when:
#
# * A Function App starts up for the very first time
# * A Function App starts up after being de-allocated due to inactivity
#
# You can define helper functions, run commands, or specify environment variables
# NOTE: any variables defined that are not environment variables will get reset after the first execution

# The LogCollectorAPI and health functions do not require Azure PowerShell sign-in.
# They call the managed identity token endpoint directly when a Microsoft Graph token is needed.
#
# If a future function needs Az cmdlets, add the Az module to requirements.psd1 and use
# the current managed identity environment rather than the legacy MSI_SECRET check.
# Example:
#
# if ($env:IDENTITY_ENDPOINT -and $env:IDENTITY_HEADER) {
#     Disable-AzContextAutosave -Scope Process | Out-Null
#     Connect-AzAccount -Identity
# }

# Uncomment the next line to enable legacy AzureRm alias in Azure PowerShell.
# Enable-AzureRmAlias

# You can also define functions or aliases that can be referenced in any of your PowerShell functions.
