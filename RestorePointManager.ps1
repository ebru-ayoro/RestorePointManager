Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ── Admin check ──────────────────────────────────────────────
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $result = [System.Windows.Forms.MessageBox]::Show(
        "This app requires administrator privileges.`nRestart as administrator?",
        "Admin Required",
        "YesNo", "Warning"
    )
    if ($result -eq 'Yes') {
        Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -PassThru
    }
    return
}

# ── P/Invoke ─────────────────────────────────────────────────
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class SrAPI {
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
    public static extern int SRSetRestorePointW(ref RESTOREPOINTINFOW pRestorePtSpec, out STATEMGRSTATUS pSMgrStatus);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct RESTOREPOINTINFOW {
        public int dwEventType;
        public int dwRestorePtType;
        public long llSequenceNumber;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string szDescription;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct STATEMGRSTATUS {
        public int nStatus;
        public long llSequenceNumber;
    }
    public const int BEGIN_SYSTEM_CHANGE = 100;
    public const int END_SYSTEM_CHANGE = 101;
    public const int MODIFY_SETTINGS = 12;
    public static bool Create(string desc) {
        var rpi = new RESTOREPOINTINFOW();
        rpi.dwEventType = BEGIN_SYSTEM_CHANGE;
        rpi.dwRestorePtType = MODIFY_SETTINGS;
        rpi.llSequenceNumber = 0;
        rpi.szDescription = desc;
        STATEMGRSTATUS status;
        int ret = SRSetRestorePointW(ref rpi, out status);
        if (ret != 0) {
            rpi.dwEventType = END_SYSTEM_CHANGE;
            rpi.llSequenceNumber = status.llSequenceNumber;
            SRSetRestorePointW(ref rpi, out status);
            return true;
        }
        return false;
    }
}
public class DwmAPI {
    [DllImport("dwmapi.dll", PreserveSig = true)]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
    public static extern int SetWindowTheme(IntPtr hWnd, string pszSubAppName, string pszSubIdList);
    public const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
    public static void SetDarkMode(IntPtr hwnd, bool enabled) {
        int value = enabled ? 1 : 0;
        DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref value, 4);
    }
    public static void SetDarkListView(IntPtr hwnd) {
        SetWindowTheme(hwnd, "DarkMode_Explorer", null);
    }
}
"@

# ── WMI helpers ──────────────────────────────────────────────
function Get-RestorePoints {
    try {
        return Get-CimInstance -Namespace "root/default" -ClassName "SystemRestore" -ErrorAction Stop
    } catch {
        return @()
    }
}

function New-RestorePointManually {
    param([string]$Description)
    $lastErr = ""
    try {
        Checkpoint-Computer -Description $Description -RestorePointType "MODIFY_SETTINGS" -ErrorAction Stop
        return $true
    } catch { $lastErr = "Checkpoint-Computer: $($_.Exception.Message)" }
    try {
        $params = @{
            Description       = $Description
            RestorePointType  = [uint32]12
            EventType         = [uint32]100
        }
        Invoke-CimMethod -Namespace "root/default" -ClassName "SystemRestore" -MethodName "CreateRestorePoint" -Arguments $params -ErrorAction Stop
        $params.EventType = [uint32]101
        Invoke-CimMethod -Namespace "root/default" -ClassName "SystemRestore" -MethodName "CreateRestorePoint" -Arguments $params -ErrorAction Stop
        return $true
    } catch { $lastErr = "WMI: $($_.Exception.Message)" }
    try {
        if ([SrAPI]::Create($Description)) { return $true }
    } catch { $lastErr = "P/Invoke: $($_.Exception.Message)" }
    Write-Warning "All restore point methods failed. Last error: $lastErr"
    return $false
}

