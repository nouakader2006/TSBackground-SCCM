<#
.SYNOPSIS
    TSBackground-OSD - Modern Fullscreen Task Sequence Background for SCCM / MECM
.DESCRIPTION
    v3.0.0 - Single-surface GDI+ design: big percentage hero, segmented phase bar,
    DEVICE / NETWORK / STATUS cards, vertical step timeline, info bar and footer.
    Persistent timer across WinPE/FullOS reboots, optional hiding of the standard SCCM
    progress window (HideSCCMProgress), password-protected debug console (Ctrl+Shift+D).
.AUTHOR
    Abdelkader Nouacer IT
.VERSION
    3.0.0
#>

param(
    [string]$ConfigFile = "config.json"
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

$AppVersion = "3.0.0"

# --- Win32 API: hide the standard SCCM "Installation Progress" window + DPI awareness ---
$Win32Code = @"
using System;
using System.Runtime.InteropServices;
public class Win32Window {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
}
"@
Add-Type -TypeDefinition $Win32Code -ErrorAction SilentlyContinue
try { [void][Win32Window]::SetProcessDPIAware() } catch { }

# --- Diagnostic log (read it with: type %SystemRoot%\Temp\TSBackground-OSD.log) ---
$LogFile = Join-Path $env:SystemRoot "Temp\TSBackground-OSD.log"
function Write-Log {
    param([string]$Message)
    try { Add-Content -Path $LogFile -Value ("{0} {1}" -f (Get-Date -Format "HH:mm:ss"), $Message) -ErrorAction SilentlyContinue } catch { }
}
$script:LoggedOnce = @{}
function Write-LogOnce {
    param([string]$Key, [string]$Message)
    if (-not $script:LoggedOnce.ContainsKey($Key)) {
        $script:LoggedOnce[$Key] = $true
        Write-Log $Message
    }
}

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

function Get-Cfg {
    param([string]$Name, [string]$Default)
    $v = $Config.$Name
    if ([string]::IsNullOrWhiteSpace([string]$v)) { return $Default }
    return [string]$v
}

# Close the UI automatically when the task sequence is over (default: true)
$AutoClose = $true
if ($null -ne $Config.AutoCloseOnCompletion) { $AutoClose = [bool]$Config.AutoCloseOnCompletion }

# --- Single instance guard (a second launch in the same phase exits silently) ---
$MutexCreated = $false
$script:InstanceMutex = New-Object System.Threading.Mutex($true, "Global\TSBackground-OSD", [ref]$MutexCreated)
if (-not $MutexCreated) { exit 0 }

# --- Persistent timer between WinPE and the full Windows environment ---
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

# ==============================================================================
# TEXTS (all optional in config.json, defaults match the design)
# ==============================================================================
$CompanyName   = Get-Cfg 'CompanyName'    'Sidra Tech'
$DeptName      = (Get-Cfg 'DepartmentName' 'IT Department').ToUpper()
$HeadLines     = @((Get-Cfg 'Headline' 'Preparing your|new workspace') -split '\|')
$OsName        = Get-Cfg 'OsName'         'Windows 11 Enterprise'
$PillRunning   = Get-Cfg 'StatusPill'     'DEPLOYMENT IN PROGRESS'
$InfoMessage   = Get-Cfg 'InfoMessage'    'Please keep your device connected to power.'
$SupportTitle  = Get-Cfg 'SupportTitle'   'IT Support - Service Desk'
$SupportText   = Get-Cfg 'SupportText'    'For assistance, contact the IT Help Desk.'

# Per-step defaults (used when a step has no Description / DoneText / StatusText in config.json)
$DefaultDesc   = @{ 1 = 'Partitioning the disk'; 2 = 'Applying Windows image'; 3 = 'Configuring network settings'; 4 = 'Installing software and drivers'; 5 = 'Preparing for first use' }
$DefaultDone   = @{ 1 = 'Disk partitioning complete'; 2 = 'Windows image applied'; 3 = 'Network configured'; 4 = 'Software and drivers installed'; 5 = 'Ready for first use' }
$DefaultStatus = @{ 1 = 'Preparing the disk'; 2 = 'Installing the operating system'; 3 = 'Configuring network and domain'; 4 = 'Installing applications'; 5 = 'Finalizing the deployment' }

function Get-StepText {
    param($Step, [string]$Field, $Defaults)
    $v = $Step.$Field
    if (-not [string]::IsNullOrWhiteSpace([string]$v)) { return [string]$v }
    $id = [int]$Step.Id
    if ($Defaults.ContainsKey($id)) { return [string]$Defaults[$id] }
    return ''
}

function Get-StepTitle {
    param($Step)
    foreach ($f in @('TimelineName', 'ShortName', 'Name')) {
        $v = $Step.$f
        if (-not [string]::IsNullOrWhiteSpace([string]$v)) { return [string]$v }
    }
    return ''
}

# ==============================================================================
# DRAWING HELPERS
# ==============================================================================
function Set-DoubleBuffered {
    param($Control)
    $Control.GetType().GetProperty("DoubleBuffered", [System.Reflection.BindingFlags]"Instance,NonPublic").SetValue($Control, $true, $null)
}

function New-RectF {
    param($X, $Y, $W, $H)
    return (New-Object System.Drawing.RectangleF([single]$X, [single]$Y, [single]$W, [single]$H))
}

function New-RoundedPath {
    param([double]$X, [double]$Y, [double]$W, [double]$H, [double]$R)
    $d = [Math]::Min(($R * 2), [Math]::Min($W, $H))
    if ($d -lt 1) { $d = 1 }
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.AddArc([single]$X, [single]$Y, [single]$d, [single]$d, [single]180, [single]90)
    $p.AddArc([single]($X + $W - $d), [single]$Y, [single]$d, [single]$d, [single]270, [single]90)
    $p.AddArc([single]($X + $W - $d), [single]($Y + $H - $d), [single]$d, [single]$d, [single]0, [single]90)
    $p.AddArc([single]$X, [single]($Y + $H - $d), [single]$d, [single]$d, [single]90, [single]90)
    $p.CloseFigure()
    return $p
}

function ConvertTo-ThemeColor {
    param($Hex, [string]$Fallback)
    if ([string]::IsNullOrWhiteSpace([string]$Hex)) { return [System.Drawing.ColorTranslator]::FromHtml($Fallback) }
    try { return [System.Drawing.ColorTranslator]::FromHtml([string]$Hex) } catch { return [System.Drawing.ColorTranslator]::FromHtml($Fallback) }
}

function Scale-Color {
    param($Color, [double]$Factor)
    $rr = [int][Math]::Min(255, [Math]::Max(0, $Color.R * $Factor))
    $gg = [int][Math]::Min(255, [Math]::Max(0, $Color.G * $Factor))
    $bb = [int][Math]::Min(255, [Math]::Max(0, $Color.B * $Factor))
    return [System.Drawing.Color]::FromArgb($rr, $gg, $bb)
}

function New-PenS {
    param($Color, $Width)
    $p = New-Object System.Drawing.Pen($Color, [single]$Width)
    $p.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $p.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
    $p.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    return $p
}

# Pixel-sized fonts, cached
$script:FontCache = @{}
function Get-Fnt {
    param([string]$Name, $Px, [bool]$Bold = $false)
    $pxr = [Math]::Round([double]$Px * 2) / 2
    if ($pxr -lt 6) { $pxr = 6 }
    $key = "$Name|$pxr|$Bold"
    if (-not $script:FontCache.ContainsKey($key)) {
        $style = [System.Drawing.FontStyle]::Regular
        if ($Bold) { $style = [System.Drawing.FontStyle]::Bold }
        $script:FontCache[$key] = New-Object System.Drawing.Font($Name, [single]$pxr, $style, [System.Drawing.GraphicsUnit]::Pixel)
    }
    return $script:FontCache[$key]
}

# String formats (typographic = no hidden padding), vertically centered on the given Y
$SfMeasure = [System.Drawing.StringFormat]::GenericTypographic
$SfL = New-Object System.Drawing.StringFormat([System.Drawing.StringFormat]::GenericTypographic)
$SfC = New-Object System.Drawing.StringFormat([System.Drawing.StringFormat]::GenericTypographic)
$SfR = New-Object System.Drawing.StringFormat([System.Drawing.StringFormat]::GenericTypographic)
$SfL.Alignment = [System.Drawing.StringAlignment]::Near
$SfC.Alignment = [System.Drawing.StringAlignment]::Center
$SfR.Alignment = [System.Drawing.StringAlignment]::Far
foreach ($sfx in @($SfL, $SfC, $SfR)) {
    $sfx.LineAlignment = [System.Drawing.StringAlignment]::Center
    $sfx.Trimming      = [System.Drawing.StringTrimming]::EllipsisCharacter
    $sfx.FormatFlags   = [System.Drawing.StringFormatFlags]'NoWrap, NoClip'
}

function Draw-Text {
    param($g, [string]$Text, $Font, $Brush, $X, $Cy, $W, [string]$Align = 'L')
    if ([string]::IsNullOrEmpty($Text)) { return }
    $sf = $SfL
    if ($Align -eq 'C') { $sf = $SfC } elseif ($Align -eq 'R') { $sf = $SfR }
    $h = $Font.Size * 1.8
    $g.DrawString($Text, $Font, $Brush, (New-RectF $X ($Cy - $h / 2) $W $h), $sf)
}

function Get-SpacedWidth {
    param($g, [string]$Text, $Font, $Spacing)
    $tw = 0.0
    foreach ($c in $Text.ToCharArray()) {
        if ($c -eq ' ') { $tw += $Font.Size * 0.28 }
        else { $tw += $g.MeasureString([string]$c, $Font, 1000, $SfMeasure).Width }
        $tw += $Spacing
    }
    return ($tw - $Spacing)
}

function Draw-Spaced {
    param($g, [string]$Text, $Font, $Brush, $X, $Cy, $Spacing)
    $cx = [double]$X
    foreach ($c in $Text.ToCharArray()) {
        if ($c -eq ' ') {
            $cx += $Font.Size * 0.28 + $Spacing
        } else {
            $ch = [string]$c
            Draw-Text $g $ch $Font $Brush $cx $Cy ($Font.Size * 2) 'L'
            $cx += $g.MeasureString($ch, $Font, 1000, $SfMeasure).Width + $Spacing
        }
    }
}

function Fill-RR {
    param($g, $Brush, $X, $Y, $W, $H, $R)
    $p = New-RoundedPath -X $X -Y $Y -W $W -H $H -R $R
    $g.FillPath($Brush, $p)
    $p.Dispose()
}

function Draw-RR {
    param($g, $Pen, $X, $Y, $W, $H, $R)
    $p = New-RoundedPath -X $X -Y $Y -W $W -H $H -R $R
    $g.DrawPath($Pen, $p)
    $p.Dispose()
}

function Fill-Circle {
    param($g, $Brush, $Cx, $Cy, $R)
    $g.FillEllipse($Brush, (New-RectF ($Cx - $R) ($Cy - $R) (2 * $R) (2 * $R)))
}

function Draw-Circle {
    param($g, $Pen, $Cx, $Cy, $R)
    $g.DrawEllipse($Pen, (New-RectF ($Cx - $R) ($Cy - $R) (2 * $R) (2 * $R)))
}

function Draw-Line {
    param($g, $Pen, $X1, $Y1, $X2, $Y2)
    $g.DrawLine($Pen, [single]$X1, [single]$Y1, [single]$X2, [single]$Y2)
}

# ==============================================================================
# COLORS, BRUSHES, FONT NAMES
# ==============================================================================
$ColBg        = ConvertTo-ThemeColor $Config.Theme.Background     '#0B1220'
$ColCard      = ConvertTo-ThemeColor $Config.Theme.CardBackground '#172337'
$ColText      = ConvertTo-ThemeColor $Config.Theme.TextPrimary    '#F1F5F9'
$ColDim       = ConvertTo-ThemeColor $Config.Theme.TextSecondary  '#94A3B8'
$ColAccent    = ConvertTo-ThemeColor $Config.Theme.AccentColor    '#22D3EE'
$ColGreen     = ConvertTo-ThemeColor $Config.Theme.SuccessColor   '#22C55E'
$ColBlue      = [System.Drawing.ColorTranslator]::FromHtml('#2563EB')
$ColBlueText  = [System.Drawing.ColorTranslator]::FromHtml('#60A5FA')
$ColGreenDark = [System.Drawing.ColorTranslator]::FromHtml('#16A34A')
$ColAmber     = [System.Drawing.ColorTranslator]::FromHtml('#F59E0B')

$BrText      = New-Object System.Drawing.SolidBrush($ColText)
$BrDim       = New-Object System.Drawing.SolidBrush($ColDim)
$BrLabel     = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(205, $ColText))
$BrAccent    = New-Object System.Drawing.SolidBrush($ColAccent)
$BrGreen     = New-Object System.Drawing.SolidBrush($ColGreen)
$BrBlueText  = New-Object System.Drawing.SolidBrush($ColBlueText)
$BrWhite     = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
$BrCardFill  = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(150, $ColCard))
$BrInset     = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(130, $ColCard))
$BrTrack     = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(150, 20, 32, 56))
$BrBarOff    = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 44, 60, 90))
$BrNodeFill  = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 14, 24, 44))
$BrHighlight = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(70, 37, 99, 235))
$BrInfo      = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(55, 37, 99, 235))

