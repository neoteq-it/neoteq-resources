#Requires -Version 5.1
# Als Administrator ausfuehren. Windows x64, Zabbix Agent 2 8.0 LTS.
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9_][A-Za-z0-9_. -]{0,127}$')]
    [string]$Hostname,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9_.:-]+$')]
    [string]$ZabbixServer
)

$ErrorActionPreference = 'Stop'
$folder = Join-Path $env:TEMP ('Zabbix-Setup-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $folder | Out-Null
$installDir = Join-Path $env:ProgramFiles 'Zabbix Agent 2'

function Invoke-Msi {
    param([string]$Arguments, [string]$Log)
    $process = Start-Process msiexec.exe -ArgumentList "$Arguments /qn /norestart REBOOT=ReallySuppress /L*v `"$Log`"" -Wait -PassThru
    if ($process.ExitCode -eq 3010) {
        Write-Warning 'Windows Installer meldet: Neustart erforderlich. Es wird nicht automatisch neu gestartet.'
    } elseif ($process.ExitCode -ne 0) {
        throw "MSI-Fehler $($process.ExitCode). Protokoll: $Log"
    }
}

# 1. Alten klassischen Agenten deinstallieren. Bei Fehler sofort abbrechen.
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

# Bei manueller/ZIP-Installation den alten Agent-Dienst entfernen.
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

# 2. Agent 2 herunterladen und mit einer neuen Konfiguration installieren.
$msi = Join-Path $folder 'agent2.msi'
$config = Join-Path $folder 'agent2.conf'
Write-Host 'Lade Zabbix Agent 2 (8.0 LTS) ...'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -UseBasicParsing -Uri 'https://cdn.zabbix.com/zabbix/binaries/stable/8.0/latest/zabbix_agent2-8.0-latest-windows-amd64-openssl.msi' -OutFile $msi
$activeServer = if ($ZabbixServer.Contains(':')) { "[${ZabbixServer}]:10051" } else { "${ZabbixServer}:10051" }
$text = @"
LogFile=$installDir\zabbix_agent2.log
LogFileSize=10
Server=$ZabbixServer
ServerActive=$activeServer
Hostname=$Hostname
ListenPort=10050
TLSConnect=unencrypted
TLSAccept=unencrypted
Include=$installDir\zabbix_agent2.d\plugins.d\*.conf
"@
[IO.File]::WriteAllText($config, $text + "`r`n", (New-Object Text.UTF8Encoding($false)))
Write-Host 'Installiere Zabbix Agent 2 ...'
Invoke-Msi -Arguments "/i `"$msi`" ADDLOCAL=AgentProgram SERVER=`"$ZabbixServer`" SERVERACTIVE=`"$activeServer`" HOSTNAME=`"$Hostname`" TLSCONNECT=unencrypted TLSACCEPT=unencrypted STARTUPTYPE=automatic INSTALLFOLDER=`"$installDir`" CONF=`"$config`"" -Log (Join-Path $folder 'install.log')

# 3. Dienst direkt starten. Startfehler werden von PowerShell ausgegeben.
Start-Service -Name 'Zabbix Agent 2'
Write-Host "Fertig. Agent 2 gestartet: $Hostname -> $ZabbixServer" -ForegroundColor Green
Write-Host "Installationsprotokolle: $folder"