function Remove-RestorePoint {
    param([uint32]$SequenceNumber)
    try {
        Invoke-CimMethod -Namespace "root/default" -ClassName "SystemRestore" -MethodName "Remove" -Arguments @{ SequenceNumber = $SequenceNumber } -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

# ── Theme detection ──────────────────────────────────────────
function Get-SystemTheme {
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    $appsLight = (Get-ItemProperty -Path $key -Name 'AppsUseLightTheme' -ErrorAction SilentlyContinue).AppsUseLightTheme
    if ($appsLight -eq 0) { return "Dark" }
    return "Light"
}

$theme = Get-SystemTheme
$isDarkTheme = ($theme -eq "Dark")
if ($theme -eq "Dark") {
    $c = @{
        bg        = "#1e1e1e"
        card      = "#2d2d2d"
        text      = "#e0e0e0"
        accent    = "#0078d4"
        accentHov = "#106ebe"
        danger    = "#c42b1c"
        success   = "#2e7d32"
        border    = "#3d3d3d"
        muted     = "#6e6e6e"
        inputBg   = "#3d3d3d"
        inputText = "#e0e0e0"
    }
} else {
    $c = @{
        bg        = "#f3f3f3"
        card      = "#ffffff"
        text      = "#1e1e1e"
        accent    = "#0078d4"
        accentHov = "#106ebe"
        danger    = "#c42b1c"
        success   = "#2e7d32"
        border    = "#d0d0d0"
        muted     = "#8e8e8e"
        inputBg   = "#ffffff"
        inputText = "#1e1e1e"
    }
}

function FromHex($h) { [System.Drawing.ColorTranslator]::FromHtml($h) }

# ── Toggle state store ──────────────────────────────────────
$script:toggleStore = @{}
$script:toggleIdCounter = 0

# ── Toggle switch ────────────────────────────────────────────
function New-Toggle {
    param($X, $Y, $Initial, $Text, $OnToggle, $Tip)
    $id = $script:toggleIdCounter++

    $container = New-Object System.Windows.Forms.Panel
    $container.Location = New-Object System.Drawing.Point($X, $Y)
    $container.Size = New-Object System.Drawing.Size(170, 24)
    $container.BackColor = [System.Drawing.Color]::Transparent

    $track = New-Object System.Windows.Forms.Panel
    $track.Size = New-Object System.Drawing.Size(44, 24)
    $track.Location = New-Object System.Drawing.Point(0, 0)
    $track.Font = New-Object System.Drawing.Font("Segoe UI", 7.0, [System.Drawing.FontStyle]::Bold)
    $track.Cursor = "Hand"
    $track.Tag = $id

    $trkGp = New-Object System.Drawing.Drawing2D.GraphicsPath
    $trkGp.AddArc(0, 0, 24, 24, 90, 180)
    $trkGp.AddArc(20, 0, 24, 24, 270, 180)
    $trkGp.CloseFigure()
    $track.Region = New-Object System.Drawing.Region($trkGp)
    $trkGp.Dispose()

    $thumb = New-Object System.Windows.Forms.Panel
    $thumb.Size = New-Object System.Drawing.Size(18, 18)
    $thumb.Cursor = "Hand"

    $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
    $gp.AddEllipse(0, 0, 18, 18)
    $thumb.Region = New-Object System.Drawing.Region($gp)
    $gp.Dispose()
    $thumb.BackColor = [System.Drawing.Color]::White

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point(52, 2)
    $label.Size = New-Object System.Drawing.Size(115, 20)
    $label.TextAlign = "MiddleLeft"
    $label.BackColor = [System.Drawing.Color]::Transparent

    $track.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $tid = $s.Tag
        if ($null -eq $tid) { return }
        $d = $script:toggleStore[$tid]
        if (-not $d) { return }
        $txt = if ($d.state) { "ON" } else { "OFF" }
        $fg = if ($d.state) { [System.Drawing.Color]::White } else { [System.Drawing.Color]::FromArgb(180,180,180) }
        $sf = [System.Drawing.StringFormat]::GenericDefault
        $sf.Alignment = [System.Drawing.StringAlignment]::Near
        $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
        $brush = New-Object System.Drawing.SolidBrush($fg)
        $rect = if ($d.state) { New-Object System.Drawing.RectangleF(0, 0, 22, 24) } else { New-Object System.Drawing.RectangleF(22, 0, 22, 24) }
        $g.DrawString($txt, $s.Font, $brush, $rect, $sf)
        $brush.Dispose()
        $sf.Dispose()
    })

    $container.Controls.Add($label)
    $container.Controls.Add($track)
    $track.Controls.Add($thumb)

    $script:toggleStore[$id] = @{
        state = $Initial
        callback = $OnToggle
        track = $track
        thumb = $thumb
    }

    if ($Initial) {
        $track.BackColor = FromHex $c.accent
        $thumb.Location = New-Object System.Drawing.Point(24, 3)
    } else {
        $track.BackColor = FromHex $c.muted
        $thumb.Location = New-Object System.Drawing.Point(2, 3)
    }

    $thumb.Tag = $id
    $label.Tag = $id

    $handler = {
        $iid = $this.Tag
        if ($null -eq $iid) { return }
        $d = $script:toggleStore[$iid]
        if (-not $d) { return }
        $d.state = -not $d.state
        if ($d.state) {
            $d.track.BackColor = FromHex $c.accent
            $d.thumb.Location = New-Object System.Drawing.Point(24, 3)
        } else {
            $d.track.BackColor = FromHex $c.muted
            $d.thumb.Location = New-Object System.Drawing.Point(2, 3)
        }
        $d.track.Invalidate()
        if ($d.callback) { & $d.callback $d.state }
    }

    $track.Add_Click($handler)
    $thumb.Add_Click($handler)

    if ($Tip) {
        $Tip.SetToolTip($track, $Text)
        $Tip.SetToolTip($thumb, $Text)
        $Tip.SetToolTip($label, $Text)
    }

    return $container
}

