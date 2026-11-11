<#
Switch off the OLD Windows TeamCity build agent: stop its service and disable
autostart, so it no longer connects to the old TeamCity server.

The old agent folder and settings are not changed or deleted; the script prints
the command that switches the old agent back on.

Run in PowerShell "as Administrator":
  powershell -ExecutionPolicy Bypass -File teamcity-agent-windows-disable-old.ps1 -Check
  powershell -ExecutionPolicy Bypass -File teamcity-agent-windows-disable-old.ps1
#>
[CmdletBinding()]
param(
  [string]$OldDir,       # old agent folder; taken from the old agent service if empty
  [string]$NewServiceName = 'TCBuildAgent2026',  # never touched
  [string]$NewDir = 'C:\BuildAgent2026',         # never touched
  [switch]$Check,        # only show the state and the plan
  [switch]$Yes,          # do not ask for confirmation
  [switch]$Force         # stop the old agent even if a build seems to be running
)
$ErrorActionPreference = 'Stop'

$script:problems = 0
function Ok($m)   { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Bad($m)  { Write-Host "  [НЕТ]  $m" -ForegroundColor Red; $script:problems++ }
function Warn($m) { Write-Host "  [ВНИМ] $m" -ForegroundColor Yellow }
function Info($m) { Write-Host "         $m" }
function Fail($m) { Write-Host "ОШИБКА: $m" -ForegroundColor Red; exit 1 }

function Get-AgentJvms([string]$dir) {
  # TeamCity agent/launcher JVMs whose command line or executable points into $dir.
  if (-not $dir) { return @() }
  @(Get-CimInstance Win32_Process -Filter "Name='java.exe'" | Where-Object {
      $_.CommandLine -and $_.CommandLine -like '*jetbrains.buildServer.agent.*' -and
      ($_.CommandLine -like "*$dir\*" -or $_.ExecutablePath -like "$dir\*") })
}
function Get-BuildProcesses($jvms) {
  # Children of the agent JVMs (other than the JVMs and consoles) are build steps.
  $ids = @($jvms | ForEach-Object { $_.ProcessId })
  if (-not $ids) { return @() }
  @(Get-CimInstance Win32_Process | Where-Object {
      $ids -contains $_.ParentProcessId -and $ids -notcontains $_.ProcessId -and
      $_.Name -notin @('conhost.exe', 'java.exe') })
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Fail 'запустите PowerShell "от имени администратора" (нужно для служб).' }
$NewDir = $NewDir.TrimEnd('\')

Write-Host "`n== Проверка =="

# Old agent service: any TeamCity agent service except the new one.
$agentServices = @(Get-CimInstance Win32_Service | Where-Object {
    $_.PathName -match 'TeamCityAgentService|\\launcher\\' -and
    $_.Name -ne $NewServiceName -and $_.PathName -notlike "*$NewDir\*" })
$oldSvc = $null
if ($OldDir) {
  $OldDir = $OldDir.TrimEnd('\')
  if ($OldDir -eq $NewDir) { Fail "-OldDir совпадает с папкой нового агента $NewDir" }
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

if ($OldDir -and (Test-Path -LiteralPath (Join-Path $OldDir 'conf\buildAgent.properties'))) {
  Ok "Старый агент: $OldDir (папка и настройки не меняются)"
} elseif (-not $script:problems) {
  Bad 'Не найден старый агент (conf\buildAgent.properties). Укажите: -OldDir C:\путь\к\агенту'
}
if ($oldSvc) {
  Ok "Служба старого агента: $($oldSvc.Name), состояние $($oldSvc.State), запуск $($oldSvc.StartMode)"
} elseif ($OldDir) {
  Warn 'Служба старого агента не найдена - вероятно, он запускается вручную (agent.bat)'
}

$jvms = Get-AgentJvms $OldDir
$building = Get-BuildProcesses $jvms
if ($jvms) { Info "Процессы старого агента: PID $(($jvms | ForEach-Object { $_.ProcessId }) -join ', ')" }
if ($building) {
  Warn "На старом агенте, похоже, идёт сборка: $(($building | ForEach-Object { $_.Name }) -join ', ')"
  Info '  Дождитесь окончания (или Disable агента в старом TeamCity). Без -Force скрипт его не остановит.'
}

$running = ($oldSvc -and $oldSvc.State -ne 'Stopped') -or $jvms
$enabled = $oldSvc -and $oldSvc.StartMode -ne 'Disabled'

Write-Host "`n== Что будет сделано =="
$steps = @()
if ($oldSvc -and $oldSvc.State -ne 'Stopped') { $steps += "Остановить службу $($oldSvc.Name)" }
elseif ($jvms) { $steps += "Остановить агента, запущенного вручную: $OldDir\bin\agent.bat stop" }
if ($enabled) { $steps += "Отключить автозапуск службы $($oldSvc.Name) (было: $($oldSvc.StartMode))" }
if ($running) { $steps += 'Проверить, что процессов старого агента не осталось' }
if ($script:problems -eq 0 -and -not $steps) {
  Write-Host "`nСтарый агент уже выключен: служба остановлена и отключена, процессов нет. Ничего не изменено."
  exit 0
}
for ($i = 0; $i -lt $steps.Count; $i++) { Info "$($i + 1). $($steps[$i])" }
Info "Не меняется: папка старого агента, его настройки, новый агент ($NewServiceName), серверы TeamCity."

if ($script:problems -gt 0) {
  Write-Host "`nЕсть пункты [НЕТ] ($($script:problems)) - исправьте их и запустите снова. Ничего не изменено." -ForegroundColor Red
  exit 1
}
if ($building -and -not $Force) {
  Write-Host "`nНа старом агенте идёт сборка - дождитесь её или запустите с -Force. Ничего не изменено." -ForegroundColor Yellow
  exit 3
}
if ($Check) { Write-Host "`nРежим -Check: ничего не изменено."; exit 0 }
if (-not $Yes) {
  $a = Read-Host "`nВыключить старого агента? [y/N]"
  if ($a -notmatch '^[YyДд]') { Write-Host 'Отменено, ничего не изменено.'; exit 0 }
}

Write-Host "`n== Что сделано =="
try {
  if ($oldSvc) {
    # A build may have started since the check: look again right before stopping.
    $busy = Get-BuildProcesses (Get-AgentJvms $OldDir)
    if ($busy -and -not $Force) { throw "на старом агенте началась сборка ($(($busy | ForEach-Object { $_.Name }) -join ', ')) - не останавливаю" }
    if ((Get-Service -Name $oldSvc.Name).Status -ne 'Stopped') {
      Stop-Service -Name $oldSvc.Name -Force
      (Get-Service -Name $oldSvc.Name).WaitForStatus('Stopped', [TimeSpan]::FromMinutes(2))
      Ok "Служба $($oldSvc.Name) остановлена"
    }
    if ($enabled) {
      Set-Service -Name $oldSvc.Name -StartupType Disabled
      Ok "Автозапуск службы $($oldSvc.Name) отключён"
    }
  }
  # Agent started by hand (no service, or alongside a stopped service).
  if (Get-AgentJvms $OldDir) {
    Push-Location (Join-Path $OldDir 'bin')
    try { cmd /c 'agent.bat stop' | Out-Null } finally { Pop-Location }
    Ok "Отправлена команда остановки: $OldDir\bin\agent.bat stop"
  }
  $left = @()
  for ($i = 0; $i -lt 12; $i++) {
    $left = Get-AgentJvms $OldDir
    if (-not $left) { break }
    Start-Sleep -Seconds 5
  }
  if ($left) { Bad "Процессы старого агента ещё работают через минуту: PID $(($left | ForEach-Object { $_.ProcessId }) -join ', ')" }
  else { Ok 'Процессов старого агента нет' }
} catch {
  Bad "Остановлено на ошибке: $($_.Exception.Message)"
}

Write-Host "`n== Итог =="
if ($script:problems -eq 0) { Info 'Старый агент выключен. В старом TeamCity он будет показан как Disconnected.' }
else { Info "Есть пункты [НЕТ] ($($script:problems)) - см. выше." }
if ($oldSvc) {
  $mode = $oldSvc.StartMode -replace '^Auto$', 'Automatic'
  if ($mode -eq 'Disabled') { $mode = 'Automatic' }
  Info "Включить старого агента обратно: Set-Service $($oldSvc.Name) -StartupType $mode; Start-Service $($oldSvc.Name)"
}
if ($script:problems -gt 0) { exit 1 }
