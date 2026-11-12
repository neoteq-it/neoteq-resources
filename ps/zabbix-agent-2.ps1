#Requires -Version 5.1
<#
.SYNOPSIS
Ersetzt einen klassischen Zabbix Agent durch Zabbix Agent 2 auf Windows x64.
.DESCRIPTION
Als Administrator ausfuehren. Windows Server 2016 oder neuer.
Aktive und passive Checks, unverschluesselt, Standardports 10051/10050.
Der Hostname muss dem technischen Hostnamen in Zabbix entsprechen.
Unterstuetzt eine klassische MSI-Installation oder einen manuell registrierten
Agent-Dienst. Mehrere Instanzen und vorhandener Agent 2 werden nicht veraendert.
Alte Sonderparameter/UserParameter werden gesichert, aber nicht uebernommen.
Bei manuellen Installationen werden Dienst und Autostart entfernt; Dateien bleiben.
Kein API-Token erforderlich. Das Skript legt keinen Host im Zabbix-Frontend an.
.EXAMPLE
.\install-zabbix-agent2.ps1 -Hostname 'SRV-01' -ZabbixServer 'zabbix.example.org'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateLength(1, 128)]
    [ValidatePattern('^[A-Za-z0-9_][A-Za-z0-9_. -]*$')]
    [string]$Hostname,

    [Parameter(Mandatory = $true, Position = 1)]
    [ValidateNotNullOrEmpty()]
    [string]$ZabbixServer
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Zentral vor dem Veroeffentlichen anpassbar. Aktueller Patchstand der 8.0-LTS-Reihe.
$Release = '8.0'
$DownloadUrl = "https://cdn.zabbix.com/zabbix/binaries/stable/$Release/latest/zabbix_agent2-$Release-latest-windows-amd64-openssl.msi"

function Get-ServerSettings {
    param([string]$Server)
    $address = $null
    if ([System.Net.IPAddress]::TryParse($Server, [ref]$address)) {
        if ($Server.Contains('%')) { throw 'IPv6-Zonen-IDs werden nicht unterstuetzt.' }
        $active = if ($address.AddressFamily -eq 'InterNetworkV6') {
            "[$Server]:10051"
        } else { "${Server}:10051" }
        return [pscustomobject]@{ Server = $Server; Active = $active; Addresses = @($address.IPAddressToString) }
    }
    if ($Server.Length -gt 253 -or $Server -notmatch '^(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*\.?$') {
        throw 'ZabbixServer muss eine einzelne IP-Adresse oder ein DNS-Name ohne Protokoll, Pfad oder Port sein.'
    }
    $addresses = @([System.Net.Dns]::GetHostAddresses($Server) | ForEach-Object { $_.IPAddressToString })
    if ($addresses.Count -eq 0) { throw "Keine IP-Adresse fuer $Server gefunden." }
    [pscustomobject]@{ Server = $Server; Active = "${Server}:10051"; Addresses = $addresses }
}

function Get-ZabbixProducts {
    foreach ($path in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )) {
        Get-ItemProperty -Path $path -ErrorAction SilentlyContinue | Where-Object {
            $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -match '^Zabbix Agent(?: 2)?(?: \((?:32|64)-bit\))?$'
        } | ForEach-Object {
            [pscustomobject]@{
                Name = $_.DisplayName
                ProductCode = $_.PSChildName
                IsAgent2 = $_.DisplayName -match '^Zabbix Agent 2(?:\s|$)'
                IsMsi = [bool]($_.PSObject.Properties['WindowsInstaller'] -and $_.WindowsInstaller -eq 1)
            }
        }
    }
}

function Get-AgentServices {
    Get-CimInstance Win32_Service | Where-Object {
        $_.PathName -match '(?i)(?:^|[\\/\"])zabbix_agent(?:d|2)\.exe(?:\"|\s|$)'
    }
}

