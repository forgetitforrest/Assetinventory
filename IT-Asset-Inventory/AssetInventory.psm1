#Requires -Version 5.1
<#
.SYNOPSIS
    IT Asset Inventory PowerShell Module
.DESCRIPTION
    Collects detailed hardware, software, network, security, and OS information from Windows devices.
    Supports local and remote (WinRM) collection, multiple export formats, and clean reporting.
.NOTES
    Author: Your Name
    Version: 1.1.0
    Compatible with: Windows 10 / 11, PowerShell 5.1+
#>

#region Theme & Helpers

$script:Orange = "DarkYellow"
$script:Green  = "Green"
$script:Red    = "Red"
$script:Gray   = "DarkGray"
$script:White  = "White"
$script:Cyan   = "Cyan"

$script:LogPath = Join-Path $env:TEMP "AssetInventory_$(Get-Date -Format 'yyyyMMdd').log"
$script:DefaultOutput = Join-Path $PSScriptRoot "output"
$script:ModuleVersion = "1.1.0"

function Write-Orange {
    param([string]$Message, [switch]$NoNewline)
    if ($NoNewline) { Write-Host $Message -ForegroundColor $script:Orange -NoNewline }
    else { Write-Host $Message -ForegroundColor $script:Orange }
}

function Write-Success { param([string]$Message) Write-Host "  [OK] $Message" -ForegroundColor $script:Green }
function Write-Fail    { param([string]$Message) Write-Host "  [FAIL] $Message" -ForegroundColor $script:Red }
function Write-Info    { param([string]$Message) Write-Host "  → $Message" -ForegroundColor $script:Gray }
function Write-Warn    { param([string]$Message) Write-Host "  [!] $Message" -ForegroundColor Yellow }
function Write-Header  {
    param([string]$Title)
    Write-Host ""
    Write-Host ("═" * 62) -ForegroundColor $script:Orange
    Write-Host "  $Title" -ForegroundColor $script:Orange
    Write-Host ("═" * 62) -ForegroundColor $script:Orange
}

function Write-Log {
    param([string]$Action, [string]$Status, [string]$Details = "")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$timestamp | $env:COMPUTERNAME | $env:USERNAME | $Action | $Status | $Details"
    Add-Content -Path $script:LogPath -Value $line -ErrorAction SilentlyContinue
}

function Show-ProgressBar {
    param([string]$Activity, [int]$PercentComplete, [string]$Status = "Working...")
    Write-Progress -Activity $Activity -Status $Status -PercentComplete $PercentComplete
}

function Ensure-OutputFolder {
    if (-not (Test-Path $script:DefaultOutput)) {
        New-Item -Path $script:DefaultOutput -ItemType Directory -Force | Out-Null
    }
}

