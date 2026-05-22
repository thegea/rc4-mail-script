#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigPath = 'C:\ProgramData\KerberosRc4Monitor\KerberosRc4Monitor.config.json'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Write-MonitorLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Message,

        [Parameter()]
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO',

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$LogPath
    )

    $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    $line = '{0} [{1}] {2}' -f $timestamp, $Level, $Message
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
}

function Invoke-LogRetention {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$LogDirectory,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 3650)]
        [int]$RetentionDays,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$CurrentLogPath
    )

    if (-not (Test-Path -LiteralPath $LogDirectory)) {
        return
    }

    $cutoff = (Get-Date).AddDays(-1 * $RetentionDays)
    Get-ChildItem -Path $LogDirectory -Filter '*.log' -File -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.FullName -eq $CurrentLogPath) {
            return
        }
        if ($_.LastWriteTime -lt $cutoff) {
            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

function Read-MonitorConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Config file not found: $Path"
    }

    $raw = Get-Content -LiteralPath $Path -Encoding UTF8 -Raw
    $config = $raw | ConvertFrom-Json
    if (-not $config) {
        throw "Config file is empty or invalid JSON: $Path"
    }

    $required = @(
        'InstallPath',
        'StatePath',
        'LogPath',
        'ReportPath',
        'SmtpServer',
        'SmtpPort',
        'UseSsl',
        'From',
        'To',
        'SubjectPrefix',
        'EnvironmentName'
    )

    foreach ($name in $required) {
        if (-not $config.PSObject.Properties[$name]) {
            throw "Missing required config property: $name"
        }
    }

    if (-not $config.PSObject.Properties['MaxMessageLength']) { $config | Add-Member -NotePropertyName 'MaxMessageLength' -NotePropertyValue 4000 }
    if (-not $config.PSObject.Properties['AttachCsv']) { $config | Add-Member -NotePropertyName 'AttachCsv' -NotePropertyValue $true }
    if (-not $config.PSObject.Properties['AttachHtml']) { $config | Add-Member -NotePropertyName 'AttachHtml' -NotePropertyValue $false }
    if (-not $config.PSObject.Properties['EnableHeartbeat']) { $config | Add-Member -NotePropertyName 'EnableHeartbeat' -NotePropertyValue $false }
    if (-not $config.PSObject.Properties['LookbackMinutesOnFirstRun']) { $config | Add-Member -NotePropertyName 'LookbackMinutesOnFirstRun' -NotePropertyValue 60 }
    if (-not $config.PSObject.Properties['SafeLookbackMinutesOnRollover']) { $config | Add-Member -NotePropertyName 'SafeLookbackMinutesOnRollover' -NotePropertyValue 60 }
    if (-not $config.PSObject.Properties['LogRetentionDays']) { $config | Add-Member -NotePropertyName 'LogRetentionDays' -NotePropertyValue 30 }
    if (-not $config.PSObject.Properties['MaxDetailedRowsInEmail']) { $config | Add-Member -NotePropertyName 'MaxDetailedRowsInEmail' -NotePropertyValue 200 }

    return $config
}

function New-DefaultLogState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$LogName
    )

    return [pscustomobject]@{
        LogName             = $LogName
        LastRecordId        = 0
        LastProcessedTimeUtc = $null
        LastRunStartedUtc   = $null
        LastRunCompletedUtc = $null
    }
}

function Read-MonitorState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$StatePath
    )

    if (-not (Test-Path -LiteralPath $StatePath)) {
        return [pscustomobject]@{
            Logs = @(
                (New-DefaultLogState -LogName 'Security'),
                (New-DefaultLogState -LogName 'System')
            )
        }
    }

    $raw = Get-Content -LiteralPath $StatePath -Encoding UTF8 -Raw
    $state = $raw | ConvertFrom-Json
    if (-not $state -or -not $state.Logs) {
        return [pscustomobject]@{
            Logs = @(
                (New-DefaultLogState -LogName 'Security'),
                (New-DefaultLogState -LogName 'System')
            )
        }
    }

    $requiredLogs = @('Security', 'System')
    foreach ($logName in $requiredLogs) {
        if (-not ($state.Logs | Where-Object { $_.LogName -eq $logName })) {
            $state.Logs += (New-DefaultLogState -LogName $logName)
        }
    }

    return $state
}

function Save-MonitorStateAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$StatePath,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object]$State
    )

    $parent = Split-Path -Path $StatePath -Parent
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }

    $json = $State | ConvertTo-Json -Depth 8
    $tempPath = '{0}.{1}.tmp' -f $StatePath, ([guid]::NewGuid().ToString('N'))
    [System.IO.File]::WriteAllText($tempPath, $json, [System.Text.Encoding]::UTF8)
    Move-Item -LiteralPath $tempPath -Destination $StatePath -Force
}

