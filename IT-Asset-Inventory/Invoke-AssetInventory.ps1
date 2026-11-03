#Requires -Version 5.1
<#
.SYNOPSIS
    Launcher for the IT Asset Inventory Toolkit
.DESCRIPTION
    Imports the AssetInventory module and starts the interactive menu.
.NOTES
    Place this file in the same folder as AssetInventory.psm1
#>

$modulePath = Join-Path $PSScriptRoot "AssetInventory.psm1"

if (-not (Test-Path $modulePath)) {
    Write-Host ""
    Write-Host "  ERROR: AssetInventory.psm1 not found." -ForegroundColor Red
    Write-Host "  Make sure this script is in the same folder as AssetInventory.psm1" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

try {
    Import-Module $modulePath -Force -ErrorAction Stop
    Start-AssetInventoryMenu
}
catch {
    Write-Host ""
    Write-Host "  Failed to load the module: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    exit 1
}