# ── Tray / Background ────────────────────────────────────────
$autoMode = $false
$autoInterval = 1
$autoTimer = New-Object System.Windows.Forms.Timer
$autoTimer.Interval = 3600000

$trayIcon = New-Object System.Windows.Forms.NotifyIcon
$trayIcon.Icon = [System.Drawing.SystemIcons]::Shield
$trayIcon.Text = "Restore Point Manager"

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$showItem = New-Object System.Windows.Forms.ToolStripMenuItem("Show Window")
$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem("Exit")
$trayMenu.Items.AddRange(@($showItem, $exitItem))
$trayIcon.ContextMenuStrip = $trayMenu

# ── Startup path ─────────────────────────────────────────────
$startupPath = [System.IO.Path]::Combine(
    [Environment]::GetFolderPath("Startup"),
    "RestorePointManager.ps1.lnk"
)

# ── Main Form ────────────────────────────────────────────────
$form = New-Object System.Windows.Forms.Form
$form.Text = "Restore Point Manager"
$form.Size = New-Object System.Drawing.Size(820, 620)
$form.StartPosition = "CenterScreen"
$form.MinimumSize = New-Object System.Drawing.Size(650, 480)
$form.BackColor = FromHex $c.bg
$form.ForeColor = FromHex $c.text
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)
$form.Icon = [System.Drawing.SystemIcons]::Shield
$form.add_FormClosing({
    param($s, $e)
    $e.Cancel = $true
    $form.Hide()
})

# ── Root layout ──────────────────────────────────────────────
$root = New-Object System.Windows.Forms.TableLayoutPanel
$root.Dock = "Fill"
$root.ColumnCount = 1
$root.RowCount = 4
$root.Padding = New-Object System.Windows.Forms.Padding(12)
$root.BackColor = FromHex $c.bg
$form.Controls.Add($root)

$root.RowStyles.Clear()
$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle("Absolute", 94)))
$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle("Absolute", 48)))
$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle("Percent", 100)))
$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle("Absolute", 32)))

# ═══════════════════════════════════════════════════════════════
# ROW 0 – Create card
# ═══════════════════════════════════════════════════════════════
$createCard = New-Object System.Windows.Forms.Panel
$createCard.Dock = "Fill"
$createCard.BackColor = FromHex $c.card
$createCard.Padding = New-Object System.Windows.Forms.Padding(14, 10, 14, 10)
$createCard.BorderStyle = "FixedSingle"
$root.Controls.Add($createCard, 0, 0)

$createTable = New-Object System.Windows.Forms.TableLayoutPanel
$createTable.Dock = "Fill"
$createTable.ColumnCount = 3
$createTable.RowCount = 3
$createTable.Padding = New-Object System.Windows.Forms.Padding(0)
$createTable.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 0)
$createTable.BackColor = [System.Drawing.Color]::Transparent
$createCard.Controls.Add($createTable)

