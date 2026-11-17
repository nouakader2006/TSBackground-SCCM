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

# --- Chargement de la configuration JSON ---
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ScriptDir) { $ScriptDir = (Get-Location).Path }
$ConfigFullPath = Join-Path $ScriptDir $ConfigFile

if (Test-Path $ConfigFullPath) {
    $Config = Get-Content -Path $ConfigFullPath -Raw -Encoding UTF8 | ConvertFrom-Json
} else {
    Write-Warning "Fichier $ConfigFullPath introuvable. Utilisation des valeurs par défaut."
    exit 1
}

# --- Gestion du chronomètre persistant entre WinPE et Windows complet ---
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
    # Mode hors séquence de tâches (test local)
}

# --- Création de l'interface plein écran ---
$Form = New-Object System.Windows.Forms.Form
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
# BARRE LATÉRALE DROITE : SUIVI DES ÉTAPES
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
$LblStepsHeader.Text      = "ÉTAPES D'INSTALLATION"
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

# Bouton discret de diagnostic en bas à droite
$LblDebugHint = New-Object System.Windows.Forms.Label
$LblDebugHint.Text      = "v2.0 • Ctrl+Shift+D : Console Diagnostic"
$LblDebugHint.Font      = New-Object System.Drawing.Font("Segoe UI", 8.5)
$LblDebugHint.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.TextSecondary)
$LblDebugHint.Location  = New-Object System.Drawing.Point(35, ($ScreenH - 35))
$LblDebugHint.Size      = New-Object System.Drawing.Size(370, 22)
$LblDebugHint.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$RightPanel.Controls.Add($LblDebugHint)

# ==============================================================================
# ZONE PRINCIPALE GAUCHE : LOGO, TITRE, PROGRESSION GLOBALE & INFOS SYSTÈME
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
    $LblBrand = New-Object System.Windows.Forms.Label
    $LblBrand.Text      = $Config.BrandName
    $LblBrand.Font      = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
    $LblBrand.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.AccentColor)
    $LblBrand.Location  = New-Object System.Drawing.Point($LeftMarginX, $CurrentY)
    $LblBrand.Size      = New-Object System.Drawing.Size(600, 34)
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
$TxtActionActuelle.Text      = "Initialisation de la séquence..."
$TxtActionActuelle.Font      = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Regular)
$TxtActionActuelle.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.AccentColor)
$TxtActionActuelle.Location  = New-Object System.Drawing.Point($LeftMarginX, $CurrentY)
$TxtActionActuelle.Size      = New-Object System.Drawing.Size(620, 32)
$Form.Controls.Add($TxtActionActuelle)
$CurrentY += 48

# Carte d'informations système
$InfoPanel = New-Object System.Windows.Forms.Panel
$InfoPanel.Location  = New-Object System.Drawing.Point($LeftMarginX, $CurrentY)
$InfoPanel.Size      = New-Object System.Drawing.Size(560, 165)
$InfoPanel.BackColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.CardBackground)
$Form.Controls.Add($InfoPanel)

$TxtPCName = New-Object System.Windows.Forms.Label
$TxtPCName.Text      = "Nom du poste : En attente..."
$TxtPCName.Font      = New-Object System.Drawing.Font("Segoe UI", 11)
$TxtPCName.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.TextPrimary)
$TxtPCName.Location  = New-Object System.Drawing.Point(22, 18)
$TxtPCName.Size      = New-Object System.Drawing.Size(510, 26)
$InfoPanel.Controls.Add($TxtPCName)

$TxtModel = New-Object System.Windows.Forms.Label
$ModelHW = (Get-WmiObject Win32_ComputerSystem -ErrorAction SilentlyContinue).Model
$TxtModel.Text      = "Modèle matériel : $(if ($ModelHW) { $ModelHW } else { 'Détection...' })"
$TxtModel.Font      = New-Object System.Drawing.Font("Segoe UI", 11)
$TxtModel.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.TextPrimary)
$TxtModel.Location  = New-Object System.Drawing.Point(22, 50)
$TxtModel.Size      = New-Object System.Drawing.Size(510, 26)
$InfoPanel.Controls.Add($TxtModel)
$TxtIP = New-Object System.Windows.Forms.Label
$TxtIP.Text      = "Adresse IP : Détection..."
$TxtIP.Font      = New-Object System.Drawing.Font("Segoe UI", 11)
$TxtIP.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.TextPrimary)
$TxtIP.Location  = New-Object System.Drawing.Point(22, 82)
$TxtIP.Size      = New-Object System.Drawing.Size(510, 26)
$InfoPanel.Controls.Add($TxtIP)
$TxtTimer = New-Object System.Windows.Forms.Label
$TxtTimer.Text      = "Temps écoulé : 00:00:00"
$TxtTimer.Font      = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$TxtTimer.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($Config.Theme.AccentColor)
$TxtTimer.Location  = New-Object System.Drawing.Point(22, 118)
$TxtTimer.Size      = New-Object System.Drawing.Size(510, 26)
$InfoPanel.Controls.Add($TxtTimer)

