<#
.SYNOPSIS
    TSBackground-OSD - Modern Fullscreen Task Sequence Background for SCCM / MECM
.DESCRIPTION
    Displays a modern fullscreen progress UI with a dynamic right-hand step tracker,
    real-time task sequence variables, persistent timer across WinPE/FullOS reboots,
    automatic SCCM progress window hiding, and a password-protected debug console (Ctrl+Shift+D).
.AUTHOR
    Abdelkader Nouacer IT
.VERSION
    2.0.0
#>

param(
    [string]$ConfigFile = "config.json"
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

# --- API Win32 pour masquer proprement la fenêtre standard SCCM "Installation Progress" ---
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

# --- Loading JSON configuration---
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ScriptDir) { $ScriptDir = (Get-Location).Path }
$ConfigFullPath = Join-Path $ScriptDir $ConfigFile

if (Test-Path $ConfigFullPath) {
    $Config = Get-Content -Path $ConfigFullPath -Raw -Encoding UTF8 | ConvertFrom-Json
} else {
    Write-Warning "File $ConfigFullPath not found. Using default values."
    exit 1
}

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
    #Out-of-sequence task mode (local test)
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
$SidebarW = 440
$LeftW    = $ScreenW - $SidebarW

# ==============================================================================
# RIGHT SIDEBAR: STEP TRACKER
# ==============================================================================
$RightPanel = New-Object System.Windows.Forms.Panel
$RightPanel.Location  = New-Object System.Drawing.Point($LeftW, 0)
$RightPanel.Size      = New-Object System.Drawing.Size($SidebarW, $ScreenH)
$RightPanel.BackColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.SidebarBackground)
$Form.Controls.Add($RightPanel)

$StepsCount = $Config.Steps.Count
$StartY = [int](($ScreenH - (60 + ($StepsCount * 74))) / 2)
if ($StartY -lt 40) { $StartY = 40 }

$LblStepsHeader = New-Object System.Windows.Forms.Label
$LblStepsHeader.Text      = "INSTALLATION STEPS"
$LblStepsHeader.Font      = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$LblStepsHeader.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.TextSecondary)
$LblStepsHeader.Location  = New-Object System.Drawing.Point(35, $StartY)
$LblStepsHeader.Size      = New-Object System.Drawing.Size(370, 30)
$RightPanel.Controls.Add($LblStepsHeader)

$ControlesEtapes = @{}
$StepY = $StartY + 50
foreach ($e in $Config.Steps) {
    $Lbl = New-Object System.Windows.Forms.Label
    $Lbl.Text      = "   ○   $($e.Name)"
    $Lbl.Font      = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Regular)
    $Lbl.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.StepPendingText)
    $Lbl.BackColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.StepPendingBg)
    $Lbl.Location  = New-Object System.Drawing.Point(35, $StepY)
    $Lbl.Size      = New-Object System.Drawing.Size(370, 54)
    $Lbl.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $RightPanel.Controls.Add($Lbl)

    $ControlesEtapes[$e.Id] = @{
        Label    = $Lbl
        Keywords = $e.Keywords
        Name     = $e.Name
    }
    $StepY += 72
}

# Discreet diagnostic button at the bottom right
$LblDebugHint = New-Object System.Windows.Forms.Label
$LblDebugHint.Text      = "v2.1 • Ctrl+Shift+D : Console Diagnostic"
$LblDebugHint.Font      = New-Object System.Drawing.Font("Segoe UI", 8.5)
$LblDebugHint.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.TextSecondary)
$LblDebugHint.Location  = New-Object System.Drawing.Point(35, ($ScreenH - 35))
$LblDebugHint.Size      = New-Object System.Drawing.Size(370, 22)
$LblDebugHint.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$RightPanel.Controls.Add($LblDebugHint)

# ==============================================================================
# MAIN LEFT AREA: LOGO, TITLE, OVERALL PROGRESS & SYSTEM INFO
# ==============================================================================
$LeftCenterY = [int](($ScreenH - 440) / 2)
if ($LeftCenterY -lt 40) { $LeftCenterY = 40 }
$LeftMarginX = [int](($LeftW - 600) / 2)
if ($LeftMarginX -lt 40) { $LeftMarginX = 40 }

