<#
.SYNOPSIS
    TSBackground-OSD - Modern Fullscreen Task Sequence Background for SCCM / MECM
.DESCRIPTION
    Displays a modern fullscreen progress UI with a dynamic right-hand step tracker,
    real-time task sequence variables, persistent timer across WinPE/FullOS reboots,
    optional hiding of the standard SCCM progress window (HideSCCMProgress), and a password-protected debug console (Ctrl+Shift+D).
.AUTHOR
    Abdelkader Nouacer IT
.VERSION
    2.5.0
#>

param(
    [string]$ConfigFile = "config.json"
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

# --- Win32 API to cleanly hide the standard SCCM "Installation Progress" window ---
$Win32Code = @"
using System;
using System.Runtime.InteropServices;
public class Win32Window {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@
Add-Type -TypeDefinition $Win32Code -ErrorAction SilentlyContinue

# --- Loading JSON configuration ---
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ScriptDir) { $ScriptDir = (Get-Location).Path }
$ConfigFullPath = Join-Path $ScriptDir $ConfigFile

if (Test-Path $ConfigFullPath) {
    $Config = Get-Content -Path $ConfigFullPath -Raw -Encoding UTF8 | ConvertFrom-Json
} else {
    Write-Warning "File $ConfigFullPath not found."
    exit 1
}

# --- Single instance guard (a second launch in the same phase exits silently) ---
$MutexCreated = $false
$script:InstanceMutex = New-Object System.Threading.Mutex($true, "Global\TSBackground-OSD", [ref]$MutexCreated)
if (-not $MutexCreated) { exit 0 }

# --- Managing a persistent timer between WinPE and the full Windows environment ---
$StartTime = Get-Date
try {
    $TSEnvInit = New-Object -ComObject Microsoft.SMS.TSEnvironment
    $SavedStart = $TSEnvInit.Value("TSBackgroundStartTime")
    if ([string]::IsNullOrEmpty($SavedStart)) {
        $TSEnvInit.Value("TSBackgroundStartTime") = $StartTime.ToString("o")
    } else {
        $StartTime = [DateTime]::Parse($SavedStart)
    }
} catch {
    # Out-of-sequence mode (local test)
}

# --- Creating the full-screen interface ---
$Form = New-Object System.Windows.Forms.Form
$Form.GetType().GetProperty("DoubleBuffered", [System.Reflection.BindingFlags]"Instance,NonPublic").SetValue($Form, $true, $null)
$Form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$Form.WindowState     = [System.Windows.Forms.FormWindowState]::Maximized
$Form.BackColor       = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.Background)
$Form.TopMost         = $false
$Form.KeyPreview      = $true

$ScreenW  = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width
$ScreenH  = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Height
$SidebarW   = [Math]::Min(440, [int]($ScreenW * 0.34))
$LeftW      = $ScreenW - $SidebarW
$SideInnerW = $SidebarW - 70
$ContentW   = [Math]::Min(560, $LeftW - 80)
$InnerW     = $ContentW - 50
$TitleSize  = 28
$Gfx = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
while ($TitleSize -gt 14) {
    $TestFont = New-Object System.Drawing.Font("Segoe UI", $TitleSize, [System.Drawing.FontStyle]::Regular)
    $TitleW   = $Gfx.MeasureString([string]$Config.Title, $TestFont).Width
    $TestFont.Dispose()
    if ($TitleW -le ($ContentW - 10)) { break }
    $TitleSize--
}
$Gfx.Dispose()

# ==============================================================================
# RIGHT SIDEBAR: STEP TRACKER
# ==============================================================================
$RightPanel = New-Object System.Windows.Forms.Panel
$RightPanel.Location  = New-Object System.Drawing.Point($LeftW, 0)
$RightPanel.Size      = New-Object System.Drawing.Size($SidebarW, $ScreenH)
$RightPanel.BackColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.SidebarBackground)
$Form.Controls.Add($RightPanel)

$StepsCount = @($Config.Steps).Count
$StartY = [int](($ScreenH - (60 + ($StepsCount * 74))) / 2)
if ($StartY -lt 40) { $StartY = 40 }

$LblStepsHeader = New-Object System.Windows.Forms.Label
$LblStepsHeader.Text      = "INSTALLATION STEPS"
$LblStepsHeader.Font      = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$LblStepsHeader.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.TextSecondary)
$LblStepsHeader.Location  = New-Object System.Drawing.Point(35, $StartY)
$LblStepsHeader.Size      = New-Object System.Drawing.Size($SideInnerW, 30)
$RightPanel.Controls.Add($LblStepsHeader)