#==============================================================================
#BOUCLE DE RAFRAÎCHISSEMENT DYNAMIQUE (TOUTES LES 2 SECONDES)
#==============================================================================

$script:EtapeCouranteMax = 1
$script:CachedIP = $null

$UpdateUI = {
    # 1. Mise à jour du chronomètre (uniquement le texte du timer qui change chaque seconde)
    $Elapsed = (Get-Date) - $StartTime
    $NewTimerText = "Temps écoulé : {0:hh\:mm\:ss}" -f $Elapsed
    if ($TxtTimer.Text -ne $NewTimerText) { $TxtTimer.Text = $NewTimerText }

    # 2. Masquage optionnel de la fenêtre SCCM "Installation Progress"
    if ($Config.HideSCCMProgress -eq $true) {
        $Hwnd = [Win32Window]::FindWindow($null, "Installation Progress")
        if ($Hwnd -ne [IntPtr]::Zero) {
            [Win32Window]::ShowWindow($Hwnd, 0) | Out-Null
        }
    }

    # 3. Lecture des variables de séquence de tâches SCCM
    try {
        $TSEnv = New-Object -ComObject Microsoft.SMS.TSEnvironment
        $CurrentAction = $TSEnv.Value("_SMSTSCurrentActionName")
        $PCName        = $TSEnv.Value("OSDComputerName")
        $StepIndex     = [int]$TSEnv.Value("_SMSTSNextInstructionPointer")
        $TotalSteps    = [int]$TSEnv.Value("_SMSTSInstructionTableSize")

        if ($CurrentAction) {
            $NewAction = "Étape en cours : $CurrentAction"
            if ($TxtActionActuelle.Text -ne $NewAction) { $TxtActionActuelle.Text = $NewAction }
        }
        if ($PCName) {
            $NewPC = "Nom du poste : $PCName"
            if ($TxtPCName.Text -ne $NewPC) { $TxtPCName.Text = $NewPC }
        }

        if ($TotalSteps -gt 0 -and $StepIndex -gt 0) {
            $Pct = [Math]::Min(100, [Math]::Round(($StepIndex / $TotalSteps) * 100))
            $NewWidth = [int](($Pct / 100) * 560)
            if ($ProgressFill.Width -ne $NewWidth) { $ProgressFill.Width = $NewWidth }
        }

        foreach ($id in ($ControlesEtapes.Keys | Sort-Object)) {
            if ($CurrentAction -match $ControlesEtapes[$id].Keywords) {
                if ($id -gt $script:EtapeCouranteMax) {
                    $script:EtapeCouranteMax = $id
                }
            }
        }
    } catch {
        $PreviewAction = "Mode prévisualisation hors séquence SCCM"
        $PreviewPC     = "Nom du poste : $env:COMPUTERNAME"
        if ($TxtActionActuelle.Text -ne $PreviewAction) { $TxtActionActuelle.Text = $PreviewAction }
        if ($TxtPCName.Text -ne $PreviewPC)             { $TxtPCName.Text = $PreviewPC }
        if ($ProgressFill.Width -ne 240)                { $ProgressFill.Width = 240 }
    }

    # 4. Mise à jour de l'adresse IPv4 (requête WMI uniquement si pas encore trouvée)
    if (-not $script:CachedIP) {
        $IP = (Get-WmiObject Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" -ErrorAction SilentlyContinue | Select-Object -First 1).IPAddress | Where-Object { $_ -notmatch ":" } | Select-Object -First 1
        if ($IP) {
            $script:CachedIP = $IP
            $TxtIP.Text = "Adresse IP : $IP"
        }
    }

    # 5. Mise à jour visuelle des étapes sur la barre latérale (uniquement si changement)
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

# Exécution immédiate à l'ouverture (évite l'écran vide pendant les 2 premières secondes)
& $UpdateUI

$Timer = New-Object System.Windows.Forms.Timer
$Timer.Interval = 1000
$Timer.Add_Tick($UpdateUI)


#==============================================================================
#RACCOURCIS CLAVIER : ÉCHAP (TEST) & CTRL+SHIFT+D (CONSOLE DIAGNOSTIC)
#==============================================================================

$Form.Add_KeyDown({
    if ($_.KeyCode -eq "Escape") {
        $Timer.Stop()
        $Form.Close()
    }
    elseif ($_.Control -and $_.Shift -and $_.KeyCode -eq "D") {
        $PwdInput = [Microsoft.VisualBasic.Interaction]::InputBox("Entrez le mot de passe administrateur pour ouvrir l'invite de commandes :", "Diagnostic OSD", "")
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


$Timer.Start()
[void]$Form.ShowDialog()