# Fonts: "Segoe UI Light" for the big number if installed, otherwise Segoe UI (WinPE safe)
$InstalledFonts = @((New-Object System.Drawing.Text.InstalledFontCollection).Families | ForEach-Object { $_.Name })
$BigFontName = "Segoe UI"
if ($InstalledFonts -contains "Segoe UI Light") { $BigFontName = "Segoe UI Light" }

# ==============================================================================
# LAYOUT (everything scales with the screen: 1536 x 1024 design units)
# ==============================================================================
function Get-Layout {
    param([int]$W, [int]$H)
    $s = [Math]::Min($H / 1024.0, $W / 1536.0)
    if ($s -lt 0.5) { $s = 0.5 }
    if ($s -gt 2.5) { $s = 2.5 }
    $sbW   = 451 * $s
    $sbX   = $W - $sbW
    $cw    = [Math]::Min($sbX - 74 * $s, 1320 * $s)
    $cl    = ($sbX - $cw) / 2
    $extra = [Math]::Max(0, $H - 1024 * $s)
    $y0    = 140 * $s + $extra / 2
    return @{ s = $s; W = $W; H = $H; sbX = $sbX; cl = $cl; cw = $cw; y0 = $y0 }
}

# Background (cached bitmap): navy gradient + soft blue glows
$script:BgBmp = $null
function Add-Glow {
    param($Gr, $Cx, $Cy, $Rx, $Ry, $Color, [int]$Alpha)
    $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
    $gp.AddEllipse([single]($Cx - $Rx), [single]($Cy - $Ry), [single](2 * $Rx), [single](2 * $Ry))
    $pg = New-Object System.Drawing.Drawing2D.PathGradientBrush($gp)
    $pg.CenterColor    = [System.Drawing.Color]::FromArgb($Alpha, $Color)
    $pg.SurroundColors = [System.Drawing.Color[]]@([System.Drawing.Color]::FromArgb(0, $Color))
    $Gr.FillPath($pg, $gp)
    $pg.Dispose()
    $gp.Dispose()
}