function Test-IsAdmin {
    $current = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($current)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Show-ElevationWarning {
    if (-not (Test-IsAdmin)) {
        Write-Host ""
        Write-Warn "Not running as Administrator."
        Write-Info "Some details (full software list, BitLocker, certain hardware) may be incomplete."
        Write-Info "For best results, right-click → Run with PowerShell as Administrator."
        Write-Host ""
    }
}

#endregion

#region Data Collection Functions

function Get-HardwareInfo {
    [CmdletBinding()]
    param()

    $cs   = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
    $cpu  = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    $mb   = Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction SilentlyContinue
    $ram  = Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction SilentlyContinue
    $disks = Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction SilentlyContinue
    $gpu  = Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -First 1

    $totalRAM = [math]::Round(($ram | Measure-Object -Property Capacity -Sum).Sum / 1GB, 2)
    $diskInfo = @()
    foreach ($d in $disks) {
        $diskInfo += [PSCustomObject]@{
            Model     = $d.Model
            SizeGB    = [math]::Round($d.Size / 1GB, 2)
            Serial    = $d.SerialNumber
            Interface = $d.InterfaceType
        }
    }

    [PSCustomObject]@{
        Manufacturer     = $cs.Manufacturer
        Model            = $cs.Model
        SystemType       = $cs.SystemType
        Domain           = $cs.Domain
        SerialNumber     = $bios.SerialNumber
        BIOSVersion      = $bios.SMBIOSBIOSVersion
        BIOSManufacturer = $bios.Manufacturer
        CPUName          = $cpu.Name
        CPUCores         = $cpu.NumberOfCores
        CPULogical       = $cpu.NumberOfLogicalProcessors
        CPUMaxClockMHz   = $cpu.MaxClockSpeed
        TotalRAM_GB      = $totalRAM
        RAMSlots         = @($ram).Count
        Motherboard      = "$($mb.Manufacturer) $($mb.Product)"
        GPU              = $gpu.Name
        Disks            = $diskInfo
    }
}

function Get-BatteryInfo {
    [CmdletBinding()]
    param()

    $batteries = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue
    if (-not $batteries) {
        return [PSCustomObject]@{
            Present          = $false
            Name             = $null
            EstimatedCharge  = $null
            BatteryStatus    = "No battery detected (desktop or battery not present)"
            HealthPercent    = $null
        }
    }

    # Take the first battery (most systems have one)
    $b = $batteries | Select-Object -First 1
    $statusMap = @{
        1 = "Other"
        2 = "Unknown"
        3 = "Fully Charged"
        4 = "Low"
        5 = "Critical"
        6 = "Charging"
        7 = "Charging and High"
        8 = "Charging and Low"
        9 = "Charging and Critical"
        10 = "Undefined"
        11 = "Partially Charged"
    }

    [PSCustomObject]@{
        Present         = $true
        Name            = $b.Name
        EstimatedCharge = $b.EstimatedChargeRemaining
        BatteryStatus   = $statusMap[[int]$b.BatteryStatus]
        HealthPercent   = $b.EstimatedChargeRemaining
    }
}

function Get-MonitorInfo {
    [CmdletBinding()]
    param()

    $monitors = @()

    # Try WmiMonitorID first (more detailed)
    try {
        $monitorIDs = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction Stop
        foreach ($m in $monitorIDs) {
            $name = ($m.UserFriendlyName | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ }) -join ""
            $serial = ($m.SerialNumberID | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ }) -join ""
            $manufacturer = ($m.ManufacturerName | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ }) -join ""

            $monitors += [PSCustomObject]@{
                Name         = if ($name) { $name.Trim() } else { "Unknown Monitor" }
                Manufacturer  = $manufacturer.Trim()
                SerialNumber = $serial.Trim()
                YearOfManufacture = $m.YearOfManufacture
            }
        }
    }
    catch {
        # Fallback
        $desktopMonitors = Get-CimInstance -ClassName Win32_DesktopMonitor -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -eq "OK" -or $_.Name }

        foreach ($m in $desktopMonitors) {
            $monitors += [PSCustomObject]@{
                Name         = $m.Name
                Manufacturer  = $m.MonitorManufacturer
                SerialNumber = $null
                YearOfManufacture = $null
            }
        }
    }

    if (@($monitors).Count -eq 0) {
        $monitors += [PSCustomObject]@{
            Name = "No monitor information available"
            Manufacturer = $null
            SerialNumber = $null
            YearOfManufacture = $null
        }
    }

    return $monitors
}

function Get-BitLockerInfo {
    [CmdletBinding()]
    param()

    $results = @()

    try {
        # Prefer BitLocker module if available
        if (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue) {
            $volumes = Get-BitLockerVolume -ErrorAction Stop
            foreach ($v in $volumes) {
                $results += [PSCustomObject]@{
                    MountPoint       = $v.MountPoint
                    VolumeStatus     = $v.VolumeStatus
                    ProtectionStatus = $v.ProtectionStatus
                    EncryptionMethod = $v.EncryptionMethod
                    EncryptionPct    = $v.EncryptionPercentage
                }
            }
        }
        else {
            # Fallback via manage-bde (works more often without extra modules)
            $output = manage-bde -status 2>$null
            if ($output) {
                $results += [PSCustomObject]@{
                    MountPoint       = "C:"
                    VolumeStatus     = "See manage-bde output"
                    ProtectionStatus = if ($output -match "Protection On") { "On" } else { "Off or Unknown" }
                    EncryptionMethod = $null
                    EncryptionPct    = $null
                    RawOutput        = ($output -join "`n")
                }
            }
        }
    }
    catch {
        $results += [PSCustomObject]@{
            MountPoint       = "N/A"
            VolumeStatus     = "Unable to query"
            ProtectionStatus = "Unknown (may require elevation)"
            EncryptionMethod = $null
            EncryptionPct    = $null
        }
    }

    if (@($results).Count -eq 0) {
        $results += [PSCustomObject]@{
            MountPoint       = "N/A"
            VolumeStatus     = "No information"
            ProtectionStatus = "Unknown"
            EncryptionMethod = $null
            EncryptionPct    = $null
        }
    }

    return $results
}