$createTable.ColumnStyles.Clear()
$createTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle("Absolute", 88)))
$createTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle("Percent", 100)))
$createTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle("Absolute", 342)))

$createTable.RowStyles.Clear()
$createTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle("Absolute", 34)))
$createTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle("Absolute", 6)))
$createTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle("Absolute", 26)))

$lblDesc = New-Object System.Windows.Forms.Label
$lblDesc.Text = "Description"
$lblDesc.Dock = "Fill"
$lblDesc.TextAlign = "MiddleLeft"
$lblDesc.BackColor = [System.Drawing.Color]::Transparent
$lblDesc.ForeColor = FromHex $c.text
$createTable.Controls.Add($lblDesc, 0, 0)

$txtDesc = New-Object System.Windows.Forms.TextBox
$txtDesc.Dock = "Fill"
$txtDesc.BackColor = FromHex $c.inputBg
$txtDesc.ForeColor = FromHex $c.inputText
$txtDesc.BorderStyle = "FixedSingle"
$txtDesc.Text = "Manual Restore Point - $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
$createTable.Controls.Add($txtDesc, 1, 0)

$btnRow = New-Object System.Windows.Forms.FlowLayoutPanel
$btnRow.Dock = "Fill"
$btnRow.FlowDirection = "LeftToRight"
$btnRow.BackColor = [System.Drawing.Color]::Transparent
$btnRow.Margin = New-Object System.Windows.Forms.Padding(0)
$btnRow.Padding = New-Object System.Windows.Forms.Padding(0, 0, 0, 0)
$createTable.Controls.Add($btnRow, 2, 0)

$btnCreate = New-Object System.Windows.Forms.Button
$btnCreate.Text = " Create "
$btnCreate.FlatStyle = "Flat"
$btnCreate.FlatAppearance.BorderSize = 0
$btnCreate.BackColor = FromHex $c.accent
$btnCreate.ForeColor = [System.Drawing.Color]::White
$btnCreate.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$btnCreate.Size = New-Object System.Drawing.Size(100, 30)
$btnCreate.Margin = New-Object System.Windows.Forms.Padding(0, 0, 4, 0)
$btnCreate.Cursor = "Hand"
$btnCreate.UseVisualStyleBackColor = $false

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = " Refresh "
$btnRefresh.FlatStyle = "Flat"
$btnRefresh.FlatAppearance.BorderSize = 1
$btnRefresh.FlatAppearance.BorderColor = FromHex $c.border
$btnRefresh.BackColor = FromHex $c.inputBg
$btnRefresh.ForeColor = FromHex $c.text
$btnRefresh.Size = New-Object System.Drawing.Size(85, 30)
$btnRefresh.Margin = New-Object System.Windows.Forms.Padding(0, 0, 4, 0)
$btnRefresh.Cursor = "Hand"
$btnRefresh.UseVisualStyleBackColor = $false

$btnSysProps = New-Object System.Windows.Forms.Button
$btnSysProps.Text = "System Properties..."
$btnSysProps.FlatStyle = "Flat"
$btnSysProps.FlatAppearance.BorderSize = 1
$btnSysProps.FlatAppearance.BorderColor = FromHex $c.accent
$btnSysProps.BackColor = FromHex $c.inputBg
$btnSysProps.ForeColor = FromHex $c.accent
$btnSysProps.Size = New-Object System.Drawing.Size(145, 30)
$btnSysProps.Margin = New-Object System.Windows.Forms.Padding(0)
$btnSysProps.Cursor = "Hand"
$btnSysProps.UseVisualStyleBackColor = $false

$tooltip = New-Object System.Windows.Forms.ToolTip
$tooltip.InitialDelay = 400
$tooltip.ReshowDelay = 100
$tooltip.AutoPopDelay = 5000

$btnRow.Controls.AddRange(@($btnCreate, $btnRefresh, $btnSysProps))