function Build-Background {
    param([int]$W, [int]$H)
    try {
        if ($script:BgBmp) { $script:BgBmp.Dispose(); $script:BgBmp = $null }
        $bmp = New-Object System.Drawing.Bitmap($W, $H)
        $bg  = [System.Drawing.Graphics]::FromImage($bmp)
        $bg.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $rc  = New-RectF 0 0 $W $H
        $c1  = Scale-Color $ColBg 0.72
        $c2  = Scale-Color $ColBg 1.12
        $lg  = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rc, $c1, $c2, [single]35)
        $bg.FillRectangle($lg, $rc)
        $lg.Dispose()
        Add-Glow $bg ($W * 0.10) ($H * 0.05) ($W * 0.40) ($H * 0.55) $ColBlue 60
        Add-Glow $bg ($W * 0.48) ($H * 1.00) ($W * 0.50) ($H * 0.45) $ColBlue 70
        Add-Glow $bg ($W * 0.88) ($H * 0.45) ($W * 0.25) ($H * 0.60) $ColBlue 38
        $bg.Dispose()
        $script:BgBmp = $bmp
    } catch {
        Write-LogOnce 'bg' "Build-Background: $_"
        $script:BgBmp = $null
    }
}

# ==============================================================================
# ICONS (vector, no icon font needed in WinPE)
# ==============================================================================
function Draw-IconLaptop {
    param($g, $X, $Y, $s)
    $p = $script:Pens.icon
    Draw-RR $g $p ($X + 7 * $s) ($Y + 2 * $s) (48 * $s) (30 * $s) (4 * $s)
    Draw-Line $g $p ($X + 0 * $s) ($Y + 40 * $s) ($X + 62 * $s) ($Y + 40 * $s)
}

function Draw-IconNetwork {
    param($g, $X, $Y, $s)
    $p = $script:Pens.icon
    Draw-RR $g $p ($X + 23 * $s) ($Y + 0 * $s) (16 * $s) (16 * $s) (3 * $s)
    Draw-RR $g $p ($X + 0 * $s) ($Y + 34 * $s) (16 * $s) (16 * $s) (3 * $s)
    Draw-RR $g $p ($X + 46 * $s) ($Y + 34 * $s) (16 * $s) (16 * $s) (3 * $s)
    Draw-Line $g $p ($X + 31 * $s) ($Y + 16 * $s) ($X + 31 * $s) ($Y + 25 * $s)
    Draw-Line $g $p ($X + 8 * $s) ($Y + 25 * $s) ($X + 54 * $s) ($Y + 25 * $s)
    Draw-Line $g $p ($X + 8 * $s) ($Y + 25 * $s) ($X + 8 * $s) ($Y + 34 * $s)
    Draw-Line $g $p ($X + 54 * $s) ($Y + 25 * $s) ($X + 54 * $s) ($Y + 34 * $s)
}

function Draw-IconClock {
    param($g, $X, $Y, $s)
    $p  = $script:Pens.icon
    $cx = $X + 31 * $s
    $cy = $Y + 25 * $s
    Draw-Circle $g $p $cx $cy (24 * $s)
    Draw-Line $g $p $cx $cy $cx ($cy - 13 * $s)
    Draw-Line $g $p $cx $cy ($cx + 10 * $s) ($cy + 6 * $s)
}

function Draw-IconHeadset {
    param($g, $X, $Y, $s)
    $p = $script:Pens.icon2
    $g.DrawArc($p, (New-RectF ($X + 3 * $s) ($Y + 1 * $s) (24 * $s) (24 * $s)), [single]180, [single]180)
    Draw-RR $g $p ($X + 0 * $s) ($Y + 13 * $s) (7 * $s) (11 * $s) (2.5 * $s)
    Draw-RR $g $p ($X + 23 * $s) ($Y + 13 * $s) (7 * $s) (11 * $s) (2.5 * $s)
    Draw-Line $g $p ($X + 26 * $s) ($Y + 24 * $s) ($X + 26 * $s) ($Y + 28 * $s)
    Draw-Line $g $p ($X + 26 * $s) ($Y + 28 * $s) ($X + 18 * $s) ($Y + 29 * $s)
}

function Fill-Arrow {
    param($g, $Cx, $Cy, $R, $Ang, $s)
    $t  = $Ang * [Math]::PI / 180.0
    $px = $Cx + $R * [Math]::Cos($t)
    $py = $Cy + $R * [Math]::Sin($t)
    $dx = -[Math]::Sin($t)
    $dy = [Math]::Cos($t)
    $rx = [Math]::Cos($t)
    $ry = [Math]::Sin($t)
    $a  = 5.5 * $s
    $b  = 4.5 * $s
    $pts = [System.Drawing.PointF[]]@(
        (New-Object System.Drawing.PointF([single]($px + $dx * $a), [single]($py + $dy * $a))),
        (New-Object System.Drawing.PointF([single]($px + $rx * $b), [single]($py + $ry * $b))),
        (New-Object System.Drawing.PointF([single]($px - $rx * $b), [single]($py - $ry * $b)))
    )
    $g.FillPolygon($BrAccent, $pts)
}

function Draw-IconRestart {
    param($g, $Cx, $Cy, $s)
    $r = 11 * $s
    $p = $script:Pens.icon2
    $g.DrawArc($p, (New-RectF ($Cx - $r) ($Cy - $r) (2 * $r) (2 * $r)), [single]200, [single]140)
    $g.DrawArc($p, (New-RectF ($Cx - $r) ($Cy - $r) (2 * $r) (2 * $r)), [single]20, [single]140)
    Fill-Arrow $g $Cx $Cy $r 340 $s
    Fill-Arrow $g $Cx $Cy $r 160 $s
}

# ==============================================================================
# STATE (declared before the drawing code that reads it)
# ==============================================================================
$StepMap = @{}
foreach ($e in $Config.Steps) {
    $StepMap[[int]$e.Id] = @{ Keywords = $e.Keywords; Name = $e.Name }
}
$SortedIds = @($StepMap.Keys | Sort-Object)
$PhaseList = @($Config.Steps | Sort-Object { [int]$_.Id })

$script:CurrentStepMax = 1
$script:CachedIP = $null
$script:TSEnvObj = $null
$script:TSConnected = $false
$script:LastAction = $null
$script:UIUnregistered = $false
$script:LastTSError = $null
$script:TSFailCount = 0
$script:Finished = $false
$script:EndTime = $null
$script:CloseAt = $null
$script:PctValue = 0
$script:Pulse = 0
$script:Pens = @{}

# Live texts read by the painter
$script:StatTimer         = '00:00:00'
$script:StatStep          = ''
$script:StatState         = 'Starting...'
$script:StepCaption       = 'Step 1 of 1'
$script:RemainText        = 'Estimating remaining time...'
$script:CurrentActionText = ''
$script:PillText          = $PillRunning
$script:DomTick           = 0

# Remaining-time estimate: no guess during long steps (default: step 2 = image apply),
# rate measured only since the last long step, then smoothed
$NoEstSteps = @(2)
if ($null -ne $Config.NoEstimateSteps) { $NoEstSteps = @($Config.NoEstimateSteps | ForEach-Object { [int]$_ }) }
$script:EstAnchorReady = $false
$script:EstAnchorMin   = 0.0
$script:EstAnchorPct   = 0
$script:EstWasLong     = $false
$script:EstSmooth      = $null