# Keys are [int] => correct numeric sort (2 before 10)
$StepControls = @{}
$StepY = $StartY + 50
foreach ($e in $Config.Steps) {
    $Lbl = New-Object System.Windows.Forms.Label
    $Lbl.Text      = "   ○   $($e.Name)"
    $Lbl.Font      = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Regular)
    $Lbl.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.StepPendingText)
    $Lbl.BackColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.StepPendingBg)
    $Lbl.Location  = New-Object System.Drawing.Point(35, $StepY)
    $Lbl.Size      = New-Object System.Drawing.Size($SideInnerW, 54)
    $Lbl.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $Lbl.UseMnemonic = $false
    $RightPanel.Controls.Add($Lbl)

    $StepControls[[int]$e.Id] = @{
        Label    = $Lbl
        Keywords = $e.Keywords
        Name     = $e.Name
    }
    $StepY += 72
}

# Discreet diagnostic hint at the bottom right
$LblDebugHint = New-Object System.Windows.Forms.Label
$LblDebugHint.Text      = "v2.5 • Ctrl+Shift+D : Console Diagnostic"
$LblDebugHint.Font      = New-Object System.Drawing.Font("Segoe UI", 8.5)
$LblDebugHint.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.TextSecondary)
$LblDebugHint.Location  = New-Object System.Drawing.Point(35, ($ScreenH - 35))
$LblDebugHint.Size      = New-Object System.Drawing.Size($SideInnerW, 22)
$LblDebugHint.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$RightPanel.Controls.Add($LblDebugHint)

# ==============================================================================
# MAIN LEFT AREA: LOGO, TITLE, OVERALL PROGRESS & SYSTEM INFO
# ==============================================================================
$LeftCenterY = [int](($ScreenH - 440) / 2)
if ($LeftCenterY -lt 40) { $LeftCenterY = 40 }
$LeftMarginX = [int](($LeftW - $ContentW) / 2)
if ($LeftMarginX -lt 40) { $LeftMarginX = 40 }

$CurrentY = $LeftCenterY

# Optional logo
$LogoFullPath = $null
if (-not [string]::IsNullOrEmpty($Config.LogoPath)) {
    $LogoFullPath = Join-Path $ScriptDir $Config.LogoPath
}
if ($LogoFullPath -and (Test-Path $LogoFullPath)) {
    $PicLogo = New-Object System.Windows.Forms.PictureBox
    $PicLogo.Image    = [System.Drawing.Image]::FromFile($LogoFullPath)
    $PicLogo.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
    $PicLogo.Location = New-Object System.Drawing.Point($LeftMarginX, $CurrentY)
    $PicLogo.Size     = New-Object System.Drawing.Size(180, 60)
    $Form.Controls.Add($PicLogo)
    $CurrentY += 75
} else {
    $LblCompany = New-Object System.Windows.Forms.Label
    $LblCompany.Text      = $Config.CompanyName
    $LblCompany.Font      = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $LblCompany.ForeColor = [System.Drawing.Color]::Silver
    $LblCompany.Location  = New-Object System.Drawing.Point($LeftMarginX, $CurrentY)
    $LblCompany.Size      = New-Object System.Drawing.Size($ContentW, 24)
    $Form.Controls.Add($LblCompany)

    $CurrentY += 22

    $LblBrand = New-Object System.Windows.Forms.Label
    $LblBrand.Text      = $Config.DepartmentName
    $LblBrand.Font      = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
    $LblBrand.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.AccentColor)
    $LblBrand.Location  = New-Object System.Drawing.Point($LeftMarginX, $CurrentY)
    $LblBrand.Size      = New-Object System.Drawing.Size($ContentW, 34)
    $Form.Controls.Add($LblBrand)

    $CurrentY += 42
}

$LblTitle = New-Object System.Windows.Forms.Label
$LblTitle.Text      = $Config.Title
$LblTitle.Font      = New-Object System.Drawing.Font("Segoe UI", $TitleSize, [System.Drawing.FontStyle]::Regular)
$LblTitle.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.TextPrimary)
$LblTitle.Location  = New-Object System.Drawing.Point($LeftMarginX, $CurrentY)
$LblTitle.Size      = New-Object System.Drawing.Size($ContentW, 54)
$Form.Controls.Add($LblTitle)
$CurrentY += 58