$tooltip.SetToolTip($btnCreate, "Create a system restore point with the description above")
$tooltip.SetToolTip($btnRefresh, "Refresh the restore points list")
$tooltip.SetToolTip($btnSysProps, "Open System Protection settings")
$tooltip.SetToolTip($txtDesc, "Enter a description for the restore point")

# Row 1 – empty spacer
$spacer = New-Object System.Windows.Forms.Label
$createTable.SetColumnSpan($spacer, 3)
$createTable.Controls.Add($spacer, 0, 1)

# Row 2 – protection status
$protIndicator = New-Object System.Windows.Forms.Panel
$protIndicator.Size = New-Object System.Drawing.Size(12, 12)
$protIndicator.Dock = "None"
$protIndicator.Location = New-Object System.Drawing.Point(2, 7)
$protIndicator.BackColor = FromHex $c.muted
$indGp = New-Object System.Drawing.Drawing2D.GraphicsPath
$indGp.AddEllipse(0, 0, 12, 12)
    $protIndicator.Region = New-Object System.Drawing.Region($indGp)
    $indGp.Dispose()
    $tooltip.SetToolTip($protIndicator, "Indicates System Protection status: green = Active, red = Disabled")
$createTable.Controls.Add($protIndicator, 0, 2)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Dock = "Fill"
$lblStatus.TextAlign = "MiddleLeft"
$lblStatus.BackColor = [System.Drawing.Color]::Transparent
$lblStatus.ForeColor = FromHex $c.text
$lblStatus.Text = ""
$createTable.SetColumnSpan($lblStatus, 2)
$createTable.Controls.Add($lblStatus, 1, 2)

# ═══════════════════════════════════════════════════════════════
# ROW 1 – Toggles bar
# ═══════════════════════════════════════════════════════════════
$toggleBar = New-Object System.Windows.Forms.Panel
$toggleBar.Dock = "Fill"
$toggleBar.BackColor = FromHex $c.bg
$toggleBar.Height = 48
$root.Controls.Add($toggleBar, 0, 1)

$chkAutoToggle = New-Toggle -X 0 -Y 10 -Initial $false -Text "Auto-create every" -Tip $tooltip -OnToggle {
    param($checked)
    $script:autoMode = $checked
    $numInterval.Enabled = $checked
    if ($checked) {
        $autoInterval = [int]$numInterval.Value
        $autoTimer.Interval = $autoInterval * 3600000
        $autoTimer.Start()
        $lblStatus.Text = "Auto: every $autoInterval hour(s)"
        $lblStatus.ForeColor = FromHex $c.accent
    } else {
        $autoTimer.Stop()
        $lblStatus.Text = "Auto mode disabled"
        $lblStatus.ForeColor = FromHex $c.muted
    }
}
$tooltip.SetToolTip($chkAutoToggle, "Automatically create restore points at the interval below")
$chkAutoToggle.Location = New-Object System.Drawing.Point(8, 12)
$toggleBar.Controls.Add($chkAutoToggle)

$numInterval = New-Object System.Windows.Forms.NumericUpDown
$numInterval.Location = New-Object System.Drawing.Point(185, 13)
$numInterval.Size = New-Object System.Drawing.Size(60, 23)
$numInterval.Minimum = 1
$numInterval.Maximum = 168
$numInterval.Value = 1
$numInterval.Enabled = $false
$numInterval.BackColor = FromHex $c.inputBg
$numInterval.ForeColor = FromHex $c.inputText
$numInterval.BorderStyle = "FixedSingle"
$tooltip.SetToolTip($numInterval, "Interval in hours between auto-creations (1-168)")
$toggleBar.Controls.Add($numInterval)

$lblHours = New-Object System.Windows.Forms.Label
$lblHours.Text = "hours"
$lblHours.Location = New-Object System.Drawing.Point(250, 15)
$lblHours.Size = New-Object System.Drawing.Size(50, 20)
$lblHours.BackColor = [System.Drawing.Color]::Transparent
$lblHours.ForeColor = FromHex $c.text
$tooltip.SetToolTip($lblHours, "Number of hours between auto-creations")
$toggleBar.Controls.Add($lblHours)