$CurrentY = $LeftCenterY

# Logo optionnel
$LogoFullPath = Join-Path $ScriptDir $Config.LogoPath
if (-not [string]::IsNullOrEmpty($Config.LogoPath) -and (Test-Path $LogoFullPath)) {
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
    $LblCompany.Size      = New-Object System.Drawing.Size(800, 24)
    $Form.Controls.Add($LblCompany)

    $CurrentY += 22

    $LblBrand = New-Object System.Windows.Forms.Label
    $LblBrand.Text      = $Config.DepartmentName
    $LblBrand.Font      = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
    $LblBrand.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.AccentColor)
    $LblBrand.Location  = New-Object System.Drawing.Point($LeftMarginX, $CurrentY)
    $LblBrand.Size      = New-Object System.Drawing.Size(800, 34)
    $Form.Controls.Add($LblBrand)

    $CurrentY += 42
}

$LblTitle = New-Object System.Windows.Forms.Label
$LblTitle.Text      = $Config.Title
$LblTitle.Font      = New-Object System.Drawing.Font("Segoe UI", 28, [System.Drawing.FontStyle]::Regular)
$LblTitle.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.TextPrimary)
$LblTitle.Location  = New-Object System.Drawing.Point($LeftMarginX, $CurrentY)
$LblTitle.Size      = New-Object System.Drawing.Size(620, 54)
$Form.Controls.Add($LblTitle)
$CurrentY += 58

$LblSubTitle = New-Object System.Windows.Forms.Label
$LblSubTitle.Text      = $Config.SubTitle
$LblSubTitle.Font      = New-Object System.Drawing.Font("Segoe UI", 11.5)
$LblSubTitle.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.TextSecondary)
$LblSubTitle.Location  = New-Object System.Drawing.Point($LeftMarginX, $CurrentY)
$LblSubTitle.Size      = New-Object System.Drawing.Size(620, 28)
$Form.Controls.Add($LblSubTitle)
$CurrentY += 42

# Barre de progression globale personnalisée
$ProgressBg = New-Object System.Windows.Forms.Panel
$ProgressBg.Location  = New-Object System.Drawing.Point($LeftMarginX, $CurrentY)
$ProgressBg.Size      = New-Object System.Drawing.Size(560, 10)
$ProgressBg.BackColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.CardBackground)
$Form.Controls.Add($ProgressBg)

$ProgressFill = New-Object System.Windows.Forms.Panel
$ProgressFill.Location  = New-Object System.Drawing.Point(0, 0)
$ProgressFill.Size      = New-Object System.Drawing.Size(30, 10)
$ProgressFill.BackColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.AccentColor)
$ProgressBg.Controls.Add($ProgressFill)
$CurrentY += 22

$TxtActionActuelle = New-Object System.Windows.Forms.Label
$TxtActionActuelle.Text      = "Sequence initialization..."
$TxtActionActuelle.Font      = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Regular)
$TxtActionActuelle.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.AccentColor)
$TxtActionActuelle.Location  = New-Object System.Drawing.Point($LeftMarginX, $CurrentY)
$TxtActionActuelle.Size      = New-Object System.Drawing.Size(620, 32)
$Form.Controls.Add($TxtActionActuelle)
$CurrentY += 48

# Carte d'informations système
$InfoPanel = New-Object System.Windows.Forms.Panel
$InfoPanel.Location  = New-Object System.Drawing.Point($LeftMarginX, $CurrentY)
$InfoPanel.Size      = New-Object System.Drawing.Size(560, 280)
$InfoPanel.Height = 280
$InfoPanel.BackColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.CardBackground)
$Form.Controls.Add($InfoPanel)

$TxtPCName = New-Object System.Windows.Forms.Label
$TxtPCName.Text      = "Computer Name : On hold..."
$TxtPCName.Font      = New-Object System.Drawing.Font("Segoe UI", 11)
$TxtPCName.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.TextPrimary)
$TxtPCName.Location  = New-Object System.Drawing.Point(22, 18)
$TxtPCName.Size      = New-Object System.Drawing.Size(510, 26)
$InfoPanel.Controls.Add($TxtPCName)