$LblSubTitle = New-Object System.Windows.Forms.Label
$LblSubTitle.Text      = $Config.SubTitle
$LblSubTitle.Font      = New-Object System.Drawing.Font("Segoe UI", 11.5)
$LblSubTitle.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.TextSecondary)
$LblSubTitle.Location  = New-Object System.Drawing.Point($LeftMarginX, $CurrentY)
$LblSubTitle.Size      = New-Object System.Drawing.Size($ContentW, 28)
$Form.Controls.Add($LblSubTitle)
$CurrentY += 42

# Custom overall progress bar
$ProgressBg = New-Object System.Windows.Forms.Panel
$ProgressBg.Location  = New-Object System.Drawing.Point($LeftMarginX, $CurrentY)
$ProgressBg.Size      = New-Object System.Drawing.Size($ContentW, 10)
$ProgressBg.BackColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.CardBackground)
$Form.Controls.Add($ProgressBg)

$ProgressFill = New-Object System.Windows.Forms.Panel
$ProgressFill.Location  = New-Object System.Drawing.Point(0, 0)
$ProgressFill.Size      = New-Object System.Drawing.Size(30, 10)
$ProgressFill.BackColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.AccentColor)
$ProgressBg.Controls.Add($ProgressFill)
$CurrentY += 22

$TxtCurrentAction = New-Object System.Windows.Forms.Label
$TxtCurrentAction.Text      = "Initializing Task Sequence..."
$TxtCurrentAction.Font      = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Regular)
$TxtCurrentAction.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.AccentColor)
$TxtCurrentAction.Location  = New-Object System.Drawing.Point($LeftMarginX, $CurrentY)
$TxtCurrentAction.Size      = New-Object System.Drawing.Size($ContentW, 32)
$Form.Controls.Add($TxtCurrentAction)
$CurrentY += 48

# System information card
$InfoPanel = New-Object System.Windows.Forms.Panel
$InfoPanel.Location  = New-Object System.Drawing.Point($LeftMarginX, $CurrentY)
$InfoPanel.Size      = New-Object System.Drawing.Size($ContentW, 260)
$InfoPanel.BackColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.CardBackground)
$Form.Controls.Add($InfoPanel)

$TxtPCName = New-Object System.Windows.Forms.Label
$TxtPCName.Text      = "Computer Name : $env:COMPUTERNAME"
$TxtPCName.Font      = New-Object System.Drawing.Font("Segoe UI", 11)
$TxtPCName.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.TextPrimary)
$TxtPCName.Location  = New-Object System.Drawing.Point(22, 16)
$TxtPCName.Size      = New-Object System.Drawing.Size($InnerW, 26)
$InfoPanel.Controls.Add($TxtPCName)

$SerialHW = (Get-WmiObject Win32_BIOS -ErrorAction SilentlyContinue).SerialNumber
$TxtSerial = New-Object System.Windows.Forms.Label
$TxtSerial.Text      = "Serial Number : $(if ($SerialHW) { $SerialHW } else { 'Unknown' })"
$TxtSerial.Font      = New-Object System.Drawing.Font("Segoe UI", 11)
$TxtSerial.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.TextPrimary)
$TxtSerial.Location  = New-Object System.Drawing.Point(22, 46)
$TxtSerial.Size      = New-Object System.Drawing.Size($InnerW, 26)
$InfoPanel.Controls.Add($TxtSerial)

$ModelHW = (Get-WmiObject Win32_ComputerSystem -ErrorAction SilentlyContinue).Model
$TxtModel = New-Object System.Windows.Forms.Label
$TxtModel.Text      = "Hardware model : $(if ($ModelHW) { $ModelHW } else { 'Detecting...' })"
$TxtModel.Font      = New-Object System.Drawing.Font("Segoe UI", 11)
$TxtModel.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.TextPrimary)
$TxtModel.Location  = New-Object System.Drawing.Point(22, 76)
$TxtModel.Size      = New-Object System.Drawing.Size($InnerW, 26)
$InfoPanel.Controls.Add($TxtModel)