function Get-OperatingSystemInfo {
    [CmdletBinding()]
    param()

    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
    $hotfixes = Get-HotFix -ErrorAction SilentlyContinue | Sort-Object InstalledOn -Descending | Select-Object -First 5

    [PSCustomObject]@{
        Caption          = $os.Caption
        Version          = $os.Version
        BuildNumber      = $os.BuildNumber
        OSArchitecture   = $os.OSArchitecture
        InstallDate      = $os.InstallDate
        LastBootUpTime   = $os.LastBootUpTime
        RegisteredUser   = $os.RegisteredUser
        SerialNumber     = $os.SerialNumber
        WindowsDirectory = $os.WindowsDirectory
        RecentHotfixes   = $hotfixes | ForEach-Object { "$($_.HotFixID) ($($_.InstalledOn))" }
    }
}

function Get-NetworkInfo {
    [CmdletBinding()]
    param()

    $adapters = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter "IPEnabled = True" -ErrorAction SilentlyContinue
    $results = @()

    foreach ($a in $adapters) {
        $results += [PSCustomObject]@{
            Description    = $a.Description
            MACAddress     = $a.MACAddress
            DHCPEnabled    = $a.DHCPEnabled
            IPAddress      = ($a.IPAddress -join ", ")
            SubnetMask     = ($a.IPSubnet -join ", ")
            DefaultGateway = ($a.DefaultIPGateway -join ", ")
            DNSServers     = ($a.DNSServerSearchOrder -join ", ")
        }
    }
    return $results
}

function Get-SoftwareInventory {
    [CmdletBinding()]
    param()

    $paths = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    $software = @()
    foreach ($path in $paths) {
        $items = Get-ItemProperty $path -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -and $_.DisplayName.Trim() -ne "" } |
            Select-Object DisplayName, DisplayVersion, Publisher, InstallDate, EstimatedSize

        foreach ($item in $items) {
            $software += [PSCustomObject]@{
                Name         = $item.DisplayName
                Version      = $item.DisplayVersion
                Publisher    = $item.Publisher
                InstallDate  = $item.InstallDate
                EstimatedMB  = if ($item.EstimatedSize) { [math]::Round($item.EstimatedSize / 1024, 1) } else { $null }
            }
        }
    }

    $software | Sort-Object Name -Unique
}

function Get-StorageInfo {
    [CmdletBinding()]
    param()

    Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType = 3" -ErrorAction SilentlyContinue |
        Select-Object DeviceID,
            @{N='VolumeName';E={$_.VolumeName}},
            @{N='SizeGB';E={[math]::Round($_.Size / 1GB, 2)}},
            @{N='FreeGB';E={[math]::Round($_.FreeSpace / 1GB, 2)}},
            @{N='UsedPercent';E={
                if ($_.Size -gt 0) { [math]::Round((($_.Size - $_.FreeSpace) / $_.Size) * 100, 1) } else { 0 }
            }},
            FileSystem
}

function Get-UserInfo {
    [CmdletBinding()]
    param()

    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue

    [PSCustomObject]@{
        CurrentUser  = $env:USERNAME
        UserDomain   = $env:USERDOMAIN
        LoggedOnUser = $cs.UserName
        ComputerName = $env:COMPUTERNAME
    }
}

#endregion

#region Main Inventory Function