function Get-AgentPaths {
    param([string]$CommandLine)
    if ($CommandLine -notmatch '^\s*"?(.+?zabbix_agentd\.exe)"?(?:\s|$)') {
        throw "Der Programmpfad des alten Dienstes ist nicht eindeutig: $CommandLine"
    }
    $exe = [Environment]::ExpandEnvironmentVariables($Matches[1])
    if (-not [IO.Path]::IsPathRooted($exe)) { throw 'Der alte Agent verwendet keinen absoluten Programmpfad.' }
    $config = $null
    if ($CommandLine -match '(?:^|\s)(?:-c|--config)(?:\s+|=)(?:"([^"]+)"|(\S+))') {
        $config = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
        $config = [Environment]::ExpandEnvironmentVariables($config)
        if (-not [IO.Path]::IsPathRooted($config)) {
            throw 'Relativer Konfigurationspfad des alten Agenten. Vor der Migration einen absoluten Pfad verwenden.'
        }
    } else {
        $config = Join-Path (Split-Path $exe -Parent) 'zabbix_agentd.conf'
    }
    if (-not (Test-Path -LiteralPath $config -PathType Leaf)) {
        throw "Alte Konfiguration nicht gefunden: $config. Vor der Migration den -c-Pfad im Dienst pruefen."
    }
    [pscustomobject]@{ Exe = $exe; Config = $config }
}

function Invoke-Msi {
    param([string]$Arguments, [string]$Log, [switch]$AllowNotInstalled)
    $process = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -ArgumentList "$Arguments /qn /norestart REBOOT=ReallySuppress /L*v `"$Log`"" -Wait -PassThru
    if ($process.ExitCode -eq 1605 -and $AllowNotInstalled) {
        Write-Host 'Agent 2 ist nicht installiert; keine Deinstallation erforderlich.'
    } elseif ($process.ExitCode -eq 3010) {
        $script:RebootRequired = $true
        Write-Warning 'Windows Installer meldet einen erforderlichen Neustart. Es wird nicht automatisch neu gestartet.'
    } elseif ($process.ExitCode -ne 0) {
        throw "Windows Installer meldet Fehler $($process.ExitCode). Protokoll: $Log"
    }
}

function Stop-AgentService {
    param([string]$Name)
    $service = Get-Service -Name $Name
    if ($service.Status -ne 'Stopped') {
        Stop-Service -Name $Name -ErrorAction Stop
        $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
    }
    $service.Dispose()
}

function Assert-AgentPingResult {
    param([AllowEmptyCollection()][string[]]$Output, [int]$ExitCode)
    $resultText = ($Output -join "`n").Trim()
    # Der Test kann den Wert 1 als unsigned integer (u) oder string (s) ausgeben.
    if ($ExitCode -ne 0 -or $resultText -cnotmatch '(?m)^\s*agent\.ping\s+\[(?:u|s)\|1\]\s*$') {
        if ([string]::IsNullOrWhiteSpace($resultText)) { $resultText = '<keine Ausgabe>' }
        throw "Der lokale Funktionstest agent.ping ist fehlgeschlagen. Exitcode=$ExitCode; Ausgabe: $resultText"
    }
}

function Assert-NewAgentRunning {
    $service = Get-Service -Name 'Zabbix Agent 2'
    $service.WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
    $service.Dispose()
    Start-Sleep -Seconds 3
    $running = Get-CimInstance Win32_Service -Filter "Name='Zabbix Agent 2'"
    if ($running.State -ne 'Running') { throw 'Agent 2 ist nach dem Start wieder beendet worden.' }
    $listener = @(Get-NetTCPConnection -State Listen -LocalPort 10050 -ErrorAction SilentlyContinue | Where-Object { $_.OwningProcess -eq $running.ProcessId })
    if ($listener.Count -eq 0) { throw 'Agent 2 lauscht nicht auf TCP-Port 10050.' }
}