$SerialNumber = (Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue).SerialNumber
$TxtSerial = New-Object System.Windows.Forms.Label
$TxtSerial.Text      = "Serial Number : $(if ($SerialNumber) { $SerialNumber } else { 'Detection...' })"
$TxtSerial.Font      = New-Object System.Drawing.Font("Segoe UI", 11)
$TxtSerial.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.TextPrimary)
$TxtSerial.Location  = New-Object System.Drawing.Point(22, 50)
$TxtSerial.Size      = New-Object System.Drawing.Size(510, 26)
$InfoPanel.Controls.Add($TxtSerial)

$TxtModel = New-Object System.Windows.Forms.Label
$ModelHW = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).Model
$TxtModel.Text      = "Hardware model : $(if ($ModelHW) { $ModelHW } else { 'Detection...' })"
$TxtModel.Font      = New-Object System.Drawing.Font("Segoe UI", 11)
$TxtModel.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.TextPrimary)
$TxtModel.Location  = New-Object System.Drawing.Point(22, 82)
$TxtModel.Size      = New-Object System.Drawing.Size(510, 26)
$InfoPanel.Controls.Add($TxtModel)

$TxtTS = New-Object System.Windows.Forms.Label
$TxtTS.Text      = "Task Sequence : Detecting..."
$TxtTS.Font      = New-Object System.Drawing.Font("Segoe UI", 11)
$TxtTS.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.TextPrimary)
$TxtTS.Location  = New-Object System.Drawing.Point(22, 114)
$TxtTS.Size      = New-Object System.Drawing.Size(510, 26)
$InfoPanel.Controls.Add($TxtTS)

$TxtIP = New-Object System.Windows.Forms.Label
$TxtIP.Text      = "IP Address : Detection..."
$TxtIP.Font      = New-Object System.Drawing.Font("Segoe UI", 11)
$TxtIP.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.TextPrimary)
$TxtIP.Location  = New-Object System.Drawing.Point(22, 146)
$TxtIP.Size      = New-Object System.Drawing.Size(510, 26)
$InfoPanel.Controls.Add($TxtIP)

$TxtMAC = New-Object System.Windows.Forms.Label
$TxtMAC.Text      = "MAC Address : Detecting..."
$TxtMAC.Font      = New-Object System.Drawing.Font("Segoe UI", 11)
$TxtMAC.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.TextPrimary)
$TxtMAC.Location  = New-Object System.Drawing.Point(22, 178)
$TxtMAC.Size      = New-Object System.Drawing.Size(510, 26)
$InfoPanel.Controls.Add($TxtMAC)

$TxtTimer = New-Object System.Windows.Forms.Label
$TxtTimer.Text      = "Time elapsed : 00:00:00"
$TxtTimer.Font      = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$TxtTimer.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.AccentColor)
$TxtTimer.Location  = New-Object System.Drawing.Point(22, 210)
$TxtTimer.Size      = New-Object System.Drawing.Size(510, 26)
$InfoPanel.Controls.Add($TxtTimer)

$LblStep = New-Object System.Windows.Forms.Label
$LblStep.Visible = $false
$LblStep.Text = "Step 0 of 0"
$LblStep.Font = New-Object System.Drawing.Font("Segoe UI",11)
$LblStep.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.TextPrimary)
$LblStep.Location = New-Object System.Drawing.Point(22,242)
$LblStep.Size = New-Object System.Drawing.Size(510,26)
$InfoPanel.Controls.Add($LblStep)

#==============================================================================
#DYNAMIC REFRESH LOOP (EVERY 2 SECONDS)
#==============================================================================

$script:EtapeCouranteMax = 1
$script:CachedIP = $null