function Get-AssetInventory {
    <#
    .SYNOPSIS
        Collects a full asset inventory from the local or remote computer.
    .PARAMETER ComputerName
        Target computer. Defaults to local machine.
    .PARAMETER Credential
        Optional credentials for remote collection.
    .EXAMPLE
        Get-AssetInventory
    .EXAMPLE
        Get-AssetInventory -ComputerName "PC-042" -Credential (Get-Credential)
    #>
    [CmdletBinding()]
    param(
        [string]$ComputerName = $env:COMPUTERNAME,
        [System.Management.Automation.PSCredential]$Credential
    )

    $isLocal = ($ComputerName -eq $env:COMPUTERNAME -or $ComputerName -eq "localhost" -or $ComputerName -eq ".")

    Write-Header "Collecting Asset Inventory → $ComputerName"
    Write-Log -Action "Get-AssetInventory" -Status "Started" -Details $ComputerName

    if ($isLocal) { Show-ElevationWarning }

    try {
        if ($isLocal) {
            Show-ProgressBar -Activity "Inventory" -PercentComplete 8  -Status "Hardware..."
            $hardware = Get-HardwareInfo

            Show-ProgressBar -Activity "Inventory" -PercentComplete 18 -Status "Battery..."
            $battery = Get-BatteryInfo

            Show-ProgressBar -Activity "Inventory" -PercentComplete 28 -Status "Monitors..."
            $monitors = Get-MonitorInfo

            Show-ProgressBar -Activity "Inventory" -PercentComplete 38 -Status "BitLocker..."
            $bitlocker = Get-BitLockerInfo

            Show-ProgressBar -Activity "Inventory" -PercentComplete 48 -Status "Operating System..."
            $os = Get-OperatingSystemInfo

            Show-ProgressBar -Activity "Inventory" -PercentComplete 58 -Status "Network..."
            $network = Get-NetworkInfo

            Show-ProgressBar -Activity "Inventory" -PercentComplete 68 -Status "Storage..."
            $storage = Get-StorageInfo

            Show-ProgressBar -Activity "Inventory" -PercentComplete 80 -Status "Software..."
            $software = Get-SoftwareInventory

            Show-ProgressBar -Activity "Inventory" -PercentComplete 92 -Status "User info..."
            $user = Get-UserInfo
        }
        else {
            # Remote collection
            $cimParams = @{ ComputerName = $ComputerName; ErrorAction = "Stop" }
            if ($Credential) { $cimParams.Credential = $Credential }

            Write-Info "Connecting to remote computer via CIM/WinRM..."

            Show-ProgressBar -Activity "Inventory" -PercentComplete 15 -Status "Connecting..."
            $session = New-CimSession @cimParams

            Show-ProgressBar -Activity "Inventory" -PercentComplete 30 -Status "Hardware..."
            $cs   = Get-CimInstance -CimSession $session -ClassName Win32_ComputerSystem
            $bios = Get-CimInstance -CimSession $session -ClassName Win32_BIOS
            $cpu  = Get-CimInstance -CimSession $session -ClassName Win32_Processor | Select-Object -First 1
            $ram  = Get-CimInstance -CimSession $session -ClassName Win32_PhysicalMemory
            $disks= Get-CimInstance -CimSession $session -ClassName Win32_DiskDrive

            $hardware = [PSCustomObject]@{
                Manufacturer = $cs.Manufacturer
                Model        = $cs.Model
                SerialNumber = $bios.SerialNumber
                CPUName      = $cpu.Name
                CPUCores     = $cpu.NumberOfCores
                TotalRAM_GB  = [math]::Round(($ram | Measure-Object Capacity -Sum).Sum / 1GB, 2)
                Disks        = $disks | ForEach-Object {
                    [PSCustomObject]@{ Model = $_.Model; SizeGB = [math]::Round($_.Size/1GB,2) }
                }
                GPU          = $null
            }

            $battery  = [PSCustomObject]@{ Present = $false; BatteryStatus = "Not collected remotely" }
            $monitors = @([PSCustomObject]@{ Name = "Not collected remotely" })
            $bitlocker = @([PSCustomObject]@{ ProtectionStatus = "Not collected remotely" })

            Show-ProgressBar -Activity "Inventory" -PercentComplete 55 -Status "OS & Storage..."
            $osCim = Get-CimInstance -CimSession $session -ClassName Win32_OperatingSystem
            $os = [PSCustomObject]@{
                Caption        = $osCim.Caption
                Version        = $osCim.Version
                BuildNumber    = $osCim.BuildNumber
                OSArchitecture = $osCim.OSArchitecture
                LastBootUpTime = $osCim.LastBootUpTime
            }

            $storage = Get-CimInstance -CimSession $session -ClassName Win32_LogicalDisk -Filter "DriveType=3" |
                Select-Object DeviceID,
                    @{N='SizeGB';E={[math]::Round($_.Size/1GB,2)}},
                    @{N='FreeGB';E={[math]::Round($_.FreeSpace/1GB,2)}},
                    @{N='UsedPercent';E={ if ($_.Size -gt 0) { [math]::Round((($_.Size - $_.FreeSpace)/$_.Size)*100,1) } else { 0 } }}

            $network = Get-CimInstance -CimSession $session -ClassName Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" |
                Select-Object Description, MACAddress, @{N='IPAddress';E={$_.IPAddress -join ', '}}

            $software = @()
            $user = [PSCustomObject]@{ ComputerName = $ComputerName; LoggedOnUser = $cs.UserName }

            Remove-CimSession $session -ErrorAction SilentlyContinue
        }

        Show-ProgressBar -Activity "Inventory" -PercentComplete 100 -Status "Complete"
        Write-Progress -Activity "Inventory" -Completed

        $inventory = [PSCustomObject]@{
            CollectedAt     = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            ComputerName    = $ComputerName
            ModuleVersion   = $script:ModuleVersion
            User            = $user
            Hardware        = $hardware
            Battery         = $battery
            Monitors        = $monitors
            BitLocker       = $bitlocker
            OperatingSystem = $os
            Network         = $network
            Storage         = $storage
            Software        = $software
            SoftwareCount   = @($software).Count
        }

        Write-Success "Inventory collected successfully"
        Write-Log -Action "Get-AssetInventory" -Status "Success" -Details $ComputerName

        return $inventory
    }
    catch {
        Write-Fail "Failed to collect inventory: $($_.Exception.Message)"
        Write-Log -Action "Get-AssetInventory" -Status "Failed" -Details $_.Exception.Message
        return $null
    }
}

