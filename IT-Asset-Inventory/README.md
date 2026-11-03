# IT Asset Inventory Toolkit

**Windows Hardware • Software • Network • Security Inventory for Tier 1 / Tier 2**

A clean, menu-driven PowerShell toolkit that collects detailed asset information from local or remote Windows computers and exports professional reports (HTML, CSV, JSON).

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue)
![Platform](https://img.shields.io/badge/Platform-Windows%2010%2F11-lightgrey)
![Version](https://img.shields.io/badge/Version-1.1.0-orange)
![License](https://img.shields.io/badge/License-MIT-green)

---

## Features

| Category | What it collects |
|----------|------------------|
| **Hardware** | Manufacturer, Model, Serial, CPU, RAM, GPU, Disks, Motherboard |
| **Battery** | Presence, charge level, status (great for laptop fleets) |
| **Monitors** | Connected displays, manufacturer, serial, year |
| **BitLocker** | Protection status, encryption method, percentage |
| **Operating System** | Caption, Version, Build, Architecture, Last Boot, recent hotfixes |
| **Network** | Adapters, MAC, IP, Subnet, Gateway, DNS |
| **Storage** | Logical drives with size, free space, and usage % |
| **Software** | Installed programs (32-bit + 64-bit) from registry |
| **Remote Support** | Scan remote machines via WinRM / CIM + credential prompt |
| **Exports** | Styled HTML report, CSV summary, full JSON |
| **Usability** | Admin elevation warning, progress bars, daily logging |

---

## Quick Start

### Option 1 – Interactive Menu (recommended)

1. Download or clone this repository
2. Right-click `Invoke-AssetInventory.ps1` → **Run with PowerShell**  
   *(For best results, run as Administrator)*

### Option 2 – Use as a module

```powershell
Import-Module .\AssetInventory.psm1

# Scan local computer
$inv = Get-AssetInventory
Show-InventorySummary -Inventory $inv

# Export results
Export-AssetInventory -Inventory $inv -Format HTML
Export-AssetInventory -Inventory $inv -Format CSV
Export-AssetInventory -Inventory $inv -Format JSON

# Scan a remote computer
$inv = Get-AssetInventory -ComputerName "PC-042" -Credential (Get-Credential)
```

---

## Requirements

- Windows 10 or Windows 11
- PowerShell 5.1 or later
- **Administrator rights recommended** (especially for BitLocker and complete software list)
- For remote scans: WinRM enabled on the target + appropriate permissions

---

## Output

Reports are saved to the `output` folder by default:

```
output/
├── DESKTOP-ABC123_Inventory_20261103_154211.html
├── DESKTOP-ABC123_Inventory_20261103_154211.csv
└── DESKTOP-ABC123_Inventory_20261103_154211.json
```

The HTML report uses a dark theme and includes hardware, battery, monitors, BitLocker, network, storage, and software.

---

## Project Structure

```
IT-Asset-Inventory/
├── AssetInventory.psm1         # Main module (v1.1.0)
├── Invoke-AssetInventory.ps1   # Menu launcher
├── README.md
├── LICENSE
├── .gitignore
├── output/                     # Generated reports land here
└── docs/
```

---

## Example Use Cases

- Quick audit of a user’s machine before a hardware refresh
- Collect serial numbers, models, and monitor info for asset tracking
- Check BitLocker status across machines
- Generate a clean report to attach to a ticket
- Baseline software inventory for compliance checks
- Remote scan of machines on the network (when WinRM is available)

---

## What’s New in v1.1.0

- Admin elevation detection + friendly warning
- Battery information (charge + status)
- Monitor / display inventory
- BitLocker protection status
- Improved remote scan credential prompt
- Version shown in menu and HTML reports

---

## Safety & Notes

- Software inventory reads from the Uninstall registry keys only.
- BitLocker information is most accurate when run as Administrator.
- Remote collection of battery, monitors, and BitLocker is limited (by design for speed/reliability).
- HTML reports contain only inventory data — no credentials or secrets.

---

## License

MIT License — free to use, modify, and share.

---

**Built for helpdesk engineers who want clean, useful data.**
