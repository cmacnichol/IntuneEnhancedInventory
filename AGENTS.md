# Repository Guidelines

## Project Structure & Module Organization

This repository contains the Intune Enhanced Inventory solution. Key paths:

- `Proactive Remediation/`: Intune remediation scripts. The recommended script is `Invoke-CustomInventoryAzureFunction.ps1`; the direct Log Analytics script is legacy.
- `Azure Functions/LogCollectorAPI/`: PowerShell Azure Function that validates devices and forwards log payloads to Log Analytics.
- `Deploy/`: Bicep and ARM templates for initial deployment and update flows.
- `Packages/`: packaged deployment artifacts, including `LogCollectorAPI.zip`.
- `Sample Workbooks/`: Azure Workbook samples for inventory visualization.
- Root scripts such as `Add-MSIGraphPermissions.ps1` support setup and permissions.

## Build, Test, and Development Commands

There is no formal build pipeline in the repo. Use targeted validation:

```powershell
Invoke-ScriptAnalyzer -Path 'Proactive Remediation\Invoke-CustomInventoryAzureFunction.ps1'
```

Runs PowerShell lint checks. Install with `Install-Module PSScriptAnalyzer -Scope CurrentUser` if needed.

```powershell
$errors=$null; $tokens=$null
[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path 'path\to\script.ps1'), [ref]$tokens, [ref]$errors)
$errors
```

Checks PowerShell syntax without executing scripts.

```powershell
az bicep build --file 'Deploy\SecuredEnhancedInventory.bicep'
```

Validates Bicep template compilation when Azure CLI is available.

## Coding Style & Naming Conventions

Use PowerShell with clear verb-noun function names, PascalCase variables, and four-space indentation or the surrounding file’s existing tab style. Prefer `Get-CimInstance` over `Get-WmiObject` for new code. Keep JSON payload field names stable because Azure Workbooks and Log Analytics queries may depend on them.

## Testing Guidelines

No automated tests are currently included. For remediation scripts, validate syntax, run PSScriptAnalyzer, and test in a controlled Intune or local admin/System context before broad deployment. For Azure Function changes, verify request/response shape against `LogPayloads`, `AzureADTenantID`, and `AzureADDeviceID`.

## Commit & Pull Request Guidelines

Recent history uses short, imperative messages such as `Update README.md` and `Update CHANGELOG.MD`. Keep commits focused and describe the changed component. Pull requests should include a summary, deployment impact, validation performed, and any required configuration changes. Link related issues when available.

## Security & Configuration Tips

Do not commit workspace IDs, shared keys, function URLs, tenant-specific secrets, or test payloads containing device identifiers. Prefer the Azure Function flow over the legacy direct-ingestion script because secrets stay out of remediation code.