#endregion

#region Export Functions

function Export-AssetInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Inventory,

        [ValidateSet("CSV", "JSON", "HTML")]
        [string]$Format = "HTML",

        [string]$Path
    )

    Ensure-OutputFolder

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $safeName  = ($Inventory.ComputerName -replace '[\\/:*?"<>|]', '_')

    if (-not $Path) {
        $Path = Join-Path $script:DefaultOutput "$safeName`_Inventory_$timestamp.$($Format.ToLower())"
    }

    try {
        switch ($Format) {
            "JSON" {
                $Inventory | ConvertTo-Json -Depth 8 | Out-File -FilePath $Path -Encoding UTF8
            }
            "CSV" {
                $flat = [PSCustomObject]@{
                    ComputerName     = $Inventory.ComputerName
                    CollectedAt      = $Inventory.CollectedAt
                    Manufacturer     = $Inventory.Hardware.Manufacturer
                    Model            = $Inventory.Hardware.Model
                    SerialNumber     = $Inventory.Hardware.SerialNumber
                    CPU              = $Inventory.Hardware.CPUName
                    RAM_GB           = $Inventory.Hardware.TotalRAM_GB
                    OS               = $Inventory.OperatingSystem.Caption
                    OSVersion        = $Inventory.OperatingSystem.Version
                    LastBoot         = $Inventory.OperatingSystem.LastBootUpTime
                    BitLockerStatus  = ($Inventory.BitLocker | Select-Object -First 1).ProtectionStatus
                    BatteryPresent   = $Inventory.Battery.Present
                    BatteryCharge    = $Inventory.Battery.EstimatedCharge
                    SoftwareCount    = $Inventory.SoftwareCount
                    PrimaryIP        = if ($Inventory.Network) { ($Inventory.Network | Select-Object -First 1).IPAddress } else { "" }
                }
                $flat | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
            }
            "HTML" {
                $html = Build-HtmlReport -Inventory $Inventory
                $html | Out-File -FilePath $Path -Encoding UTF8
            }
        }

        Write-Success "Exported to: $Path"
        Write-Log -Action "Export-AssetInventory" -Status "Success" -Details $Path
        return $Path
    }
    catch {
        Write-Fail "Export failed: $($_.Exception.Message)"
        Write-Log -Action "Export-AssetInventory" -Status "Failed" -Details $_.Exception.Message
        return $null
    }
}

