#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$TaskName = 'Kerberos RC4 Monitor',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$InstallPath = 'C:\ProgramData\KerberosRc4Monitor',

    [Parameter()]
    [switch]$RemoveFiles,

    [Parameter()]
    [switch]$KeepReports,

    [Parameter()]
    [switch]$KeepState
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

function Remove-PathIfExists {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter()]
        [switch]$Recurse
    )

    if (Test-Path -LiteralPath $Path) {
        if ($PSCmdlet.ShouldProcess($Path, 'Remove path')) {
            Remove-Item -LiteralPath $Path -Force -Recurse:$Recurse
            Write-Host ("Removed: {0}" -f $Path)
        }
    }
}

if (-not (Test-IsAdministrator)) {
    throw 'This script must be run in an elevated PowerShell session (Administrator).'
}

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    try {
        $taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($taskInfo -and $taskInfo.State -eq 'Running') {
            if ($PSCmdlet.ShouldProcess($TaskName, 'Stop scheduled task')) {
                Stop-ScheduledTask -TaskName $TaskName | Out-Null
                Write-Host ("Stopped task: {0}" -f $TaskName)
            }
        }
    }
    catch {
        Write-Warning ("Unable to evaluate or stop running task '{0}': {1}" -f $TaskName, $_.Exception.Message)
    }

    if ($PSCmdlet.ShouldProcess($TaskName, 'Unregister scheduled task')) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host ("Unregistered task: {0}" -f $TaskName)
    }
}
else {
    Write-Host ("Scheduled task not found: {0}" -f $TaskName)
}

if (-not $RemoveFiles) {
    Write-Host 'RemoveFiles was not specified. Installed files are preserved.'
    Write-Host ("Install path: {0}" -f $InstallPath)
    return
}

$reportsPath = Join-Path -Path $InstallPath -ChildPath 'Reports'
$logsPath = Join-Path -Path $InstallPath -ChildPath 'Logs'
$statePath = Join-Path -Path $InstallPath -ChildPath 'KerberosRc4Monitor.state.json'
$configPath = Join-Path -Path $InstallPath -ChildPath 'KerberosRc4Monitor.config.json'
$monitorScriptPath = Join-Path -Path $InstallPath -ChildPath 'KerberosRc4Monitor.ps1'

Remove-PathIfExists -Path $monitorScriptPath
Remove-PathIfExists -Path (Join-Path -Path $InstallPath -ChildPath 'Install-KerberosRc4MonitorTask.ps1')
Remove-PathIfExists -Path (Join-Path -Path $InstallPath -ChildPath 'Remove-KerberosRc4MonitorTask.ps1')
Remove-PathIfExists -Path $configPath
Remove-PathIfExists -Path $logsPath -Recurse

if (-not $KeepReports) {
    Remove-PathIfExists -Path $reportsPath -Recurse
}
else {
    Write-Host ("Keeping reports as requested: {0}" -f $reportsPath)
}

if (-not $KeepState) {
    Remove-PathIfExists -Path $statePath
}
else {
    Write-Host ("Keeping state as requested: {0}" -f $statePath)
}

if (Test-Path -LiteralPath $InstallPath) {
    $remaining = Get-ChildItem -LiteralPath $InstallPath -Force -ErrorAction SilentlyContinue
    if (-not $remaining -or $remaining.Count -eq 0) {
        Remove-PathIfExists -Path $InstallPath -Recurse
    }
    else {
        Write-Host ("Install path retained because files remain: {0}" -f $InstallPath)
    }
}

Write-Host 'Removal completed.'