function Acquire-MonitorLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$LockName
    )

    $isCreatedNew = $false
    $mutex = New-Object System.Threading.Mutex($true, $LockName, [ref]$isCreatedNew)
    if (-not $isCreatedNew) {
        $mutex.Dispose()
        return $null
    }

    return $mutex
}

function Release-MonitorLock {
    [CmdletBinding()]
    param(
        [Parameter()]
        [System.Threading.Mutex]$Mutex
    )

    if (-not $Mutex) {
        return
    }

    try {
        $Mutex.ReleaseMutex() | Out-Null
    }
    catch {
    }
    finally {
        $Mutex.Dispose()
    }
}

function Get-EventDataMap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [System.Diagnostics.Eventing.Reader.EventRecord]$EventRecord
    )

    $map = @{}
    [xml]$xml = $EventRecord.ToXml()
    $dataNodes = @($xml.Event.EventData.Data)
    foreach ($node in $dataNodes) {
        if (-not $node) { continue }
        if ($node.Name) {
            $value = ''
            if ($null -ne $node.'#text') { $value = [string]$node.'#text' }
            $map[$node.Name] = $value
        }
    }

    return $map
}

function Get-EventDataValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Map,

        [Parameter(Mandatory = $true)]
        [string[]]$Names
    )

    foreach ($name in $Names) {
        if ($Map.ContainsKey($name)) {
            return [string]$Map[$name]
        }
    }
    return $null
}

function Test-Rc4EncryptionValue {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    $normalized = $Value.Trim().ToLowerInvariant()
    return ($normalized -eq '0x17' -or $normalized -eq '0x18')
}

function Get-Rc4Trigger {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Map
    )

    $fields = @('TicketEncryptionType', 'SessionKeyEncryptionType', 'PreAuthEncryptionType')
    $triggers = New-Object System.Collections.Generic.List[string]
    foreach ($field in $fields) {
        $value = Get-EventDataValue -Map $Map -Names @($field)
        if (Test-Rc4EncryptionValue -Value $value) {
            [void]$triggers.Add(('{0}={1}' -f $field, $value))
        }
    }

    return $triggers.ToArray()
}

