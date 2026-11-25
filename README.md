# TSBackground-OSD

A modern full-screen background for **Configuration Manager (SCCM / MECM) OS deployment** task sequences.
It shows a branded progress screen with a live step tracker while Windows is being deployed, from WinPE to the
first boot of the full OS.

> Version 2.6.0

## Features

- Full-screen UI with a right-hand **step tracker** (pending / active / done).
- Reads the running task sequence through `Microsoft.SMS.TSEnvironment`: current action, instruction progress, computer name.
- **Elapsed timer and current step survive reboots** (WinPE to full OS), stored in task sequence variables.
- Hardware and network card: serial number, model, BIOS version, IPv4, MAC address.
- Fully configurable through `config.json`: texts, colors, logo, steps and keywords.
- Optional hiding of the standard "Installation Progress" window.
- **Closes automatically** when the task sequence is over (optional).
- Password-protected diagnostic console (`Ctrl+Shift+D`).
- Diagnostic log: `%SystemRoot%\Temp\TSBackground-OSD.log`.
- Layout adapts to the screen resolution (WinPE often runs at a low resolution).

## Requirements

- Configuration Manager OSD with a boot image that includes **Windows PowerShell**, **.NET** and **WMI** (the default ConfigMgr boot image does).
- For the full OS phase: `ServiceUI.exe` (x64), see [ServiceUI](#serviceui-full-os-phase).
- Windows PowerShell 5.1.

## Repository content

| File | Purpose |
|---|---|
| `TSBackground-OSD.ps1` | The script. Keep it saved as **UTF-8 with BOM**. |
| `config.example.json` | Example configuration. Copy it to `config.json` and edit it. |
| `logo.png` (optional) | Logo displayed top-left. If missing, the company and department names are shown as text. |

## Installation

1. Create a folder and copy `TSBackground-OSD.ps1`, your `config.json`, an optional `logo.png` and `ServiceUI.exe` (x64) into it.
2. In the console, create a **package** from that folder (*This package contains source files*, no program) and distribute it to your distribution points.
3. Add **two "Run Command Line" steps** to your task sequence, both using this package (a step can only use one package, so every file must be in it).

### Step 1: WinPE

Place it in *Install Operating System*, right after *Restart in Windows PE*:

```
cmd.exe /c start "" powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File TSBackground-OSD.ps1
```

### Step 2: full OS

Place it **after** *Setup Windows and Configuration Manager* (everything before that step still runs in WinPE):

```
cmd.exe /c start "" ServiceUI.exe -process:TSProgressUI.exe %SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File TSBackground-OSD.ps1
```

Recommended options for both steps:

- **Continue on error** (a background screen should never fail a deployment).
- On the full OS step, tick **Disable 64-bit file system redirection** so the 64-bit PowerShell is used.

> The full OS phase starts only after *Setup Windows and Configuration Manager* has finished, so nothing can be displayed while the ConfigMgr client is being installed.

After every change, **update the distribution points** and wait for the *Success* status before testing. The text at the bottom of the sidebar shows the version actually served.

## ServiceUI (full OS phase)

During the full OS phase, task sequence steps run as SYSTEM in session 0, so a window started directly is not visible.
`ServiceUI.exe` starts the script in the session of `TSProgressUI.exe`, which is the visible one.

- It is a Microsoft binary shipped with the Microsoft Deployment Toolkit (`Templates\Distribution\Tools\x64\ServiceUI.exe`). **This repository does include it.**
- MDT was retired by Microsoft on January 6, 2026, so its download may no longer be available. Use a copy you already have.
- Use the **x64** version. A 32-bit `ServiceUI` starts the 32-bit PowerShell.
- Check the file before using it, since it runs as SYSTEM:

```powershell
Get-AuthenticodeSignature .\ServiceUI.exe | Select-Object Status, @{n='Signer';e={$_.SignerCertificate.Subject}}
```

The status must be `Valid` and the signer `Microsoft Corporation`.

`-process:TSProgressUI.exe` relies on the standard progress window being running, so keep `HideSCCMProgress` set to `false` if you use it this way.

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

### How step detection works

- Keywords are plain text, **case-insensitive**, not regular expressions. Separate them with `|`, `;` or `,`, or use a JSON array.
- For each running action, the script selects the **first step after the current one** whose keywords match. It never goes backwards.
- The reached step is stored in the task sequence variable `TSBackgroundCurrentStep` and restored after a reboot.
- Keywords must match the **real action names** of your task sequence. Avoid broad words (for example `Restart` or `Package`) that also appear in earlier actions.
- If your task sequence is not in English, add the local action names to `Keywords`.

## Diagnostics

The log is written to `%SystemRoot%\Temp\TSBackground-OSD.log` (`X:\Windows\Temp` in WinPE, `C:\Windows\Temp` in the full OS):

```
type X:\Windows\Temp\TSBackground-OSD.log
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

## Security

- `DebugPassword` is stored in **plain text** in `config.json`, readable by anyone who can read the package content.
  Use a dedicated value, never a password you use elsewhere. Keep the diagnostic console disabled by leaving `DebugPassword` empty.
- `ServiceUI.exe` runs as SYSTEM: verify its signature and keep it out of public repositories.

## Author

Abdelkader Nouacer IT

## License

Add a license of your choice (for example MIT) in a `LICENSE` file before publishing.
