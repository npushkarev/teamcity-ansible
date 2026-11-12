<#
Helper for playbooks/62-teamcity-agents-windows.yml (Windows PowerShell 5.1, ASCII only).
Run:  powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File <this> -Action <A> [...]
Prints one JSON line (prefix 'TCJSON ') and exits: 0 ok, 3 busy (a build is running), 1 error.

Actions
  State     what is on the host: OS/PowerShell, old agent service(s), new agent, mode
  Probe     https probe of the new server the same way the migrate script does (TLS 1.2 on)
  Idle      wait until no build runs on the agent in -Dir (log markers + process tree)
  Repoint   point an installed new agent (-Dir) to -ServerUrl: certificates first, then
            buildAgent.properties (Latin-1, token dropped); the agent restarts itself after
            the current build (documented TeamCity behaviour); service restart only as fallback.
            Exit 0 only with proof of registration on that server; already pointed there -
            the log must show registration since the agent started, else (idle) restart + wait
  Wait      wait for 'Registered on server' in the agent log written after -Offset
  Rollback  return the new agent (-Dir) to -ServerUrl: newest buildAgent.properties.bak-repoint-*
            with that serverUrl (previous token inside) is put back when no build runs; service
            stop/start; exit 0 only after 'Registered on server', otherwise the file from before
            the rollback is put back
  SaveOld   save the old agent service state (rollback source) to -Out
  OldOff    verify the old agent is off: services stopped+disabled, no JVM, no scheduled task,
            no HKLM Run entry
Pure functions (properties, log parsing) are dot-source safe for tests: -Action None.
#>
[CmdletBinding()]
param(
  [ValidateSet('State', 'Probe', 'Idle', 'Repoint', 'Rollback', 'Wait', 'SaveOld', 'OldOff', 'None')]
  [string]$Action = 'None',
  [string]$Dir = 'C:\BuildAgent2026',
  [string]$OldDir = '',
  [string]$NewService = 'TCBuildAgent2026',
  [string]$ServerUrl = '',
  [string]$CertDir = '',
  [string]$Out = '',
  [long]$Offset = -1,
  [int]$WaitSec = 600
)
$ErrorActionPreference = 'Stop'
$script:Latin1 = [Text.Encoding]::GetEncoding(28591)
$script:BuildRe = ' - (Starting Build [{]id=[0-9]+|Build finished, build id [0-9]+|Build detached from agent, build id [0-9]+|Build agent started)'
$script:RegRe = 'Registered on server'
$script:TlsRe = 'PKIX|SSLHandshakeException|unable to find valid certification path|CertificateException'

function Emit($obj, [int]$code) {
  Write-Output ('TCJSON ' + ($obj | ConvertTo-Json -Compress -Depth 6))
  exit $code
}