function Convert-EventToRc4Record {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Eventing.Reader.EventRecord]$EventRecord,

        [Parameter(Mandatory = $true)]
        [ValidateSet('SecurityRc4Evidence', 'KdcsvcDependencyOrHardening')]
        [string]$EvidenceType,

        [Parameter()]
        [string[]]$Rc4Triggers = @(),

        [Parameter(Mandatory = $true)]
        [ValidateRange(200, 100000)]
        [int]$MaxMessageLength
    )

    $eventData = Get-EventDataMap -EventRecord $EventRecord
    $message = $null
    try {
        $message = $EventRecord.FormatDescription()
    }
    catch {
        $message = $null
    }

    if ([string]::IsNullOrEmpty($message)) {
        $message = ''
    }
    if ($message.Length -gt $MaxMessageLength) {
        $message = $message.Substring(0, $MaxMessageLength) + '...[truncated]'
    }

    $timeCreated = $EventRecord.TimeCreated
    $timeCreatedUtc = $null
    if ($timeCreated) {
        $timeCreatedUtc = $timeCreated.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
    }

    $spn = Get-EventDataValue -Map $eventData -Names @('SPN', 'ServiceName', 'TargetName')
    $clientAddress = Get-EventDataValue -Map $eventData -Names @('ClientAddress', 'IpAddress')

    $record = [pscustomobject]@{
        TimeCreated                          = if ($timeCreated) { $timeCreated.ToString('yyyy-MM-dd HH:mm:ss') } else { $null }
        TimeCreatedUtc                       = $timeCreatedUtc
        DCName                               = $env:COMPUTERNAME
        DomainName                           = $env:USERDNSDOMAIN
        LogName                              = $EventRecord.LogName
        EventId                              = [int]$EventRecord.Id
        RecordId                             = [long]$EventRecord.RecordId
        ProviderName                         = $EventRecord.ProviderName
        LevelDisplayName                     = $EventRecord.LevelDisplayName
        MachineName                          = $EventRecord.MachineName
        EvidenceType                         = if ($EvidenceType -eq 'SecurityRc4Evidence') { 'Actual RC4 Kerberos ticket/session/pre-auth evidence' } else { 'RC4 dependency/hardening warning or enforcement event' }
        RC4Trigger                           = ($Rc4Triggers -join '; ')
        TargetUserName                       = Get-EventDataValue -Map $eventData -Names @('TargetUserName')
        TargetDomainName                     = Get-EventDataValue -Map $eventData -Names @('TargetDomainName')
        TargetSid                            = Get-EventDataValue -Map $eventData -Names @('TargetSid')
        AccountName                          = Get-EventDataValue -Map $eventData -Names @('AccountName')
        AccountDomain                        = Get-EventDataValue -Map $eventData -Names @('AccountDomain')
        ServiceName                          = Get-EventDataValue -Map $eventData -Names @('ServiceName')
        ServiceSid                           = Get-EventDataValue -Map $eventData -Names @('ServiceSid')
        SPN                                  = $spn
        ClientAddress                        = $clientAddress
        IpAddress                            = Get-EventDataValue -Map $eventData -Names @('IpAddress', 'ClientAddress')
        IpPort                               = Get-EventDataValue -Map $eventData -Names @('IpPort')
        WorkstationName                      = Get-EventDataValue -Map $eventData -Names @('WorkstationName')
        TicketEncryptionType                 = Get-EventDataValue -Map $eventData -Names @('TicketEncryptionType')
        SessionKeyEncryptionType             = Get-EventDataValue -Map $eventData -Names @('SessionKeyEncryptionType')
        PreAuthEncryptionType                = Get-EventDataValue -Map $eventData -Names @('PreAuthEncryptionType')
        ClientAdvertizedEncryptionTypes      = Get-EventDataValue -Map $eventData -Names @('ClientAdvertizedEncryptionTypes')
        ClientAdvertisedEncryptionTypes      = Get-EventDataValue -Map $eventData -Names @('ClientAdvertisedEncryptionTypes')
        AdvertizedEtypes                     = Get-EventDataValue -Map $eventData -Names @('AdvertizedEtypes')
        AdvertisedEtypes                     = Get-EventDataValue -Map $eventData -Names @('AdvertisedEtypes')
        AccountSupportedEncryptionTypes      = Get-EventDataValue -Map $eventData -Names @('AccountSupportedEncryptionTypes')
        AccountAvailableKeys                 = Get-EventDataValue -Map $eventData -Names @('AccountAvailableKeys')
        ServiceSupportedEncryptionTypes      = Get-EventDataValue -Map $eventData -Names @('ServiceSupportedEncryptionTypes')
        ServiceAvailableKeys                 = Get-EventDataValue -Map $eventData -Names @('ServiceAvailableKeys')
        DCSupportedEncryptionTypes           = Get-EventDataValue -Map $eventData -Names @('DCSupportedEncryptionTypes')
        DCAvailableKeys                      = Get-EventDataValue -Map $eventData -Names @('DCAvailableKeys')
        'msDS-SupportedEncryptionTypes'      = Get-EventDataValue -Map $eventData -Names @('msDS-SupportedEncryptionTypes')
        TicketOptions                        = Get-EventDataValue -Map $eventData -Names @('TicketOptions')
        Status                               = Get-EventDataValue -Map $eventData -Names @('Status')
        FailureCode                          = Get-EventDataValue -Map $eventData -Names @('FailureCode')
        ErrorCode                            = Get-EventDataValue -Map $eventData -Names @('ErrorCode')
        PreAuthType                          = Get-EventDataValue -Map $eventData -Names @('PreAuthType')
        TransmittedServices                  = Get-EventDataValue -Map $eventData -Names @('TransmittedServices')
        EventMessage                         = $message
        RawEventDataJson                     = ($eventData | ConvertTo-Json -Depth 6 -Compress)
    }

    return $record
}

function Get-NewEventsForLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$LogName,

        [Parameter(Mandatory = $true)]
        [int[]]$EventIds,

        [Parameter(Mandatory = $true)]
        [long]$LastRecordId,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 10080)]
        [int]$FirstRunLookbackMinutes,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 10080)]
        [int]$SafeLookbackMinutesOnRollover,

        [Parameter(Mandatory = $true)]
        [string]$LogPath
    )

    $newest = Get-WinEvent -FilterHashtable @{ LogName = $LogName; Id = $EventIds } -MaxEvents 1 -ErrorAction SilentlyContinue
    $newestRecordId = if ($newest) { [long]$newest.RecordId } else { 0 }

    $startTime = $null
    $mode = 'RecordId'
    if ($LastRecordId -le 0) {
        $startTime = (Get-Date).AddMinutes(-1 * $FirstRunLookbackMinutes)
        $mode = 'FirstRunLookback'
        Write-MonitorLog -Message ("[{0}] first run state detected; using lookback of {1} minutes." -f $LogName, $FirstRunLookbackMinutes) -Level 'INFO' -LogPath $LogPath
    }
    elseif ($newestRecordId -gt 0 -and $LastRecordId -gt $newestRecordId) {
        $startTime = (Get-Date).AddMinutes(-1 * $SafeLookbackMinutesOnRollover)
        $mode = 'RolloverLookback'
        Write-MonitorLog -Message ("[{0}] saved LastRecordId ({1}) is newer than current newest record ({2}); using safe lookback of {3} minutes." -f $LogName, $LastRecordId, $newestRecordId, $SafeLookbackMinutesOnRollover) -Level 'WARN' -LogPath $LogPath
    }

    if ($startTime) {
        $events = Get-WinEvent -FilterHashtable @{
            LogName   = $LogName
            Id        = $EventIds
            StartTime = $startTime
        } -ErrorAction SilentlyContinue | Sort-Object -Property RecordId
    }
    else {
        $events = Get-WinEvent -FilterHashtable @{
            LogName = $LogName
            Id      = $EventIds
        } -ErrorAction SilentlyContinue | Where-Object { $_.RecordId -gt $LastRecordId } | Sort-Object -Property RecordId
    }

    $result = [pscustomobject]@{
        Events          = @($events)
        NewestRecordId  = $newestRecordId
        RetrievalMode   = $mode
    }
    return $result
}