$BiosVer = (Get-WmiObject Win32_BIOS -ErrorAction SilentlyContinue).SMBIOSBIOSVersion
$TxtBios = New-Object System.Windows.Forms.Label
$TxtBios.Text      = "BIOS Version : $(if ($BiosVer) { $BiosVer } else { 'Unknown' })"
$TxtBios.Font      = New-Object System.Drawing.Font("Segoe UI", 11)
$TxtBios.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.TextPrimary)
$TxtBios.Location  = New-Object System.Drawing.Point(22, 106)
$TxtBios.Size      = New-Object System.Drawing.Size($InnerW, 26)
$InfoPanel.Controls.Add($TxtBios)

$TxtIP = New-Object System.Windows.Forms.Label
$TxtIP.Text      = "IP Address : Detecting..."
$TxtIP.Font      = New-Object System.Drawing.Font("Segoe UI", 11)
$TxtIP.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.TextPrimary)
$TxtIP.Location  = New-Object System.Drawing.Point(22, 136)
$TxtIP.Size      = New-Object System.Drawing.Size($InnerW, 26)
$InfoPanel.Controls.Add($TxtIP)

$MACAddr = (Get-WmiObject Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" -ErrorAction SilentlyContinue | Select-Object -First 1).MACAddress
$TxtMAC = New-Object System.Windows.Forms.Label
$TxtMAC.Text      = "MAC Address : $(if ($MACAddr) { $MACAddr } else { 'Detecting...' })"
$TxtMAC.Font      = New-Object System.Drawing.Font("Segoe UI", 11)
$TxtMAC.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.TextPrimary)
$TxtMAC.Location  = New-Object System.Drawing.Point(22, 166)
$TxtMAC.Size      = New-Object System.Drawing.Size($InnerW, 26)
$InfoPanel.Controls.Add($TxtMAC)

$TxtTimer = New-Object System.Windows.Forms.Label
$TxtTimer.Text      = "Time elapsed : 00:00:00"
$TxtTimer.Font      = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$TxtTimer.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.AccentColor)
$TxtTimer.Location  = New-Object System.Drawing.Point(22, 196)
$TxtTimer.Size      = New-Object System.Drawing.Size($InnerW, 26)
$InfoPanel.Controls.Add($TxtTimer)

$TxtProgressStep = New-Object System.Windows.Forms.Label
$TxtProgressStep.Text      = "Deployment Progress : Initializing..."
$TxtProgressStep.Font      = New-Object System.Drawing.Font("Segoe UI", 11)
$TxtProgressStep.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.TextPrimary)
$TxtProgressStep.Location  = New-Object System.Drawing.Point(22, 226)
$TxtProgressStep.Size      = New-Object System.Drawing.Size($InnerW, 26)
$InfoPanel.Controls.Add($TxtProgressStep)

# ==============================================================================
# STEP DETECTION HELPERS
# ==============================================================================
$script:CurrentStepMax = 1
$script:CachedIP = $null
$script:TSEnvObj = $null
$script:TSConnected = $false
$script:LastAction = $null
$script:UIUnregistered = $false
$script:LastTSError = $null
$SortedIds = @($StepControls.Keys | Sort-Object)

# Restore the step reached before a reboot (WinPE -> Full OS)
try {
    $TSRestore = New-Object -ComObject Microsoft.SMS.TSEnvironment
    $SavedStep = $TSRestore.Value("TSBackgroundCurrentStep")
    if ($SavedStep -match '^\d+$' -and [int]$SavedStep -ge 1) {
        $script:CurrentStepMax = [int]$SavedStep
    }
} catch { }