$UpdateUI = {
    # 1. Timer update (only the timer text, which changes every second)
    $Elapsed = (Get-Date) - $StartTime
    $NewTimerText = "Time elapsed : {0:hh\:mm\:ss}" -f $Elapsed
    if ($TxtTimer.Text -ne $NewTimerText) { $TxtTimer.Text = $NewTimerText }

    # 2. Optional hiding of the SCCM "Installation Progress" window"
    if ($Config.HideSCCMProgress -eq $true) {
        $Hwnd = [Win32Window]::FindWindow($null, "Installation Progress")
        if ($Hwnd -ne [IntPtr]::Zero) {
            [Win32Window]::ShowWindow($Hwnd, 0) | Out-Null
        }
    }

    # 3. Reading SCCM task sequence variables
    try {
        $TSEnv = New-Object -ComObject Microsoft.SMS.TSEnvironment
        $TSPackageName = $TSEnv.Value("_SMSTSPackageName")
        $CurrentAction = $TSEnv.Value("_SMSTSCurrentActionName")
        $PCName        = $TSEnv.Value("OSDComputerName")
        $StepIndex     = [int]$TSEnv.Value("_SMSTSNextInstructionPointer")
        $TotalSteps    = [int]$TSEnv.Value("_SMSTSInstructionTableSize")
            if ($TSPackageName) {
        $NewTS = "Task Sequence : $TSPackageName"
        if ($TxtTS.Text -ne $NewTS) {
            $TxtTS.Text = $NewTS
        }
    }

    if ($CurrentAction) {
        $NewAction = "Current Step : $CurrentAction"
        if ($TxtActionActuelle.Text -ne $NewAction) {
            $TxtActionActuelle.Text = $NewAction
        }
    }

    if ($PCName) {
        $NewPC = "Computer Name : $PCName"
        if ($TxtPCName.Text -ne $NewPC) {
            $TxtPCName.Text = $NewPC
        }
    }

       if ($TotalSteps -gt 0) {

    $Pct = [Math]::Round(($StepIndex / $TotalSteps) * 100)

    if ($Pct -lt 0)   { $Pct = 0 }
    if ($Pct -gt 100) { $Pct = 100 }

    $NewWidth = [int](($Pct / 100) * $ProgressBar.Width)

    if ($ProgressFill.Width -ne $NewWidth) {
        $ProgressFill.Width = $NewWidth
    }

    # Progression des étapes
    $CurrentStepNumber = [Math]::Max(1, [Math]::Min($StepIndex + 1, $TotalSteps))

    $NewStepInfo = "Deployment Progress : $Pct% ($CurrentStepNumber/$TotalSteps)"

    if ($LblStep.Text -ne $NewStepInfo) {
        $LblStep.Text = $NewStepInfo
    }

    $LblStep.Visible = $true
}
    else {
        $LblStep.Visible = $false
    }


            # Step Counter
            $CurrentStepNumber = [Math]::Max(1, [Math]::Min($StepIndex + 1, $TotalSteps))

            $NewStepInfo = "Deployment Progress : $CurrentStepNumber / $TotalSteps"

            if ($LblStep.Text -ne $NewStepInfo) {
                $LblStep.Text = $NewStepInfo
            }

            $NewStatus = "$Pct% Complete ($CurrentStepNumber/$TotalSteps)"

            if ($LblProgress.Text -ne $NewStatus) {
                $LblProgress.Text = $NewStatus
            }
        

            foreach ($id in ($ControlesEtapes.Keys | Sort-Object)) {
                if ($CurrentAction -match $ControlesEtapes[$id].Keywords) {
                    if ($id -gt $script:EtapeCouranteMax) {
                        $script:EtapeCouranteMax = $id
                    }
                }
            }
    } catch {
        $PreviewAction = "Preview Mode - SCCM Task Sequence Not Detected"
        $PreviewPC     = "Computer Name : $env:COMPUTERNAME"
        if ($TxtActionActuelle.Text -ne $PreviewAction) { $TxtActionActuelle.Text = $PreviewAction }
        if ($TxtPCName.Text -ne $PreviewPC)             { $TxtPCName.Text = $PreviewPC }
        if ($ProgressFill.Width -ne 240)                { $ProgressFill.Width = 240 }
    }

    # 4. Update IPv4 address (WMI query only if not yet found)
    if (-not $script:CachedIP) {

    $IP = (
        Get-NetIPConfiguration |
        Where-Object {
            $_.IPv4Address -and
            $_.IPv4DefaultGateway
        } |
        Select-Object -First 1
    ).IPv4Address.IPAddress

    if ($IP) {
        $script:CachedIP = $IP
        $TxtIP.Text = "IP Address : $IP"
    }
}

           $MACAddress = (
            Get-CimInstance Win32_NetworkAdapterConfiguration -ErrorAction SilentlyContinue |
            Where-Object { $_.IPEnabled -eq $true } |
            Select-Object -First 1
        ).MACAddress

        if ($MACAddress) {
            $NewMAC = "MAC Address : $MACAddress"
            if ($TxtMAC.Text -ne $NewMAC) {
                $TxtMAC.Text = $NewMAC
            }
        }

    # 5. Visual update of the steps in the sidebar (only if a change occurs)
    foreach ($id in ($ControlesEtapes.Keys | Sort-Object)) {
        $Ctrl = $ControlesEtapes[$id]
        if ($id -lt $script:EtapeCouranteMax) {
            $NewText = "   ✔   $($Ctrl.Name)"
            if ($Ctrl.Label.Text -ne $NewText) {
                $Ctrl.Label.Text      = $NewText
                $Ctrl.Label.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.StepDoneText)
                $Ctrl.Label.BackColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.StepDoneBg)
            }
        } elseif ($id -eq $script:EtapeCouranteMax) {
            $NewText = "   ▶   $($Ctrl.Name)"
            if ($Ctrl.Label.Text -ne $NewText) {
                $Ctrl.Label.Text      = $NewText
                $Ctrl.Label.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.StepActiveText)
                $Ctrl.Label.BackColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.StepActiveBg)
            }
        } else {
            $NewText = "   ○   $($Ctrl.Name)"
            if ($Ctrl.Label.Text -ne $NewText) {
                $Ctrl.Label.Text      = $NewText
                $Ctrl.Label.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.StepPendingText)
                $Ctrl.Label.BackColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.StepPendingBg)
            }
        }
    }
}