function ConvertTo-HtmlEncoded {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return ''
    }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Get-TopCounts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Items,

        [Parameter(Mandatory = $true)]
        [string]$Property,

        [Parameter()]
        [ValidateRange(1, 100)]
        [int]$Top = 10
    )

    $values = @($Items | ForEach-Object { $_.$Property } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if (-not $values -or $values.Count -eq 0) {
        return @()
    }

    return @(
        $values |
            Group-Object |
            Sort-Object -Property Count -Descending |
            Select-Object -First $Top
    )
}

function Build-HtmlReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Records,

        [Parameter(Mandatory = $true)]
        [psobject]$Config,

        [Parameter(Mandatory = $true)]
        [datetime]$RunStartUtc,

        [Parameter(Mandatory = $true)]
        [datetime]$RunEndUtc
    )

    $countsByEventId = $Records | Group-Object -Property EventId | Sort-Object -Property Name
    $countsByObject = @(
        $Records |
            ForEach-Object {
                if (-not [string]::IsNullOrWhiteSpace([string]$_.TargetUserName)) { $_.TargetUserName }
                elseif (-not [string]::IsNullOrWhiteSpace([string]$_.AccountName)) { $_.AccountName }
            } |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            Group-Object |
            Sort-Object -Property Count -Descending |
            Select-Object -First 10
    )
    $countsByService = @(
        $Records |
            ForEach-Object {
                if (-not [string]::IsNullOrWhiteSpace([string]$_.ServiceName)) { $_.ServiceName }
                elseif (-not [string]::IsNullOrWhiteSpace([string]$_.SPN)) { $_.SPN }
            } |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            Group-Object |
            Sort-Object -Property Count -Descending |
            Select-Object -First 10
    )
    $countsByClient = @(
        $Records |
            ForEach-Object {
                if (-not [string]::IsNullOrWhiteSpace([string]$_.ClientAddress)) { $_.ClientAddress }
                elseif (-not [string]::IsNullOrWhiteSpace([string]$_.IpAddress)) { $_.IpAddress }
            } |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            Group-Object |
            Sort-Object -Property Count -Descending |
            Select-Object -First 10
    )
    $countsByTrigger = Get-TopCounts -Items $Records -Property 'RC4Trigger' -Top 10
    $detailsRows = @($Records | Sort-Object -Property RecordId | Select-Object -First ([int]$Config.MaxDetailedRowsInEmail))
    $truncatedDetails = ($detailsRows.Count -lt $Records.Count)

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<html><body style="font-family:Segoe UI,Arial,sans-serif;font-size:12px;">')
    [void]$sb.AppendLine('<h2>Kerberos RC4 Monitoring Report</h2>')
    [void]$sb.AppendLine('<p>')
    [void]$sb.AppendLine('<strong>Scope note:</strong> Security 4768/4769/4770 rows are included only when encryption fields contain RC4 values (0x17/0x18). ')
    [void]$sb.AppendLine('System Kdcsvc 201/202/203/204/206/207/208/209 rows indicate RC4 dependency, hardening warning, or enforcement/blocking conditions and are not automatically proof of successful RC4 ticket issuance.')
    [void]$sb.AppendLine('</p>')

    [void]$sb.AppendLine('<h3>Summary</h3>')
    [void]$sb.AppendLine('<table border="1" cellpadding="4" cellspacing="0">')
    [void]$sb.AppendLine(('<tr><td>Environment</td><td>{0}</td></tr>' -f (ConvertTo-HtmlEncoded $Config.EnvironmentName)))
    [void]$sb.AppendLine(('<tr><td>DC Name</td><td>{0}</td></tr>' -f (ConvertTo-HtmlEncoded $env:COMPUTERNAME)))
    [void]$sb.AppendLine(('<tr><td>Domain</td><td>{0}</td></tr>' -f (ConvertTo-HtmlEncoded $env:USERDNSDOMAIN)))
    [void]$sb.AppendLine(('<tr><td>Run Start (UTC)</td><td>{0}</td></tr>' -f (ConvertTo-HtmlEncoded $RunStartUtc.ToString('yyyy-MM-dd HH:mm:ss'))))
    [void]$sb.AppendLine(('<tr><td>Run End (UTC)</td><td>{0}</td></tr>' -f (ConvertTo-HtmlEncoded $RunEndUtc.ToString('yyyy-MM-dd HH:mm:ss'))))
    [void]$sb.AppendLine(('<tr><td>Total Matching Events</td><td>{0}</td></tr>' -f $Records.Count))
    [void]$sb.AppendLine('</table>')

    [void]$sb.AppendLine('<h4>Counts by EventId</h4><ul>')
    foreach ($g in $countsByEventId) {
        [void]$sb.AppendLine(('<li>{0}: {1}</li>' -f (ConvertTo-HtmlEncoded $g.Name), $g.Count))
    }
    [void]$sb.AppendLine('</ul>')

    [void]$sb.AppendLine('<h4>Top Requesting Objects</h4><ul>')
    foreach ($g in $countsByObject) {
        [void]$sb.AppendLine(('<li>{0}: {1}</li>' -f (ConvertTo-HtmlEncoded $g.Name), $g.Count))
    }
    [void]$sb.AppendLine('</ul>')

    [void]$sb.AppendLine('<h4>Top Services/SPNs</h4><ul>')
    foreach ($g in $countsByService) {
        [void]$sb.AppendLine(('<li>{0}: {1}</li>' -f (ConvertTo-HtmlEncoded $g.Name), $g.Count))
    }
    [void]$sb.AppendLine('</ul>')

    [void]$sb.AppendLine('<h4>Top Client Addresses</h4><ul>')
    foreach ($g in $countsByClient) {
        [void]$sb.AppendLine(('<li>{0}: {1}</li>' -f (ConvertTo-HtmlEncoded $g.Name), $g.Count))
    }
    [void]$sb.AppendLine('</ul>')

    [void]$sb.AppendLine('<h4>Top RC4 Trigger Field/Value</h4><ul>')
    foreach ($g in $countsByTrigger) {
        [void]$sb.AppendLine(('<li>{0}: {1}</li>' -f (ConvertTo-HtmlEncoded $g.Name), $g.Count))
    }
    [void]$sb.AppendLine('</ul>')

    [void]$sb.AppendLine('<h3>Detailed Events</h3>')
    if ($truncatedDetails) {
        [void]$sb.AppendLine(('<p>Detailed table truncated to first {0} rows for email size control. CSV attachment contains all rows if enabled.</p>' -f [int]$Config.MaxDetailedRowsInEmail))
    }

    [void]$sb.AppendLine('<table border="1" cellpadding="3" cellspacing="0">')
    [void]$sb.AppendLine('<tr><th>TimeCreated</th><th>EventId</th><th>EvidenceType</th><th>RC4Trigger</th><th>RequestingObject</th><th>RequestingSid</th><th>TargetService</th><th>TargetServiceSid</th><th>ClientAddress</th><th>DCName</th><th>TicketEncryptionType</th><th>SessionKeyEncryptionType</th><th>PreAuthEncryptionType</th><th>ClientAdvertizedEncryptionTypes</th><th>AccountSupportedEncryptionTypes</th><th>AccountAvailableKeys</th><th>ServiceSupportedEncryptionTypes</th><th>ServiceAvailableKeys</th><th>RecordId</th></tr>')

    foreach ($row in $detailsRows) {
        $requestingObject = if ([string]::IsNullOrWhiteSpace([string]$row.TargetUserName)) { $row.AccountName } else { $row.TargetUserName }
        [void]$sb.AppendLine('<tr>')
        [void]$sb.AppendLine(('<td>{0}</td>' -f (ConvertTo-HtmlEncoded $row.TimeCreatedUtc)))
        [void]$sb.AppendLine(('<td>{0}</td>' -f (ConvertTo-HtmlEncoded $row.EventId)))
        [void]$sb.AppendLine(('<td>{0}</td>' -f (ConvertTo-HtmlEncoded $row.EvidenceType)))
        [void]$sb.AppendLine(('<td>{0}</td>' -f (ConvertTo-HtmlEncoded $row.RC4Trigger)))
        [void]$sb.AppendLine(('<td>{0}</td>' -f (ConvertTo-HtmlEncoded $requestingObject)))
        [void]$sb.AppendLine(('<td>{0}</td>' -f (ConvertTo-HtmlEncoded $row.TargetSid)))
        [void]$sb.AppendLine(('<td>{0}</td>' -f (ConvertTo-HtmlEncoded $row.ServiceName)))
        [void]$sb.AppendLine(('<td>{0}</td>' -f (ConvertTo-HtmlEncoded $row.ServiceSid)))
        [void]$sb.AppendLine(('<td>{0}</td>' -f (ConvertTo-HtmlEncoded $row.ClientAddress)))
        [void]$sb.AppendLine(('<td>{0}</td>' -f (ConvertTo-HtmlEncoded $row.DCName)))
        [void]$sb.AppendLine(('<td>{0}</td>' -f (ConvertTo-HtmlEncoded $row.TicketEncryptionType)))
        [void]$sb.AppendLine(('<td>{0}</td>' -f (ConvertTo-HtmlEncoded $row.SessionKeyEncryptionType)))
        [void]$sb.AppendLine(('<td>{0}</td>' -f (ConvertTo-HtmlEncoded $row.PreAuthEncryptionType)))
        [void]$sb.AppendLine(('<td>{0}</td>' -f (ConvertTo-HtmlEncoded $row.ClientAdvertizedEncryptionTypes)))
        [void]$sb.AppendLine(('<td>{0}</td>' -f (ConvertTo-HtmlEncoded $row.AccountSupportedEncryptionTypes)))
        [void]$sb.AppendLine(('<td>{0}</td>' -f (ConvertTo-HtmlEncoded $row.AccountAvailableKeys)))
        [void]$sb.AppendLine(('<td>{0}</td>' -f (ConvertTo-HtmlEncoded $row.ServiceSupportedEncryptionTypes)))
        [void]$sb.AppendLine(('<td>{0}</td>' -f (ConvertTo-HtmlEncoded $row.ServiceAvailableKeys)))
        [void]$sb.AppendLine(('<td>{0}</td>' -f (ConvertTo-HtmlEncoded $row.RecordId)))
        [void]$sb.AppendLine('</tr>')
    }

    [void]$sb.AppendLine('</table>')
    [void]$sb.AppendLine('</body></html>')

    return $sb.ToString()
}