# Optional logo (replaces the built-in brand mark)
$script:LogoImage = $null
if (-not [string]::IsNullOrEmpty($Config.LogoPath)) {
    $LogoFullPath = Join-Path $ScriptDir $Config.LogoPath
    if (Test-Path $LogoFullPath) {
        try { $script:LogoImage = [System.Drawing.Image]::FromFile($LogoFullPath) } catch { }
    }
}

# Company domain: WinPE always reports WORKGROUP, so look in several places (first match wins)
function Get-CompanyDomain {
    param($TSEnv)
    # 1. Fixed value from config.json ("DomainName": "corp.example.com")
    if (-not [string]::IsNullOrWhiteSpace([string]$Config.DomainName)) { return [string]$Config.DomainName }
    # 2. Domain defined in the task sequence (OSDDomain, Apply Network Settings)
    if ($null -ne $TSEnv) {
        try {
            $d = [string]$TSEnv.Value("OSDDomain")
            if (-not [string]::IsNullOrWhiteSpace($d)) { return $d }
        } catch { }
    }
    # 3. Real domain membership (full Windows, once joined)
    try {
        $cs = Get-WmiObject Win32_ComputerSystem -ErrorAction SilentlyContinue
        if ($cs -and $cs.PartOfDomain -and $cs.Domain) { return [string]$cs.Domain }
    } catch { }
    # 4. DNS suffix received from DHCP (works in WinPE)
    try {
        $dns = Get-WmiObject Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" -ErrorAction SilentlyContinue |
               ForEach-Object { $_.DNSDomain } | Where-Object { $_ } | Select-Object -First 1
        if ($dns) { return [string]$dns }
    } catch { }
    return $null
}

# Hardware info (read once)
$SerialHW = (Get-WmiObject Win32_BIOS -ErrorAction SilentlyContinue).SerialNumber
$ModelHW  = (Get-WmiObject Win32_ComputerSystem -ErrorAction SilentlyContinue).Model
$BiosVer  = (Get-WmiObject Win32_BIOS -ErrorAction SilentlyContinue).SMBIOSBIOSVersion
$MACAddr  = (Get-WmiObject Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" -ErrorAction SilentlyContinue | Select-Object -First 1).MACAddress

$script:vPC     = [string]$env:COMPUTERNAME
$script:vSerial = 'Unknown';      if ($SerialHW) { $script:vSerial = [string]$SerialHW }
$script:vModel  = 'Detecting...'; if ($ModelHW)  { $script:vModel  = [string]$ModelHW }
$script:vBios   = 'Unknown';      if ($BiosVer)  { $script:vBios   = [string]$BiosVer }
$script:vMac    = 'Detecting...'; if ($MACAddr)  { $script:vMac    = [string]$MACAddr }
$script:vIP     = 'Detecting...'
$script:vDomain = 'Not joined yet'
$DomFound = Get-CompanyDomain -TSEnv $null
if ($DomFound) { $script:vDomain = [string]$DomFound }

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

function Get-StatusTitle {
    if ($script:Finished) { return 'Deployment complete' }
    $step = $PhaseList | Where-Object { [int]$_.Id -eq [int]$script:CurrentStepMax } | Select-Object -First 1
    if ($step) {
        $t = Get-StepText $step 'StatusText' $DefaultStatus
        if ($t) { return $t }
    }
    return 'Preparing the deployment'
}

# ==============================================================================
# PAINT SECTIONS
# ==============================================================================
function Paint-Header {
    param($g, $L)
    $s = $L.s
    $x = $L.cl + 6 * $s
    if ($script:LogoImage) {
        $lh = 64 * $s
        $lw = $script:LogoImage.Width * $lh / $script:LogoImage.Height
        $g.DrawImage($script:LogoImage, (New-RectF $x (62 * $s - $lh / 2) $lw $lh))
    } else {
        $bs = 56 * $s
        $by = 62 * $s - $bs / 2
        $rc = New-RectF $x $by $bs $bs
        $lg = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rc, $ColAccent, $ColBlue, [single]45)
        $p  = New-RoundedPath -X $x -Y $by -W $bs -H $bs -R (15 * $s)
        $g.FillPath($lg, $p)
        $p.Dispose()
        $lg.Dispose()
        Draw-Text $g 'S' (Get-Fnt 'Segoe UI' (36 * $s) $true) $BrWhite $x (62 * $s) $bs 'C'
        $tx = $x + $bs + 18 * $s
        Draw-Text $g $CompanyName (Get-Fnt 'Segoe UI' (34 * $s) $true) $BrText $tx (47 * $s) (700 * $s) 'L'
        Draw-Spaced $g $DeptName (Get-Fnt 'Segoe UI' (15 * $s) $false) $BrDim $tx (81 * $s) (5 * $s)
    }

    # Top-right status pill
    $pc = $ColAccent
    if ($script:Finished) { $pc = $ColGreen }
    $f  = Get-Fnt 'Segoe UI' (16.5 * $s) $false
    $tw = Get-SpacedWidth $g $script:PillText $f (1.4 * $s)
    $pw = $tw + 76 * $s
    $ph = 44 * $s
    $px = $L.W - 35 * $s - $pw
    $py = 36 * $s
    $b  = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(34, $pc))
    Fill-RR $g $b $px $py $pw $ph ($ph / 2)
    $b.Dispose()
    $pen = New-PenS ([System.Drawing.Color]::FromArgb(150, $pc)) (1.6 * $s)
    Draw-RR $g $pen $px $py $pw $ph ($ph / 2)
    $pen.Dispose()
    $da = 255
    if ($script:Pulse -eq 1) { $da = 150 }
    $db = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($da, $pc))
    Fill-Circle $g $db ($px + 30 * $s) ($py + $ph / 2) (8.5 * $s)
    $db.Dispose()
    Draw-Spaced $g $script:PillText $f $BrText ($px + 54 * $s) ($py + $ph / 2) (1.4 * $s)
}

function Paint-Hero {
    param($g, $L)
    $s  = $L.s
    $x0 = $L.cl
    $y0 = $L.y0

    # Big percentage
    $fBig = Get-Fnt $BigFontName (180 * $s) $false
    $fPct = Get-Fnt $BigFontName (94 * $s) $false
    $num  = [string][int]$script:PctValue
    $nw   = $g.MeasureString($num, $fBig, 3000, $SfMeasure).Width
    Draw-Text $g $num $fBig $BrText $x0 ($y0 + 90.5 * $s) 3000 'L'
    Draw-Text $g '%' $fPct $BrDim ($x0 + $nw + 8 * $s) ($y0 + 126 * $s) 600 'L'
    Draw-Spaced $g 'OVERALL PROGRESS' (Get-Fnt 'Segoe UI' (17 * $s) $false) $BrDim ($x0 + 44 * $s) ($y0 + 196 * $s) (4.6 * $s)

    # Vertical divider
    Draw-Line $g $script:Pens.sepV ($x0 + 403 * $s) ($y0 + 3 * $s) ($x0 + 403 * $s) ($y0 + 237 * $s)

    # Headline
    $hx = $x0 + 460 * $s
    $fH = Get-Fnt 'Segoe UI' (62 * $s) $true
    if ($HeadLines.Count -ge 1) { Draw-Text $g ([string]$HeadLines[0]) $fH $BrText $hx ($y0 + 32 * $s) 2000 'L' }
    if ($HeadLines.Count -ge 2) { Draw-Text $g ([string]$HeadLines[1]) $fH $BrText $hx ($y0 + 92 * $s) 2000 'L' }
    Draw-Text $g $OsName (Get-Fnt 'Segoe UI' (30 * $s) $false) $BrBlueText $hx ($y0 + 145 * $s) 2000 'L'

    # Status line
    $sc = $ColAccent
    if ($script:Finished) { $sc = $ColGreen }
    $da = 255
    if ($script:Pulse -eq 1) { $da = 140 }
    $db = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($da, $sc))
    Fill-Circle $g $db ($hx + 12 * $s) ($y0 + 199 * $s) (10 * $s)
    $db.Dispose()
    Draw-Text $g (Get-StatusTitle) (Get-Fnt 'Segoe UI' (25 * $s) $false) $BrText ($hx + 44 * $s) ($y0 + 199 * $s) 2000 'L'
    $act = [string]$script:CurrentActionText
    if ([string]::IsNullOrWhiteSpace($act)) { $act = 'Waiting for the task sequence...' }
    Draw-Text $g $act (Get-Fnt 'Segoe UI' (21 * $s) $false) $BrDim ($hx + 44 * $s) ($y0 + 229 * $s) 2000 'L'
}