# Alle Vorpruefungen erfolgen vor dem Stoppen oder Entfernen des alten Agenten.
if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitOperatingSystem -or -not [Environment]::Is64BitProcess) {
    throw 'Bitte in einer 64-Bit-PowerShell auf Windows x64 ausfuehren.'
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'PowerShell als Administrator starten.'
}
$osInfo = Get-CimInstance Win32_OperatingSystem
if ([version]$osInfo.Version -lt [version]'10.0.14393') {
    throw 'Diese Agent-2-Version benoetigt Windows Server 2016 oder neuer.'
}
if ($Hostname -ne $Hostname.Trim()) { throw 'Hostname darf nicht mit einem Leerzeichen enden.' }
$settings = Get-ServerSettings -Server $ZabbixServer
$products = @(Get-ZabbixProducts)
$services = @(Get-AgentServices)
$oldProducts = @($products | Where-Object { -not $_.IsAgent2 })
$oldServices = @($services | Where-Object { $_.PathName -match 'zabbix_agentd\.exe(?:"|\s|$)' })
$installDir = Join-Path $env:ProgramFiles 'Zabbix Agent 2'
if (@($products | Where-Object IsAgent2).Count -gt 0 -or @($services | Where-Object { $_.PathName -match 'zabbix_agent2\.exe(?:"|\s|$)' }).Count -gt 0 -or (Test-Path -LiteralPath $installDir)) {
    throw 'Agent 2 oder sein Zielordner ist bereits vorhanden. Keine Aenderung vorgenommen; vorhandene Installation zuerst pruefen.'
}
if ($oldProducts.Count -gt 1 -or $oldServices.Count -gt 1) {
    throw 'Mehrere alte Agent-Installationen erkannt. Diese muessen einzeln migriert werden.'
}
foreach ($product in $oldProducts) {
    if (-not $product.IsMsi -or $product.ProductCode -notmatch '^\{[0-9A-Fa-f-]{36}\}$') {
        throw "Keine eindeutig identifizierte MSI-Installation: $($product.Name). Keine Aenderung vorgenommen."
    }
}
if ($oldProducts.Count -gt 0 -and $oldServices.Count -eq 0) {
    throw 'Altes MSI gefunden, aber kein zugehoeriger Dienst. Installation vor der Migration pruefen.'
}
$oldService = if ($oldServices.Count -eq 1) { $oldServices[0] } else { $null }
$oldPaths = if ($oldService) { Get-AgentPaths -CommandLine $oldService.PathName } else { $null }
if ($oldService -and $oldService.StartName -notin @('LocalSystem', 'NT AUTHORITY\SYSTEM')) {
    throw 'Der alte Agent nutzt ein eigenes Dienstkonto. Diese Installation muss mit Erhalt der Kontoberechtigungen migriert werden.'
}
$ruleName = 'Zabbix-Agent2-Migration-TCP10050'
if (Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue) {
    throw "Firewallregel $ruleName existiert bereits. Vorherigen Migrationsversuch zuerst pruefen."
}

# Program Files schuetzt Installer und Sicherungen vor Schreibzugriff normaler Benutzer.
$runDir = Join-Path $env:ProgramFiles ('Zabbix-Migration-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $runDir | Out-Null
$acl = New-Object Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true, $false)
foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
    $rule = New-Object Security.AccessControl.FileSystemAccessRule(
        (New-Object Security.Principal.SecurityIdentifier($sid)),
        'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'
    )
    $acl.AddAccessRule($rule)
}
Set-Acl -LiteralPath $runDir -AclObject $acl
Write-Host "Sicherungen und Installationsprotokolle: $runDir"
$msi = Join-Path $runDir 'zabbix-agent2.msi'
$template = Join-Path $runDir 'agent2.conf'
$agentExe = Join-Path $installDir 'zabbix_agent2.exe'
$agentConfig = Join-Path $installDir 'zabbix_agent2.conf'
$script:RebootRequired = $false
$cutoverComplete = $false
$installAttempted = $false
$firewallCreated = $false
$oldStopped = $false
$oldWasRunning = $oldService -and $oldService.State -eq 'Running'