$intervalDebounce = New-Object System.Windows.Forms.Timer
$intervalDebounce.Interval = 5000
$intervalDebounce.Add_Tick({
    $intervalDebounce.Stop()
    $autoInterval = [int]$numInterval.Value
    $autoTimer.Interval = $autoInterval * 3600000
    $lblStatus.Text = "Auto: every $autoInterval hour(s)"
    $lblStatus.ForeColor = FromHex $c.accent
})

$numInterval.Add_ValueChanged({
    if ($autoMode) {
        $intervalDebounce.Stop()
        $intervalDebounce.Start()
    }
})

$isStartup = Test-Path $startupPath
$chkStartupToggle = New-Toggle -X 350 -Y 10 -Initial $isStartup -Text "Run at startup" -Tip $tooltip -OnToggle {
    param($checked)
    if ($checked) {
        $wshell = New-Object -ComObject WScript.Shell
        $shortcut = $wshell.CreateShortcut($startupPath)
        $shortcut.TargetPath = "powershell.exe"
        $shortcut.Arguments = "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        $shortcut.WorkingDirectory = [System.IO.Path]::GetDirectoryName($PSCommandPath)
        $shortcut.Description = "Restore Point Manager"
        $shortcut.Save()
    } else {
        Remove-Item $startupPath -Force -ErrorAction SilentlyContinue
    }
}
$tooltip.SetToolTip($chkStartupToggle, "Launch automatically when Windows starts")
$chkStartupToggle.Location = New-Object System.Drawing.Point(320, 12)
$toggleBar.Controls.Add($chkStartupToggle)

# ═══════════════════════════════════════════════════════════════
# ROW 2 – List
# ═══════════════════════════════════════════════════════════════
$listCard = New-Object System.Windows.Forms.Panel
$listCard.Dock = "Fill"
$listCard.BackColor = FromHex $c.card
$listCard.Padding = New-Object System.Windows.Forms.Padding(0)
$listCard.BorderStyle = "FixedSingle"
$root.Controls.Add($listCard, 0, 2)

$listLayout = New-Object System.Windows.Forms.TableLayoutPanel
$listLayout.Dock = "Fill"
$listLayout.ColumnCount = 1
$listLayout.RowCount = 2
$listLayout.Padding = New-Object System.Windows.Forms.Padding(0)
$listLayout.Margin = New-Object System.Windows.Forms.Padding(0)
$listCard.Controls.Add($listLayout)

$listLayout.RowStyles.Clear()
$listLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle("Percent", 100)))
$listLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle("Absolute", 40)))

$listView = New-Object System.Windows.Forms.ListView
$listView.Dock = "Fill"
$listView.View = "Details"
$listView.FullRowSelect = $true
$listView.GridLines = $false
$listView.MultiSelect = $false
$listView.BorderStyle = "None"
$listView.BackColor = FromHex $c.card
$listView.ForeColor = FromHex $c.text
$listView.Font = New-Object System.Drawing.Font("Segoe UI", 9)

$tooltip.SetToolTip($listView, "Select a restore point to enable deletion")
$listView.HeaderStyle = "Nonclickable"

$colSeq = $listView.Columns.Add("Seq#", 70)
$colDesc = $listView.Columns.Add("Description", 280)
$colDate = $listView.Columns.Add("Created", 160)
$colType = $listView.Columns.Add("Type", 120)

$listLayout.Controls.Add($listView, 0, 0)

$listBottom = New-Object System.Windows.Forms.Panel
$listBottom.Dock = "Fill"
$listBottom.BackColor = [System.Drawing.Color]::Transparent
$listLayout.Controls.Add($listBottom, 0, 1)

$delFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$delFlow.Dock = "Fill"
$delFlow.FlowDirection = "RightToLeft"
$delFlow.BackColor = [System.Drawing.Color]::Transparent
$delFlow.Padding = New-Object System.Windows.Forms.Padding(0, 0, 4, 0)
$listBottom.Controls.Add($delFlow)