function Build-HtmlReport {
    param([psobject]$Inventory)

    $hw = $Inventory.Hardware
    $os = $Inventory.OperatingSystem
    $bat = $Inventory.Battery

    $netRows = ""
    foreach ($n in $Inventory.Network) {
        $netRows += "<tr><td>$($n.Description)</td><td>$($n.MACAddress)</td><td>$($n.IPAddress)</td><td>$($n.DefaultGateway)</td></tr>"
    }

    $storageRows = ""
    foreach ($s in $Inventory.Storage) {
        $storageRows += "<tr><td>$($s.DeviceID)</td><td>$($s.VolumeName)</td><td>$($s.SizeGB) GB</td><td>$($s.FreeGB) GB</td><td>$($s.UsedPercent)%</td></tr>"
    }

    $monitorRows = ""
    foreach ($m in $Inventory.Monitors) {
        $monitorRows += "<tr><td>$($m.Name)</td><td>$($m.Manufacturer)</td><td>$($m.SerialNumber)</td><td>$($m.YearOfManufacture)</td></tr>"
    }

    $bitlockerRows = ""
    foreach ($b in $Inventory.BitLocker) {
        $bitlockerRows += "<tr><td>$($b.MountPoint)</td><td>$($b.VolumeStatus)</td><td>$($b.ProtectionStatus)</td><td>$($b.EncryptionMethod)</td><td>$($b.EncryptionPct)</td></tr>"
    }

    $softwareRows = ""
    $topSoftware = $Inventory.Software | Select-Object -First 40
    foreach ($sw in $topSoftware) {
        $softwareRows += "<tr><td>$($sw.Name)</td><td>$($sw.Version)</td><td>$($sw.Publisher)</td></tr>"
    }

    $batterySection = if ($bat.Present) {
        "<div class='label'>Battery</div><div class='value'>$($bat.Name) — $($bat.EstimatedCharge)% ($($bat.BatteryStatus))</div>"
    } else {
        "<div class='label'>Battery</div><div class='value'>No battery detected</div>"
    }

    @"
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <title>Asset Inventory - $($Inventory.ComputerName)</title>
    <style>
        body { font-family: Segoe UI, Arial, sans-serif; background: #1a1a1a; color: #eee; margin: 0; padding: 20px; }
        h1 { color: #f5a623; margin-bottom: 5px; }
        h2 { color: #f5a623; border-bottom: 1px solid #444; padding-bottom: 6px; margin-top: 30px; }
        .meta { color: #aaa; margin-bottom: 20px; }
        table { border-collapse: collapse; width: 100%; margin-bottom: 20px; }
        th, td { border: 1px solid #444; padding: 8px 12px; text-align: left; }
        th { background: #333; color: #f5a623; }
        tr:nth-child(even) { background: #252525; }
        .card { background: #222; padding: 15px 20px; border-radius: 6px; margin-bottom: 15px; }
        .label { color: #888; font-size: 0.85em; }
        .value { font-size: 1.1em; margin-bottom: 8px; }
    </style>
</head>
<body>
    <h1>Asset Inventory</h1>
    <div class="meta">
        Computer: <strong>$($Inventory.ComputerName)</strong> &nbsp;|&nbsp;
        Collected: $($Inventory.CollectedAt) &nbsp;|&nbsp;
        Toolkit v$($Inventory.ModuleVersion)
    </div>

    <h2>Hardware</h2>
    <div class="card">
        <div class="label">Manufacturer / Model</div>
        <div class="value">$($hw.Manufacturer) — $($hw.Model)</div>
        <div class="label">Serial Number</div>
        <div class="value">$($hw.SerialNumber)</div>
        <div class="label">CPU</div>
        <div class="value">$($hw.CPUName) ($($hw.CPUCores) cores / $($hw.CPULogical) logical)</div>
        <div class="label">Memory</div>
        <div class="value">$($hw.TotalRAM_GB) GB</div>
        <div class="label">GPU</div>
        <div class="value">$($hw.GPU)</div>
        $batterySection
    </div>

    <h2>Monitors</h2>
    <table>
        <tr><th>Name</th><th>Manufacturer</th><th>Serial</th><th>Year</th></tr>
        $monitorRows
    </table>

    <h2>BitLocker / Encryption</h2>
    <table>
        <tr><th>Drive</th><th>Volume Status</th><th>Protection</th><th>Method</th><th>%</th></tr>
        $bitlockerRows
    </table>

    <h2>Operating System</h2>
    <div class="card">
        <div class="label">OS</div>
        <div class="value">$($os.Caption) ($($os.OSArchitecture))</div>
        <div class="label">Version / Build</div>
        <div class="value">$($os.Version) — Build $($os.BuildNumber)</div>
        <div class="label">Last Boot</div>
        <div class="value">$($os.LastBootUpTime)</div>
    </div>

    <h2>Network Adapters</h2>
    <table>
        <tr><th>Description</th><th>MAC</th><th>IP Address</th><th>Gateway</th></tr>
        $netRows
    </table>

    <h2>Storage</h2>
    <table>
        <tr><th>Drive</th><th>Volume</th><th>Size</th><th>Free</th><th>Used</th></tr>
        $storageRows
    </table>

    <h2>Installed Software (Top 40)</h2>
    <p class="meta">Total detected: $($Inventory.SoftwareCount)</p>
    <table>
        <tr><th>Name</th><th>Version</th><th>Publisher</th></tr>
        $softwareRows
    </table>

    <p style="color:#666; margin-top:40px; font-size:0.85em;">
        Generated by IT Asset Inventory Toolkit v$($Inventory.ModuleVersion)
    </p>
</body>
</html>
"@
}

#endregion

#region Display & Menu

function Show-InventorySummary {
    param([psobject]$Inventory)

    if (-not $Inventory) { return }

    Write-Header "Inventory Summary — $($Inventory.ComputerName)"

    Write-Host ""
    Write-Host "  Hardware" -ForegroundColor $script:Cyan
    Write-Info "Manufacturer : $($Inventory.Hardware.Manufacturer)"
    Write-Info "Model        : $($Inventory.Hardware.Model)"
    Write-Info "Serial       : $($Inventory.Hardware.SerialNumber)"
    Write-Info "CPU          : $($Inventory.Hardware.CPUName)"
    Write-Info "RAM          : $($Inventory.Hardware.TotalRAM_GB) GB"
    Write-Info "GPU          : $($Inventory.Hardware.GPU)"

    Write-Host ""
    Write-Host "  Battery" -ForegroundColor $script:Cyan
    if ($Inventory.Battery.Present) {
        Write-Info "Charge       : $($Inventory.Battery.EstimatedCharge)%"
        Write-Info "Status       : $($Inventory.Battery.BatteryStatus)"
    } else {
        Write-Info "No battery detected"
    }

    Write-Host ""
    Write-Host "  Monitors" -ForegroundColor $script:Cyan
    foreach ($m in $Inventory.Monitors) {
        Write-Info "$($m.Name) $(if($m.SerialNumber){"($($m.SerialNumber))"})"
    }

    Write-Host ""
    Write-Host "  BitLocker" -ForegroundColor $script:Cyan
    foreach ($b in $Inventory.BitLocker) {
        Write-Info "$($b.MountPoint) → Protection: $($b.ProtectionStatus)"
    }

    Write-Host ""
    Write-Host "  Operating System" -ForegroundColor $script:Cyan
    Write-Info "OS           : $($Inventory.OperatingSystem.Caption)"
    Write-Info "Version      : $($Inventory.OperatingSystem.Version)"
    Write-Info "Last Boot    : $($Inventory.OperatingSystem.LastBootUpTime)"

    Write-Host ""
    Write-Host "  Storage" -ForegroundColor $script:Cyan
    foreach ($s in $Inventory.Storage) {
        Write-Info "$($s.DeviceID)  $($s.SizeGB) GB total — $($s.FreeGB) GB free ($($s.UsedPercent)% used)"
    }

    Write-Host ""
    Write-Host "  Network" -ForegroundColor $script:Cyan
    foreach ($n in $Inventory.Network) {
        Write-Info "$($n.Description) — $($n.IPAddress)"
    }

    Write-Host ""
    Write-Host "  Software" -ForegroundColor $script:Cyan
    Write-Info "Installed programs detected: $($Inventory.SoftwareCount)"
    Write-Host ""
}

function Show-MainMenu {
    Clear-Host
    Write-Host ""
    Write-Host "  ██╗████████╗     █████╗ ███████╗███████╗███████╗████████╗" -ForegroundColor $script:Orange
    Write-Host "  ██║╚══██╔══╝    ██╔══██╗██╔════╝██╔════╝██╔════╝╚══██╔══╝" -ForegroundColor $script:Orange
    Write-Host "  ██║   ██║       ███████║███████╗███████╗█████╗     ██║   " -ForegroundColor $script:Orange
    Write-Host "  ██║   ██║       ██╔══██║╚════██║╚════██║██╔══╝     ██║   " -ForegroundColor $script:Orange
    Write-Host "  ██║   ██║       ██║  ██║███████║███████║███████╗   ██║   " -ForegroundColor $script:Orange
    Write-Host "  ╚═╝   ╚═╝       ╚═╝  ╚═╝╚══════╝╚══════╝╚══════╝   ╚═╝   " -ForegroundColor $script:Orange
    Write-Host ""
    Write-Host "           IT ASSET INVENTORY TOOLKIT  •  v$script:ModuleVersion" -ForegroundColor $script:White
    Write-Host "           Log: $script:LogPath" -ForegroundColor $script:Gray
    Write-Host ""
    Write-Host ("─" * 62) -ForegroundColor $script:Orange
    Write-Host ""
    Write-Host "   [1]  Scan Local Computer" -ForegroundColor $script:White
    Write-Host "   [2]  Scan Remote Computer" -ForegroundColor $script:White
    Write-Host "   [3]  Export Last Scan (HTML)" -ForegroundColor $script:White
    Write-Host "   [4]  Export Last Scan (CSV)" -ForegroundColor $script:White
    Write-Host "   [5]  Export Last Scan (JSON)" -ForegroundColor $script:White
    Write-Host "   [6]  Open Output Folder" -ForegroundColor $script:White
    Write-Host ""
    Write-Host "   [L]  Open today's log" -ForegroundColor $script:Gray
    Write-Host "   [0]  Exit" -ForegroundColor $script:Gray
    Write-Host ""
    Write-Host ("─" * 62) -ForegroundColor $script:Orange
    Write-Host ""
}

function Start-AssetInventoryMenu {
    $script:LastInventory = $null

    do {
        Show-MainMenu
        Write-Orange "  Select an option: " -NoNewline
        $choice = Read-Host

        switch ($choice.ToUpper()) {
            "1" {
                $script:LastInventory = Get-AssetInventory
                if ($script:LastInventory) {
                    Show-InventorySummary -Inventory $script:LastInventory
                }
                Pause
            }
            "2" {
                Write-Host ""
                Write-Orange "  Enter computer name or IP: " -NoNewline
                $target = Read-Host
                if ($target) {
                    Write-Host ""
                    Write-Orange "  Use different credentials? (Y/N): " -NoNewline
                    $useCred = Read-Host
                    $cred = $null
                    if ($useCred -match '^[Yy]') {
                        $cred = Get-Credential -Message "Enter credentials for $target"
                    }
                    $script:LastInventory = Get-AssetInventory -ComputerName $target -Credential $cred
                    if ($script:LastInventory) {
                        Show-InventorySummary -Inventory $script:LastInventory
                    }
                }
                Pause
            }
            "3" {
                if ($script:LastInventory) {
                    Export-AssetInventory -Inventory $script:LastInventory -Format HTML
                } else {
                    Write-Host "  No scan results yet. Run a scan first." -ForegroundColor $script:Red
                }
                Pause
            }
            "4" {
                if ($script:LastInventory) {
                    Export-AssetInventory -Inventory $script:LastInventory -Format CSV
                } else {
                    Write-Host "  No scan results yet. Run a scan first." -ForegroundColor $script:Red
                }
                Pause
            }
            "5" {
                if ($script:LastInventory) {
                    Export-AssetInventory -Inventory $script:LastInventory -Format JSON
                } else {
                    Write-Host "  No scan results yet. Run a scan first." -ForegroundColor $script:Red
                }
                Pause
            }
            "6" {
                Ensure-OutputFolder
                Start-Process explorer.exe -ArgumentList $script:DefaultOutput
            }
            "L" {
                if (Test-Path $script:LogPath) {
                    notepad $script:LogPath
                } else {
                    Write-Host "  No log file yet." -ForegroundColor $script:Gray
                    Start-Sleep -Seconds 1
                }
            }
            "0" {
                Write-Host ""
                Write-Orange "  Exiting IT Asset Inventory Toolkit."
                Write-Host ""
                return
            }
            default {
                Write-Host "  Invalid selection." -ForegroundColor $script:Red
                Start-Sleep -Seconds 1
            }
        }
    } while ($true)
}

#endregion

# Export public functions
Export-ModuleMember -Function @(
    'Get-AssetInventory',
    'Export-AssetInventory',
    'Show-InventorySummary',
    'Start-AssetInventoryMenu',
    'Get-HardwareInfo',
    'Get-BatteryInfo',
    'Get-MonitorInfo',
    'Get-BitLockerInfo',
    'Get-OperatingSystemInfo',
    'Get-NetworkInfo',
    'Get-SoftwareInventory',
    'Get-StorageInfo'
)