# Immediate execution upon opening (prevents a blank screen during the first 2 seconds)
& $UpdateUI

$Timer = New-Object System.Windows.Forms.Timer
$Timer.Interval = 1000
$Timer.Add_Tick($UpdateUI)


#==============================================================================
#KEYBOARD SHORTCUTS: ESC (TEST) & CTRL+SHIFT+D (DIAGNOSTIC CONSOLE)
#==============================================================================

$Form.Add_KeyDown({
    if ($_.KeyCode -eq "Escape") {
        $Timer.Stop()
        $Form.Close()
    }
    elseif ($_.Control -and $_.Shift -and $_.KeyCode -eq "D") {

    $PwdForm = New-Object System.Windows.Forms.Form
    $PwdForm.Text = "Diagnostic OSD"
    $PwdForm.Size = New-Object System.Drawing.Size(400,150)
    $PwdForm.StartPosition = "CenterScreen"
    $PwdForm.FormBorderStyle = "FixedDialog"
    $PwdForm.MaximizeBox = $false
    $PwdForm.MinimizeBox = $false
    $PwdForm.TopMost = $true

    $Lbl = New-Object System.Windows.Forms.Label
    $Lbl.Text = "Enter the administrator password:"
    $Lbl.Location = New-Object System.Drawing.Point(10,15)
    $Lbl.Size = New-Object System.Drawing.Size(350,20)

    $TxtPwd = New-Object System.Windows.Forms.TextBox
    $TxtPwd.Location = New-Object System.Drawing.Point(10,45)
    $TxtPwd.Size = New-Object System.Drawing.Size(360,25)
    $TxtPwd.UseSystemPasswordChar = $true

    $BtnOK = New-Object System.Windows.Forms.Button
    $BtnOK.Text = "OK"
    $BtnOK.Location = New-Object System.Drawing.Point(205,80)
    $BtnOK.DialogResult = [System.Windows.Forms.DialogResult]::OK

    $BtnCancel = New-Object System.Windows.Forms.Button
    $BtnCancel.Text = "Cancel"
    $BtnCancel.Location = New-Object System.Drawing.Point(290,80)
    $BtnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    $PwdForm.Controls.AddRange(@($Lbl,$TxtPwd,$BtnOK,$BtnCancel))
    $PwdForm.AcceptButton = $BtnOK
    $PwdForm.CancelButton = $BtnCancel

    if ($PwdForm.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        if ($TxtPwd.Text -eq $Config.DebugPassword) {
            Start-Process "cmd.exe"
        }
    }
    $PwdForm.Dispose()
}

})

$Form.Add_FormClosing({
    $Timer.Stop()
    $Timer.Dispose()
})

$Timer.Start()
[void]$Form.ShowDialog()