$btnDelete = New-Object System.Windows.Forms.Button
$btnDelete.Text = "Delete Selected"
$btnDelete.FlatStyle = "Flat"
$btnDelete.FlatAppearance.BorderSize = 0
$btnDelete.BackColor = FromHex $c.danger
$btnDelete.ForeColor = [System.Drawing.Color]::Black
$btnDelete.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$btnDelete.Size = New-Object System.Drawing.Size(120, 30)
$btnDelete.Margin = New-Object System.Windows.Forms.Padding(0, 5, 0, 0)
$btnDelete.Enabled = $false
$btnDelete.Cursor = "Hand"
$btnDelete.UseVisualStyleBackColor = $false
$tooltip.SetToolTip($btnDelete, "Delete the selected restore point")
$delFlow.Controls.Add($btnDelete)

# ═══════════════════════════════════════════════════════════════
# ROW 3 – Status bar
# ═══════════════════════════════════════════════════════════════
$statusBar = New-Object System.Windows.Forms.Panel
$statusBar.Dock = "Fill"
$statusBar.BackColor = FromHex $c.card
$statusBar.BorderStyle = "FixedSingle"

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = "Ready"
$statusLabel.Dock = "Fill"
$statusLabel.TextAlign = "MiddleLeft"
$statusLabel.ForeColor = FromHex $c.muted
$statusLabel.BackColor = [System.Drawing.Color]::Transparent
$statusLabel.Padding = New-Object System.Windows.Forms.Padding(6, 0, 0, 0)
$statusBar.Controls.Add($statusLabel)

$root.Controls.Add($statusBar, 0, 3)

# ── Functions ────────────────────────────────────────────────
function LoadRestorePoints {
    $listView.BeginUpdate()
    $listView.Items.Clear()
    $points = Get-RestorePoints
    $btnDelete.Enabled = $false
    foreach ($p in $points) {
        $item = New-Object System.Windows.Forms.ListViewItem($p.SequenceNumber.ToString())
        $item.SubItems.Add($p.Description)
        $item.SubItems.Add($p.CreationTime)
        $typeMap = @{"0"="App Install";"5"="OS Upgrade";"10"="Device Driver";"12"="Modify Settings";"13"="Cancelled Operation";"14"="Manual";"100"="Uninstall";"7"="System Checkpoint"}
        $typeStr = [string]$p.RestorePointType
        if ($typeMap.ContainsKey($typeStr)) { $item.SubItems.Add($typeMap[$typeStr]) } else { $item.SubItems.Add("Unknown") }
        $item.Tag = $p.SequenceNumber
        $listView.Items.Add($item) | Out-Null
    }
    $listView.EndUpdate()
}

function CreateRestorePoint {
    $desc = $txtDesc.Text.Trim()
    if ([string]::IsNullOrEmpty($desc)) {
        [System.Windows.Forms.MessageBox]::Show("Please enter a description.", "Input Required", "OK", "Warning")
        return
    }
    $btnCreate.Enabled = $false
    $btnCreate.Text = "Creating..."
    $btnCreate.BackColor = FromHex $c.muted
    [System.Windows.Forms.Application]::DoEvents()
    $ok = New-RestorePointManually -Description $desc
    if ($ok) {
        $lblStatus.Text = "Restore point created: $desc"
        $lblStatus.ForeColor = FromHex $c.success
        $txtDesc.Text = "Manual Restore Point - $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
        $protIndicator.BackColor = FromHex $c.success
        LoadRestorePoints
    } else {
        $lblStatus.Text = "Failed to create restore point. Ensure System Protection is enabled on your system drive."
        $lblStatus.ForeColor = FromHex $c.danger
        $protIndicator.BackColor = FromHex $c.danger
    }
    $btnCreate.Enabled = $true
    $btnCreate.Text = " Create "
    $btnCreate.BackColor = FromHex $c.accent
}

function AutoCreate {
    $desc = "Auto Restore Point - $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    $ok = New-RestorePointManually -Description $desc
    $trayIcon.BalloonTipTitle = "Restore Point"
    if ($ok) {
        $trayIcon.BalloonTipText = "Auto restore point created successfully."
        $trayIcon.BalloonTipIcon = "Info"
    } else {
        $trayIcon.BalloonTipText = "Failed to create auto restore point."
        $trayIcon.BalloonTipIcon = "Error"
    }
    $trayIcon.ShowBalloonTip(3000)
    if ($form.Visible) { LoadRestorePoints }
}

