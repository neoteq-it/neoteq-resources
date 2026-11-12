#Requires -Version 5.1
# Als Administrator ausfuehren. Windows x64, neue Installationen: Agent 2 8.0 LTS.
# Jeder Aufruf erzeugt einen neuen PSK. Diesen danach auch in Zabbix eintragen.
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9_][A-Za-z0-9_. -]{0,127}$')]
    [string]$Hostname,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9_.:-]+$')]
    [string]$ZabbixServer
)

$ErrorActionPreference = 'Stop'

function Invoke-Msi {
    param([string]$Arguments, [string]$Log)
    $process = Start-Process msiexec.exe -ArgumentList "$Arguments /qn /norestart REBOOT=ReallySuppress /L*v `"$Log`"" -Wait -PassThru
    if ($process.ExitCode -eq 3010) {
        Write-Warning 'Windows Installer meldet: Neustart erforderlich. Es wird nicht automatisch neu gestartet.'
    } elseif ($process.ExitCode -ne 0) {
        throw "MSI-Fehler $($process.ExitCode). Protokoll: $Log"
    }
}

function New-Psk {
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return [BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()
}

function Set-AgentSettings {
    param([string]$Text, [System.Collections.IDictionary]$Settings)
    # Ersetzt aktive Eintraege und vermeidet doppelte Parameter. Andere Zeilen bleiben.
    foreach ($name in $Settings.Keys) {
        $pattern = '(?m)^\s*' + [regex]::Escape($name) + '[ \t]*=[^\r\n]*(?:\r?\n|$)'
        $Text = [regex]::Replace($Text, $pattern, '')
    }
    $Text = $Text.TrimEnd() + "`r`n"
    foreach ($name in $Settings.Keys) { $Text += "$name=$($Settings[$name])`r`n" }
    return $Text
}

function Write-PskFile {
    param([string]$Path, [string]$Key, [string]$ServiceAccount)
    $parent = Split-Path $Path -Parent
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType File -Path $Path | Out-Null }
    # Berechtigungen vor dem Schreiben setzen: SYSTEM, Administratoren und Dienstkonto.
    $acl = New-Object Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $identity = New-Object Security.Principal.SecurityIdentifier($sid)
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'Allow')))
    }
    if ($ServiceAccount -notin @('LocalSystem', 'NT AUTHORITY\SYSTEM')) {
        if ($ServiceAccount.StartsWith('.\')) { $ServiceAccount = "$env:COMPUTERNAME\" + $ServiceAccount.Substring(2) }
        $identity = New-Object Security.Principal.NTAccount($ServiceAccount)
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($identity, 'ReadAndExecute', 'Allow')))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
    [IO.File]::WriteAllText($Path, $Key + "`r`n", (New-Object Text.UTF8Encoding($false)))
}

$services = @(Get-CimInstance Win32_Service | Where-Object {
    $_.PathName -match '(?i)(?:^|[\\/\"])zabbix_agent2\.exe(?:\"|\s|$)'
})
if ($services.Count -gt 1) { throw 'Mehrere Agent-2-Dienste gefunden. PSK je Instanz separat konfigurieren.' }
$existing = $services.Count -eq 1
$installDir = Join-Path $env:ProgramFiles 'Zabbix Agent 2'
$serviceName = 'Zabbix Agent 2'
$serviceAccount = 'LocalSystem'
$folder = $null

if ($existing) {
    # Den tatsaechlich vom Dienst verwendeten Konfigurationspfad benutzen.
    $service = $services[0]
    $serviceName = $service.Name
    $serviceAccount = $service.StartName
    if ($service.PathName -notmatch '^\s*"?(.+?zabbix_agent2\.exe)"?(?:\s|$)') {
        throw 'Programmpfad des Agent-2-Dienstes nicht erkannt.'
    }
    $installDir = Split-Path ([Environment]::ExpandEnvironmentVariables($Matches[1])) -Parent
    $config = Join-Path $installDir 'zabbix_agent2.conf'
    if ($service.PathName -match '(?:^|\s)(?:-c|--config)(?:\s+|=)(?:"([^"]+)"|(\S+))') {
        $config = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
        $config = [Environment]::ExpandEnvironmentVariables($config)
    }
    if (-not [IO.Path]::IsPathRooted($config)) { throw 'Der Konfigurationspfad im Agent-2-Dienst muss absolut sein.' }
    $text = [IO.File]::ReadAllText($config)
    Write-Host 'Agent 2 vorhanden. Aktiviere PSK und ersetze den Schluessel ...'
} else {
    $folder = Join-Path $env:TEMP ('Zabbix-Setup-' + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $folder | Out-Null
    $oldAgents = @(Get-ItemProperty -Path @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    ) -ErrorAction SilentlyContinue | Where-Object {
        $_.DisplayName -match '^Zabbix Agent(?: \((?:32|64)-bit\))?$'
    })
    foreach ($agent in $oldAgents) {
        if ($agent.PSChildName -notmatch '^\{[0-9A-Fa-f-]{36}\}$') {
            throw "Die Deinstallation von '$($agent.DisplayName)' ist kein MSI-Aufruf. Bitte diesen Agenten manuell deinstallieren."
        }
        Write-Host "Deinstalliere $($agent.DisplayName) ..."
        Invoke-Msi -Arguments "/x $($agent.PSChildName)" -Log (Join-Path $folder "uninstall-$($agent.PSChildName).log")
    }
    if ($oldAgents.Count -eq 0) {
        $oldServices = @(Get-CimInstance Win32_Service | Where-Object {
            $_.PathName -match '(?i)(?:^|[\\/\"])zabbix_agentd\.exe(?:\"|\s|$)'
        })
        foreach ($service in $oldServices) {
            Write-Host "Entferne Dienst $($service.Name) ..."
            Stop-Service -Name $service.Name
            & sc.exe delete $service.Name | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "Dienst konnte nicht entfernt werden: $($service.Name)" }
        }
    }
    $msi = Join-Path $folder 'agent2.msi'
    $config = Join-Path $folder 'agent2.conf'
    Write-Host 'Lade Zabbix Agent 2 (8.0 LTS) ...'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -UseBasicParsing -Uri 'https://cdn.zabbix.com/zabbix/binaries/stable/8.0/latest/zabbix_agent2-8.0-latest-windows-amd64-openssl.msi' -OutFile $msi
    $text = @"
LogFile=$installDir\zabbix_agent2.log
LogFileSize=10
ListenPort=10050
Include=$installDir\zabbix_agent2.d\plugins.d\*.conf
"@
}

# Vorhandene PSK-Datei ueberschreiben; andernfalls eine neue am Agenten anlegen.
$pskFile = Join-Path $installDir 'zabbix_agent2.psk'
if ($text -match '(?m)^[ \t]*TLSPSKFile[ \t]*=[ \t]*([^\r\n]+)') {
    $pskFile = $Matches[1].Trim()
}
if (-not [IO.Path]::IsPathRooted($pskFile)) { throw 'TLSPSKFile muss einen absoluten Dateipfad enthalten.' }
$psk = New-Psk
Write-PskFile -Path $pskFile -Key $psk -ServiceAccount $serviceAccount
$activeServer = if ($ZabbixServer.Contains(':')) { "[${ZabbixServer}]:10051" } else { "${ZabbixServer}:10051" }
$settings = [ordered]@{
    Server = $ZabbixServer
    ServerActive = $activeServer
    Hostname = $Hostname
    TLSConnect = 'psk'
    TLSAccept = 'psk'
    TLSPSKIdentity = $Hostname
    TLSPSKFile = $pskFile
}
$text = Set-AgentSettings -Text $text -Settings $settings
[IO.File]::WriteAllText($config, $text, (New-Object Text.UTF8Encoding($false)))

if (-not $existing) {
    Write-Host 'Installiere Zabbix Agent 2 mit PSK ...'
    # Nur Dateipfad und Identitaet an MSI uebergeben. Kein Schluessel im MSI-Protokoll.
    Invoke-Msi -Arguments "/i `"$msi`" ADDLOCAL=AgentProgram DONOTSTART=1 SERVER=`"$ZabbixServer`" SERVERACTIVE=`"$activeServer`" HOSTNAME=`"$Hostname`" TLSCONNECT=psk TLSACCEPT=psk TLSPSKIDENTITY=`"$Hostname`" TLSPSKFILE=`"$pskFile`" STARTUPTYPE=automatic INSTALLFOLDER=`"$installDir`" CONF=`"$config`"" -Log (Join-Path $folder 'install.log')
}

# Ausgabe vor dem Dienststart, damit der Schluessel auch bei einem Startfehler vorliegt.
Write-Host ''
Write-Host "PSK-Identitaet (Secret ID): $Hostname" -ForegroundColor Cyan
Write-Host "PSK: $psk" -ForegroundColor Yellow
Write-Host "PSK-Datei: $pskFile"
Write-Host 'Diese Identitaet und diesen PSK im Zabbix-Host unter Verschluesselung eintragen.'
Write-Host 'Verbindungen zum Host: PSK. Verbindungen vom Host: nur PSK.'
Set-Service -Name $serviceName -StartupType Automatic
if ($existing) { Restart-Service -Name $serviceName } else { Start-Service -Name $serviceName }
Write-Host "Fertig. Agent 2 mit PSK gestartet: $Hostname -> $ZabbixServer" -ForegroundColor Green
if ($folder) { Write-Host "Installationsprotokolle: $folder" }
