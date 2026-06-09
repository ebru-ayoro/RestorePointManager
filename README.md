# Windows Restore Point Manager

A lightweight PowerShell GUI app for Windows 11 (25H2+) to manually and automatically create, view, and delete System Restore points.

## Features

- **Manual restore points** — enter a description and create instantly
- **Auto mode** — schedule periodic restore points (1–168 hour intervals), runs in system tray
- **List existing points** — view Sequence#, Description, Created date, and Type
- **Delete restore points** — select and remove unwanted points
- **Startup option** — one-click toggle for auto-launch at login (minimized to tray)
- **System Protection status** — shows whether protection is active on your system drive

## Requirements

- Windows 11 25H2 (or any modern Windows with System Restore support)
- PowerShell 5.1+
- Administrator privileges (required for creating/deleting restore points)
- System Protection must be enabled on at least one drive

## Installation

1. Download `RestorePointManager.ps1` and `Run_RestorePointManager.bat`
2. Place both files in the same folder
3. Double-click `Run_RestorePointManager.bat` (auto-elevates to admin)

> **Note:** You can also run `RestorePointManager.ps1` directly from an elevated PowerShell prompt.

## Usage

### Enable System Protection (if needed)

1. Open **System Properties** → **System Protection** tab
2. Select your system drive (usually C:) → click **Configure**
3. Select **Turn on system protection** → adjust max usage → **OK**

### Manual Creation

1. Launch the app
2. Type a description (or keep the auto-generated one)
3. Click **Create**

### Automatic Scheduling

1. Check **"Auto-create every"**
2. Set the interval in hours (default: 1)
3. The app minimizes to the system tray and creates restore points on schedule

### Managing Points

- **Refresh** the list to see latest points
- **Delete Selected** removes the chosen restore point

## How It Works

The app uses two methods to create restore points (fallback):

1. **Win32 API** (`SRSetRestorePointW` via P/Invoke) — most reliable on modern Windows
2. **WMI** (`Invoke-CimMethod` on `SystemRestore` class) — fallback if the API fails

Listing and deleting use the WMI `SystemRestore` class.

## Files

| File | Purpose |
|------|---------|
| `RestorePointManager.ps1` | Main application script (PowerShell GUI) |
| `Run_RestorePointManager.bat` | Launcher that auto-elevates to administrator |

## License

MIT — see [LICENSE](LICENSE) for details.