function Paint-Bar {
    param($g, $L)
    $s  = $L.s
    $x0 = $L.cl
    $cw = $L.cw
    $y0 = $L.y0
    $n  = $PhaseList.Count
    if ($n -lt 1) { return }
    $gap   = 10 * $s
    $bh    = 30 * $s
    $by    = $y0 + 274 * $s
    $segW  = ($cw - $gap * ($n - 1)) / $n
    $share = 100.0 / $n
    $cur   = [int]$script:CurrentStepMax
    $fLab  = Get-Fnt 'Segoe UI' (19 * $s) $false

    for ($i = 0; $i -lt $n; $i++) {
        $x  = $x0 + $i * ($segW + $gap)
        $id = [int]$PhaseList[$i].Id
        Fill-RR $g $BrTrack $x $by $segW $bh ($bh / 2)
        Draw-RR $g $script:Pens.trackBorder $x $by $segW $bh ($bh / 2)
        $lb = $BrDim

        if ($id -lt $cur) {
            $rc = New-RectF $x $by $segW $bh
            $gr = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rc, $ColGreenDark, $ColGreen, [single]0)
            $p  = New-RoundedPath -X $x -Y $by -W $segW -H $bh -R ($bh / 2)
            $g.FillPath($gr, $p)
            $p.Dispose()
            $gr.Dispose()
            $ccx = $x + $segW / 2
            $ccy = $by + $bh / 2
            Draw-Line $g $script:Pens.checkSmall ($ccx - 8 * $s) ($ccy + 0.5 * $s) ($ccx - 3 * $s) ($ccy + 5.5 * $s)
            Draw-Line $g $script:Pens.checkSmall ($ccx - 3 * $s) ($ccy + 5.5 * $s) ($ccx + 8 * $s) ($ccy - 5.5 * $s)
        }
        elseif ($id -eq $cur) {
            $frac = ($script:PctValue - $i * $share) / $share
            $frac = [Math]::Max(0.12, [Math]::Min(0.92, $frac))
            $fw   = $segW * $frac
            $gb   = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(40, $ColAccent))
            Fill-RR $g $gb ($x - 3 * $s) ($by - 3 * $s) ($fw + 6 * $s) ($bh + 6 * $s) (($bh + 6 * $s) / 2)
            $gb.Dispose()
            $rc = New-RectF $x $by $fw $bh
            $gr = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rc, $ColAccent, $ColBlue, [single]0)
            $p  = New-RoundedPath -X $x -Y $by -W $fw -H $bh -R ($bh / 2)
            $g.FillPath($gr, $p)
            $p.Dispose()
            $gr.Dispose()
            $lb = $BrText
        }

        $lbl = [string]$PhaseList[$i].Name
        if ($PhaseList[$i].ShortName) { $lbl = [string]$PhaseList[$i].ShortName }
        Draw-Text $g $lbl $fLab $lb $x ($by + $bh + 22 * $s) $segW 'C'
    }

    $fCap = Get-Fnt 'Segoe UI' (18 * $s) $false
    Draw-Text $g $script:StepCaption $fCap $BrDim ($x0 + 3 * $s) ($y0 + 356 * $s) 600 'L'
    Draw-Text $g $script:RemainText $fCap $BrDim $x0 ($y0 + 356 * $s) $cw 'R'
}

function Paint-CardFrame {
    param($g, $L, $X, $Y, $W, $H, [string]$Icon, [string]$Title, [string]$Sub)
    $s = $L.s
    Fill-RR $g $BrCardFill $X $Y $W $H (16 * $s)
    Draw-RR $g $script:Pens.border $X $Y $W $H (16 * $s)
    $ix = $X + 33 * $s
    $iy = $Y + 24 * $s
    switch ($Icon) {
        'laptop'  { Draw-IconLaptop  $g $ix $iy $s }
        'network' { Draw-IconNetwork $g $ix $iy $s }
        'clock'   { Draw-IconClock   $g $ix $iy $s }
    }
    Draw-Text $g $Title (Get-Fnt 'Segoe UI' (21 * $s) $true) $BrText ($X + 120 * $s) ($Y + 39 * $s) (300 * $s) 'L'
    Draw-Text $g $Sub (Get-Fnt 'Segoe UI' (17 * $s) $false) $BrDim ($X + 120 * $s) ($Y + 66 * $s) ($W - 130 * $s) 'L'
    Draw-Line $g $script:Pens.sep ($X + 22 * $s) ($Y + 97 * $s) ($X + $W - 22 * $s) ($Y + 97 * $s)
}

function Paint-Rows {
    param($g, $L, $X, $Y, $W, $Rows)
    $s    = $L.s
    $fLab = Get-Fnt 'Segoe UI' (18 * $s) $false
    $fVal = Get-Fnt 'Segoe UI' (18 * $s) $false
    $n    = $Rows.Count
    for ($i = 0; $i -lt $n; $i++) {
        $cy  = $Y + (122 + 49 * $i) * $s
        $lab = [string]$Rows[$i].L
        $val = [string]$Rows[$i].V
        Draw-Text $g $lab $fLab $BrLabel ($X + 26 * $s) $cy (124 * $s) 'L'
        Draw-Text $g $val $fVal $BrText ($X + 150 * $s) $cy ($W - 166 * $s) 'L'
        if ($i -lt ($n - 1)) {
            Draw-Line $g $script:Pens.sep ($X + 22 * $s) ($cy + 24.5 * $s) ($X + $W - 22 * $s) ($cy + 24.5 * $s)
        }
    }
}