# ── Events ───────────────────────────────────────────────────
$btnCreate.Add_Click({ CreateRestorePoint })

$btnRefresh.Add_Click({ LoadRestorePoints })

$btnSysProps.Add_Click({
    try {
        Start-Process "SystemPropertiesProtection.exe"
    } catch {
        Start-Process "rundll32.exe" -ArgumentList "shell32.dll,Control_RunDLL sysdm.cpl,,3"
    }
})

$autoTimer.Add_Tick({ AutoCreate })

$listView.Add_SelectedIndexChanged({
    $btnDelete.Enabled = $listView.SelectedItems.Count -gt 0
})

$btnDelete.Add_Click({
    $sel = $listView.SelectedItems[0]
    if (-not $sel) { return }
    $seq = [uint32]$sel.Tag
    $desc = $sel.SubItems[1].Text
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Delete restore point '$desc' (Seq# $seq)?",
        "Confirm Delete",
        "YesNo",
        "Warning"
    )
    if ($r -eq 'Yes') {
        if (Remove-RestorePoint -SequenceNumber $seq) {
            $lblStatus.Text = "Deleted: $desc"
            $lblStatus.ForeColor = FromHex $c.success
            LoadRestorePoints
        } else {
            [System.Windows.Forms.MessageBox]::Show("Failed to delete restore point.", "Error", "OK", "Error")
        }
    }
})

$showItem.Add_Click({ $form.Show(); $form.WindowState = "Normal"; $form.Activate(); LoadRestorePoints })
$exitItem.Add_Click({
    $autoTimer.Stop()
    $trayIcon.Visible = $false
    [System.Windows.Forms.Application]::Exit()
})

$form.Add_Resize({
    if ($form.WindowState -eq "Minimized") {
        $form.Hide()
        $trayIcon.Visible = $true
        $trayIcon.ShowBalloonTip(1500, "Restore Point Manager", "App minimized to tray.", "Info")
    }
})

# ── Theme change timer ────────────────────────────────────────
$themeTimer = New-Object System.Windows.Forms.Timer
$themeTimer.Interval = 5000
$themeTimer.Add_Tick({
    $themeKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
    try {
        $val = (Get-ItemProperty -Path $themeKey -Name "AppsUseLightTheme" -ErrorAction Stop).AppsUseLightTheme
    } catch { $val = 1 }
    $isDark = ($val -eq 0)
    if ($isDark -ne $script:lastDark) {
        $lblStatus.Text = "Theme changed. Restart app to apply."
        $lblStatus.ForeColor = FromHex $c.accent
        $script:lastDark = $isDark
    }
})
$script:lastDark = $isDarkTheme

$form.Add_Shown({
    $trayIcon.Visible = $true
    try { [DwmAPI]::SetDarkMode($form.Handle, $isDarkTheme) } catch {}
    $vss = Get-Service VSS -ErrorAction SilentlyContinue
    $vssOk = $vss -and $vss.Status -eq "Running"
    $points = Get-CimInstance -Namespace "root/default" -ClassName "SystemRestore" -ErrorAction SilentlyContinue
    if ($vssOk -or $points) {
        $lblStatus.Text = "System Protection: Active"
        $lblStatus.ForeColor = FromHex $c.success
        $form.Text = "Restore Point Manager  -  Protection: Active"
        $protIndicator.BackColor = FromHex $c.success
    } else {
        $lblStatus.Text = "System Protection: Disabled - click System Properties to enable it"
        $lblStatus.ForeColor = FromHex $c.danger
        $form.Text = "Restore Point Manager  -  Protection: Disabled!"
        $protIndicator.BackColor = FromHex $c.danger
    }
    $statusLabel.Text = "Loaded - $($points.Count) restore point(s)"
    LoadRestorePoints
    $themeTimer.Start()
})

# ── Go ───────────────────────────────────────────────────────
if ($isDarkTheme) {
    try { [DwmAPI]::SetDarkMode($form.Handle, $true) } catch {}
    try { [DwmAPI]::SetDarkListView($listView.Handle) } catch {}
}
[System.Windows.Forms.Application]::Run($form)
