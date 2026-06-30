# Remediation Script Review

Reviewed files:

- `Proactive Remediation/Invoke-CustomInventoryAzureFunction.ps1`
- `Azure Functions/LogCollectorAPI/run.ps1`
- `Sample Workbooks/Device Inventory.workbook`
- `Sample Workbooks/Application Inventory.workbook`

Completed findings have been removed from this file.

## Remaining Findings

### Deferred: Preserve JSON depth when reserializing log payloads

Location:

- `Azure Functions/LogCollectorAPI/run.ps1:197`

The remediation script serializes the main payload with `ConvertTo-Json -Depth 9`, but the Azure Function reserializes each individual log with default `ConvertTo-Json` depth. Current device inventory arrays appear shallow enough, but custom inventory or future nested data could be truncated.

Status:

- Deferred for later implementation.
- Do not update `Azure Functions/LogCollectorAPI/run.ps1` or `Packages/LogCollectorAPI.zip` as part of the current fix set.

Suggestion:

- Use an explicit `-Depth 9` when converting `$MainPayLoad.$LogName` to JSON.
- Refresh `Packages/LogCollectorAPI.zip` after the function source change.

### Optional Style Cleanup: `PSUseSingularNouns`

Location:

- `Proactive Remediation/Invoke-CustomInventoryAzureFunction.ps1`

The function name `Get-InstalledApplications` uses a plural noun.

Status:

- Not changed intentionally. This is a low-priority style-only warning, and keeping the function name avoids unnecessary churn.

Suggestion:

- Rename only if full PSScriptAnalyzer style cleanliness becomes a goal.

## Verification Notes

- PowerShell parser reported no syntax errors for `Proactive Remediation/Invoke-CustomInventoryAzureFunction.ps1`.
- Workbook JSON parsing succeeded for both sample workbooks.
- `git diff --check` passed.
- Targeted searches found no remaining completed-review sentinels: `Get-WmiObject`, `Sort-Object [version]`, `$value -ne $null`, `$value -eq $null`, `DeviceName_v`, `fallbackResourceIds`, `1Password`, or `CLOUDWAY-JKS-WS`.
- PSScriptAnalyzer could not be rerun in this shell because `Invoke-ScriptAnalyzer` was not discoverable after the install attempt.