function Write-CsvReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Records,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ReportDirectory,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$FilePrefix
    )

    if (-not (Test-Path -LiteralPath $ReportDirectory)) {
        New-Item -Path $ReportDirectory -ItemType Directory -Force | Out-Null
    }

    $csvPath = Join-Path -Path $ReportDirectory -ChildPath ('{0}.csv' -f $FilePrefix)
    $Records | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    return $csvPath
}

function Write-HtmlReportArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Html,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ReportDirectory,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$FilePrefix
    )

    if (-not (Test-Path -LiteralPath $ReportDirectory)) {
        New-Item -Path $ReportDirectory -ItemType Directory -Force | Out-Null
    }

    $htmlPath = Join-Path -Path $ReportDirectory -ChildPath ('{0}.html' -f $FilePrefix)
    [System.IO.File]::WriteAllText($htmlPath, $Html, [System.Text.Encoding]::UTF8)
    return $htmlPath
}

function Send-MonitorEmail {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Config,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Subject,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$HtmlBody,

        [Parameter()]
        [string[]]$AttachmentPaths = @()
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

        $mail.Subject = $Subject
        $mail.Body = $HtmlBody
        $mail.IsBodyHtml = $true
        $mail.BodyEncoding = [System.Text.Encoding]::UTF8
        $mail.SubjectEncoding = [System.Text.Encoding]::UTF8

        foreach ($path in $AttachmentPaths) {
            if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path)) {
                [void]$mail.Attachments.Add((New-Object System.Net.Mail.Attachment($path)))
            }
        }

        $smtp = New-Object System.Net.Mail.SmtpClient($Config.SmtpServer, [int]$Config.SmtpPort)
        $smtp.EnableSsl = [bool]$Config.UseSsl
        $smtp.DeliveryMethod = [System.Net.Mail.SmtpDeliveryMethod]::Network
        $smtp.UseDefaultCredentials = $true
        $smtp.Send($mail)
    }
    finally {
        if ($mail) {
            $mail.Dispose()
        }
    }
}

