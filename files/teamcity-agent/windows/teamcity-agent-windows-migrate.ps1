<#
Move a Windows TeamCity build agent to the new TeamCity server.

Reports what is missing and the exact plan first; after confirmation installs a
NEW agent next to the old one (own folder, own service, Java 21), copies the old
agent's custom system.*/env.* parameters, disables the old agent service and
verifies that the new service runs on Java 21. The old agent folder is not
changed or deleted, so the old service can be switched back on.

Run in PowerShell "as Administrator":
  powershell -ExecutionPolicy Bypass -File teamcity-agent-windows-migrate.ps1 -Check
  powershell -ExecutionPolicy Bypass -File teamcity-agent-windows-migrate.ps1
#>
[CmdletBinding()]
param(
  [string]$ServerUrl = 'http://172.17.6.61:8111',
  [string]$Zip,          # buildAgentFull.zip from the NEW server (Agents -> Install Build Agents)
  [string]$Jdk,          # Java 21: Corretto .zip or JDK folder; searched automatically if empty
  [string]$OldDir,       # old agent folder; taken from the old agent service if empty
  [string]$NewDir = 'C:\BuildAgent2026',
  [string]$Name,         # new agent name; default: <old name>-2026
  [string]$ServiceName = 'TCBuildAgent2026',
  [switch]$Check,        # only show what is missing and the plan
  [switch]$Yes,          # do not ask for confirmation
  [switch]$KeepOldService, # leave the old service running (new agent gets port 9091)
  [switch]$Force         # stop the old agent even if a build seems to be running
)
$ErrorActionPreference = 'Stop'
# ansible: unattended run (playbooks/62-teamcity-agents-windows.yml) - TLS 1.2 for the https
# check of the new server (Windows PowerShell 5.1 on older builds offers only SSL3/TLS1.0), and no
# progress bar (Expand-Archive is very slow with it in 5.1). Nothing else changes.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'
# ansible: unattended run (Ansible/WinRM): the service account password may come from the
# environment. Read once and removed at once, before any child process is started.
# Only .NET calls here: a cmdlet parameter (ConvertTo-SecureString -String, New-Object -ArgumentList)
# would be written in clear text to the PowerShell module log (event 4103).
$svcPassword = $null
if ($env:TC_AGENT_SERVICE_PASSWORD) {
  $svcPassword = [System.Net.NetworkCredential]::new('', $env:TC_AGENT_SERVICE_PASSWORD).SecurePassword
  Remove-Item -Path Env:\TC_AGENT_SERVICE_PASSWORD
}
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$latin1 = [Text.Encoding]::GetEncoding(28591)  # .properties are ISO-8859-1: keep bytes as is

