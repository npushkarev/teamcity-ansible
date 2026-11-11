<#
Remove the NEW Windows TeamCity agent installed by teamcity-agent-windows-migrate.ps1
(its service and folder), so the migration can be run again from scratch.

The old agent (its folder, settings and service) is not touched.

Run in PowerShell "as Administrator":
  powershell -ExecutionPolicy Bypass -File teamcity-agent-windows-remove-new.ps1 -Check
  powershell -ExecutionPolicy Bypass -File teamcity-agent-windows-remove-new.ps1
#>
[CmdletBinding()]
param(
  [string]$NewDir = 'C:\BuildAgent2026',
  [string]$ServiceName = 'TCBuildAgent2026',
  [switch]$Check,        # only show what will be removed
  [switch]$Yes           # do not ask for confirmation
)
$ErrorActionPreference = 'Stop'

$script:problems = 0
function Ok($m)   { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Bad($m)  { Write-Host "  [НЕТ]  $m" -ForegroundColor Red; $script:problems++ }
function Warn($m) { Write-Host "  [ВНИМ] $m" -ForegroundColor Yellow }
function Info($m) { Write-Host "         $m" }
function Fail($m) { Write-Host "ОШИБКА: $m" -ForegroundColor Red; exit 1 }

function Get-DirProcesses([string]$dir) {
  # Any process started from $dir or pointing into it (java, service wrapper, cmd).
  @(Get-CimInstance Win32_Process | Where-Object {
      $_.ProcessId -ne $PID -and (($_.ExecutablePath -like "$dir\*") -or ($_.CommandLine -like "*$dir\*")) })
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Fail 'запустите PowerShell "от имени администратора" (нужно для служб).' }
$NewDir = $NewDir.TrimEnd('\')

Write-Host "`n== Проверка =="

# Never remove a drive root, a system folder or a folder that is not a TeamCity agent.
if ($NewDir -notmatch '^[A-Za-z]:\\.+' -or $NewDir -match '^[A-Za-z]:\\(Windows|Program Files|Program Files \(x86\)|Users)(\\|$)') {
  Fail "папка $NewDir не похожа на папку агента - не удаляю"
}
# The service must belong to $NewDir: otherwise it may be the old agent's service.
$svc = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'"
$svcInDir = $svc -and $svc.PathName -like "*$NewDir\*"

# A half-removed agent folder (an earlier run stopped on a locked file) may have lost
# bin\agent.bat: it is still ours if our service runs from it or only agent folders remain.
$agentEntries = 'bin', 'conf', 'launcher', 'lib', 'plugins', 'jre', 'logs', 'temp', 'work', 'system',
  'tools', 'update', 'backup', 'contrib', 'BUILD_*', 'README*', '*.md', '*.txt', '*.xml', '*.properties'
$dirExists = Test-Path -LiteralPath $NewDir
if ($dirExists) {
  $entries = @(Get-ChildItem -LiteralPath $NewDir -Force)
  $unknown = @($entries | Where-Object { $n = $_.Name; -not ($agentEntries | Where-Object { $n -like $_ }) })
  if (Test-Path -LiteralPath (Join-Path $NewDir 'bin\agent.bat')) { Ok "Папка нового агента: $NewDir" }
  elseif (-not $entries) { Ok "Папка $NewDir пустая" }
  elseif ($svcInDir -or -not $unknown) { Ok "Папка нового агента (остаток прошлого удаления): $NewDir" }
  else {
    Bad "В $NewDir нет bin\agent.bat и есть посторонние файлы - это не похоже на папку агента, не удаляю:"
    foreach ($u in ($unknown | Select-Object -First 10)) { Info "- $($u.Name)" }
  }
} else { Ok "Папки $NewDir нет - удалять нечего" }
if ($svc) {
  if ($svcInDir) {
    Ok "Служба $ServiceName ($($svc.State)), запуск из $NewDir"
  } else {
    Bad "Служба $ServiceName запускается не из $NewDir, а: $($svc.PathName) - не удаляю (это может быть старый агент)"
  }
} else { Ok "Службы $ServiceName нет - удалять нечего" }

$procs = Get-DirProcesses $NewDir
foreach ($p in $procs) { Info "Процесс из $NewDir будет завершён: $($p.Name) (PID $($p.ProcessId))" }
if ($PWD.ProviderPath -like "$NewDir*") { Bad "Текущая папка консоли внутри $NewDir - перейдите из неё: cd C:\" }

# Show the old agent so it is clear it stays as it is.
$others = @(Get-CimInstance Win32_Service | Where-Object {
    $_.PathName -match 'TeamCityAgentService|\\launcher\\' -and $_.Name -ne $ServiceName })
foreach ($o in $others) { Info "Не трогаю: служба $($o.Name) ($($o.State), запуск $($o.StartMode)): $($o.PathName)" }
if ($others | Where-Object { $_.StartMode -eq 'Disabled' }) {
  Warn 'Служба старого агента отключена. Если нужно вернуть старого агента сейчас:'
  foreach ($o in ($others | Where-Object { $_.StartMode -eq 'Disabled' })) {
    Info "  Set-Service $($o.Name) -StartupType Automatic; Start-Service $($o.Name)"
  }
}

Write-Host "`n== Что будет сделано =="
$steps = @()
if ($svc -and $svc.State -ne 'Stopped') { $steps += "Остановить службу $ServiceName" }
if ($procs) { $steps += "Завершить процессы нового агента ($($procs.Count))" }
if ($svc) { $steps += "Удалить службу $ServiceName (sc.exe delete)" }
if ($dirExists) { $steps += "Удалить папку $NewDir" }
if (-not $steps) { Write-Host "`nНовый агент не установлен - удалять нечего."; exit 0 }
for ($i = 0; $i -lt $steps.Count; $i++) { Info "$($i + 1). $($steps[$i])" }
Info 'Не меняется: старый агент, его папка, настройки и служба.'

if ($script:problems -gt 0) {
  Write-Host "`nЕсть пункты [НЕТ] ($($script:problems)) - ничего не изменено." -ForegroundColor Red
  exit 1
}
if ($Check) { Write-Host "`nРежим -Check: ничего не изменено."; exit 0 }
if (-not $Yes) {
  $a = Read-Host "`nУдалить нового агента? [y/N]"
  if ($a -notmatch '^[YyДд]') { Write-Host 'Отменено, ничего не изменено.'; exit 0 }
}

Write-Host "`n== Что сделано =="
try {
  if ($svc) {
    if ((Get-Service -Name $ServiceName).Status -ne 'Stopped') {
      Stop-Service -Name $ServiceName -Force
      (Get-Service -Name $ServiceName).WaitForStatus('Stopped', [TimeSpan]::FromMinutes(2))
    }
    Ok "Служба $ServiceName остановлена"
  }
  foreach ($p in (Get-DirProcesses $NewDir)) {
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    Ok "Завершён процесс $($p.Name) (PID $($p.ProcessId))"
  }
  if ($svc) {
    $out = & sc.exe delete $ServiceName 2>&1
    # 1072: already marked for deletion by an earlier run.
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 1072) { throw "sc.exe delete ${ServiceName}: $out" }
    for ($i = 0; $i -lt 20 -and (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 500 }
    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
      Warn "Служба $ServiceName помечена на удаление, но ещё видна: закройте окно services.msc (Службы) и диспетчер задач"
    } else { Ok "Служба $ServiceName удалена" }
  }
  if ($dirExists) {
    # Killed processes release their files with a delay: retry for up to ~30 s.
    for ($i = 1; $i -le 10; $i++) {
      Start-Sleep -Seconds 3
      try { Remove-Item -LiteralPath $NewDir -Recurse -Force -ErrorAction Stop; break }
      catch {
        if ($i -eq 10) {
          throw "папку $NewDir держит другой процесс ($($_.Exception.Message)). Закройте окна Проводника/консоли в этой папке, services.msc и диспетчер задач, либо перезагрузите сервер и запустите скрипт снова"
        }
        foreach ($p in (Get-DirProcesses $NewDir)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
      }
    }
    Ok "Папка $NewDir удалена"
  }
} catch {
  Bad "Остановлено на ошибке: $($_.Exception.Message)"
}

Write-Host "`n== Итог =="
if ($script:problems -eq 0) {
  Info 'Новый агент удалён. Можно запускать teamcity-agent-windows-migrate.ps1 заново.'
  Info 'Если новый агент успел зарегистрироваться, удалите его запись в новом TeamCity: Agents -> агент -> Remove.'
  exit 0
}
Info "Есть пункты [НЕТ] ($($script:problems)) - см. выше."
exit 1