function Paint-Cards {
    param($g, $L)
    $s    = $L.s
    $gap  = 16 * $s
    $cw3  = ($L.cw - 2 * $gap) / 3
    $y    = $L.y0 + 387 * $s
    $h    = 316 * $s
    $x1   = $L.cl
    $x2   = $x1 + $cw3 + $gap
    $x3   = $x2 + $cw3 + $gap

    # DEVICE
    Paint-CardFrame $g $L $x1 $y $cw3 $h 'laptop' 'DEVICE' 'Hardware information'
    $devRows = @(
        @{ L = 'Computer name'; V = $script:vPC },
        @{ L = 'Model';         V = $script:vModel },
        @{ L = 'Serial number'; V = $script:vSerial },
        @{ L = 'BIOS version';  V = $script:vBios }
    )
    Paint-Rows $g $L $x1 $y $cw3 $devRows

    # NETWORK
    Paint-CardFrame $g $L $x2 $y $cw3 $h 'network' 'NETWORK' 'Connectivity details'
    $netRows = @(
        @{ L = 'Domain';      V = $script:vDomain },
        @{ L = 'IP address';  V = $script:vIP },
        @{ L = 'MAC address'; V = $script:vMac }
    )
    Paint-Rows $g $L $x2 $y $cw3 $netRows
    $ntxt = 'Waiting for network'
    $ncol = $ColAmber
    if ($script:CachedIP) { $ntxt = 'Connected'; $ncol = $ColGreen }
    $fPill = Get-Fnt 'Segoe UI' (19 * $s) $false
    $ntw   = $g.MeasureString($ntxt, $fPill, 1000, $SfMeasure).Width
    $npw   = $ntw + 66 * $s
    $npy   = $y + 254 * $s
    $nph   = 43 * $s
    $nb    = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(45, $ncol))
    Fill-RR $g $nb ($x2 + 24 * $s) $npy $npw $nph ($nph / 2)
    $nb.Dispose()
    $npen = New-PenS ([System.Drawing.Color]::FromArgb(170, $ncol)) (1.5 * $s)
    Draw-RR $g $npen ($x2 + 24 * $s) $npy $npw $nph ($nph / 2)
    $npen.Dispose()
    $nd = New-Object System.Drawing.SolidBrush($ncol)
    Fill-Circle $g $nd ($x2 + 24 * $s + 25 * $s) ($npy + $nph / 2) (8 * $s)
    Draw-Text $g $ntxt $fPill $nd ($x2 + 24 * $s + 46 * $s) ($npy + $nph / 2) ($npw - 50 * $s) 'L'
    $nd.Dispose()

    # STATUS
    Paint-CardFrame $g $L $x3 $y $cw3 $h 'clock' 'STATUS' 'Deployment progress'
    Draw-Text $g ([string]$script:StatTimer) (Get-Fnt 'Segoe UI' (54 * $s) $true) $BrAccent ($x3 + 30 * $s) ($y + 123 * $s) ($cw3 - 40 * $s) 'L'
    Draw-Text $g 'Time elapsed' (Get-Fnt 'Segoe UI' (19 * $s) $false) $BrLabel ($x3 + 30 * $s) ($y + 163 * $s) (300 * $s) 'L'
    Draw-Line $g $script:Pens.sep ($x3 + 22 * $s) ($y + 195 * $s) ($x3 + $cw3 - 22 * $s) ($y + 195 * $s)
    Draw-Text $g ([string]$script:StatState) (Get-Fnt 'Segoe UI' (19 * $s) $false) $BrText ($x3 + 30 * $s) ($y + 220 * $s) ($cw3 - 60 * $s) 'L'
    Draw-Text $g ([string]$script:StatStep) (Get-Fnt 'Segoe UI' (17 * $s) $false) $BrDim ($x3 + 30 * $s) ($y + 220 * $s) ($cw3 - 60 * $s) 'R'

    # Activity bars (filled according to the overall progress)
    $nbars  = 18
    $availW = $cw3 - 60 * $s
    $pitch  = $availW / $nbars
    $bw     = $pitch * 0.5
    $filled = [int][Math]::Round(($script:PctValue / 100.0) * $nbars)
    for ($i = 0; $i -lt $nbars; $i++) {
        $bx = $x3 + 30 * $s + $i * $pitch + ($pitch - $bw) / 2
        $br = $BrBarOff
        if ($i -lt $filled) { $br = $BrAccent }
        Fill-RR $g $br $bx ($y + 253 * $s) $bw (28 * $s) (2.5 * $s)
    }
}

function Paint-Sidebar {
    param($g, $L)
    $s     = $L.s
    $sbX   = $L.sbX
    $y0    = $L.y0
    $right = $L.W
    $tx    = $sbX + 47 * $s
    Draw-Spaced $g 'INSTALLATION STEPS' (Get-Fnt 'Segoe UI' (21 * $s) $false) $BrText $tx $y0 (1.2 * $s)
    Draw-Text $g 'Your device is being configured.' (Get-Fnt 'Segoe UI' (19 * $s) $false) $BrDim $tx ($y0 + 32 * $s) (380 * $s) 'L'

    $n        = $PhaseList.Count
    $ny0      = $y0 + 95 * $s
    $insetTop = $y0 + 606 * $s
    $pitch    = 101 * $s
    if ($n -gt 1) {
        $fit = ($insetTop - 30 * $s - $ny0) / ($n - 1)
        if ($fit -lt $pitch) { $pitch = $fit }
    }
    $nx    = $sbX + 71 * $s
    $cur   = [int]$script:CurrentStepMax
    $tx2   = $sbX + 122 * $s
    $textW = $right - 20 * $s - $tx2
    $rNode = 18 * $s
    $fTit  = Get-Fnt 'Segoe UI' (21 * $s) $true
    $fDes  = Get-Fnt 'Segoe UI' (18 * $s) $false

    # Highlight behind the active step
    for ($i = 0; $i -lt $n; $i++) {
        if ([int]$PhaseList[$i].Id -eq $cur) {
            $ny = $ny0 + $i * $pitch
            $hx = $sbX + 28 * $s
            $hw = ($right - 27 * $s) - $hx
            Fill-RR $g $BrHighlight $hx ($ny - 41 * $s) $hw (96 * $s) (14 * $s)
            Draw-RR $g $script:Pens.hiBorder $hx ($ny - 41 * $s) $hw (96 * $s) (14 * $s)
        }
    }

    # Connecting lines
    for ($i = 0; $i -lt ($n - 1); $i++) {
        $ya  = $ny0 + $i * $pitch + $rNode
        $yb  = $ny0 + ($i + 1) * $pitch - $rNode
        $pen = $script:Pens.grayLine
        if ([int]$PhaseList[$i + 1].Id -le $cur) { $pen = $script:Pens.greenLine }
        Draw-Line $g $pen $nx $ya $nx $yb
    }

    # Nodes + texts
    for ($i = 0; $i -lt $n; $i++) {
        $st = $PhaseList[$i]
        $id = [int]$st.Id
        $ny = $ny0 + $i * $pitch
        if ($id -lt $cur) {
            Fill-Circle $g $BrGreen $nx $ny $rNode
            Draw-Line $g $script:Pens.check ($nx - 7 * $s) ($ny + 0.5 * $s) ($nx - 2 * $s) ($ny + 5.5 * $s)
            Draw-Line $g $script:Pens.check ($nx - 2 * $s) ($ny + 5.5 * $s) ($nx + 7.5 * $s) ($ny - 5 * $s)
            $desc = Get-StepText $st 'DoneText' $DefaultDone
        }
        elseif ($id -eq $cur) {
            $ga = 45
            if ($script:Pulse -eq 1) { $ga = 20 }
            $gb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($ga, $ColAccent))
            Fill-Circle $g $gb $nx $ny (27 * $s)
            $gb.Dispose()
            Fill-Circle $g $BrNodeFill $nx $ny $rNode
            Draw-Circle $g $script:Pens.ringCyan $nx $ny $rNode
            Fill-Circle $g $BrAccent $nx $ny (8 * $s)
            $desc = Get-StepText $st 'Description' $DefaultDesc
        }
        else {
            Fill-Circle $g $BrNodeFill $nx $ny $rNode
            Draw-Circle $g $script:Pens.ringGray $nx $ny $rNode
            $desc = Get-StepText $st 'Description' $DefaultDesc
        }
        Draw-Text $g (Get-StepTitle $st) $fTit $BrText $tx2 ($ny - 5 * $s) $textW 'L'
        Draw-Text $g $desc $fDes $BrDim $tx2 ($ny + 24 * $s) $textW 'L'
    }

    # "Automatic restart" inset (bottom aligned with the cards)
    $ix = $sbX + 28 * $s
    $iw = ($right - 34 * $s) - $ix
    $ih = 97 * $s
    $iy = $insetTop
    Fill-RR $g $BrInset $ix $iy $iw $ih (16 * $s)
    Draw-RR $g $script:Pens.border $ix $iy $iw $ih (16 * $s)
    $icx = $ix + 52 * $s
    $icy = $iy + $ih / 2
    Fill-Circle $g $BrNodeFill $icx $icy (27 * $s)
    Draw-Circle $g $script:Pens.ringGray $icx $icy (27 * $s)
    Draw-IconRestart $g $icx $icy $s
    Draw-Text $g 'Automatic restart' (Get-Fnt 'Segoe UI' (21 * $s) $true) $BrText ($ix + 100 * $s) ($iy + 36 * $s) ($iw - 112 * $s) 'L'
    Draw-Text $g 'Your device may restart several times.' (Get-Fnt 'Segoe UI' (15 * $s) $false) $BrDim ($ix + 100 * $s) ($iy + 65 * $s) ($iw - 112 * $s) 'L'
}