try {
    if ($oldService) {
        $backup = Join-Path $runDir 'old-agent'
        New-Item -ItemType Directory -Path $backup | Out-Null
        $oldService | Select-Object Name, PathName, StartMode, StartName, State | Export-Clixml (Join-Path $backup 'service.xml')
        $oldProducts | Export-Clixml (Join-Path $backup 'products.xml')
        Copy-Item -LiteralPath $oldPaths.Config -Destination (Join-Path $backup 'original-agent.conf')
        # Sichert benachbarte Konfigurationsdateien und uebliche Include-Verzeichnisse.
        $configDir = Split-Path $oldPaths.Config -Parent
        Get-ChildItem -LiteralPath $configDir -Force | Where-Object {
            $_.Name -match '\.(conf|conf\.d|d)$'
        } | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $backup -Recurse
        }
        Write-Warning 'Alte Sonderparameter werden nicht automatisch uebernommen. Externe Includes ausserhalb des Konfigurationsordners sind nicht Teil der Sicherung.'
    }

    Write-Host "Lade Zabbix Agent 2 ($Release LTS) ..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $msi -UseBasicParsing -TimeoutSec 300
    $signature = Get-AuthenticodeSignature -FilePath $msi
    if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or $signature.SignerCertificate.Subject -notmatch '(?i)(?:^|,\s*)(?:CN|O)="?(?:Zabbix SIA|SIA Zabbix)"?(?:,|$)') {
        throw "Das MSI hat keine gueltige Zabbix-Herstellersignatur. Status: $($signature.Status). Der alte Agent bleibt unveraendert."
    }
    Get-FileHash -Path $msi -Algorithm SHA256 | Format-List | Out-File (Join-Path $runDir 'download-sha256.txt')
    $configText = @"
