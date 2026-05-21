#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$InstallPath = 'C:\ProgramData\KerberosRc4Monitor',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$TaskName = 'Kerberos RC4 Monitor',

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SmtpServer,

    [Parameter()]
    [ValidateRange(1, 65535)]
    [int]$SmtpPort = 25,

    [Parameter()]
    [bool]$UseSsl = $false,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$From,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$To,

    [Parameter()]
    [string]$Cc = '',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$SubjectPrefix = '[Kerberos RC4 Monitor]',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$EnvironmentName = 'PROD',

    [Parameter()]
    [ValidateRange(1, 1440)]
    [int]$IntervalMinutes = 15,

    [Parameter()]
    [ValidateRange(1, 10080)]
    [int]$LookbackMinutesOnFirstRun = 60,

    [Parameter()]
    [switch]$AttachCsv,

    [Parameter()]
    [switch]$AttachHtml,

    [Parameter()]
    [switch]$EnableHeartbeat,

    [Parameter()]
    [switch]$TestEmail,

    [Parameter()]
    [switch]$RunOnce,

    [Parameter()]
    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    [CmdletBinding()]
    param()

    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Directory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
        Write-Host ("Created directory: {0}" -f $Path)
    }
}

function Write-MonitorConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ConfigPath,

        [Parameter(Mandatory = $true)]
        [psobject]$ConfigObject,

        [Parameter(Mandatory = $true)]
        [bool]$AllowOverwrite
    )

    if ((Test-Path -LiteralPath $ConfigPath) -and (-not $AllowOverwrite)) {
        Write-Host ("Config already exists and was not overwritten: {0}" -f $ConfigPath)
        return
    }

    $json = $ConfigObject | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($ConfigPath, $json, [System.Text.Encoding]::UTF8)
    Write-Host ("Config written: {0}" -f $ConfigPath)
}

function Send-TestMonitorEmail {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Config
    )

    $mail = New-Object System.Net.Mail.MailMessage
    try {
        $mail.From = New-Object System.Net.Mail.MailAddress($Config.From)
        foreach ($address in @($Config.To -split ';|,')) {
            $trimmed = $address.Trim()
            if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
                [void]$mail.To.Add($trimmed)
            }
        }
        foreach ($address in @([string]$Config.Cc -split ';|,')) {
            $trimmed = $address.Trim()
            if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
                [void]$mail.CC.Add($trimmed)
            }
        }

        $mail.Subject = '{0} [{1}] Kerberos RC4 monitor test email on {2}' -f $Config.SubjectPrefix, $Config.EnvironmentName, $env:COMPUTERNAME
        $mail.Body = '<html><body><p>Kerberos RC4 monitor test email.</p></body></html>'
        $mail.IsBodyHtml = $true

        $smtp = New-Object System.Net.Mail.SmtpClient($Config.SmtpServer, [int]$Config.SmtpPort)
        $smtp.EnableSsl = [bool]$Config.UseSsl
        $smtp.UseDefaultCredentials = $true
        $smtp.Send($mail)
    }
    finally {
        if ($mail) {
            $mail.Dispose()
        }
    }
}

if (-not (Test-IsAdministrator)) {
    throw 'This script must be run in an elevated PowerShell session (Administrator).'
}

$logsPath = Join-Path -Path $InstallPath -ChildPath 'Logs'
$reportsPath = Join-Path -Path $InstallPath -ChildPath 'Reports'
$configPath = Join-Path -Path $InstallPath -ChildPath 'KerberosRc4Monitor.config.json'
$statePath = Join-Path -Path $InstallPath -ChildPath 'KerberosRc4Monitor.state.json'
$monitorScriptPath = Join-Path -Path $InstallPath -ChildPath 'KerberosRc4Monitor.ps1'

Ensure-Directory -Path $InstallPath
Ensure-Directory -Path $logsPath
Ensure-Directory -Path $reportsPath

$sourceMonitorPath = Join-Path -Path $PSScriptRoot -ChildPath 'KerberosRc4Monitor.ps1'
if (-not (Test-Path -LiteralPath $sourceMonitorPath)) {
    throw "Source monitor script not found next to installer: $sourceMonitorPath"
}

if ($PSCmdlet.ShouldProcess($monitorScriptPath, 'Copy monitor script to install path')) {
    Copy-Item -LiteralPath $sourceMonitorPath -Destination $monitorScriptPath -Force
    Write-Host ("Copied monitor script: {0}" -f $monitorScriptPath)
}

$configObject = [pscustomobject]@{
    InstallPath                    = $InstallPath
    LogPath                        = $logsPath
    ReportPath                     = $reportsPath
    StatePath                      = $statePath
    SmtpServer                     = $SmtpServer
    SmtpPort                       = $SmtpPort
    UseSsl                         = $UseSsl
    From                           = $From
    To                             = $To
    Cc                             = $Cc
    SubjectPrefix                  = $SubjectPrefix
    EnvironmentName                = $EnvironmentName
    MaxMessageLength               = 4000
    AttachCsv                      = [bool]$AttachCsv
    AttachHtml                     = [bool]$AttachHtml
    EnableHeartbeat                = [bool]$EnableHeartbeat
    LookbackMinutesOnFirstRun      = $LookbackMinutesOnFirstRun
    SafeLookbackMinutesOnRollover  = $LookbackMinutesOnFirstRun
    LogRetentionDays               = 30
    MaxDetailedRowsInEmail         = 200
}

if ($PSCmdlet.ShouldProcess($configPath, 'Write monitor config')) {
    Write-MonitorConfig -ConfigPath $configPath -ConfigObject $configObject -AllowOverwrite ([bool]$Force)
}

$startTime = (Get-Date).AddMinutes(2)
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}"' -f $monitorScriptPath, $configPath)
$trigger = New-ScheduledTaskTrigger -Once -At $startTime -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) -RepetitionDuration (New-TimeSpan -Days 3650)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

if ($PSCmdlet.ShouldProcess($TaskName, 'Register or update scheduled task')) {
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Monitors Kerberos RC4 evidence/dependency events and emails a report.' -Force | Out-Null
    Write-Host ("Scheduled task registered/updated: {0}" -f $TaskName)
}

if ($TestEmail) {
    if ($PSCmdlet.ShouldProcess($To, 'Send test email')) {
        Send-TestMonitorEmail -Config $configObject
        Write-Host 'Test email sent successfully.'
    }
}

if ($RunOnce) {
    if ($PSCmdlet.ShouldProcess($monitorScriptPath, 'Run monitor once now')) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $monitorScriptPath -ConfigPath $configPath
        Write-Host 'RunOnce execution completed.'
    }
}

Write-Host 'Installation/configuration completed.'
Write-Host ("Install path: {0}" -f $InstallPath)
Write-Host ("Config path: {0}" -f $configPath)
Write-Host ("Task name: {0}" -f $TaskName)