function Paint-Info {
    param($g, $L)
    $s   = $L.s
    $x   = $L.cl
    $wid = ($L.W - 34 * $s) - $x
    $hgt = 66 * $s
    $y   = $L.H - 156 * $s
    Fill-RR $g $BrInfo $x $y $wid $hgt (16 * $s)
    Draw-RR $g $script:Pens.infoBorder $x $y $wid $hgt (16 * $s)
    $icx = $x + 42 * $s
    $icy = $y + $hgt / 2
    Draw-Circle $g $script:Pens.icon2 $icx $icy (17 * $s)
    Fill-Circle $g $BrAccent $icx ($icy - 7 * $s) (2.2 * $s)
    Draw-Line $g $script:Pens.icon2 $icx ($icy - 2 * $s) $icx ($icy + 8 * $s)
    Draw-Line $g $script:Pens.sep ($x + 84 * $s) ($y + 16 * $s) ($x + 84 * $s) ($y + $hgt - 16 * $s)
    Draw-Text $g $InfoMessage (Get-Fnt 'Segoe UI' (22 * $s) $false) $BrText ($x + 106 * $s) $icy ($wid - 130 * $s) 'L'
}

function Paint-Footer {
    param($g, $L)
    $s  = $L.s
    $x  = $L.cl + 6 * $s
    $cy = $L.H - 38 * $s
    Draw-IconHeadset $g $x ($cy - 15 * $s) $s
    Draw-Text $g $SupportTitle (Get-Fnt 'Segoe UI' (18 * $s) $false) $BrText ($x + 50 * $s) ($L.H - 47 * $s) (700 * $s) 'L'
    Draw-Text $g $SupportText (Get-Fnt 'Segoe UI' (14.5 * $s) $false) $BrDim ($x + 50 * $s) ($L.H - 26 * $s) (800 * $s) 'L'
    Draw-Text $g ("v{0}  -  Ctrl+Shift+D : Diagnostics" -f $AppVersion) (Get-Fnt 'Segoe UI' (16 * $s) $false) $BrDim 0 ($L.H - 37 * $s) ($L.W - 45 * $s) 'R'
}

function New-PenSet {
    param($s)
    return @{
        border      = (New-PenS ([System.Drawing.Color]::FromArgb(70, 120, 160, 230)) (1.3 * $s))
        sep         = (New-PenS ([System.Drawing.Color]::FromArgb(32, 255, 255, 255)) (1.2 * $s))
        sepV        = (New-PenS ([System.Drawing.Color]::FromArgb(45, 255, 255, 255)) (1.5 * $s))
        trackBorder = (New-PenS ([System.Drawing.Color]::FromArgb(70, 160, 190, 255)) (1.2 * $s))
        icon        = (New-PenS $ColAccent (2.6 * $s))
        icon2       = (New-PenS $ColAccent (2.4 * $s))
        greenLine   = (New-PenS $ColGreen (3.2 * $s))
        grayLine    = (New-PenS ([System.Drawing.Color]::FromArgb(255, 52, 72, 108)) (3.2 * $s))
        ringCyan    = (New-PenS $ColAccent (3.4 * $s))
        ringGray    = (New-PenS ([System.Drawing.Color]::FromArgb(255, 62, 82, 118)) (3.0 * $s))
        check       = (New-PenS ([System.Drawing.Color]::White) (3.4 * $s))
        checkSmall  = (New-PenS ([System.Drawing.Color]::White) (2.8 * $s))
        infoBorder  = (New-PenS ([System.Drawing.Color]::FromArgb(110, $ColAccent)) (1.4 * $s))
        hiBorder    = (New-PenS ([System.Drawing.Color]::FromArgb(90, $ColAccent)) (1.3 * $s))
    }
}

# ==============================================================================
# FORM + SINGLE DRAWING SURFACE
# ==============================================================================
$Form = New-Object System.Windows.Forms.Form
Set-DoubleBuffered $Form
$Form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$Form.WindowState     = [System.Windows.Forms.FormWindowState]::Maximized
$Form.BackColor       = $ColBg
$Form.TopMost         = $false
$Form.KeyPreview      = $true

$Canvas = New-Object System.Windows.Forms.Panel
$Canvas.Dock      = [System.Windows.Forms.DockStyle]::Fill
$Canvas.BackColor = $ColBg
Set-DoubleBuffered $Canvas
$Form.Controls.Add($Canvas)

$Canvas.Add_Resize({ $Canvas.Invalidate() })

$Canvas.Add_Paint({
    param($sender, $e)
    $g = $e.Graphics
    try {
        $cw = $sender.ClientSize.Width
        $ch = $sender.ClientSize.Height
        if ($cw -lt 300 -or $ch -lt 300) { return }
        $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit

        if ($null -eq $script:BgBmp -or $script:BgBmp.Width -ne $cw -or $script:BgBmp.Height -ne $ch) {
            Build-Background $cw $ch
        }
        if ($script:BgBmp) { $g.DrawImageUnscaled($script:BgBmp, 0, 0) } else { $g.Clear($ColBg) }

        $L = Get-Layout $cw $ch
        $script:Pens = New-PenSet $L.s

        # Vertical separator between the main area and the sidebar
        Draw-Line $g $script:Pens.sepV $L.sbX (24 * $L.s) $L.sbX ($ch - 74 * $L.s)

        foreach ($sec in @('Paint-Header', 'Paint-Hero', 'Paint-Bar', 'Paint-Cards', 'Paint-Sidebar', 'Paint-Info', 'Paint-Footer')) {
            try { & $sec $g $L } catch { Write-LogOnce $sec ("{0}: {1}" -f $sec, $_) }
        }
    } catch {
        Write-LogOnce 'paint' "Paint canvas: $_"
    } finally {
        foreach ($k in @($script:Pens.Keys)) { try { $script:Pens[$k].Dispose() } catch { } }
        $script:Pens = @{}
    }
})