function Invoke-KerberosRc4Monitor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$MonitorConfigPath
    )

    $config = Read-MonitorConfig -Path $MonitorConfigPath
    foreach ($path in @($config.InstallPath, $config.LogPath, $config.ReportPath)) {
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -Path $path -ItemType Directory -Force | Out-Null
        }
    }

    $logFile = Join-Path -Path $config.LogPath -ChildPath ('KerberosRc4Monitor-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
    Invoke-LogRetention -LogDirectory $config.LogPath -RetentionDays ([int]$config.LogRetentionDays) -CurrentLogPath $logFile

    $mutexName = 'Global\KerberosRc4MonitorMutex'
    $mutex = Acquire-MonitorLock -LockName $mutexName
    if (-not $mutex) {
        Write-MonitorLog -Message 'Another monitor instance is active; exiting this run.' -Level 'WARN' -LogPath $logFile
        return
    }

    try {
        $runStartUtc = (Get-Date).ToUniversalTime()
        Write-MonitorLog -Message ("Run started. ConfigPath={0}" -f $MonitorConfigPath) -Level 'INFO' -LogPath $logFile

        $state = Read-MonitorState -StatePath $config.StatePath
        $stateByLog = @{}
        foreach ($entry in $state.Logs) {
            $stateByLog[$entry.LogName] = $entry
        }

        foreach ($logName in @('Security', 'System')) {
            if (-not $stateByLog.ContainsKey($logName)) {
                $newEntry = New-DefaultLogState -LogName $logName
                $state.Logs += $newEntry
                $stateByLog[$logName] = $newEntry
            }
            $stateByLog[$logName].LastRunStartedUtc = $runStartUtc.ToString('o')
        }

        $securityIds = 4768, 4769, 4770
        $kdcsvcIds = 201, 202, 203, 204, 206, 207, 208, 209

        $securityState = $stateByLog['Security']
        $systemState = $stateByLog['System']

        $securityQuery = Get-NewEventsForLog -LogName 'Security' -EventIds $securityIds -LastRecordId ([long]$securityState.LastRecordId) -FirstRunLookbackMinutes ([int]$config.LookbackMinutesOnFirstRun) -SafeLookbackMinutesOnRollover ([int]$config.SafeLookbackMinutesOnRollover) -LogPath $logFile
        $systemQuery = Get-NewEventsForLog -LogName 'System' -EventIds $kdcsvcIds -LastRecordId ([long]$systemState.LastRecordId) -FirstRunLookbackMinutes ([int]$config.LookbackMinutesOnFirstRun) -SafeLookbackMinutesOnRollover ([int]$config.SafeLookbackMinutesOnRollover) -LogPath $logFile

        $securityEvents = @($securityQuery.Events)
        $systemEvents = @($systemQuery.Events | Where-Object { $_.ProviderName -match '^Microsoft-Windows-Kerberos-Key-Distribution-Center$|^Kdcsvc$' })

        Write-MonitorLog -Message ("Fetched candidate events: Security={0}, SystemKdcsvc={1}" -f $securityEvents.Count, $systemEvents.Count) -Level 'INFO' -LogPath $logFile

        $records = New-Object System.Collections.Generic.List[object]
        foreach ($event in $securityEvents) {
            $map = Get-EventDataMap -EventRecord $event
            $triggers = Get-Rc4Trigger -Map $map
            if ($triggers.Count -gt 0) {
                [void]$records.Add((Convert-EventToRc4Record -EventRecord $event -EvidenceType 'SecurityRc4Evidence' -Rc4Triggers $triggers -MaxMessageLength ([int]$config.MaxMessageLength)))
            }
        }

        foreach ($event in $systemEvents) {
            [void]$records.Add((Convert-EventToRc4Record -EventRecord $event -EvidenceType 'KdcsvcDependencyOrHardening' -Rc4Triggers @() -MaxMessageLength ([int]$config.MaxMessageLength)))
        }

        $recordsArray = $records.ToArray()
        $matchingCount = $recordsArray.Count
        Write-MonitorLog -Message ("Matching events count: {0}" -f $matchingCount) -Level 'INFO' -LogPath $logFile

        $newSecurityRecordId = [long]$securityState.LastRecordId
        $newSystemRecordId = [long]$systemState.LastRecordId
        if ($securityEvents.Count -gt 0) {
            $newSecurityRecordId = [long](($securityEvents | Select-Object -Last 1).RecordId)
        }
        if ($systemQuery.Events.Count -gt 0) {
            $newSystemRecordId = [long](($systemQuery.Events | Select-Object -Last 1).RecordId)
        }

        $runEndUtc = (Get-Date).ToUniversalTime()
        $shouldSendHeartbeat = [bool]$config.EnableHeartbeat
        $shouldSendEmail = ($matchingCount -gt 0 -or $shouldSendHeartbeat)
        $stateCanAdvance = $false

        if ($matchingCount -gt 0) {
            $filePrefix = 'KerberosRc4-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss')
            $csvPath = $null
            $htmlArchivePath = $null
            $htmlBody = Build-HtmlReport -Records $recordsArray -Config $config -RunStartUtc $runStartUtc -RunEndUtc $runEndUtc

            if ($PSCmdlet.ShouldProcess($config.ReportPath, 'Write CSV report')) {
                $csvPath = Write-CsvReport -Records $recordsArray -ReportDirectory $config.ReportPath -FilePrefix $filePrefix
                Write-MonitorLog -Message ("CSV report written: {0}" -f $csvPath) -Level 'INFO' -LogPath $logFile
            }

            if ($PSCmdlet.ShouldProcess($config.ReportPath, 'Write HTML report archive')) {
                $htmlArchivePath = Write-HtmlReportArchive -Html $htmlBody -ReportDirectory $config.ReportPath -FilePrefix $filePrefix
                Write-MonitorLog -Message ("HTML report written: {0}" -f $htmlArchivePath) -Level 'INFO' -LogPath $logFile
            }

            if (-not $WhatIfPreference -and $shouldSendEmail) {
                $times = $recordsArray | Sort-Object -Property TimeCreatedUtc
                $windowStart = $times[0].TimeCreatedUtc
                $windowEnd = $times[$times.Count - 1].TimeCreatedUtc
                $subject = '{0} [{1}] Kerberos RC4 events on {2} - {3} events - {4} to {5} UTC' -f $config.SubjectPrefix, $config.EnvironmentName, $env:COMPUTERNAME, $matchingCount, $windowStart, $windowEnd

                $attachments = @()
                if ([bool]$config.AttachCsv -and $csvPath) { $attachments += $csvPath }
                if ([bool]$config.AttachHtml -and $htmlArchivePath) { $attachments += $htmlArchivePath }

                Send-MonitorEmail -Config $config -Subject $subject -HtmlBody $htmlBody -AttachmentPaths $attachments
                Write-MonitorLog -Message 'Email sent successfully.' -Level 'INFO' -LogPath $logFile
                $stateCanAdvance = $true
            }
            elseif ($WhatIfPreference) {
                Write-MonitorLog -Message 'WhatIf active: skipping email and state update by design.' -Level 'INFO' -LogPath $logFile
            }
        }
        else {
            if ($shouldSendHeartbeat -and -not $WhatIfPreference) {
                $heartbeatBody = '<html><body><p>No matching Kerberos RC4 events detected in this run.</p></body></html>'
                $subject = '{0} [{1}] Kerberos RC4 monitor heartbeat on {2} - no matching events' -f $config.SubjectPrefix, $config.EnvironmentName, $env:COMPUTERNAME
                Send-MonitorEmail -Config $config -Subject $subject -HtmlBody $heartbeatBody
                Write-MonitorLog -Message 'Heartbeat email sent successfully.' -Level 'INFO' -LogPath $logFile
            }
            if ($WhatIfPreference) {
                Write-MonitorLog -Message 'WhatIf active: no state update by design.' -Level 'INFO' -LogPath $logFile
            }
            else {
                $stateCanAdvance = $true
            }
        }

        if ($stateCanAdvance) {
            $completionUtc = (Get-Date).ToUniversalTime().ToString('o')
            $securityState.LastRecordId = $newSecurityRecordId
            $securityState.LastProcessedTimeUtc = $completionUtc
            $securityState.LastRunCompletedUtc = $completionUtc

            $systemState.LastRecordId = $newSystemRecordId
            $systemState.LastProcessedTimeUtc = $completionUtc
            $systemState.LastRunCompletedUtc = $completionUtc

            if ($PSCmdlet.ShouldProcess($config.StatePath, 'Save monitor state')) {
                Save-MonitorStateAtomic -StatePath $config.StatePath -State $state
                Write-MonitorLog -Message ("State updated. Security.LastRecordId={0}; System.LastRecordId={1}" -f $securityState.LastRecordId, $systemState.LastRecordId) -Level 'INFO' -LogPath $logFile
            }
        }
        else {
            Write-MonitorLog -Message 'State was not updated because processing/email did not complete successfully.' -Level 'WARN' -LogPath $logFile
        }

        Write-MonitorLog -Message 'Run completed.' -Level 'INFO' -LogPath $logFile
    }
    catch {
        try {
            $fallbackLog = Join-Path -Path (Split-Path -Path $MonitorConfigPath -Parent) -ChildPath ('KerberosRc4Monitor-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
            Write-MonitorLog -Message ("Fatal error: {0}" -f $_.Exception.Message) -Level 'ERROR' -LogPath $fallbackLog
        }
        catch {
        }
        throw
    }
    finally {
        Release-MonitorLock -Mutex $mutex
    }
}

Invoke-KerberosRc4Monitor -MonitorConfigPath $ConfigPath