LogType=file
LogFile=$installDir\zabbix_agent2.log
LogFileSize=10
Server=$($settings.Server)
ServerActive=$($settings.Active)
Hostname=$Hostname
ListenPort=10050
TLSConnect=unencrypted
TLSAccept=unencrypted
Include=$installDir\zabbix_agent2.d\plugins.d\*.conf
"@
    [IO.File]::WriteAllText($template, $configText + "`r`n", (New-Object Text.UTF8Encoding($false)))

    Write-Host 'Installiere Agent 2, zunaechst ohne Dienststart ...'
    $installAttempted = $true
    # SERVER ist auch mit CONF fuer die MSI-Startbedingungen erforderlich.
    Invoke-Msi -Arguments "/i `"$msi`" ADDLOCAL=AgentProgram DONOTSTART=1 STARTUPTYPE=disabled SKIP=fw SERVER=`"$($settings.Server)`" SERVERACTIVE=`"$($settings.Active)`" HOSTNAME=`"$Hostname`" TLSCONNECT=unencrypted TLSACCEPT=unencrypted INSTALLFOLDER=`"$installDir`" CONF=`"$template`"" -Log (Join-Path $runDir 'install.log')
    & $agentExe -c $agentConfig -T
    if ($LASTEXITCODE -ne 0) { throw 'Die neue Agent-Konfiguration ist ungueltig.' }
    $ping = @(& $agentExe -c $agentConfig -t agent.ping)
    $pingExitCode = $LASTEXITCODE
    Assert-AgentPingResult -Output $ping -ExitCode $pingExitCode

    New-NetFirewallRule -Name $ruleName -DisplayName 'Zabbix Agent 2 - Serverzugriff' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 10050 -RemoteAddress $settings.Addresses -Program $agentExe -Profile Any | Out-Null
    $firewallCreated = $true
    if ($oldService) {
        Write-Host 'Stoppe den alten Agenten ...'
        $oldStopped = $true
        Stop-AgentService -Name $oldService.Name
    }
    Set-Service -Name 'Zabbix Agent 2' -StartupType Automatic
    Start-Service -Name 'Zabbix Agent 2'
    Assert-NewAgentRunning
    # Ab hier bleibt der funktionierende neue Agent auch bei Deinstallationsfehlern aktiv.
    $cutoverComplete = $true

    if ($oldService) {
        Set-Service -Name $oldService.Name -StartupType Disabled
        Write-Host 'Entferne den alten Agenten ...'
        if ($oldProducts.Count -eq 1) {
            Invoke-Msi -Arguments "/x $($oldProducts[0].ProductCode)" -Log (Join-Path $runDir 'uninstall-old.log')
        } else {
            # ZIP/manuelle Installation: nur den eindeutig erkannten Agent-Dienst entfernen.
            & "$env:SystemRoot\System32\sc.exe" delete $oldService.Name | Out-Host
            if ($LASTEXITCODE -ne 0) { throw 'Der alte Agent-Dienst konnte nicht entfernt werden.' }
            Write-Host 'Manuelle Installation: alte Programmdateien bleiben zur Wiederherstellung erhalten.'
        }
        $deadline = (Get-Date).AddSeconds(30)
        do {
            $remaining = @(Get-AgentServices | Where-Object { $_.Name -eq $oldService.Name })
            if ($remaining.Count -eq 0) { break }
            Start-Sleep -Seconds 1
        } while ((Get-Date) -lt $deadline)
        if ($remaining.Count -gt 0) { throw 'Der alte Dienst ist noch vorhanden oder zur Loeschung vorgemerkt. Installationsprotokoll pruefen.' }
        if (@(Get-ZabbixProducts | Where-Object { -not $_.IsAgent2 }).Count -gt 0) {
            throw 'Der alte Agent wird noch als installiert aufgefuehrt. Deinstallationsprotokoll pruefen.'
        }
    }
    Assert-NewAgentRunning
    Write-Host "Fertig: Zabbix Agent 2 laeuft. Hostname=$Hostname; Server=$ZabbixServer" -ForegroundColor Green
    Write-Host 'Aktive Checks: TCP 10051 ausgehend. Passive Checks: TCP 10050 eingehend.'
    Write-Host 'Die Datenannahme bitte im Zabbix-Frontend pruefen; ein lokaler Diensttest bestaetigt sie nicht.'
    Write-Host "Konfiguration: $agentConfig"
    Write-Host "Sicherung und Protokolle: $runDir"
    if ($script:RebootRequired) { Write-Warning 'Windows hat einen Neustart angefordert. Bitte einen passenden Zeitpunkt einplanen.' }
} catch {
    $failure = $_
    if (-not $cutoverComplete) {
        Write-Warning 'Migration fehlgeschlagen. Raeume die neue Installation auf und stelle den alten Dienststatus wieder her.'
        $newStopped = $true
        try {
            if (Get-Service -Name 'Zabbix Agent 2' -ErrorAction SilentlyContinue) {
                Stop-AgentService -Name 'Zabbix Agent 2'
                Set-Service -Name 'Zabbix Agent 2' -StartupType Disabled
            }
        } catch { $newStopped = $false; Write-Warning "Agent 2 konnte nicht gestoppt werden: $_" }
        if ($firewallCreated) {
            try { Remove-NetFirewallRule -Name $ruleName } catch { Write-Warning "Firewallregel konnte nicht entfernt werden: $_" }
        }
        if ($installAttempted -and $newStopped) {
            try {
                Invoke-Msi -Arguments "/x `"$msi`"" -Log (Join-Path $runDir 'rollback-new.log') -AllowNotInstalled
            } catch { Write-Warning "Aufraeumen der Agent-2-Installation fehlgeschlagen: $_" }
        }
        if ($oldStopped -and $oldWasRunning -and $newStopped) {
            try { Start-Service -Name $oldService.Name } catch { Write-Warning "Alter Agent konnte nicht gestartet werden: $_" }
        }
    } else {
        Write-Warning 'Der Wechsel auf Agent 2 war erfolgreich, aber ein anschliessender Schritt ist fehlgeschlagen. Agent 2 bleibt installiert; alten Dienst und Protokolle pruefen.'
    }
    throw "Migration nicht vollstaendig abgeschlossen: $($failure.Exception.Message) Protokolle/Sicherung: $runDir"
}