Write-Log ("START v{0} PS={1} Apartment={2} Dir={3} Steps={4} Win32Type={5} Is64Bit={6} User={7} Session={8} Font={9}" -f $AppVersion, $PSVersionTable.PSVersion, [Threading.Thread]::CurrentThread.GetApartmentState(), $ScriptDir, $SortedIds.Count, ($null -ne ('Win32Window' -as [type])), [Environment]::Is64BitProcess, [Environment]::UserName, (Get-Process -Id $PID).SessionId, $BigFontName)

# ==============================================================================
# DYNAMIC REFRESH LOOP (EVERY 1 SECOND)
# ==============================================================================
$UpdateUI = {
    try {
    # 1. Timer, pulse and remaining-time estimate
    $Now = if ($script:Finished -and $script:EndTime) { $script:EndTime } else { Get-Date }
    $Elapsed = $Now - $StartTime
    if ($script:CloseAt -and (Get-Date) -ge $script:CloseAt) {
        $script:CloseAt = $null
        Write-Log "Closing UI (deployment complete)"
        $Form.Close()
    }
    $script:StatTimer = "{0:hh\:mm\:ss}" -f $Elapsed
    $script:Pulse = 1 - $script:Pulse

    $RemainText = 'Estimating remaining time...'
    $InLongStep = ($NoEstSteps -contains [int]$script:CurrentStepMax)
    if ($script:Finished) {
        $RemainText = 'Deployment complete'
    } elseif ($InLongStep) {
        # Duration depends on image size and network: do not guess
        $RemainText = 'Estimate available after the image is applied'
        $script:EstWasLong = $true
        $script:EstSmooth  = $null
    } else {
        if (-not $script:EstAnchorReady -and $script:TSConnected -and $script:PctValue -gt 0) {
            $script:EstAnchorReady = $true
            $script:EstAnchorMin   = $Elapsed.TotalMinutes
            $script:EstAnchorPct   = $script:PctValue
        }
        if ($script:EstWasLong) {
            # Just left a long step: restart the measurement from here
            $script:EstWasLong   = $false
            $script:EstAnchorMin = $Elapsed.TotalMinutes
            $script:EstAnchorPct = $script:PctValue
            $script:EstSmooth    = $null
        }
        if ($script:EstAnchorReady) {
            $dMin = $Elapsed.TotalMinutes - $script:EstAnchorMin
            $dPct = $script:PctValue - $script:EstAnchorPct
            if ($dPct -ge 5 -and $dMin -ge 0.5) {
                $Raw = $dMin * (100 - $script:PctValue) / $dPct
                if ($null -eq $script:EstSmooth) { $script:EstSmooth = $Raw }
                else { $script:EstSmooth = (0.85 * $script:EstSmooth) + (0.15 * $Raw) }
                $RemMin = [int][Math]::Ceiling($script:EstSmooth)
                if ($RemMin -lt 1) { $RemainText = 'Less than 1 min remaining' } else { $RemainText = "About $RemMin min remaining" }
            }
        }
    }
    $script:RemainText = $RemainText

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
        if ([string]::IsNullOrWhiteSpace($TotalRaw)) { throw "TS variables are empty" }
        if (-not $script:TSConnected) { Write-Log "TS environment connected" }
        $script:TSConnected = $true
        $script:TSFailCount = 0
        if ($script:Finished) { $script:Finished = $false; $script:CloseAt = $null; $script:EndTime = $null }
    } catch {
        $ErrMsg = $_.Exception.Message
        if ($ErrMsg -ne $script:LastTSError) {
            $script:LastTSError = $ErrMsg
            Write-Log "TS environment unavailable: $ErrMsg"
        }
        # Transient failure: drop the object, retry on next tick
        $script:TSEnvObj = $null
        $TSEnv = $null
        $script:TSFailCount++
        if ($script:TSConnected -and -not $script:Finished -and $script:TSFailCount -ge 20) {
            $script:Finished       = $true
            $script:EndTime        = Get-Date
            $script:CurrentStepMax = [int]$SortedIds[-1] + 1
            $script:PctValue       = 100
            $script:CurrentActionText = 'Your device is ready'
            Write-Log "TS environment gone for 20 ticks: deployment complete (AutoClose=$AutoClose)"
            if ($AutoClose) { $script:CloseAt = (Get-Date).AddSeconds(5) }
        }
        if (-not $script:TSConnected) {
            $script:CurrentActionText = 'Preview mode - task sequence not detected'
            # Optional preview values from config.json (PreviewPercent / PreviewStep) to test the UI
            if ($null -ne $Config.PreviewPercent) { $script:PctValue = [int]$Config.PreviewPercent }
            if ($null -ne $Config.PreviewStep)    { $script:CurrentStepMax = [int]$Config.PreviewStep }
        }
    }

    if ($null -ne $TSEnv) {

        if ([string]::IsNullOrWhiteSpace($CurrentAction)) { $script:CurrentActionText = 'Running task sequence...' }
        else { $script:CurrentActionText = [string]$CurrentAction }

        if (-not [string]::IsNullOrWhiteSpace($PCName)) { $script:vPC = [string]$PCName }

        if ($StepRaw -match '^\d+$' -and $TotalRaw -match '^\d+$' -and [int]$TotalRaw -gt 0) {
            $script:StatStep = "$StepRaw / $TotalRaw"
            $script:PctValue = [Math]::Min(100, [Math]::Round(([int]$StepRaw / [int]$TotalRaw) * 100))
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
                (Test-StepMatch -Action $CurrentAction -Keywords $StepMap[$_].Keywords)
            } | Select-Object -First 1

            if ($null -ne $Matched) {
                $script:CurrentStepMax = [int]$Matched
                try { $TSEnv.Value("TSBackgroundCurrentStep") = [string]$script:CurrentStepMax } catch { }
            }
        }
    }

    } catch { Write-Log "Section 3 (task sequence): $_" }
    try {
    # 4. Reliable IPv4 detection across all active adapters + domain refresh
    if (-not $script:CachedIP) {
        $IP = Get-WmiObject Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" -ErrorAction SilentlyContinue |
              ForEach-Object { $_.IPAddress } |
              Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notlike '169.254.*' -and $_ -ne '127.0.0.1' } |
              Select-Object -First 1
        if ($IP) {
            $script:CachedIP = $IP
            $script:vIP = [string]$IP
        }
    }
    # Domain: re-check every 5 seconds (value appears once the TS or DHCP provides it)
    $script:DomTick++
    if (($script:DomTick % 5) -eq 1) {
        $DomNow = Get-CompanyDomain -TSEnv $script:TSEnvObj
        if ($DomNow) { $script:vDomain = [string]$DomNow }
    }

    } catch { Write-Log "Section 4 (IP/domain): $_" }
    try {
    # 5. Texts derived from the state, then repaint the surface
    $nSteps = $SortedIds.Count
    $idx    = [Array]::IndexOf($SortedIds, [int]$script:CurrentStepMax)
    $stepNo = $idx + 1
    if ($script:Finished -or $stepNo -gt $nSteps) { $stepNo = $nSteps }
    if ($stepNo -lt 1) { $stepNo = 1 }
    $script:StepCaption = "Step $stepNo of $nSteps"

    if ($script:Finished) {
        $script:StatState = 'Deployment complete'
        $script:PillText  = 'DEPLOYMENT COMPLETE'
    } elseif ($script:TSConnected) {
        $script:StatState = 'Task sequence running'
        $script:PillText  = $PillRunning
    } else {
        $script:StatState = 'Preview mode'
        $script:PillText  = $PillRunning
    }
    $Canvas.Invalidate()
    } catch { Write-Log "Section 5 (repaint): $_" }
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
        if (-not [string]::IsNullOrEmpty($Config.DebugPassword) -and $PwdInput -eq $Config.DebugPassword) {
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