# Keywords: string ("A|B", "A;B", "A,B") or JSON array, case-insensitive, no regex
function Test-StepMatch {
    param([string]$Action, $Keywords)
    if ([string]::IsNullOrWhiteSpace($Action) -or $null -eq $Keywords) { return $false }
    $List = @($Keywords) | ForEach-Object { "$_" -split '[|;,]' } |
            ForEach-Object { $_.Trim() } | Where-Object { $_ }
    foreach ($k in $List) {
        if ($Action.IndexOf($k, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    }
    return $false
}

# Diagnostic log (read it with: type %SystemRoot%\Temp\TSBackground-OSD.log)
$LogFile = Join-Path $env:SystemRoot "Temp\TSBackground-OSD.log"
function Write-Log {
    param([string]$Message)
    try { Add-Content -Path $LogFile -Value ("{0} {1}" -f (Get-Date -Format "HH:mm:ss"), $Message) -ErrorAction SilentlyContinue } catch { }
}
Write-Log ("START v2.5 PS={0} Apartment={1} Dir={2} Steps={3} Win32Type={4} Is64Bit={5} User={6} Session={7}" -f $PSVersionTable.PSVersion, [Threading.Thread]::CurrentThread.GetApartmentState(), $ScriptDir, $SortedIds.Count, ($null -ne ('Win32Window' -as [type])), [Environment]::Is64BitProcess, [Environment]::UserName, (Get-Process -Id $PID).SessionId)

# ==============================================================================
# DYNAMIC REFRESH LOOP (EVERY 1 SECOND)
# ==============================================================================
$UpdateUI = {
    try {
    # 1. Update elapsed timer
    $Elapsed = (Get-Date) - $StartTime
    $NewTimerText = "Time elapsed : {0:hh\:mm\:ss}" -f $Elapsed
    if ($TxtTimer.Text -ne $NewTimerText) { $TxtTimer.Text = $NewTimerText }

    } catch { Write-Log "Section 1 (timer): $_" }
    try {
    # 2. Hide SCCM "Installation Progress" window if enabled
    if ($Config.HideSCCMProgress -eq $true) {
        # a) Official method: TsProgressUI.exe /Unregister (once per phase)
        if (-not $script:UIUnregistered) {
            $ProcUI = Get-Process -Name "TsProgressUI" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($ProcUI) {
                $UiPath = $null
                try { $UiPath = $ProcUI.Path } catch { }
                if (-not $UiPath) {
                    foreach ($c in @("$env:SystemDrive\sms\bin\x64\TsProgressUI.exe", "$env:SystemRoot\CCM\TsProgressUI.exe")) {
                        if (Test-Path $c) { $UiPath = $c; break }
                    }
                }
                if ($UiPath) {
                    Start-Process -FilePath $UiPath -ArgumentList "/Unregister" -WindowStyle Hidden
                    $script:UIUnregistered = $true
                    Write-Log "TsProgressUI /Unregister via $UiPath"
                }
            }
        }
        # b) Fallback: hide any remaining window, then repaint our form
        $WasVisible = $false
        foreach ($WinTitle in @("Installation Progress", "Task Sequence Progress")) {
            $Hwnd = [Win32Window]::FindWindow([NullString]::Value, $WinTitle)
            if ($Hwnd -ne [IntPtr]::Zero -and [Win32Window]::ShowWindow($Hwnd, 0)) { $WasVisible = $true }
        }
        Get-Process -Name "TsProgressUI" -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.MainWindowHandle -ne [IntPtr]::Zero -and [Win32Window]::ShowWindow($_.MainWindowHandle, 0)) { $WasVisible = $true }
        }
        if ($WasVisible) { $Form.Refresh() }
    }

    } catch { Write-Log "Section 2 (hide window): $_" }
    try {
    # 3. Connect to SCCM Task Sequence Environment
    $TSEnv = $null
    try {
        if ($null -eq $script:TSEnvObj) {
            $script:TSEnvObj = New-Object -ComObject Microsoft.SMS.TSEnvironment
        }
        $TSEnv         = $script:TSEnvObj
        $CurrentAction = $TSEnv.Value("_SMSTSCurrentActionName")
        $PCName        = $TSEnv.Value("OSDComputerName")
        $StepRaw       = $TSEnv.Value("_SMSTSNextInstructionPointer")
        $TotalRaw      = $TSEnv.Value("_SMSTSInstructionTableSize")
        if (-not $script:TSConnected) { Write-Log "TS environment connected" }
        $script:TSConnected = $true
    } catch {
        $ErrMsg = $_.Exception.Message
        if ($ErrMsg -ne $script:LastTSError) {
            $script:LastTSError = $ErrMsg
            Write-Log "TS environment unavailable: $ErrMsg"
        }
        # Transient failure: drop the object, retry on next tick
        $script:TSEnvObj = $null
        $TSEnv = $null
        if (-not $script:TSConnected) {
            $PreviewAction = "Preview Mode - SCCM Task Sequence Not Detected"
            if ($TxtCurrentAction.Text -ne $PreviewAction) { $TxtCurrentAction.Text = $PreviewAction }
        }
    }

    if ($null -ne $TSEnv) {

        $DisplayAction = if ([string]::IsNullOrWhiteSpace($CurrentAction)) { "Running Task Sequence..." } else { "Current Step : $CurrentAction" }
        if ($TxtCurrentAction.Text -ne $DisplayAction) { $TxtCurrentAction.Text = $DisplayAction }

        if (-not [string]::IsNullOrWhiteSpace($PCName)) {
            $NewPC = "Computer Name : $PCName"
            if ($TxtPCName.Text -ne $NewPC) { $TxtPCName.Text = $NewPC }
        }

        if ($StepRaw -match '^\d+$' -and $TotalRaw -match '^\d+$' -and [int]$TotalRaw -gt 0) {
            $NewStepText = "Deployment Progress : $StepRaw / $TotalRaw"
            if ($TxtProgressStep.Text -ne $NewStepText) { $TxtProgressStep.Text = $NewStepText }

            $Pct = [Math]::Min(100, [Math]::Round(([int]$StepRaw / [int]$TotalRaw) * 100))
            $NewWidth = [int](($Pct / 100) * $ContentW)
            if ($ProgressFill.Width -ne $NewWidth) { $ProgressFill.Width = $NewWidth }
        }

        if ($CurrentAction -ne $script:LastAction) {
            $script:LastAction = $CurrentAction
            Write-Log "Action='$CurrentAction' Progress=$StepRaw/$TotalRaw Step=$($script:CurrentStepMax)"
        }

        # Step detection (only moves forward, saved for the next reboot)
        if (-not [string]::IsNullOrWhiteSpace($CurrentAction)) {
            # First step AFTER the current one whose keywords match the running action
            $Matched = $SortedIds | Where-Object {
                [int]$_ -gt $script:CurrentStepMax -and
                (Test-StepMatch -Action $CurrentAction -Keywords $StepControls[$_].Keywords)
            } | Select-Object -First 1

            if ($null -ne $Matched) {
                $script:CurrentStepMax = [int]$Matched
                try { $TSEnv.Value("TSBackgroundCurrentStep") = [string]$script:CurrentStepMax } catch { }
            }
        }
    }

    } catch { Write-Log "Section 3 (task sequence): $_" }
    try {
    # 4. Reliable IPv4 detection across all active adapters
    if (-not $script:CachedIP) {
        $IP = Get-WmiObject Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" -ErrorAction SilentlyContinue |
              ForEach-Object { $_.IPAddress } |
              Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notlike '169.254.*' -and $_ -ne '127.0.0.1' } |
              Select-Object -First 1
        if ($IP) {
            $script:CachedIP = $IP
            $TxtIP.Text = "IP Address : $IP"
        }
    }

    } catch { Write-Log "Section 4 (IP): $_" }
    try {
    # 5. Update right sidebar step indicators
    foreach ($id in $SortedIds) {
        $Ctrl = $StepControls[$id]
        if ([int]$id -lt $script:CurrentStepMax) {
            $Icon = "✔"; $Fg = $Config.Theme.StepDoneText;    $Bg = $Config.Theme.StepDoneBg
        } elseif ([int]$id -eq $script:CurrentStepMax) {
            $Icon = "▶"; $Fg = $Config.Theme.StepActiveText;  $Bg = $Config.Theme.StepActiveBg
        } else {
            $Icon = "○"; $Fg = $Config.Theme.StepPendingText; $Bg = $Config.Theme.StepPendingBg
        }
        $NewText = "   $Icon   $($Ctrl.Name)"
        if ($Ctrl.Label.Text -ne $NewText) {
            $Ctrl.Label.Text      = $NewText
            $Ctrl.Label.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($Fg)
            $Ctrl.Label.BackColor = [System.Drawing.ColorTranslator]::FromHtml($Bg)
        }
    }
    } catch { Write-Log "Section 5 (sidebar): $_" }
}

& $UpdateUI

$Timer = New-Object System.Windows.Forms.Timer
$Timer.Interval = 1000
$Timer.Add_Tick($UpdateUI)

$Form.Add_KeyDown({
    param($sender, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
        $Form.Close()
    }
    elseif ($e.Control -and $e.Shift -and $e.KeyCode -eq [System.Windows.Forms.Keys]::D) {
        $PwdInput = [Microsoft.VisualBasic.Interaction]::InputBox("Enter administrator password to open Command Prompt:", "OSD Diagnostic", "")
        if ($PwdInput -eq $Config.DebugPassword) {
            Start-Process "cmd.exe"
        }
    }
})

$Form.Add_FormClosing({
    $Timer.Stop()
    $Timer.Dispose()
})

$Timer.Start()
[void]$Form.ShowDialog()
