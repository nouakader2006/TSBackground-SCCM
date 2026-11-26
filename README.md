# TSBackground-OSD

A modern full-screen background for **Configuration Manager (SCCM / MECM) OS deployment** task sequences.
It shows a branded progress screen with a live step tracker while Windows is being deployed, from WinPE to the
first boot of the full OS.

![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue)
![Platform](https://img.shields.io/badge/SCCM%20%2F%20MECM-WinPE%20%26%20Full%20OS-0078D4)
https://github.com/nouakader2006/TSBackground-SCCM/blob/main/ScreenShoot/TS.jpg?raw=true

TSBackground replaces the default "Installation Progress" window with a clean, branded screen that shows the big overall percentage, the current phase, live device and network information, and a vertical step timeline. It is a single `.ps1` file plus a JSON configuration, with no external dependency.




> Version 3.0.0

## Features

- **Big overall percentage** based on the task sequence instruction pointer.
- **Segmented phase bar** (one segment per step) with a "Step X of Y" caption.
- **Vertical step timeline** with done / active / pending states and a sub-text per step.
- **Three live cards**
- **Device**: computer name, model, serial number, BIOS version.
- **Network**: domain, IP address, MAC address, connection status.
- **Status**: elapsed time, task sequence state and instruction counter (for example `11 / 21`).
- **Remaining-time estimate** that skips long steps (such as applying the OS image) instead of guessing.
- **Persistent timer and progress across reboots** (WinPE to full Windows) using task sequence variables.
- **Optional hiding of the standard SCCM progress window** (`HideSCCMProgress`).
- **Auto-close** when the task sequence ends.
- **Password-protected diagnostic console** (`Ctrl+Shift+D`).
- **Fully configurable** from `config.json`: steps, keywords, texts, colors, logo.
- **Scales with the screen**: the whole layout is drawn with GDI+ and resizes from small to 4K displays.
- **No icon font needed**: icons are drawn as vectors, so they also render in WinPE.
- **Built-in log file** for easy troubleshooting.

## Requirements

| Item | Details |
|------|---------|
| Platform | SCCM / MECM task sequence |
| PowerShell | Windows PowerShell 5.1 |
| WinPE | Configuration Manager OSD with a boot image that includes **Windows PowerShell**, **.NET** and **WMI** (the default ConfigMgr boot image does). |
| Files | `TSBackground.ps1` and `config.json` in the same folder, For the full OS phase: `ServiceUI.exe` (x64), see [ServiceUI](#serviceui-full-os-phase) |

> The script reads hardware information with WMI (`Get-WmiObject`) and draws everything with `System.Windows.Forms` / `System.Drawing`.

## Repository content

| File | Purpose |
|---|---|
| `TSBackground.ps1` | The script. Keep it saved as **UTF-8 with BOM**. |
| `config.example.json` | Example configuration. Copy it to `config.json` and edit it. |
| `logo.png` (optional) | Logo displayed top-left. If missing, the company and department names are shown as text. |

## Quick start

### 1. Test it locally (no task sequence needed)

1. Copy `config.example.json` to `config.json` next to the script.
2. Add the preview values to `config.json`:

   ```json
   "PreviewPercent": 42,
   "PreviewStep": 2
   ```
3. Run:

   ```powershell
   powershell.exe -ExecutionPolicy Bypass -File .\TSBackground.ps1
   ```

## Installation

1. Create a folder and copy `TSBackground.ps1`, your `config.json`, an optional `logo.png` and `ServiceUI.exe` (x64) into it.
2. In the console, create a **package** from that folder (*This package contains source files*, no program) and distribute it to your distribution points.
3. - your logo, if you use `LogoPath`
4. Add **two "Run Command Line" steps** to your task sequence, both using this package (a step can only use one package, so every file must be in it).


### Step 1: WinPE

Place it in *Install Operating System*, right after *Restart in Windows PE*:

```
cmd.exe /c start "" powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File TSBackground.ps1
```

### Step 2: full OS

Place it **after** *Setup Windows and Configuration Manager* (everything before that step still runs in WinPE):

```
cmd.exe /c start "" ServiceUI.exe -process:TSProgressUI.exe %SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File TSBackground.ps1
```

Recommended options for both steps:

- **Continue on error** (a background screen should never fail a deployment).
- On the full OS step, tick **Disable 64-bit file system redirection** so the 64-bit PowerShell is used.

> The full OS phase starts only after *Setup Windows and Configuration Manager* has finished, so nothing can be displayed while the ConfigMgr client is being installed.

After every change, **update the distribution points** and wait for the *Success* status before testing. The text at the bottom of the sidebar shows the version actually served.

## ServiceUI (full OS phase)

During the full OS phase, task sequence steps run as SYSTEM in session 0, so a window started directly is not visible.
`ServiceUI.exe` starts the script in the session of `TSProgressUI.exe`, which is the visible one.

- It is a Microsoft binary shipped with the Microsoft Deployment Toolkit (`Templates\Distribution\Tools\x64\ServiceUI.exe`). **This repository does not include it.**
- MDT was retired by Microsoft on January 6, 2026, so its download may no longer be available. Use a copy you already have.
- Use the **x64** version. A 32-bit `ServiceUI` starts the 32-bit PowerShell.
- Check the file before using it, since it runs as SYSTEM:

```powershell
Get-AuthenticodeSignature .\ServiceUI.exe | Select-Object Status, @{n='Signer';e={$_.SignerCertificate.Subject}}
```

The status must be `Valid` and the signer `Microsoft Corporation`.

`-process:TSProgressUI.exe` relies on the standard progress window being running, so keep `HideSCCMProgress` set to `false` if you use it this way.

## How it works

| Topic | Behavior |
|-------|----------|
| **Progress** | Percentage = `_SMSTSNextInstructionPointer / _SMSTSInstructionTableSize`. |
| **Step detection** | The running action name (`_SMSTSCurrentActionName`) is compared with each step's `Keywords`. The UI only moves **forward**. |
| **Persistence** | The start time (`TSBackgroundStartTime`) and the current step (`TSBackgroundCurrentStep`) are saved as task sequence variables. |
| **Computer name** | Taken from `OSDComputerName` when available. |
| **Completion** | If the task sequence environment disappears for about 20 seconds after being connected, the UI shows "Deployment complete" and closes after 5 seconds (see `AutoCloseOnCompletion`). |
| **Domain** | Resolved in this order: `DomainName` in `config.json`, then the task sequence variable `OSDDomain`, then the real domain membership (full Windows), then the DNS suffix received from DHCP. If nothing is found, "Not joined yet" is shown. WinPE itself always reports `WORKGROUP`, which is why it is not used. |
| **Remaining time** | Measured only after the long steps listed in `NoEstimateSteps`, then smoothed. It starts after at least 5 % of progress and 30 seconds of measurement. |

## Configuration (`config.json`)

| Key | Description |
|---|---|
| `CompanyName`, `DepartmentName` | Shown top-left when no logo is found. |
| `Title`, `SubTitle` | Main texts. The title font shrinks to fit the available width. |
| `LogoPath` | Image path relative to the script (leave empty for no logo). |
| `HideSCCMProgress` | `true` hides the standard "Installation Progress" window. Default recommendation: `false`. |
| `AutoCloseOnCompletion` | Close the UI when the task sequence ends. Default: `true`. |
| `DebugPassword` | Password for the diagnostic console. **Stored in plain text**, see [Security](#security). |
| `Theme.*` | Colors in HTML format (`#RRGGBB`). All keys of the example are required. |
| `Steps[].Id` | Integer, starting at `1`, in the order of the deployment. |
| `Steps[].Name` | Label displayed in the tracker. |
| `Steps[].Keywords` | Words matched against the **name of the running task sequence action**. |

### General options

| Key | Default | Description |
|-----|---------|-------------|
| `CompanyName` | `Your Campany` | Company name shown in the header (replaced by the logo when `LogoPath` is set). |
| `DepartmentName` | `IT Department` | Small caption under the company name (displayed in capitals). |
| `LogoPath` | *(none)* | Logo file relative to the script folder. Replaces the built-in brand mark and the company name. |
| `Headline` | `Preparing your\|new workspace` | Main title. Use `\|` to split it on two lines. |
| `OsName` | `Windows 11 Enterprise` | Line shown under the title. |
| `StatusPill` | `DEPLOYMENT IN PROGRESS` | Text of the pill in the top-right corner. |
| `InfoMessage` | `Please keep your device connected to power.` | Message shown in the information bar. |
| `SupportTitle` | `IT Support - Service Desk` | Footer title. |
| `SupportText` | `For assistance, contact the IT Help Desk.` | Footer sub-text. |
| `DomainName` | *(auto)* | Fixed domain name to display. **Recommended**, because it is shown from the first second, even in WinPE. |
| `HideSCCMProgress` | `false` | Hides the standard SCCM "Installation Progress" window. |
| `AutoCloseOnCompletion` | `true` | Closes the UI when the task sequence ends. |
| `NoEstimateSteps` | `[2]` | Step IDs during which no time estimate is shown (for example the OS image apply). |
| `DebugPassword` | *(none)* | Password required to open the diagnostic console. If empty, the console cannot be opened. |
| `PreviewPercent` | *(none)* | Test only: forces the displayed percentage outside a task sequence. |
| `PreviewStep` | *(none)* | Test only: forces the active step outside a task sequence. |

### Theme

| Key | Default |
|-----|---------|
| `Theme.Background` | `#0B1220` |
| `Theme.CardBackground` | `#172337` |
| `Theme.TextPrimary` | `#F1F5F9` |
| `Theme.TextSecondary` | `#94A3B8` |
| `Theme.AccentColor` | `#22D3EE` |
| `Theme.SuccessColor` | `#22C55E` |

### Steps

Each entry of the `Steps` array is one phase, shown as a segment in the progress bar and as a node in the timeline.

| Key | Required | Description |
|-----|----------|-------------|
| `Id` | yes | Unique number. Steps are ordered by `Id`. |
| `Name` | yes | Full step name. |
| `ShortName` | no | Short label under the progress bar segment (falls back to `Name`). |
| `TimelineName` | no | Title in the timeline (falls back to `ShortName`, then `Name`). |
| `Keywords` | yes | Action names that **start** this step (see below). |
| `Description` | no | Timeline sub-text while the step is pending or active. |
| `DoneText` | no | Timeline sub-text once the step is complete. |
| `StatusText` | no | Text of the main status line while the step is active. |

The built-in defaults are written for five phases (IDs 1 to 5: preparation, operating system, network, applications, finalization). Change the texts to match your own steps.

### Keywords

- Matching is **case-insensitive** and uses a **partial match** on the action name shown by the task sequence.
- A keyword list can be a string separated by `|`, `;` or `,`, or a JSON array. Do **not** use a comma inside a keyword.
- A step becomes active when the running action matches one of its keywords. Only steps **after** the current one are checked, and the UI never goes backwards.
- Step 1 is active from the start, so its keywords matter little.
- Avoid very generic keywords such as `Apply`: they match several steps, and the first match wins.

## Diagnostics

The log is written to `%SystemRoot%\Temp\TSBackground.log` (`X:\Windows\Temp` in WinPE, `C:\Windows\Temp` in the full OS):

```
type X:\Windows\Temp\TSBackground.log
```

It contains the version, bitness, account and session, every action seen with its progress, errors per section,
`TS environment connected` / `unavailable: ...`, and the end of the deployment. In WinPE, press **F8** to open a command prompt.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| "Preview Mode - SCCM Task Sequence Not Detected" | The script cannot read the task sequence environment. Check the log line `TS environment unavailable`, and that the process is 64-bit. |
| Step tracker stays on step 1 | No keyword matches the action name shown in "Current Step". Adjust `Keywords`. |
| Tracker jumps to the wrong step | A keyword is too broad and matches an earlier action. |
| Step fails with `0x80070002` | A file is missing from the package (`ServiceUI.exe`, the script) or the distribution points are not updated. |
| Nothing displayed after the reboot | The full OS step is placed before *Setup Windows and Configuration Manager*, or `ServiceUI.exe` is missing or 32-bit. |
| Old version still displayed | Distribution points not updated, or the command line points to another file name. |
| `ConvertFrom-Json` error | `config.json` is not valid JSON (for example a missing closing brace). |
| Garbled symbols | The script was saved without BOM. Save it as UTF-8 with BOM. |

## Keyboard shortcuts

| Key | Action |
|-----|--------|
| `Ctrl` + `Shift` + `D` | Asks for the `DebugPassword`, then opens a command prompt. |
| `Esc` | Closes the window. |

## Security

- `DebugPassword` is stored in **plain text** in `config.json`, readable by anyone who can read the package content.
  Use a dedicated value, never a password you use elsewhere. Keep the diagnostic console disabled by leaving `DebugPassword` empty.
- `ServiceUI.exe` runs as SYSTEM: verify its signature and keep it out of public repositories.

## Author

Abdelkader Nouacer IT

## License
MIT
