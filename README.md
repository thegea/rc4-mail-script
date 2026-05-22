# Kerberos RC4 Monitor (Windows DC)

This repository contains three scripts:

- `KerberosRc4Monitor.ps1` (collector/reporter/state manager)
- `Install-KerberosRc4MonitorTask.ps1` (install + scheduled task setup)
- `Remove-KerberosRc4MonitorTask.ps1` (task removal + optional file cleanup)

## What it does

Runs on a Domain Controller every 15 minutes and reports:

- Security events `4768`, `4769`, `4770` **only when** RC4 is detected in:
  - `TicketEncryptionType`
  - `SessionKeyEncryptionType`
  - `PreAuthEncryptionType`
  - RC4 values: `0x17` or `0x18`
- System/Kdcsvc events: `201,202,203,204,206,207,208,209`

State is saved per log using `RecordId` to prevent duplicate emails.

## Requirements

- Windows Server Domain Controller
- Windows PowerShell 5.1
- Local admin rights for install/remove scripts
- SMTP relay reachable from the DC

## Quick install

Run in elevated PowerShell:

```powershell
.\Install-KerberosRc4MonitorTask.ps1 `
  -SmtpServer "smtp-relay.internal.local" `
  -SmtpPort 25 `
  -From "kerberos-monitor@internal.local" `
  -To "ad-team@internal.local" `
  -EnvironmentName "PROD" `
  -SubjectPrefix "[PROD] Kerberos RC4 Monitor" `
  -IntervalMinutes 15 `
  -AttachCsv `
  -RunOnce
```

## Where to set mail server and sender/recipient addresses

You can set them in either place:

1. During install via parameters (recommended), or
2. Directly in config file after install:

`C:\ProgramData\KerberosRc4Monitor\KerberosRc4Monitor.config.json`

Key mail settings in JSON:

```json
{
  "SmtpServer": "smtp-relay.internal.local",
  "SmtpPort": 25,
  "UseSsl": false,
  "From": "kerberos-monitor@internal.local",
  "To": "ad-team@internal.local",
  "Cc": "",
  "SubjectPrefix": "[PROD] Kerberos RC4 Monitor",
  "EnvironmentName": "PROD"
}
```

`To` and `Cc` support comma/semicolon-separated recipients.

## Default paths

- Install path: `C:\ProgramData\KerberosRc4Monitor`
- Config: `C:\ProgramData\KerberosRc4Monitor\KerberosRc4Monitor.config.json`
- State: `C:\ProgramData\KerberosRc4Monitor\KerberosRc4Monitor.state.json`
- Logs: `C:\ProgramData\KerberosRc4Monitor\Logs`
- Reports: `C:\ProgramData\KerberosRc4Monitor\Reports`

## Manual run

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\KerberosRc4Monitor\KerberosRc4Monitor.ps1" -ConfigPath "C:\ProgramData\KerberosRc4Monitor\KerberosRc4Monitor.config.json"
```

Dry run (`-WhatIf`, no email/state update):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\KerberosRc4Monitor.ps1 -ConfigPath .\KerberosRc4Monitor.config.json -WhatIf
```

## Verify scheduled task

```powershell
Get-ScheduledTask -TaskName "Kerberos RC4 Monitor"
Get-ScheduledTaskInfo -TaskName "Kerberos RC4 Monitor"
```

## Remove task

Keep files:

```powershell
.\Remove-KerberosRc4MonitorTask.ps1
```

Remove files but keep state:

```powershell
.\Remove-KerberosRc4MonitorTask.ps1 -RemoveFiles -KeepState
```