$script:problems = 0
function Ok($m)   { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Bad($m)  { Write-Host "  [НЕТ]  $m" -ForegroundColor Red; $script:problems++ }
function Fix($m)  { Write-Host "  [НЕТ]  $m" -ForegroundColor Yellow }  # fixed by this script
function Warn($m) { Write-Host "  [ВНИМ] $m" -ForegroundColor Yellow }
function Info($m) { Write-Host "         $m" }
function Fail($m) { Write-Host "ОШИБКА: $m" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------- .properties
# Key ends at the first '=', ':' or whitespace; '#'/'!' lines are comments;
# a trailing backslash continues the value on the next line.
function Read-Props([string]$path) {
  $entries = New-Object System.Collections.ArrayList
  $cur = $null
  foreach ($line in [IO.File]::ReadAllLines($path, $latin1)) {
    if ($cur) { [void]$cur.Lines.Add($line) }
    elseif ($line -notmatch '^[ \t\f]*([#!]|$)' -and $line -match '^[ \t\f]*([^=: \t\f]+)[ \t\f]*[=:]?[ \t\f]*(.*)$') {
      $cur = @{ Key = $Matches[1]; Value = $Matches[2]; Lines = (New-Object System.Collections.ArrayList) }
      [void]$cur.Lines.Add($line)
      [void]$entries.Add($cur)
    }
    if ($cur -and $line -notmatch '\\$') { $cur = $null }
  }
  return ,$entries
}
function Get-Prop($entries, [string]$key) {
  $v = $null
  foreach ($e in $entries) { if ($e.Key -eq $key) { $v = $e.Value } }
  return $v
}
function Set-PropLine([string[]]$lines, [string]$key, [string]$value) {
  # Replace the active line of $key (or add it); the value is plain ASCII here.
  $out = New-Object System.Collections.ArrayList
  $done = $false
  foreach ($l in $lines) {
    if (-not $done -and $l -match ('^[ \t\f]*' + [regex]::Escape($key) + '[ \t\f]*[=:]')) {
      [void]$out.Add("$key=$value"); $done = $true
    } else { [void]$out.Add($l) }
  }
  if (-not $done) { [void]$out.Add("$key=$value") }
  return ,$out.ToArray()
}
function Show-Value([string]$key, [string]$value) {
  if ($key -match '(?i)pass|pwd|token|secret|key|credential') { return '<скрыто>' }
  return $value
}

# ---------------------------------------------------------------------- Java
function Get-JavaVersion([string]$java) {
  if (-not $java -or -not (Test-Path -LiteralPath $java)) { return $null }
  $out = cmd /c "`"$java`" -version 2>&1"
  return ($out | Select-Object -First 1)
}
function Test-Java21([string]$java) { return ((Get-JavaVersion $java) -match '"21\.') }

# -------------------------------------------------------------- processes
function Get-AgentJvms([string]$dir) {
  # TeamCity agent/launcher JVMs whose command line points into $dir.
  if (-not $dir) { return @() }
  $d = $dir.TrimEnd('\')
  @(Get-CimInstance Win32_Process -Filter "Name='java.exe'" | Where-Object {
      $_.CommandLine -and $_.CommandLine -like '*jetbrains.buildServer.agent.*' -and
      ($_.CommandLine -like "*$d\*" -or $_.ExecutablePath -like "$d\*") })
}
function Get-NewAgentJvm([string]$dir, [string]$java) {
  @(Get-CimInstance Win32_Process -Filter "Name='java.exe'" | Where-Object {
      $_.CommandLine -like '*AgentMain*' -and ($_.ExecutablePath -eq $java -or $_.CommandLine -like "*$dir\*") }) |
    Select-Object -First 1
}
function Get-BuildProcesses($jvms) {
  # Children of the agent JVMs (other than the JVMs and consoles) are build steps.
  $ids = @($jvms | ForEach-Object { $_.ProcessId })
  if (-not $ids) { return @() }
  @(Get-CimInstance Win32_Process | Where-Object {
      $ids -contains $_.ParentProcessId -and $ids -notcontains $_.ProcessId -and
      $_.Name -notin @('conhost.exe', 'java.exe') })
}

# ================================================================ diagnostics
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Fail 'запустите PowerShell "от имени администратора" (нужно для служб).' }
$NewDir = $NewDir.TrimEnd('\')
$ServerUrl = $ServerUrl.TrimEnd('/')

Write-Host "`n== Проверка: чего не хватает =="

# Old agent: its service tells where it lives and under which account it runs.
$agentServices = @(Get-CimInstance Win32_Service | Where-Object {
    $_.PathName -match 'TeamCityAgentService|\\launcher\\' -and $_.Name -ne $ServiceName })
$oldSvc = $null
if ($OldDir) {
  $OldDir = $OldDir.TrimEnd('\')
  $oldSvc = $agentServices | Where-Object { $_.PathName -like "*$OldDir\launcher*" } | Select-Object -First 1
} elseif ($agentServices.Count -eq 1) {
  $oldSvc = $agentServices[0]
  if ($oldSvc.PathName -match '"?([A-Za-z]:\\.*?)\\launcher\\') { $OldDir = $Matches[1] }
} elseif ($agentServices.Count -gt 1) {
  Bad 'Найдено несколько служб агентов TeamCity - укажите старый агент: -OldDir <папка>'
  foreach ($s in $agentServices) { Info "- $($s.Name): $($s.PathName)" }
} elseif (Test-Path 'C:\BuildAgent\conf\buildAgent.properties') {
  $OldDir = 'C:\BuildAgent'
}
$oldConf = if ($OldDir) { Join-Path $OldDir 'conf\buildAgent.properties' } else { $null }
$oldProps = New-Object System.Collections.ArrayList
if ($oldConf -and (Test-Path -LiteralPath $oldConf)) {
  $oldProps = Read-Props $oldConf
  Ok "Старый агент: $OldDir (не изменяется и не удаляется)"
  Info "serverUrl: $(Get-Prop $oldProps 'serverUrl'), name: $(Get-Prop $oldProps 'name')"
} else {
  Bad 'Не найден старый агент (conf\buildAgent.properties). Укажите: -OldDir C:\путь\к\агенту'
}
$oldAccount = 'LocalSystem'
if ($oldSvc) {
  $oldAccount = $oldSvc.StartName
  Ok "Служба старого агента: $($oldSvc.Name), состояние $($oldSvc.State), запуск $($oldSvc.StartMode), учётная запись $oldAccount"
} elseif ($OldDir) {
  Warn 'Служба старого агента не найдена - вероятно, он запускался вручную (agent.bat). Остановите его сами.'
}
if ($oldAccount -like '.\*') { $oldAccount = "$env:COMPUTERNAME\" + $oldAccount.Substring(2) }
$systemAccount = $oldAccount -match '^(LocalSystem|NT AUTHORITY\\(SYSTEM|LocalService|NetworkService))$'
if (-not $systemAccount) {
  Warn "Старый агент работал от $oldAccount - новый будет работать от него же, скрипт спросит его пароль"
}

$oldJvms = Get-AgentJvms $OldDir
$building = Get-BuildProcesses $oldJvms
if ($oldJvms) {
  $j = $oldJvms | Select-Object -First 1
  Info "Старый агент запущен на Java: $($j.ExecutablePath) ($(Get-JavaVersion $j.ExecutablePath))"
}
if ($oldJvms -and -not $oldSvc -and -not $KeepOldService) {
  Bad "Старый агент запущен вручную (не службой) - остановите его: $OldDir\bin\agent.bat stop"
}
if ($building) {
  Warn "На старом агенте, похоже, идёт сборка: $(($building | ForEach-Object { $_.Name }) -join ', ')"
  Info '  Дождитесь окончания (или Disable агента в старом TeamCity). Без -Force скрипт его не остановит.'
}

# New server reachability (any HTTP answer, even 401, means it is reachable).
$reachable = $false
try {
  Invoke-WebRequest "$ServerUrl/login.html" -UseBasicParsing -TimeoutSec 15 | Out-Null; $reachable = $true
} catch {
  if ($_.Exception.Response) { $reachable = $true }
}
if ($reachable) { Ok "Новый TeamCity доступен: $ServerUrl" }
else { Bad "Новый TeamCity недоступен с этой машины: $ServerUrl (сеть/firewall/адрес)" }

# Agent distribution from the NEW server.
if (-not $Zip) {
  $Zip = Get-ChildItem -Path @($here, "$env:USERPROFILE\Downloads") -Filter 'buildAgent*.zip' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
}
$zipHasJre = $false
if ($Zip -and (Test-Path -LiteralPath $Zip)) {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $z = [IO.Compression.ZipFile]::OpenRead($Zip)
  try {
    $names = @($z.Entries | ForEach-Object { $_.FullName -replace '\\', '/' })
    $zipOk = ($names -contains 'bin/agent.bat') -and ($names -contains 'conf/buildAgent.dist.properties')
    $zipHasJre = $names -contains 'jre/bin/java.exe'
    $unsafe = @($names | Where-Object { $_ -match '(^|/)\.\.(/|$)' -or $_ -match '^[A-Za-z]:|^/' })
  } finally { $z.Dispose() }
  if (-not $zipOk -or $unsafe) { Bad "Архив $Zip - не дистрибутив агента TeamCity (нет bin\agent.bat в корне)" ; $Zip = $null }
  else { Ok "Дистрибутив агента: $Zip$(if ($zipHasJre) { ' (с Java внутри)' })" }
} else {
  Bad 'Нет buildAgentFull.zip: скачайте в новом TeamCity Agents -> Install Build Agents -> Zip file distribution, положите рядом со скриптом'
  $Zip = $null
}

# Java 21 for the new agent: bundled, given, next to the script, or installed.
$javaSource = $null; $javaPath = $null
if ($Jdk) {
  if ((Test-Path -LiteralPath $Jdk -PathType Leaf) -and $Jdk -like '*.zip') { $javaSource = $Jdk }
  elseif (Test-Java21 (Join-Path $Jdk 'bin\java.exe')) { $javaPath = Join-Path $Jdk 'bin\java.exe' }
  else { Bad "В -Jdk $Jdk нет Java 21" }
} elseif ($zipHasJre) {
  $javaPath = Join-Path $NewDir 'jre\bin\java.exe'  # checked after unpacking
} else {
  $javaSource = Get-ChildItem -Path @($here, "$env:USERPROFILE\Downloads") -Filter 'amazon-corretto-21*-windows-x64-jdk.zip' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
  if (-not $javaSource) {
    $found = Get-ChildItem -Path 'C:\Program Files\Amazon Corretto', 'C:\Program Files\Eclipse Adoptium',
        'C:\Program Files\Java', 'C:\Program Files\Microsoft' -Directory -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match '21' } | ForEach-Object { Join-Path $_.FullName 'bin\java.exe' } |
      Where-Object { Test-Java21 $_ } | Select-Object -First 1
    if ($found) { $javaPath = $found }
  }
}
if ($javaSource) { Ok "Java 21 будет распакована из $javaSource в $NewDir\jre" }
elseif ($javaPath -and $zipHasJre) { Ok 'Java для агента есть в дистрибутиве (будет проверена после распаковки)' }
elseif ($javaPath) { Ok "Java 21: $javaPath ($(Get-JavaVersion $javaPath))" }
elseif (-not $Jdk) { Bad 'Нет Java 21: положите рядом со скриптом amazon-corretto-21...-windows-x64-jdk.zip (есть в GitLab)' }

# New agent folder, service and port.
if (Test-Path -LiteralPath $NewDir) {
  if (Get-ChildItem -LiteralPath $NewDir -Force | Select-Object -First 1) {
    Bad "Папка $NewDir уже существует и не пуста - не перезаписываю. Укажите другую: -NewDir"
  }
}
if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
  Bad "Служба $ServiceName уже существует - укажите другое имя: -ServiceName"
}
$port = 9090
if ($KeepOldService) { $port = 9091 }
$listen = $null
try { $listen = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue } catch { }
if ($listen -and -not (($oldJvms | ForEach-Object { $_.ProcessId }) -contains $listen[0].OwningProcess -and -not $KeepOldService)) {
  Bad "Порт $port уже занят процессом PID $($listen[0].OwningProcess)"
}

# Parameters of the old agent missing in a fresh agent: all custom system.*/env.*.
$custom = @($oldProps | Where-Object { $_.Key -match '^(system|env)\.' })
if ($custom) {
  Fix "Новому агенту нужны параметры старого ($($custom.Count)), из-за них сборки выбирают агента:"
  foreach ($e in $custom) { Info "- $($e.Key) = $(Show-Value $e.Key $e.Value)" }
} elseif ($oldProps.Count) {
  Ok 'Дополнительных параметров system.*/env.* у старого агента нет'
}
$other = @($oldProps | Where-Object { $_.Key -notmatch '^(system|env)\.|^(serverUrl|name|authorizationToken)$' })
if ($other) {
  Warn 'Прочие настройки старого агента не переносятся (пути/порты у нового свои):'
  foreach ($e in $other) { Info "- $($e.Key) = $(Show-Value $e.Key $e.Value)" }
}
if (-not $Name) {
  $oldName = Get-Prop $oldProps 'name'
  $Name = if ($oldName) { "$oldName-2026" } else { "$env:COMPUTERNAME-2026" }
}

# ======================================================================= plan
Write-Host "`n== Что будет сделано =="
$steps = @()
$steps += "Распаковать агента в $NewDir"
if ($javaSource) { $steps += "Распаковать Java 21 в $NewDir\jre" }
$steps += "Настроить conf\buildAgent.properties: serverUrl=$ServerUrl, name=$Name$(if ($custom) { ", + $($custom.Count) параметр(ов) старого агента" })$(if ($KeepOldService) { ', ownPort=9091' })"
$steps += "Службе нового агента задать имя $ServiceName и Java 21 (launcher\conf\wrapper.conf)"
$steps += "Установить службу $ServiceName от учётной записи $oldAccount$(if (-not $systemAccount) { ' (спрошу пароль, дам права на папку)' })"
if ($oldSvc -and -not $KeepOldService) {
  $steps += "Только после этого остановить службу старого агента $($oldSvc.Name) и отключить её автозапуск (папку $OldDir не трогаю)"
} elseif ($KeepOldService) {
  $steps += 'Старую службу оставить работать'
}
$steps += "Запустить $ServiceName и проверить: служба работает, Java 21, записи журнала о подключении к серверу"
for ($i = 0; $i -lt $steps.Count; $i++) { Info "$($i + 1). $($steps[$i])" }
Info 'Не меняется: папка старого агента, его настройки, сервер TeamCity, системная Java.'

if ($script:problems -gt 0) {
  Write-Host "`nЕсть пункты [НЕТ] ($($script:problems)) - исправьте их и запустите снова. Ничего не изменено." -ForegroundColor Red
  exit 1
}
if ($building -and -not $Force -and -not $KeepOldService) {
  Write-Host "`nНа старом агенте идёт сборка - дождитесь её или запустите с -Force. Ничего не изменено." -ForegroundColor Yellow
  exit 3
}
if ($Check) { Write-Host "`nРежим -Check: ничего не изменено."; exit 0 }
if (-not $Yes) {
  $a = Read-Host "`nВыполнить? [y/N]"
  if ($a -notmatch '^[YyДд]') { Write-Host 'Отменено, ничего не изменено.'; exit 0 }
}

# ==================================================================== actions
Write-Host "`n== Что сделано =="
$credential = $null
if (-not $systemAccount) {
  if ($svcPassword) {
    $credential = New-Object System.Management.Automation.PSCredential($oldAccount, $svcPassword)
  } else {
    $credential = Get-Credential -UserName $oldAccount -Message "Пароль учётной записи службы агента $oldAccount"
  }
  if (-not $credential) { Fail 'пароль не введён, ничего не изменено' }
}

$oldStopped = $false; $created = $false; $installed = $false
try {
New-Item -ItemType Directory -Path $NewDir -Force | Out-Null
$created = $true
Expand-Archive -LiteralPath $Zip -DestinationPath $NewDir
Ok "Агент распакован в $NewDir"

if ($javaSource) {
  $tmp = Join-Path $env:TEMP ("tc-jdk21-" + [guid]::NewGuid())
  Expand-Archive -LiteralPath $javaSource -DestinationPath $tmp
  $root = @(Get-ChildItem -LiteralPath $tmp -Directory)
  if ($root.Count -ne 1 -or -not (Test-Path (Join-Path $root[0].FullName 'bin\java.exe'))) { throw "в $javaSource нет bin\java.exe" }
  if (Test-Path "$NewDir\jre") { Remove-Item -LiteralPath "$NewDir\jre" -Recurse -Force }  # our own fresh unpack
  Move-Item -LiteralPath $root[0].FullName -Destination "$NewDir\jre"
  Remove-Item -LiteralPath $tmp -Recurse -Force
  $javaPath = "$NewDir\jre\bin\java.exe"
}
if (Test-Java21 $javaPath) { Ok "Java 21: $javaPath ($(Get-JavaVersion $javaPath))" }
else { throw "Java 21 не работает: $javaPath" }

$conf = Join-Path $NewDir 'conf\buildAgent.properties'
$lines = [IO.File]::ReadAllLines((Join-Path $NewDir 'conf\buildAgent.dist.properties'), $latin1)
$lines = Set-PropLine $lines 'serverUrl' $ServerUrl
$lines = Set-PropLine $lines 'name' $Name
if ($KeepOldService) { $lines = Set-PropLine $lines 'ownPort' '9091' }
if ($custom) {
  $lines += ''
  $lines += "# Copied from $oldConf on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') by teamcity-agent-windows-migrate.ps1"
  foreach ($e in $custom) { $lines += $e.Lines }
}
[IO.File]::WriteAllLines($conf, [string[]]$lines, $latin1)
$written = Read-Props $conf
$missing = @($custom | Where-Object { (Get-Prop $written $_.Key) -ne $_.Value })
if ((Get-Prop $written 'serverUrl') -eq $ServerUrl -and (Get-Prop $written 'name') -eq $Name -and -not $missing) {
  Ok "Настройки записаны и проверены: $conf$(if ($custom) { " (+ $($custom.Count) параметр(ов))" })"
} else { throw "настройки в $conf не совпали с ожидаемыми" }

$wrapper = Join-Path $NewDir 'launcher\conf\wrapper.conf'
$w = [IO.File]::ReadAllLines($wrapper, $latin1)
$w = Set-PropLine $w 'wrapper.java.command' $javaPath
$w = Set-PropLine $w 'wrapper.ntservice.name' $ServiceName
$w = Set-PropLine $w 'wrapper.ntservice.displayname' "TeamCity Build Agent 2026 ($ServiceName)"
# Only LocalSystem may interact with the desktop; otherwise the account change below fails (code 21).
$w = Set-PropLine $w 'wrapper.ntservice.interactive' 'false'
[IO.File]::WriteAllLines($wrapper, [string[]]$w, $latin1)
Ok "Служба настроена: имя $ServiceName, Java $javaPath"

Push-Location (Join-Path $NewDir 'bin')
try { cmd /c 'service.install.bat' | Out-Null } finally { Pop-Location }
$svc = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'"
if (-not $svc) { throw "служба $ServiceName не установилась (bin\service.install.bat)" }
$installed = $true
Set-Service -Name $ServiceName -StartupType Automatic
if ($credential) {
  # The account already ran the old agent here; give it rights on the new folder.
  & icacls $NewDir /grant "$($oldAccount):(OI)(CI)M" /Q | Out-Null
  $r = Invoke-CimMethod -InputObject $svc -MethodName Change -Arguments @{
    DesktopInteract = $false; StartName = $oldAccount; StartPassword = $credential.GetNetworkCredential().Password }
  if ($r.ReturnValue -ne 0) {
    $why = @{ 2 = 'нет прав'; 15 = 'неверный пароль'; 21 = 'неверный параметр'; 22 = 'учётная запись не найдена' }[[int]$r.ReturnValue]
    throw "не удалось задать учётную запись службы $oldAccount (код $($r.ReturnValue)$(if ($why) { ": $why" }))"
  }
}
Ok "Служба $ServiceName установлена, автозапуск, учётная запись $oldAccount"

if ($oldSvc -and -not $KeepOldService) {
  # A build may have started while we were installing: check again right before stopping.
  $busy = Get-BuildProcesses (Get-AgentJvms $OldDir)
  if ($busy -and -not $Force) { throw "на старом агенте началась сборка ($(($busy | ForEach-Object { $_.Name }) -join ', ')) - старый агент не остановлен" }
  if ($oldSvc.State -ne 'Stopped') {
    Stop-Service -Name $oldSvc.Name -Force
    (Get-Service -Name $oldSvc.Name).WaitForStatus('Stopped', [TimeSpan]::FromMinutes(2))
  }
  Set-Service -Name $oldSvc.Name -StartupType Disabled
  $oldStopped = $true
  Ok "Служба старого агента $($oldSvc.Name) остановлена, автозапуск отключён"
}

try {
  Start-Service -Name $ServiceName
  (Get-Service -Name $ServiceName).WaitForStatus('Running', [TimeSpan]::FromMinutes(1))
} catch {
  # Start-Service hides the Windows reason: show the error code, SCM events and the wrapper log.
  $why = (& sc.exe start $ServiceName 2>&1 | Out-String).Trim()
  $code = $LASTEXITCODE
  Bad "Служба $ServiceName не запускается (код Windows $code)"
  if ($code -eq 1069) { Info 'Ошибка входа: неверный пароль учётной записи службы. Задайте его: services.msc -> служба -> Вход в систему' }
  elseif ($code -eq 1385) { Info 'У учётной записи нет права "Вход в качестве службы" (secpol.msc -> Локальные политики -> Назначение прав)' }
  elseif ($why) { Info $why }
  Get-EventLog -LogName System -Source 'Service Control Manager' -After (Get-Date).AddMinutes(-5) -ErrorAction SilentlyContinue |
    Where-Object { $_.Message -like "*$ServiceName*" } | Select-Object -First 3 |
    ForEach-Object { Info "Журнал Система: $($_.Message -replace '\s+', ' ')" }
  foreach ($l in @("$NewDir\launcher\logs\wrapper.log", "$NewDir\logs\launcher.log")) {
    if (Test-Path -LiteralPath $l) { Info "Последние строки ${l}:"; Get-Content -LiteralPath $l -Tail 8 | ForEach-Object { Info "  $_" } }
  }
  throw "служба $ServiceName не запустилась"
}
$jvm = $null
for ($i = 0; $i -lt 12 -and -not $jvm; $i++) {
  Start-Sleep -Seconds 5
  $jvm = Get-NewAgentJvm $NewDir $javaPath
}
if ($jvm -and $jvm.ExecutablePath -eq $javaPath) { Ok "Служба $ServiceName работает, агент на Java 21 (PID $($jvm.ProcessId))" }
elseif ($jvm) { Bad "Агент запущен не на Java 21: $($jvm.ExecutablePath)" }
else { Bad "Процесс агента не появился - смотрите $NewDir\logs\launcher.log и teamcity-agent.log" }
Start-Sleep -Seconds 15
$log = Join-Path $NewDir 'logs\teamcity-agent.log'
if (Test-Path $log) {
  Info 'Последние записи журнала агента о подключении:'
  Get-Content $log -Tail 300 | Select-String -Pattern 'regist|connect|error' | Select-Object -Last 5 |
    ForEach-Object { Info ("  " + $_.Line.Substring(0, [Math]::Min(200, $_.Line.Length))) }
}

} catch {
  Bad "Остановлено на ошибке: $($_.Exception.Message)"
  if (-not $oldStopped -and ($installed -or $created)) {
    Info 'Старый агент не тронут. Убрать незавершённую установку нового, чтобы запустить скрипт снова:'
    if ($installed) { Info "  sc.exe delete $ServiceName" }
    Info "  Remove-Item -Recurse -Force $NewDir"
  }
}

Write-Host "`n== Итог =="
if ($script:problems -eq 0) {
  Info "Готово. В новом TeamCity: Agents -> Unauthorized -> $Name -> Authorize, затем назначьте пул."
} else { Info "Есть пункты [НЕТ] ($($script:problems)) - см. выше." }
if ($oldStopped) {
  Info "Вернуть старого агента: Stop-Service $ServiceName; Set-Service $($oldSvc.Name) -StartupType $($oldSvc.StartMode -replace '^Auto$','Automatic'); Start-Service $($oldSvc.Name)"
}
if ($script:problems -gt 0) { exit 1 }