# ---------------------------------------------------------------- properties (Latin-1)
function Get-PropLines([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return @() }
  return , [IO.File]::ReadAllLines($path, $script:Latin1)
}
function Test-PropKey([string]$line, [string]$key) {
  if ($line -match '^[ \t\f]*[#!]') { return $false }
  return $line -match ('^[ \t\f]*' + [regex]::Escape($key) + '[ \t\f]*([=:]|[ \t\f])')
}
function Get-PropValue([string[]]$lines, [string]$key) {
  # Java takes the LAST occurrence; unescape '\:' '\=' '\\'; trim.
  $v = $null
  foreach ($l in $lines) {
    if (Test-PropKey $l $key) {
      $m = [regex]::Match($l, '^[ \t\f]*[^=: \t\f]+[ \t\f]*[=:]?[ \t\f]*(.*)$')
      $v = $m.Groups[1].Value
    }
  }
  if ($null -eq $v) { return $null }
  return ($v -replace '\\:', ':' -replace '\\=', '=' -replace '\\\\', '\').Trim()
}
function Format-Url([string]$u) {
  if ($null -eq $u) { return '' }
  return $u.Trim().TrimEnd('/')
}
function Set-ServerUrlLines([string[]]$lines, [string]$url) {
  # All serverUrl lines -> one value; all authorizationToken lines removed (new server issues one).
  $out = New-Object System.Collections.Generic.List[string]
  $done = $false
  foreach ($l in $lines) {
    if (Test-PropKey $l 'authorizationToken') { continue }
    if (Test-PropKey $l 'serverUrl') {
      if (-not $done) { $out.Add("serverUrl=$url"); $done = $true }
      continue
    }
    $out.Add($l)
  }
  if (-not $done) { $out.Add("serverUrl=$url") }
  return , $out.ToArray()
}

function Find-RollbackBackup([string]$conf, [string]$url) {
  # Newest (names end with yyyyMMdd-HHmmss) buildAgent.properties.bak-repoint-* whose serverUrl is $url.
  $want = Format-Url $url
  $found = $null
  foreach ($b in @(Get-ChildItem -Path ($conf + '.bak-repoint-*') -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
    if ((Format-Url (Get-PropValue (Get-PropLines $b.FullName) 'serverUrl')) -ieq $want) { $found = $b.FullName }
  }
  return $found
}

# ---------------------------------------------------------------- logs
function Get-AgentLogs([string]$dir) {
  $r = @()
  foreach ($n in @('', '.1', '.2', '.3')) {
    $p = Join-Path $dir ('logs\teamcity-agent.log' + $n)
    if (Test-Path -LiteralPath $p) { $r += $p }
  }
  return , $r
}
function Get-LogBuildState([string[]]$lines) {
  # Last build marker decides: 'Starting Build' -> BUSY; finished/detached/agent started -> IDLE; none -> $null
  $last = $null
  foreach ($l in $lines) { if ($l -cmatch $script:BuildRe) { $last = $l } }
  if ($null -eq $last) { return $null }
  if ($last -clike '*Starting Build*') { return 'BUSY' }
  return 'IDLE'
}
function Get-LogState([string]$dir) {
  foreach ($p in (Get-AgentLogs $dir)) {
    $s = Get-LogBuildState ((Read-LogFrom $p 0) -split '\r?\n')
    if ($s) { return $s }
  }
  return 'IDLE'
}
function Get-LogRegLast([string[]]$lines) {
  # Last of 'Build agent started' / 'Registered on server' in these lines; none -> $null
  $last = $null
  foreach ($l in $lines) {
    if ($l -cmatch ' - Build agent started') { $last = 'STARTED' }
    elseif ($l -cmatch $script:RegRe) { $last = 'REGISTERED' }
  }
  return $last
}
function Get-LogRegState([string]$dir) {
  # Newest log file with a marker decides: REGISTERED = registered since the agent last started.
  foreach ($p in (Get-AgentLogs $dir)) {
    $s = Get-LogRegLast ((Read-LogFrom $p 0) -split '\r?\n')
    if ($s) { return $s }
  }
  return $null
}
function Read-LogFrom([string]$path, [long]$offset) {
  # Text written after $offset (whole file if it was rotated/truncated).
  if (-not (Test-Path -LiteralPath $path)) { return '' }
  # Shared read: the agent (log4j) keeps the file open for writing and renames it on rotation.
  $fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
  try {
    $len = $fs.Length
    if ($offset -lt 0 -or $offset -gt $len) { $offset = 0 }
    $null = $fs.Seek($offset, 'Begin')
    $buf = New-Object byte[] ($len - $offset)
    $read = 0
    while ($read -lt $buf.Length) {
      $n = $fs.Read($buf, $read, $buf.Length - $read)
      if ($n -le 0) { break }
      $read += $n
    }
    return $script:Latin1.GetString($buf, 0, $read)
  } finally { $fs.Dispose() }
}
function Get-LogLength([string]$dir) {
  $p = Join-Path $dir 'logs\teamcity-agent.log'
  if (Test-Path -LiteralPath $p) { return (Get-Item -LiteralPath $p).Length }
  return 0
}

# ---------------------------------------------------------------- processes and services (Windows only)
function Get-AgentJvms([string]$dir) {
  $d = $dir.TrimEnd('\') + '\'
  Get-CimInstance Win32_Process -Filter "Name='java.exe'" | Where-Object {
    $_.CommandLine -match 'jetbrains\.buildServer\.agent\.(AgentMain|Launcher)' -and
    ($_.CommandLine -like "*$d*" -or ($_.ExecutablePath -and $_.ExecutablePath.StartsWith($d, [StringComparison]::OrdinalIgnoreCase)))
  }
}
function Get-BuildChildren([string]$dir) {
  $jvms = @(Get-AgentJvms $dir)
  if (-not $jvms) { return @() }
  $ids = $jvms | ForEach-Object { $_.ProcessId }
  return @(Get-CimInstance Win32_Process | Where-Object {
      $ids -contains $_.ParentProcessId -and $_.Name -ne 'conhost.exe' -and
      -not ($_.CommandLine -match 'jetbrains\.buildServer\.agent\.(AgentMain|Launcher)')
    } | ForEach-Object { $_.ProcessId })
}
function Test-Busy([string]$dir) {
  # No agent JVM for this folder - no build (a 'Starting Build' marker may be left by a crash).
  if (@(Get-AgentJvms $dir).Count -eq 0) { return $null }
  if ((Get-LogState $dir) -eq 'BUSY') { return 'log: build started, not finished' }
  $a = Get-BuildChildren $dir
  if ($a.Count -eq 0) { return $null }
  Start-Sleep -Seconds 5
  $b = Get-BuildChildren $dir
  $both = @($a | Where-Object { $b -contains $_ })
  if ($both.Count -gt 0) { return "processes: $($both -join ',')" }
  return $null
}
function Get-AgentServices([string]$newService, [string]$newDir) {
  $nd = $newDir.TrimEnd('\') + '\'
  @(Get-CimInstance Win32_Service | Where-Object {
      $_.PathName -match 'TeamCityAgentService|\\launcher\\' -and $_.Name -ne $newService -and
      $_.PathName -notlike "*$nd*"
    } | ForEach-Object {
      $m = [regex]::Match([string]$_.PathName, '"?([A-Za-z]:\\.*?)\\launcher\\')
      [pscustomobject]@{
        name = $_.Name; state = $_.State; start_mode = $_.StartMode; start_name = $_.StartName
        dir = $(if ($m.Success) { $m.Groups[1].Value } else { '' }); path_name = $_.PathName
      }
    })
}
function Get-OldAutostart([string]$oldDir) {
  # Autostart of the old agent outside services: enabled scheduled tasks, HKLM Run values.
  # Unrolled output: callers collect it with @(...).
  $r = @()
  if (-not $oldDir) { return }
  $needle = Join-Path $oldDir.TrimEnd('\') 'bin\agent.bat'
  try {
    $r += @(Get-ScheduledTask | Where-Object { $_.State -ne 'Disabled' -and
        ($_.Actions | Where-Object { ("$($_.Execute) $($_.Arguments)") -like "*$needle*" }) } |
      ForEach-Object { 'task ' + $_.TaskPath + $_.TaskName })
  } catch { }
  $skip = @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider')
  foreach ($k in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run')) {
    $props = Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue
    if (-not $props) { continue }
    foreach ($pr in $props.PSObject.Properties) {
      if ($skip -contains $pr.Name) { continue }
      if ([string]$pr.Value -like "*$needle*") { $r += ('run ' + $k + '\' + $pr.Name) }
    }
  }
  return $r
}
function Test-SystemAccount([string]$name) {
  if (-not $name) { return $true }
  return @('LocalSystem', 'NT AUTHORITY\SYSTEM', 'NT AUTHORITY\LocalService', 'NT AUTHORITY\NetworkService') -contains $name
}
function Get-BuildNumber([string]$dir) {
  $f = Get-ChildItem -LiteralPath $dir -Filter 'BUILD_*' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($f -and $f.Name -match '^BUILD_(\d+)') { return [int]$Matches[1] }
  return 0
}
function Copy-Certs([string]$dir, [string]$certDir) {
  $t = Join-Path $dir 'conf\trustedCertificates'
  $null = New-Item -ItemType Directory -Force -Path $t
  $changed = $false
  foreach ($n in @('elara-ca.pem', 'teamcity-server.pem')) {
    $src = Join-Path $certDir $n
    if (-not (Test-Path -LiteralPath $src)) { continue }
    $dst = Join-Path $t $n
    if ((Test-Path -LiteralPath $dst) -and
      ((Get-FileHash -LiteralPath $src).Hash -eq (Get-FileHash -LiteralPath $dst).Hash)) { continue }
    Copy-Item -LiteralPath $src -Destination $dst -Force
    $changed = $true
  }
  return $changed
}

# ---------------------------------------------------------------- actions
if ($Action -eq 'None') { return }

try {
  switch ($Action) {
    'State' {
      $os = Get-CimInstance Win32_OperatingSystem
      $pol = @{}
      foreach ($e in (Get-ExecutionPolicy -List)) { $pol[[string]$e.Scope] = [string]$e.ExecutionPolicy }
      $svcs = @(Get-AgentServices $NewService $Dir)
      $old = $OldDir.TrimEnd('\')
      if (-not $old) {
        if ($svcs.Count -eq 1 -and $svcs[0].dir) { $old = $svcs[0].dir }
        elseif ($svcs.Count -eq 0 -and (Test-Path -LiteralPath 'C:\BuildAgent\conf\buildAgent.properties')) { $old = 'C:\BuildAgent' }
      }
      $oldSvc = $null
      if ($old) { $oldSvc = $svcs | Where-Object { $_.dir -and $_.dir.TrimEnd('\') -ieq $old } | Select-Object -First 1 }
      $oldLines = if ($old) { Get-PropLines (Join-Path $old 'conf\buildAgent.properties') } else { @() }
      $newConf = Join-Path $Dir 'conf\buildAgent.properties'
      $newLines = Get-PropLines $newConf
      $newUrl = Format-Url (Get-PropValue $newLines 'serverUrl')
      $newSvc = Get-CimInstance Win32_Service -Filter "Name='$NewService'"
      $mode = 'migrate'
      if (Test-Path -LiteralPath $newConf) {
        if ($newUrl -and $newUrl -ieq (Format-Url $ServerUrl)) { $mode = 'done' } else { $mode = 'repoint' }
      } elseif ((Test-Path -LiteralPath $Dir) -and (Get-ChildItem -LiteralPath $Dir -Force | Select-Object -First 1)) {
        $mode = 'broken'
      } elseif ($newSvc) { $mode = 'broken' }
      $free = (Get-PSDrive -Name ($Dir.Substring(0, 1))).Free
      $res = [ordered]@{
        ps = $PSVersionTable.PSVersion.ToString(); os = $os.Caption; build = $os.BuildNumber
        exec_policy = $pol; language_mode = [string]$ExecutionContext.SessionState.LanguageMode
        free_gb = [math]::Round($free / 1GB, 1)
        java_tool_options = [Environment]::GetEnvironmentVariable('JAVA_TOOL_OPTIONS', 'Machine')
        java_options = [Environment]::GetEnvironmentVariable('_JAVA_OPTIONS', 'Machine')
        old_services = $svcs; old_dir = $old
        old_conf = [bool]($old -and (Test-Path -LiteralPath (Join-Path $old 'conf\buildAgent.properties')))
        old_name = Get-PropValue $oldLines 'name'; old_server_url = Format-Url (Get-PropValue $oldLines 'serverUrl')
        old_build = $(if ($old) { Get-BuildNumber $old } else { 0 })
        old_service = $oldSvc
        old_autostart = @(Get-OldAutostart $old)
        old_system_account = Test-SystemAccount $(if ($oldSvc) { $oldSvc.start_name } else { '' })
        new_conf = [bool](Test-Path -LiteralPath $newConf); new_server_url = $newUrl
        new_name = Get-PropValue $newLines 'name'
        new_service = $(if ($newSvc) { [ordered]@{ state = $newSvc.State; start_mode = $newSvc.StartMode } } else { $null })
        mode = $mode
      }
      Emit $res 0
    }
    'Probe' {
      [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
      $code = 0; $status = 'OK'
      try {
        $r = Invoke-WebRequest -Uri ((Format-Url $ServerUrl) + '/login.html') -UseBasicParsing -TimeoutSec 15 -MaximumRedirection 0 -ErrorAction SilentlyContinue
        $code = [int]$r.StatusCode
      } catch {
        $resp = $_.Exception.Response
        if ($resp) { $code = [int]$resp.StatusCode } else {
          $status = if ($_.Exception.Status) { [string]$_.Exception.Status } else { $_.Exception.GetType().Name }
        }
      }
      Emit ([ordered]@{ code = $code; status = $status; tls = [string][Net.ServicePointManager]::SecurityProtocol }) $(if ($code -gt 0) { 0 } else { 1 })
    }
    'Idle' {
      $deadline = (Get-Date).AddSeconds($WaitSec)
      do {
        $why = Test-Busy $Dir
        if (-not $why) { Emit ([ordered]@{ state = 'IDLE' }) 0 }
        if ((Get-Date) -ge $deadline) { Emit ([ordered]@{ state = 'BUSY'; reason = $why }) 3 }
        Start-Sleep -Seconds 15
      } while ($true)
    }
    'Repoint' {
      $url = Format-Url $ServerUrl
      if (-not $url) { throw 'ServerUrl is empty' }
      $conf = Join-Path $Dir 'conf\buildAgent.properties'
      if (-not (Test-Path -LiteralPath $conf)) { throw "no $conf" }
      $log = Join-Path $Dir 'logs\teamcity-agent.log'
      $res = [ordered]@{ certs_changed = $false; changed = $false; backup = ''; restart = ''; registered = $false; tls_error = $false; offset = 0; service = '' }
      $svc = Get-CimInstance Win32_Service -Filter "Name='$NewService'"
      if (-not $svc) { $res.service = 'not found'; Emit $res 1 }
      $res.service = [string]$svc.State
      # 1) certificates first: the edit below makes the agent restart
      if ($CertDir) { $res.certs_changed = Copy-Certs $Dir $CertDir }
      if ($svc.StartMode -eq 'Disabled') {
        Set-Service -Name $NewService -StartupType Automatic
        $res.changed = $true; $res.service += ', startup Disabled -> Automatic'
      }
      $lines = Get-PropLines $conf
      $pids = @()
      if ((Format-Url (Get-PropValue $lines 'serverUrl')) -ieq $url) {
        # 2a) already pointed here: accept only with proof of registration since the agent started
        if ($svc.State -eq 'Running' -and (Get-LogRegState $Dir) -eq 'REGISTERED') {
          $res.registered = $true; $res.restart = 'not needed (registered)'; Emit $res 0
        }
        $why = Test-Busy $Dir
        if ($why) { $res.restart = "busy, no registration seen yet: $why"; Emit $res 3 }
        $res.offset = Get-LogLength $Dir
        if ($svc.State -eq 'Running') {
          Restart-Service -Name $NewService -Force; $res.restart = 'service restarted (no registration in the log)'
        } else {
          Start-Service -Name $NewService; $res.restart = 'service started'
        }
        $res.changed = $true
      } else {
        # 2b) wait until idle (the agent would also wait, but we want a predictable switch)
        $deadline = (Get-Date).AddSeconds($WaitSec)
        while ($why = Test-Busy $Dir) {
          if ((Get-Date) -ge $deadline) { $res.restart = "busy: $why"; Emit $res 3 }
          Start-Sleep -Seconds 15
        }
        # 3) backup + Latin-1 rewrite, read back
        $res.offset = Get-LogLength $Dir
        $pids = @(Get-AgentJvms $Dir | Where-Object { $_.CommandLine -match 'AgentMain' } | ForEach-Object { $_.ProcessId })
        $bak = $conf + '.bak-repoint-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item -LiteralPath $conf -Destination $bak
        [IO.File]::WriteAllLines($conf, [string[]](Set-ServerUrlLines $lines $url), $script:Latin1)
        $check = Get-PropLines $conf
        if ((Format-Url (Get-PropValue $check 'serverUrl')) -ine $url -or (Get-PropValue $check 'authorizationToken')) {
          Copy-Item -LiteralPath $bak -Destination $conf -Force
          throw 'buildAgent.properties was not written correctly - restored from backup'
        }
        $res.changed = $true; $res.backup = $bak
        if ((Get-Service -Name $NewService).Status -ne 'Running') { Start-Service -Name $NewService; $res.restart = 'service started' }
      }
      # 4) registration after the offset. The agent restarts itself on the change (TeamCity docs);
      #    fallback: service restart when no new agent JVM after 120 s and no build is running.
      $t0 = Get-Date; $tlsSeen = $null; $newJvm = $false
      while ($true) {
        $text = Read-LogFrom $log $res.offset
        if ($text -cmatch $script:RegRe) { $res.registered = $true; break }
        if ($text -match $script:TlsRe) {
          $res.tls_error = $true
          if (-not $tlsSeen) { $tlsSeen = Get-Date } elseif (((Get-Date) - $tlsSeen).TotalSeconds -ge 60) { break }
        }
        $now = @(Get-AgentJvms $Dir | Where-Object { $_.CommandLine -match 'AgentMain' } | ForEach-Object { $_.ProcessId })
        if (@($now | Where-Object { $pids -notcontains $_ }).Count -gt 0) { $newJvm = $true }
        if (-not $res.restart -and ((Get-Date) - $t0).TotalSeconds -ge 120 -and -not $newJvm -and -not (Test-Busy $Dir)) {
          Restart-Service -Name $NewService -Force; $res.restart = 'service restarted (agent did not restart itself)'
        }
        if (((Get-Date) - $t0).TotalSeconds -ge [math]::Max($WaitSec, 300)) { break }
        Start-Sleep -Seconds 10
      }
      if (-not $res.restart) {
        $res.restart = $(if ($res.registered -or $newJvm) { 'agent restarted itself' } else { 'no restart seen (agent busy or not detected)' })
      }
      Emit $res $(if ($res.registered) { 0 } else { 1 })
    }
    'Rollback' {
      $url = Format-Url $ServerUrl
      if (-not $url) { throw 'ServerUrl is empty' }
      $conf = Join-Path $Dir 'conf\buildAgent.properties'
      $log = Join-Path $Dir 'logs\teamcity-agent.log'
      $res = [ordered]@{ result = ''; backup = ''; saved = ''; registered = $false; restored = $false; tls_error = $false }
      if (-not (Test-Path -LiteralPath $conf)) { $res.result = 'nothing'; Emit $res 0 }
      if ((Format-Url (Get-PropValue (Get-PropLines $conf) 'serverUrl')) -ieq $url) { $res.result = 'already'; Emit $res 0 }
      $svc = Get-CimInstance Win32_Service -Filter "Name='$NewService'"
      if (-not $svc) { $res.result = "service $NewService not found"; Emit $res 1 }
      $bak = Find-RollbackBackup $conf $url
      if (-not $bak) { $res.result = 'no backup'; Emit $res 1 }
      $res.backup = $bak
      $deadline = (Get-Date).AddSeconds($WaitSec)
      while ($why = Test-Busy $Dir) {
        if ((Get-Date) -ge $deadline) { $res.result = "busy: $why"; Emit $res 3 }
        Start-Sleep -Seconds 15
      }
      if ($svc.StartMode -eq 'Disabled') { Set-Service -Name $NewService -StartupType Automatic }
      $saved = $conf + '.bak-rollback-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
      Copy-Item -LiteralPath $conf -Destination $saved
      $res.saved = $saved
      $offset = Get-LogLength $Dir
      # Stopped while the file is replaced: no self-restart of the agent in the middle.
      try {
        Stop-Service -Name $NewService -Force
        Copy-Item -LiteralPath $bak -Destination $conf -Force
        Start-Service -Name $NewService
      } catch {
        $err = [string]$_.Exception.Message
        try { Stop-Service -Name $NewService -Force -ErrorAction SilentlyContinue } catch { }
        Copy-Item -LiteralPath $saved -Destination $conf -Force
        try { Start-Service -Name $NewService } catch { }
        $res.restored = $true; $res.result = "service error: $err; file from before the rollback put back"
        Emit $res 1
      }
      $t0 = Get-Date; $tlsSeen = $null
      while ($true) {
        $text = Read-LogFrom $log $offset
        if ($text -cmatch $script:RegRe) { $res.registered = $true; break }
        if ($text -match $script:TlsRe) {
          $res.tls_error = $true
          if (-not $tlsSeen) { $tlsSeen = Get-Date } elseif (((Get-Date) - $tlsSeen).TotalSeconds -ge 60) { break }
        }
        if (((Get-Date) - $t0).TotalSeconds -ge [math]::Max($WaitSec, 300)) { break }
        Start-Sleep -Seconds 10
      }
      if ($res.registered) { $res.result = 'rolled back'; Emit $res 0 }
      Stop-Service -Name $NewService -Force
      Copy-Item -LiteralPath $saved -Destination $conf -Force
      Start-Service -Name $NewService
      $res.restored = $true; $res.result = 'not registered, file from before the rollback put back'
      Emit $res 1
    }
    'Wait' {
      $log = Join-Path $Dir 'logs\teamcity-agent.log'
      $res = [ordered]@{ registered = $false; tls_error = $false }
      $deadline = (Get-Date).AddSeconds($WaitSec); $tlsSeen = $null
      while ((Get-Date) -lt $deadline) {
        $text = Read-LogFrom $log $Offset
        if ($text -cmatch $script:RegRe) { $res.registered = $true; break }
        if ($text -match $script:TlsRe) {
          $res.tls_error = $true
          if (-not $tlsSeen) { $tlsSeen = Get-Date } elseif (((Get-Date) - $tlsSeen).TotalSeconds -ge 60) { break }
        }
        Start-Sleep -Seconds 10
      }
      Emit $res $(if ($res.registered) { 0 } else { 1 })
    }
    'SaveOld' {
      $svcs = @(Get-AgentServices $NewService $Dir | Where-Object { -not $OldDir -or ($_.dir -ieq $OldDir.TrimEnd('\')) })
      $state = foreach ($s in $svcs) {
        $delayed = $null
        try { $delayed = (Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$($s.name)" -Name DelayedAutostart -ErrorAction Stop).DelayedAutostart } catch { }
        [ordered]@{ name = $s.name; state = $s.state; start_mode = $s.start_mode; start_name = $s.start_name; delayed_autostart = $delayed; dir = $s.dir }
      }
      if ($Out -and -not (Test-Path -LiteralPath $Out)) {
        $state | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Out -Encoding ASCII
      }
      Emit ([ordered]@{ saved = [bool]$Out; services = @($state) }) 0
    }
    'OldOff' {
      $svcs = @(Get-AgentServices $NewService $Dir | Where-Object { -not $OldDir -or ($_.dir -ieq $OldDir.TrimEnd('\')) })
      $on = @($svcs | Where-Object { $_.state -ne 'Stopped' -or $_.start_mode -ne 'Disabled' } | ForEach-Object { $_.name })
      $jvm = @(); if ($OldDir) { $jvm = @(Get-AgentJvms $OldDir | ForEach-Object { $_.ProcessId }) }
      $auto = @(Get-OldAutostart $OldDir)
      $ok = ($on.Count -eq 0 -and $jvm.Count -eq 0 -and $auto.Count -eq 0)
      Emit ([ordered]@{ off = $ok; services_on = $on; jvm = $jvm; autostart = $auto }) $(if ($ok) { 0 } else { 1 })
    }
  }
} catch {
  Emit ([ordered]@{ error = [string]$_.Exception.Message; at = [string]$_.InvocationInfo.PositionMessage }) 1
}
