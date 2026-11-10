#!/usr/bin/env bash
# Switch off the OLD TeamCity build agent on Debian: stop it gracefully (after its current
# build, as its own user with its own Java) and switch its autostart off (systemd or SysV
# unit, cron and rc.local lines). The old agent's folder and settings are not changed, the
# new agent (teamcity-agent2026) is never touched; the script prints the commands that
# switch the old agent back on.
#
#   sudo bash teamcity-agent-linux-disable-old.sh --check
#   sudo bash teamcity-agent-linux-disable-old.sh
set -euo pipefail
umask 022

# ==== shared helpers: kept identical in teamcity-agent-linux-{migrate,disable-old,remove-new}.sh ====

# ---------------------------------------------------------------- output
problems=0
ok()   { printf '  [OK]   %s\n' "$*"; }
bad()  { printf '  [НЕТ]  %s\n' "$*"; problems=$((problems + 1)); }
fix()  { printf '  [НЕТ]  %s\n' "$*"; }  # Something this script does itself: not counted.
warn() { printf '  [ВНИМ] %s\n' "$*"; }
info() { printf '         %s\n' "$*"; }
die()  { printf 'ОШИБКА: %s\n' "$*" >&2; exit 1; }
section() { printf '\n== %s ==\n' "$*"; }
show() {  # show KEY VALUE: <скрыто> for password/token-like keys, else the value with credentials in it masked.
  local k=${1,,} v=$2 dots=''
  case $k in
    *pass*|*pwd*|*token*|*secret*|*key*|*credential*|*auth*) printf '<скрыто>'; return 0 ;;
  esac
  if [[ $v == *\\ ]]; then v=${v%\\} dots=...; fi
  printf '%s%s' "$(printf '%s\n' "$v" | mask)" "$dots"
}
mask() {  # Filter: hide tokens, passwords and URL credentials in log lines and environment values.
  LC_ALL=C sed -E \
    -e 's/[0-9A-Fa-f]{32,}/<скрыто>/g' \
    -e "s/(authorization token ')[^']*/\\1<скрыто>/g" \
    -e 's#(://)[^/@[:space:]]+@#\1<скрыто>@#g' \
    -e 's/([A-Za-z0-9_.-]*([Pp][Aa][Ss][Ss]|[Pp][Ww][Dd]|[Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Cc][Rr][Ee][Dd][Ee][Nn][Tt][Ii][Aa][Ll])[A-Za-z0-9_.-]*[=:][[:space:]]*)[^[:space:]]+/\1<скрыто>/g' \
    -e 's/([A-Za-z0-9_.-]*[Aa][Uu][Tt][Hh][A-Za-z0-9_.-]*=)[^[:space:]&]+/\1<скрыто>/g'
}
confirm() {  # confirm QUESTION: Enter, y or д = yes. Without a terminal --yes is required.
  local a=''
  [[ -t 0 ]] || { printf '\nНет терминала для подтверждения: добавьте --yes\n' >&2; exit 1; }
  read -r -p $'\n'"$1 [Y/n] " a || return 1
  case $a in ''|y|Y|yes|Yes|YES|д|Д|да|Да|ДА) return 0 ;; *) return 1 ;; esac
}
norm_url() {  # Server URL for comparison: no '\' escapes of .properties, no trailing '/'.
  local u=${1//\\/}
  while [[ $u == */ ]]; do u=${u%/}; done
  printf '%s\n' "$u"
}
safe_arg() {  # Paths and names given on the command line: no control characters (newlines...).
  [[ $2 != *[[:cntrl:]]* && -n $2 ]] || die "недопустимое значение $1"
}

# ---------------------------------------------------------------- .properties
# Java .properties: the key ends at the first '=', ':' or whitespace; '#'/'!' are
# comments; a trailing backslash continues the value. Bytes are kept (LC_ALL=C).
AWK_LIB='
  function k_of(s) { sub(/^[ \t\f]+/, "", s); return match(s, /^[^=: \t\f]+/) ? substr(s, 1, RLENGTH) : "" }
  function v_of(s) { sub(/^[ \t\f]+/, "", s); sub(/^[^=: \t\f]+[ \t\f]*/, "", s); sub(/^[=:][ \t\f]*/, "", s); return s }
  function skip(s) { return s ~ /^[ \t\f]*([#!]|$)/ }
'
prop() {  # prop FILE KEY: the value of KEY (the last active line wins), empty if absent.
  LC_ALL=C awk -v want="$2" "$AWK_LIB"'
    { sub(/\r$/, "") }
    !cont && !skip($0) && k_of($0) == want { v = v_of($0) }
    { cont = /\\$/ }
    END { print v }' "$1"
}
same_token() {  # same_token CONF1 CONF2: both have the same non-empty authorizationToken (never printed).
  local a b
  a=$(prop "$1" authorizationToken 2>/dev/null) || a=''
  b=$(prop "$2" authorizationToken 2>/dev/null) || b=''
  [[ -n $a && $a == "$b" ]]
}

# ---------------------------------------------------------------- /proc (no procps needed)
# One snapshot of all processes, read with bash builtins only. A process may exit
# between the glob and the read: such entries are skipped.
declare -A P_PPID=() P_START=() P_STATE=() P_COMM=() P_KIDS=()
ARGS=()
proc_scan() {
  P_PPID=() P_START=() P_STATE=() P_COMM=() P_KIDS=()
  local d pid s rest
  local -a f
  for d in /proc/[0-9]*; do
    pid=${d#/proc/} s=''
    { IFS= read -r -d '' s < "$d/stat"; } 2>/dev/null || true  # whole file: comm may contain a newline
    [[ $s == *') '* ]] || continue
    rest=${s##*) }               # fields after "(comm)"; comm itself may contain ") "
    read -r -a f <<< "$rest"     # f[0]=state f[1]=ppid f[19]=starttime
    s=${s#*\(}
    P_COMM[$pid]=${s%) *} P_STATE[$pid]=${f[0]} P_PPID[$pid]=${f[1]} P_START[$pid]=${f[19]}
    P_KIDS[${f[1]}]+=" $pid"
  done
}
proc_desc() {  # All descendants of the given PIDs (from the last proc_scan), one per line.
  local -A seen=()
  local -a todo=("$@")
  local p k
  while ((${#todo[@]})); do
    p=${todo[-1]}; unset 'todo[-1]'
    for k in ${P_KIDS[$p]-}; do
      [[ -z ${seen[$k]-} ]] || continue   # a cycle made by PID reuse during the scan
      seen[$k]=1; printf '%s\n' "$k"; todo+=("$k")
    done
  done
}
proc_args() {  # proc_args PID: its argv into ARGS; fails for an exited process or a kernel thread.
  ARGS=()
  { mapfile -d '' -t ARGS < "/proc/$1/cmdline"; } 2>/dev/null || return 1
  ((${#ARGS[@]} > 0))
}
proc_alive() {  # proc_alive PID STARTTIME: the same process still runs (not a reused PID, not a zombie).
  local s=''
  local -a f
  { IFS= read -r -d '' s < "/proc/$1/stat"; } 2>/dev/null || true
  [[ $s == *') '* ]] || return 1
  read -r -a f <<< "${s##*) }"
  [[ ${f[19]} == "$2" && ${f[0]} != Z ]]
}
proc_uid() {  # Real UID of PID $1.
  local k v rest
  while read -r k v rest; do
    if [[ $k == Uid: ]]; then printf '%s\n' "$v"; return 0; fi
  done < "/proc/$1/status" 2>/dev/null || return 1
  return 1
}
uid_name() { getent passwd "$1" | cut -d: -f1; }
proc_user() {  # User name of PID $1 (or its UID).
  local uid name
  uid=$(proc_uid "$1") || return 1
  name=$(uid_name "$uid") || name=''
  printf '%s\n' "${name:-$uid}"
}

# A TeamCity launcher or agent JVM: comm 'java' and the exact argument
# jetbrains.buildServer.agent.AgentMain (2018.1 and 2026.2). Build JVMs never have it:
# the Ant build JVM only has '-listener jetbrains.buildServer.agent.ant.TeamCityAntBuildListener'.
is_agent_jvm() {
  local comm='' a
  { read -r comm < "/proc/$1/comm"; } 2>/dev/null || return 1
  [[ $comm == java ]] || return 1
  proc_args "$1" || return 1
  for a in "${ARGS[@]}"; do
    if [[ $a == jetbrains.buildServer.agent.AgentMain ]]; then return 0; fi
  done
  return 1
}
jvm_role() {  # jvm_role PID: launcher, agent, check or other - the first jetbrains.buildServer.agent.* argument.
  local a
  proc_args "$1" || { echo other; return 0; }
  for a in "${ARGS[@]}"; do
    case $a in
      jetbrains.buildServer.agent.Launcher) echo launcher; return 0 ;;
      jetbrains.buildServer.agent.AgentMain) echo agent; return 0 ;;
      jetbrains.buildServer.agent.Check) echo check; return 0 ;;
      jetbrains.buildServer.agent.*) echo other; return 0 ;;
    esac
  done
  echo other
}
agent_jvm_dir() {  # Agent folder of agent JVM $1: its cwd <dir>/bin, else the absolute -classpath <dir>/lib/...
  # (cwd needs root on a real host). The launcher has only relative paths: it is attributed via its agent JVM.
  local cwd i a k
  cwd=$(readlink "/proc/$1/cwd" 2>/dev/null) || cwd=''
  if [[ $cwd == /*/bin ]]; then printf '%s\n' "${cwd%/bin}"; return 0; fi
  proc_args "$1" || return 1
  for ((i = 0; i + 1 < ${#ARGS[@]}; i++)); do
    [[ ${ARGS[i]} == -classpath || ${ARGS[i]} == -cp ]] || continue
    a=${ARGS[i+1]%%:*}
    if [[ $a == /*/lib/* ]]; then printf '%s\n' "${a%/lib/*}"; return 0; fi
  done
  for k in ${P_KIDS[$1]-}; do
    if is_agent_jvm "$k" && a=$(agent_jvm_dir "$k"); then printf '%s\n' "$a"; return 0; fi
  done
  return 1
}
# A process in a container sees other paths: its /proc/PID/cwd is the path inside the container.
# Such agent JVMs belong to container agents and are never attributed to a folder of this host.
MY_MNT=$(readlink /proc/$$/ns/mnt 2>/dev/null) || MY_MNT=''
same_mnt() {  # same_mnt PID: PID sees the same filesystem as this script (unknown = yes, the safer side).
  local m
  m=$(readlink "/proc/$1/ns/mnt" 2>/dev/null) || return 0
  [[ -z $MY_MNT || $m == "$MY_MNT" ]]
}
agent_jvms_all() {  # Every TeamCity agent JVM of this host, not in containers (from the last proc_scan).
  local pid
  for pid in "${!P_PPID[@]}"; do
    if [[ ${P_COMM[$pid]} == java ]] && same_mnt "$pid" && is_agent_jvm "$pid"; then printf '%s\n' "$pid"; fi
  done | sort -n
}
agent_jvms_container() {  # Agent JVMs in containers (other mount namespace): only listed, never touched.
  local pid
  for pid in "${!P_PPID[@]}"; do
    if [[ ${P_COMM[$pid]} == java ]] && ! same_mnt "$pid" && is_agent_jvm "$pid"; then printf '%s\n' "$pid"; fi
  done | sort -n
}
agent_jvms_in() {  # agent_jvms_in DIR: agent JVMs (launcher, agent, check) of the agent in DIR (canonical path).
  local pid d
  for pid in $(agent_jvms_all); do
    if d=$(agent_jvm_dir "$pid") && [[ $(realpath -m -- "$d") == "$1" ]]; then printf '%s\n' "$pid"; fi
  done
}
declare -A AG_PIDS=()
AG_UNKNOWN='' AG_CONTAINER=''
agents_scan() {  # All running agents: AG_PIDS[folder]="pids", AG_UNKNOWN = agent JVMs whose folder is unknown,
  # AG_CONTAINER = agent JVMs in containers.
  AG_PIDS=() AG_UNKNOWN='' AG_CONTAINER=''
  local pid d
  proc_scan
  AG_CONTAINER=$(agent_jvms_container | tr '\n' ' '); AG_CONTAINER=${AG_CONTAINER% }
  for pid in $(agent_jvms_all); do
    if d=$(agent_jvm_dir "$pid"); then
      d=$(realpath -m -- "$d"); AG_PIDS[$d]="${AG_PIDS[$d]-} $pid"; AG_PIDS[$d]=${AG_PIDS[$d]# }
    else
      AG_UNKNOWN="${AG_UNKNOWN} $pid"; AG_UNKNOWN=${AG_UNKNOWN# }
    fi
  done
}
build_pids() {  # build_pids PID...: descendants of these agent JVMs that are not agent JVMs = a build.
  local p
  (($# > 0)) || return 0
  proc_desc "$@" | while read -r p; do
    [[ ${P_STATE[$p]-} == Z ]] && continue   # exited, not yet reaped
    is_agent_jvm "$p" || printf '%s\n' "$p"
  done | sort -n
}
build_pids_stable() {  # Build processes seen in two snapshots 2 s apart (drops short helper runs).
  local -A first=()
  local p
  for p in $(build_pids "$@"); do first[$p]=${P_START[$p]}; done
  ((${#first[@]} > 0)) || return 0
  sleep 2; proc_scan
  for p in $(build_pids "$@"); do
    if [[ ${first[$p]-} == "${P_START[$p]-}" ]]; then printf '%s\n' "$p"; fi
  done
}
# Parts of a build run in the agent JVM itself, with no process under it: server-side checkout, artifact
# dependencies, publishing artifacts, the time between steps. The agent log shows them: 2018.1 and 2026.2
# agents write 'Starting Build {id=N, ...' when a build starts and 'Build finished, build id N' when it ends
# (2026.2 also 'Build detached from agent, build id N'); 'Build agent started' follows every agent start,
# so a build cut off by a crash or a kill does not count. Log files rotate: .1 is the newest older one.
BUILD_LOG_RE=' - (Starting Build [{]id=[0-9]+|Build finished, build id [0-9]+|Build detached from agent, build id [0-9]+|Build agent started)'
log_build() {  # log_build DIR: id of the build that the log of the agent in DIR shows as running (fails: none).
  local f l re='Starting Build [{]id=([0-9]+)'
  for f in "$1/logs/teamcity-agent.log" "$1/logs/teamcity-agent.log."{1,2,3}; do
    [[ -f $f && ! -L $f ]] || continue
    l=$(LC_ALL=C grep -aE -- "$BUILD_LOG_RE" "$f" 2>/dev/null | tail -n 1) || l=''
    [[ -n $l ]] || continue
    if [[ $l =~ $re ]]; then printf '%s\n' "${BASH_REMATCH[1]}"; return 0; fi
    return 1
  done
  return 1
}
BUSY=''
agent_busy() {  # agent_busy DIR PID...: 0 if the agent in DIR (these agent JVMs) runs a build; BUSY = what shows it:
  # build processes under the JVMs (seen in two snapshots) and/or a build its log shows as not finished.
  local dir=$1 b id
  shift
  BUSY=''
  b=$(build_pids_stable "$@" | tr '\n' ' ')
  # shellcheck disable=SC2086
  if [[ -n ${b// /} ]]; then BUSY=$(pid_list $b); fi
  if id=$(log_build "$dir"); then BUSY+="${BUSY:+; }сборка id ${id} по журналу агента"; fi
  [[ -n $BUSY ]]
}
pid_list() {  # pid_list PID...: "PID comm, PID comm" (never the arguments: build command lines carry secrets).
  local p out=''
  for p in "$@"; do out+="${out:+, }$p ${P_COMM[$p]-?}"; done
  printf '%s\n' "$out"
}
java_home_of() {  # Java home of JVM $1 (to pass as TEAMCITY_JRE to that agent's own agent.sh).
  local exe
  exe=$(readlink "/proc/$1/exe" 2>/dev/null) || exe=''
  exe=${exe% (deleted)}
  if [[ $exe != /*/bin/java ]] && proc_args "$1"; then exe=${ARGS[0]}; fi
  [[ $exe == /*/bin/java ]] || return 1
  printf '%s\n' "${exe%/bin/java}"
}
cgroup_of() {  # cgroup path of PID $1 (cgroup v2, or the name=systemd line of v1).
  local line
  while IFS= read -r line; do
    case $line in 0::*|*:name=systemd:*) printf '%s\n' "${line#*:*:}"; return 0 ;; esac
  done < "/proc/$1/cgroup" 2>/dev/null || return 1
  return 1
}
started_by() {  # How PID $1 was started: 'system UNIT', 'user UID UNIT', 'session ID' or 'other PATH'.
  local cg leaf u
  cg=$(cgroup_of "$1") || return 1
  leaf=${cg##*/}
  case $cg in
    */user@*.service/*) u=${cg#*/user@}; printf 'user %s %s\n' "${u%%.service/*}" "$leaf" ;;
    */session-*.scope) leaf=${leaf#session-}; printf 'session %s\n' "${leaf%.scope}" ;;
    */*.service) printf 'system %s\n' "$leaf" ;;
    *) printf 'other %s\n' "$cg" ;;
  esac
}
env_of() {  # env_of PID: NAME=VALUE entries of a running process, NUL-separated (root). Entries that cannot be
  # passed to env again are left out: exported functions (BASH_FUNC_x%%), odd names, values with a newline.
  local -a e
  local x
  { mapfile -d '' -t e < "/proc/$1/environ"; } 2>/dev/null || return 1
  ((${#e[@]} > 0)) || return 1
  for x in "${e[@]}"; do
    if [[ $x =~ ^[A-Za-z_][A-Za-z0-9_]*= && $x != *$'\n'* ]]; then printf '%s\0' "$x"; fi
  done
}
java_home_major() {  # java_home_major HOME: 8, 11, 21 ... from HOME/release (that java is never run); empty if unknown.
  local v
  v=$(sed -n 's/^JAVA_VERSION="\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "$1/release" 2>/dev/null | head -n 1) || v=''
  if [[ -z $v ]]; then
    if [[ -f $1/lib/rt.jar || -f $1/jre/lib/rt.jar ]]; then echo 8; fi   # Java 8 and older
    return 0
  fi
  if [[ $v == 1.* ]]; then v=${v#1.}; fi
  v=${v%%[!0-9]*}
  if [[ -n $v ]]; then printf '%s\n' "$v"; fi
}
build_of() {  # build_of DIR: the build number of the agent in DIR (its BUILD_<n> file), empty if none.
  local b
  for b in "$1"/BUILD_*; do
    if [[ -e $b && ${b##*/BUILD_} =~ ^[0-9]+$ ]]; then printf '%s\n' "${b##*/BUILD_}"; return 0; fi
  done
}
# Build numbers: the old 2018.1.3 agent is 58658, 2026.2 is 238924. Anything below this is not a new agent.
NEW_MIN_BUILD=200000

# ---------------------------------------------------------------- paths
canon() { realpath -m -- "$1"; }   # resolves symlinks; the path need not exist
path_has_link() {  # path_has_link PATH: PATH or one of its parent folders is a symbolic link ('x//', 'x/.' included).
  [[ $(realpath -s -m -- "$1") != "$(realpath -m -- "$1")" ]]
}
is_within() {  # is_within A B: A is B or inside B (canonical paths; '/' contains everything).
  local a b
  a=$(canon "$1") b=$(canon "$2")
  [[ $b == / || $a == "$b" || $a == "$b"/* ]]
}
home_hit() {  # home_hit DIR: "HOME (USER)" of a home directory that is DIR or lies inside DIR.
  local u h hc d
  d=$(canon "$1")
  while IFS=: read -r u _ _ _ _ h _; do
    [[ $h == /* && $h != / ]] || continue
    hc=$(canon "$h")
    if [[ $hc == "$d" || $hc == "$d"/* ]]; then printf '%s (%s)\n' "$hc" "$u"; return 0; fi
  done < <(getent passwd)
  return 1
}
protected_reason() {  # Why DIR must never be created into, chowned or deleted (fails if it may be).
  local d h
  d=$(canon "$1")
  if [[ $d == / ]]; then echo 'это корень /'; return 0; fi
  if [[ $d =~ ^/[^/]+$ ]]; then echo "это каталог верхнего уровня ${d}"; return 0; fi
  if h=$(home_hit "$d"); then
    if [[ ${h% (*} == "$d" ]]; then echo "это домашний каталог пользователя ${h##* }"; else echo "в нём домашний каталог ${h}"; fi
    return 0
  fi
  if [[ -d $d ]] && mountpoint -q -- "$d" 2>/dev/null; then echo 'это точка монтирования'; return 0; fi
  return 1
}
mounts_inside() {  # Mount points below DIR (findmnt escapes spaces as \x20).
  local d m
  d=$(canon "$1")
  findmnt -rn -o TARGET 2>/dev/null | while IFS= read -r m; do
    printf -v m '%b' "$m"
    if [[ $m == "$d"/* ]]; then printf '%s\n' "$m"; fi
  done
}
# Top-level names of a TeamCity agent folder: the 2026.2 zip, what the agent creates at run time,
# a bundled jre and the marker of teamcity-agent-linux-migrate.sh.
LAYOUT='bin conf contrib launcher launcher.latest lib plugins system logs temp tools work update backup jre README.md service.properties .teamcity-agent-linux-migrate'
foreign_entries() {  # Top-level entries of DIR that do not belong to a TeamCity agent folder.
  local e n
  for e in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    [[ -e $e || -L $e ]] || continue
    n=${e##*/}
    case " $LAYOUT " in *" $n "*) continue ;; esac
    if [[ $n == BUILD_* && $n != */* ]]; then continue; fi
    printf '%s\n' "$n"
  done
}

# ---------------------------------------------------------------- autostart detection
# A line belongs to an agent folder when it names the folder as a whole path (refs below), or when
# the agent.sh it starts resolves to the folder: through symlinks (/opt/buildAgent -> /srv/buildAgent),
# systemd specifiers (/opt/%i, expanded by systemctl show) or a small wrapper script it runs.
# Whole path: /opt/buildAgent matches '/opt/buildAgent/bin/agent.sh' and '"/opt/buildAgent"',
# but not /opt/buildAgent2026, /opt/buildAgent.old or /srv/opt/buildAgent.
AWK_REFS='
  function refs(s, d,   i, p, n, pre, post) {
    n = length(d); p = 0
    while ((i = index(substr(s, p + 1), d)) > 0) {
      p += i
      pre = p > 1 ? substr(s, p - 1, 1) : ""
      post = substr(s, p + n, 1)
      if (pre !~ /[[:alnum:]_.\/-]/ && post !~ /[[:alnum:]_.-]/) return 1
    }
    return 0
  }
'
OFF_MARK='#tcagent-off# '   # prefix of autostart lines switched off by these scripts
AGENT_SH_RE='(^|[^A-Za-z0-9_.-])agent\.sh([^A-Za-z0-9_.-]|$)'   # agent.sh as a file name (not start-agent.sh)
PATH_RE='/[^[:space:]"'\''`;|&<>()=$]+'                          # an absolute path in a command line
text_refs() {  # text_refs TEXT DIR: TEXT names DIR as a whole path.
  D=$2 LC_ALL=C awk "$AWK_REFS"'BEGIN { d = ENVIRON["D"] } refs($0, d) { f = 1 } END { exit !f }' <<< "$1"
}
dirs_in_text() {  # Agent folders named on stdin as '<dir>/bin/agent.sh' or 'cd <dir>/bin' (canonical).
  local d re="${PATH_RE}/bin/agent\\.sh|cd[[:space:]]+[\"']?${PATH_RE}/bin([[:space:]\"';&|)]|\$)"
  { LC_ALL=C grep -oE -- "$re" || true; } |
    sed -E -e '/^cd/{' -e 's#^cd[[:space:]]+["'\'']?##' -e 's#/bin[[:space:]"'\'';&|)]*$##' -e 'b' -e '}' -e 's#/bin/agent\.sh$##' |
    while IFS= read -r d; do
      if [[ $d != *%* ]]; then realpath -m -- "$d"; fi   # '/opt/%i' of a template unit: see unit_agent_dirs
    done | sort -u
}
wrappers_of() {  # wrappers_of TEXT: small text files TEXT runs by absolute path that mention agent.sh (wrapper scripts).
  local w
  local -a ws=()
  mapfile -t ws < <(LC_ALL=C grep -oE -- "$PATH_RE" <<< "$1" | sort -u)
  for w in "${ws[@]}"; do
    [[ $w != */bin/agent.sh && -f $w && -r $w ]] || continue
    (($(stat -c %s -- "$w" 2>/dev/null || echo 65536) < 65536)) || continue
    grep -Iq . -- "$w" 2>/dev/null || continue   # a text file, not a binary
    if LC_ALL=C grep -v '^[[:space:]]*#' -- "$w" 2>/dev/null | LC_ALL=C grep -qE -- "$AGENT_SH_RE"; then printf '%s\n' "$w"; fi
  done
}
line_dirs() {  # line_dirs TEXT: agent folders the command line TEXT starts, itself or through a wrapper script.
  local w
  {
    dirs_in_text <<< "$1"
    while IFS= read -r w; do
      { grep -v '^[[:space:]]*#' -- "$w" || true; } | dirs_in_text
    done < <(wrappers_of "$1")
  } | sort -u
}
line_runs_agent() {  # line_runs_agent TEXT: TEXT runs an agent.sh, itself or through a wrapper script.
  LC_ALL=C grep -qE -- "$AGENT_SH_RE" <<< "$1" || [[ -n $(wrappers_of "$1") ]]
}
active_lines() {  # active_lines FILE...: 'FILE:LINE:TEXT' of every line that is not empty and not a comment.
  local f
  local -a files=()
  for f in "$@"; do if [[ -f $f && -r $f ]]; then files+=("$f"); fi; done   # mawk stops at an unreadable file
  ((${#files[@]} > 0)) || return 0
  LC_ALL=C awk '{ sub(/\r$/, "") } $0 !~ /^[ \t]*[#;]/ && NF { print FILENAME ":" FNR ":" $0 }' "${files[@]}"
}
refs_dir() {  # refs_dir DIR FILE...: 'FILE:LINE:TEXT' of every active line naming DIR or running DIR/bin/agent.sh.
  local d=$1 l
  shift
  active_lines "$@" | while IFS= read -r l; do
    if text_refs "${l#*:*:}" "$d"; then printf '%s\n' "$l"
    elif [[ $l == *agent.sh* ]] && dirs_in_text <<< "${l#*:*:}" | grep -qFx -- "$d"; then printf '%s\n' "$l"
    fi
  done
}
off_refs() {  # off_refs DIR FILE...: 'FILE:LINE:TEXT' of lines switched off by these scripts that name or start DIR.
  local d=$1 f l t
  shift
  local -a files=()
  for f in "$@"; do if [[ -f $f && -r $f ]]; then files+=("$f"); fi; done
  ((${#files[@]} > 0)) || return 0
  M=$OFF_MARK LC_ALL=C awk 'BEGIN { m = ENVIRON["M"] } { sub(/\r$/, "") } index($0, m) == 1 { print FILENAME ":" FNR ":" $0 }' "${files[@]}" |
    while IFS= read -r l; do
      t=${l#*:*:}; t=${t#"$OFF_MARK"}
      if text_refs "$t" "$d" || line_dirs "$t" | grep -qFx -- "$d"; then printf '%s\n' "$l"; fi
    done
}
SYSTEMD_DIRS='/etc/systemd/system /run/systemd/system /usr/local/lib/systemd/system /usr/lib/systemd/system /lib/systemd/system'
unit_name_of_file() {  # .../x.service -> x.service; .../x.service.d/y.conf -> x.service
  local f=$1
  case $f in
    */*.d/*.conf) f=${f%/*}; f=${f##*/}; printf '%s\n' "${f%.d}" ;;
    *) printf '%s\n' "${f##*/}" ;;
  esac
}
unit_instances() {  # unit_instances x@.service: instances of a template unit (enabled or loaded).
  local t=${1%@.service} f
  for f in /etc/systemd/system/*.wants/"$t"@?*.service /etc/systemd/system/"$t"@?*.service; do
    if [[ -e $f || -L $f ]]; then printf '%s\n' "${f##*/}"; fi
  done
  systemctl list-units --all --no-legend --plain -- "$t@*.service" 2>/dev/null |
    LC_ALL=C awk '{ for (i = 1; i <= NF; i++) if ($i ~ /@.+\.service$/) { print $i; break } }'
}
unit_files_with() {  # unit_files_with TEXT...: unit names whose unit file or drop-in contains one of TEXT (templates
  # replaced by their instances), deduplicated. SysV scripts are listed as NAME.service.
  local d f n
  local -a e=()
  for f in "$@"; do e+=(-e "$f"); done
  {
    for d in $SYSTEMD_DIRS; do
      if [[ -d $d ]]; then grep -RlsF --include='*.service' --include='*.conf' "${e[@]}" -- "$d" 2>/dev/null || true; fi
    done | while IFS= read -r f; do
      n=$(unit_name_of_file "$f")
      if [[ $n == *@.service ]]; then unit_instances "$n"; else printf '%s\n' "$n"; fi
    done
    for f in /etc/init.d/*; do
      if [[ -f $f ]] && grep -qsF "${e[@]}" -- "$f"; then printf '%s.service\n' "${f##*/}"; fi
    done
  } | sort -u
}
unit_show() {  # unit_show UNIT PROPERTY: the value from systemctl show (empty if unknown).
  systemctl show -p "$2" --value -- "$1" 2>/dev/null || true
}
unit_enabled() {  # unit_enabled UNIT: enabled, disabled, static, masked... (empty if not found).
  local s
  s=$(systemctl is-enabled -- "$1" 2>/dev/null | tail -n 1) || true
  printf '%s\n' "${s:-not-found}"
}
unit_where() {  # unit_where UNIT: its SysV script, else its unit file.
  local f
  f=$(unit_show "$1" SourcePath); [[ -n $f ]] || f=$(unit_show "$1" FragmentPath)
  printf '%s\n' "$f"
}
unit_files() {  # Unit file, SysV script and drop-ins of UNIT, one per line.
  local f
  f=$(unit_show "$1" FragmentPath); [[ -z $f ]] || printf '%s\n' "$f"
  f=$(unit_show "$1" SourcePath); [[ -z $f ]] || printf '%s\n' "$f"
  for f in $(unit_show "$1" DropInPaths); do printf '%s\n' "$f"; done
}
unit_exec_paths() {  # Absolute paths in the ExecStart of UNIT (systemd specifiers such as %i expanded).
  systemctl show -p ExecStart --value -- "$1" 2>/dev/null | tr ' ;' '\n\n' |
    sed -n 's#^\(path=\|argv\[\]=\)\{0,1\}\(/.*\)#\2#p' | sort -u
}
unit_agent_dirs() {  # Agent folders UNIT starts: agent.sh lines of its files, its ExecStart, wrapper scripts there.
  local t
  local -a files=() toks=()
  mapfile -t files < <(unit_files "$1")
  mapfile -t toks < <(unit_exec_paths "$1")
  {
    if ((${#files[@]} > 0)); then
      { grep -hE 'agent\.sh' -- "${files[@]}" 2>/dev/null || true; } | { grep -v '^[[:space:]]*[#;]' || true; } | dirs_in_text
    fi
    for t in "${toks[@]}"; do
      if [[ $t == */bin/agent.sh ]]; then realpath -m -- "${t%/bin/agent.sh}"; fi
    done
    if ((${#toks[@]} > 0)); then line_dirs "${toks[*]}"; fi
  } | sort -u
}
unit_runs_agent() {  # unit_runs_agent UNIT: its files or the scripts in its ExecStart mention agent.sh.
  local -a files=()
  mapfile -t files < <(unit_files "$1")
  if ((${#files[@]} > 0)) && { grep -hv '^[[:space:]]*[#;]' -- "${files[@]}" 2>/dev/null || true; } | LC_ALL=C grep -qE -- "$AGENT_SH_RE"; then
    return 0
  fi
  [[ -n $(wrappers_of "$(unit_exec_paths "$1" | tr '\n' ' ')") ]]
}
unit_dir() {  # unit_dir UNIT: the (first) agent folder the unit starts.
  local d
  d=$(unit_agent_dirs "$1" | head -n 1)
  [[ -n $d ]] || return 1
  printf '%s\n' "$d"
}
unit_runs_dir() {  # unit_runs_dir UNIT DIR: UNIT starts DIR/bin/agent.sh, itself or through a script in its ExecStart.
  unit_agent_dirs "$1" | grep -qFx -- "$2"
}
unit_maybe_runs() {  # unit_maybe_runs UNIT DIR: UNIT starts DIR, or an agent.sh whose folder cannot be resolved
  # ('cd BuildAgent/bin; ./agent.sh start' of the JetBrains init.d example). Used for the unit DIR's JVM runs in.
  local ds
  ds=$(unit_agent_dirs "$1")
  if grep -qFx -- "$2" <<< "$ds"; then return 0; fi
  [[ -z $ds ]] && unit_runs_agent "$1"
}
system_units_for() {  # System units (and SysV scripts as NAME.service) that start DIR or whose files name DIR.
  local dir=$1 n f named
  unit_files_with "$dir" agent.sh | while IFS= read -r n; do
    named=''
    while IFS= read -r f; do
      if [[ -n $f && -n $(refs_dir "$dir" "$f") ]]; then named=1; break; fi
    done < <(unit_files "$n")
    if [[ -n $named ]] || unit_runs_dir "$n" "$dir"; then printf '%s\n' "$n"; fi
  done
}
cron_files() {  # Files cron starts commands from.
  local f
  for f in /var/spool/cron/crontabs/* /etc/crontab /etc/cron.d/*; do
    if [[ -f $f ]]; then printf '%s\n' "$f"; fi
  done
}
user_units_for() {  # 'USER UNIT' of systemd user units (~/.config/systemd/user) naming DIR.
  local dir=$1 u h f
  while IFS=: read -r u _ _ _ _ h _; do
    [[ $h == /* && -d $h/.config/systemd/user ]] || continue
    grep -rlsF --include='*.service' --include='*.conf' -e "$dir" -e agent.sh -- "$h/.config/systemd/user" 2>/dev/null |
      while IFS= read -r f; do
        if [[ -n $(refs_dir "$dir" "$f") ]]; then printf '%s %s\n' "$u" "$(unit_name_of_file "$f")"; fi
      done
  done < <(getent passwd) | sort -u
}
autostart_unknown() {  # 'KIND<TAB>NAME<TAB>TEXT' of enabled units and active cron/rc.local lines that run an agent.sh
  # whose folder cannot be resolved (relative path, variables): maybe the agent's autostart, maybe not.
  local n l t
  unit_files_with agent.sh | while IFS= read -r n; do
    [[ $(unit_enabled "$n") == enabled* ]] || continue
    if [[ -z $(unit_agent_dirs "$n") ]] && unit_runs_agent "$n"; then
      printf 'unit\t%s\t%s\n' "$n" "$(unit_where "$n")"
    fi
  done
  { cron_files; if [[ -f /etc/rc.local ]]; then echo /etc/rc.local; fi; } | while IFS= read -r n; do
    active_lines "$n" | while IFS= read -r l; do
      t=${l#*:*:}
      if line_runs_agent "$t" && [[ -z $(line_dirs "$t") ]]; then printf 'line\t%s\t%s\n' "$n" "$t"; fi
    done
  done
}
agent_dirs_referenced() {  # Agent folders started by any unit, init script, cron or rc.local line.
  local f n
  local -a files=()
  for f in /etc/init.d/* /etc/supervisor/supervisord.conf /etc/supervisor/conf.d/*; do
    if [[ -f $f ]]; then files+=("$f"); fi
  done
  {
    if ((${#files[@]} > 0)); then
      { grep -hv '^[[:space:]]*[#;]' -- "${files[@]}" 2>/dev/null || true; } | dirs_in_text
    fi
    { cron_files; if [[ -f /etc/rc.local ]]; then echo /etc/rc.local; fi; } | while IFS= read -r f; do
      active_lines "$f" | while IFS= read -r n; do line_dirs "${n#*:*:}"; done   # wrapper scripts too
    done
    unit_files_with agent.sh | while IFS= read -r n; do unit_agent_dirs "$n"; done
  } | sort -u
}
agent_dirs_on_disk() {  # Folders that look like a TeamCity agent: /opt, /srv, /usr/local, /var/lib, homes (and below).
  local d h
  local -a cand=(/opt/* /srv/* /usr/local/* /var/lib/*)
  while IFS=: read -r _ _ _ _ _ h _; do
    if [[ $h == /?* && -d $h ]]; then cand+=("$h" "$h"/*); fi
  done < <(getent passwd)
  for d in "${cand[@]}"; do
    if [[ -f $d/bin/agent.sh && -f $d/conf/buildAgent.properties ]]; then realpath -m -- "$d"; fi
  done 2>/dev/null | sort -u
}

# ---------------------------------------------------------------- graceful stop
# 'agent.sh stop' only asks the agent to exit when idle, at http://localhost:<port from
# logs/buildAgent.xmlRpcPort>. Without that file it falls back to port 9090 - which may be
# ANOTHER agent (verified: it stops the other one). So the request is sent only when the port
# file exists and its port is listened on by this agent's own JVMs.
agent_port() {  # agent_port DIR: XML-RPC port of the agent running from DIR.
  local line
  line=$(grep -m1 '^agentXmlRpc=' "$1/logs/buildAgent.xmlRpcPort" 2>/dev/null) || return 1
  line=${line##*:}; line=${line//[!0-9]/}
  [[ -n $line ]] && printf '%s\n' "$line"
}
port_inodes() {  # Inodes of the sockets listening on TCP port $1 (IPv4 and IPv6).
  local hex f l st inode rest
  printf -v hex ':%04X' "$1"
  for f in /proc/net/tcp /proc/net/tcp6; do
    [[ -r $f ]] || continue
    while read -r _ l _ st _ _ _ _ _ inode rest; do
      if [[ $st == 0A && $l == *"$hex" ]]; then printf '%s\n' "$inode"; fi
    done < "$f"
  done
}
socket_pids() {  # PIDs holding socket inode $1 (other users' processes: root only).
  { find /proc/[0-9]*/fd -lname "socket:\[$1\]" 2>/dev/null || true; } | cut -d/ -f3 | sort -un
}
port_owned_by() {  # port_owned_by PORT PID...: every socket listening on PORT belongs to one of the PIDs.
  local port=$1 i p found
  shift
  local -a inodes=()
  mapfile -t inodes < <(port_inodes "$port")
  ((${#inodes[@]} > 0)) || return 1
  for i in "${inodes[@]}"; do
    found=''
    for p in "$@"; do
      if [[ -n $(find "/proc/$p/fd" -lname "socket:\[$i\]" -print -quit 2>/dev/null) ]]; then found=1; break; fi
    done
    [[ -n $found ]] || return 1
  done
}
agent_cmd() {  # agent_cmd USER DIR JRE ARGS...: DIR/bin/agent.sh ARGS as USER with TEAMCITY_JRE=JRE.
  local u=$1 dir=$2 jre=$3
  shift 3
  (cd / && runuser -u "$u" -- env TEAMCITY_JRE="$jre" /bin/bash "$dir/bin/agent.sh" "$@")   # no env -C: Debian 9 has coreutils 8.26
}
STOP_WHY=''
agent_stop_request() {  # agent_stop_request DIR [force]: ask the agent running from DIR to stop.
  # 0 = sent, 1 = not running (nothing sent), 2 = not sent: unsafe or failed (reason in STOP_WHY).
  local dir=$1 jvms first u port='' jre out i
  local -a pids
  STOP_WHY=''
  proc_scan
  jvms=$(agent_jvms_in "$dir")
  [[ -n $jvms ]] || return 1
  mapfile -t pids <<< "$jvms"
  first=${pids[0]}
  u=$(proc_user "$first") || u=''
  if [[ -z $u || $u =~ ^[0-9]+$ ]]; then STOP_WHY="не удалось определить пользователя агента $dir (PID $first)"; return 2; fi
  jre=$(java_home_of "$first") || { STOP_WHY="не удалось определить Java агента $dir (PID $first)"; return 2; }
  for ((i = 0; i < 10; i++)); do   # the port file appears 5-8 s after a start
    if port=$(agent_port "$dir"); then break; fi
    sleep 2
  done
  if [[ -z $port ]]; then
    STOP_WHY="нет $dir/logs/buildAgent.xmlRpcPort - agent.sh stop ушёл бы на порт 9090, где может быть другой агент"
    return 2
  fi
  if ! port_owned_by "$port" "${pids[@]}"; then
    STOP_WHY="порт $port из $dir/logs/buildAgent.xmlRpcPort слушает не этот агент - команду остановки не отправляю"
    return 2
  fi
  if [[ $STOP_SENT != *" $dir "* ]]; then STOP_SENT+="$dir "; fi   # before sending: an interrupt may come any time
  if ! out=$(agent_cmd "$u" "$dir" "$jre" stop ${2:+"$2"} 2>&1); then
    STOP_WHY="agent.sh stop${2:+ $2} не прошла: $(printf '%s\n' "$out" | mask | tail -n 3 | tr '\n' ' ')"
    return 2
  fi
  return 0
}
wait_agent_gone() {  # wait_agent_gone DIR SECONDS [PID:START...]: 0 once no agent JVM of DIR and none of these processes is left.
  local dir=$1 left=$2 p busy n=0
  shift 2
  while :; do
    proc_scan
    busy=$(agent_jvms_in "$dir")
    for p in "$@"; do
      if proc_alive "${p%%:*}" "${p#*:}"; then busy+=" ${p%%:*}"; fi
    done
    [[ -n ${busy//[[:space:]]/} ]] || return 0
    ((left > 0)) || return 1
    if ((n > 0 && n % 60 == 0)); then info "ждём остановки агента ${dir}: ${n} с (доделывает сборку?)"; fi
    sleep 2; left=$((left - 2)); n=$((n + 2))
  done
}
signal_agent() {  # signal_agent DIR SIGNAL: the agent JVMs of DIR and every process under them.
  local p
  local -a pids=()
  proc_scan
  mapfile -t pids < <(agent_jvms_in "$1")
  [[ -n ${pids[0]-} ]] || return 0
  for p in "${pids[@]}" $(proc_desc "${pids[@]}"); do
    if proc_alive "$p" "${P_START[$p]-x}"; then kill -s "$2" "$p" 2>/dev/null || true; fi
  done
}
force_stop() {  # force_stop DIR: interrupt the agent of DIR and its build: stop force, after 60 s TERM, then KILL.
  local rc=0
  agent_stop_request "$1" force || rc=$?
  if ((rc == 0)); then
    ok "Агенту $1 отправлена команда agent.sh stop force"
    if wait_agent_gone "$1" 60; then return 0; fi
  fi
  warn "Агент $1 ещё работает - посылаю TERM его процессам"
  signal_agent "$1" TERM
  if wait_agent_gone "$1" 10; then return 0; fi
  signal_agent "$1" KILL
  wait_agent_gone "$1" 10
}

# A runtime drop-in for a unit whose agent is stopped by hand: no Restart= after the agent
# exits and no ExecStop on 'systemctl stop' (its agent.sh stop could stop another agent).
# It is in /run: gone after a reboot.
DROPIN_NAME=50-teamcity-agent-linux.conf
dropin_add() {
  local f="/run/systemd/system/$1.d/$DROPIN_NAME"
  mkdir -p -- "${f%/*}" &&
    printf '# teamcity-agent-linux-*.sh: the agent is stopped by hand (removed on reboot)\n[Service]\nRestart=no\nExecStop=\n' > "$f" &&
    systemctl daemon-reload
}
dropin_del() {
  local f="/run/systemd/system/$1.d/$DROPIN_NAME"
  [[ -e $f ]] || return 0
  rm -f -- "$f"
  rmdir -- "${f%/*}" 2>/dev/null || true
  systemctl daemon-reload
}

# ---------------------------------------------------------------- undo (migrate restores the old agent)
UNDO=()
undo_push() {  # undo_push DESCRIPTION COMMAND...: how to revert one step; undo_run runs them last first.
  local d=$1 c
  shift
  printf -v c '%q ' "$@"
  UNDO+=("$d"$'\x1f'"$c")
}
DRAINING=75   # exit code of the start helpers: the agent got 'agent.sh stop' and still finishes a build
undo_run() {
  local i d c out rc
  for ((i = ${#UNDO[@]} - 1; i >= 0; i--)); do
    d=${UNDO[i]%%$'\x1f'*} c=${UNDO[i]#*$'\x1f'} rc=0
    out=$(eval "$c" 2>&1) || rc=$?
    if ((rc == 0)); then
      ok "Возвращено: $d"
    elif ((rc == DRAINING)); then
      bad "Не возвращено сразу: $d - агент доделывает сборку и после неё остановится. Когда остановится, запустите его:"
      info "  $(tail -n 1 <<< "$out")"
    else
      bad "Не удалось вернуть: $d"
      printf '%s\n' "$out" | mask | tail -n 5 | sed 's/^/           /'
    fi
  done
  UNDO=()
}
STOP_SENT=' '   # folders that were sent 'agent.sh stop': it cannot be taken back
start_manual() {  # start_manual DIR USER JRE [NAME=VALUE...]: start the agent by hand as USER with that environment.
  local dir=$1 u=$2 jre=$3 e has='' extra=''
  shift 3
  proc_scan
  if [[ -n $(agent_jvms_in "$dir") ]]; then   # still running
    [[ $STOP_SENT == *" $dir "* ]] || return 0
    for e in "$@"; do case $e in JAVA_HOME=*|JRE_HOME=*) extra+=" $e" ;; esac; done
    printf 'sudo runuser -u %s -- env%s TEAMCITY_JRE=%s bash %s/bin/agent.sh start\n' "$u" "$extra" "$jre" "$dir"
    return "$DRAINING"
  fi
  for e in "$@"; do if [[ $e == TEAMCITY_JRE=* ]]; then has=1; fi; done
  if [[ -z $has ]]; then set -- "$@" "TEAMCITY_JRE=$jre"; fi
  (cd / && runuser -u "$u" -- env -i "$@" /bin/bash "$dir/bin/agent.sh" start)
}
unit_start_again() {  # unit_start_again UNIT DIR: start UNIT again unless its agent still runs.
  proc_scan
  if [[ -n $(agent_jvms_in "$2") ]]; then
    [[ $STOP_SENT == *" $2 "* ]] || return 0
    printf 'sudo systemctl restart %s\n' "${1%.service}"
    return "$DRAINING"
  fi
  if [[ $(unit_show "$1" ActiveState) == active ]]; then systemctl restart -- "$1"; else systemctl start -- "$1"; fi
}

# ---------------------------------------------------------------- autostart of one agent folder
# autostart_scan DIR [UNIT] fills one entry per mechanism (UNIT = the unit its running JVM is in):
#   unit      systemd unit or SysV script: AS_NAME=UNIT.service, AS_STATE=is-enabled, AS_ACT=ActiveState
#   crontab   user crontab (AS_NAME=user), cronfile (/etc/crontab, /etc/cron.d/*), rclocal (/etc/rc.local):
#             AS_STATE=on with AS_LINES = active lines starting DIR/bin/agent.sh, directly or through a
#             wrapper script (commented out to switch off), or AS_STATE=off with the lines these scripts
#             commented out earlier
#   shared    an active cron/rc.local line that starts this agent AND another one (not changed: [НЕТ])
#   unknown   an enabled unit or active line running an agent.sh whose folder cannot be resolved
#   other     references the scripts do not change (shown): supervisor, user units, other lines
AS_KIND=() AS_NAME=() AS_STATE=() AS_ACT=() AS_LINES=() AS_BACK=()
as_add() { AS_KIND+=("$1") AS_NAME+=("$2") AS_STATE+=("$3") AS_ACT+=("$4") AS_LINES+=("$5"); }
autostart_scan() {
  local dir=$1 cg=${2:-} u f kind name lines l t ds auto shared rest
  local -A seen=()
  AS_KIND=() AS_NAME=() AS_STATE=() AS_ACT=() AS_LINES=()
  case $cg in cron.service|rc-local.service|supervisor.service|supervisord.service) cg='' ;; esac
  while IFS= read -r u; do
    [[ -n $u && -z ${seen[$u]-} ]] || continue
    seen[$u]=1
    lines=$(unit_enabled "$u")
    [[ $lines != not-found ]] || continue
    # Only a unit that starts DIR/bin/agent.sh is the agent's: a unit that merely names the folder
    # (a backup job), or the unit of an SSH session the agent was started from, is left alone.
    # The unit the running agent is in counts when it starts an agent.sh it cannot resolve.
    if unit_runs_dir "$u" "$dir" || { [[ $u == "$cg" ]] && unit_maybe_runs "$u" "$dir"; }; then
      as_add unit "$u" "$lines" "$(unit_show "$u" ActiveState)" ''
    elif [[ $u != "$cg" ]]; then
      as_add other "служба $u" '' '' "$(unit_where "$u") - упоминает каталог, но не запускает из него agent.sh"
    fi
  done < <(system_units_for "$dir"; if [[ -n $cg ]]; then printf '%s\n' "$cg"; fi)
  while IFS= read -r f; do
    case $f in
      /var/spool/cron/crontabs/*) kind=crontab name=${f##*/} ;;
      /etc/rc.local) kind=rclocal name=$f ;;
      *) kind=cronfile name=$f ;;
    esac
    auto='' shared='' rest=''
    while IFS= read -r l; do
      t=${l#*:*:}
      ds=$(line_dirs "$t")
      if grep -qFx -- "$dir" <<< "$ds"; then
        if (($(grep -c . <<< "$ds") > 1)); then shared+="$l"$'\n'; else auto+="$l"$'\n'; fi
      elif text_refs "$t" "$dir"; then
        if [[ -z $ds ]] && LC_ALL=C grep -qE -- "$AGENT_SH_RE" <<< "$t"; then auto+="$l"$'\n'; else rest+="$l"$'\n'; fi
      fi
    done < <(active_lines "$f")
    if [[ -n $auto ]]; then as_add "$kind" "$name" on '' "${auto%$'\n'}"; fi
    if [[ -n $shared ]]; then as_add shared "$name" on "$kind" "${shared%$'\n'}"; fi
    if [[ -n $rest ]]; then as_add other "$f" '' '' "${rest%$'\n'}"; fi
    lines=$(off_refs "$dir" "$f")
    if [[ -n $lines ]]; then as_add "$kind" "$name" off '' "$lines"; fi
  done < <(cron_files; if [[ -f /etc/rc.local ]]; then echo /etc/rc.local; fi)
  lines=$(refs_dir "$dir" /etc/supervisor/supervisord.conf /etc/supervisor/conf.d/*)
  if [[ -n $lines ]]; then as_add other supervisor '' '' "$lines"; fi
  while read -r u f; do
    as_add other "user-unit $u $f" '' '' "~$u/.config/systemd/user/$f"
  done < <(user_units_for "$dir")
  while IFS=$'\t' read -r kind name t; do
    [[ -n $kind && -z ${seen[$name]-} ]] || continue
    as_add unknown "$name" "$kind" '' "$t"
  done < <(autostart_unknown)
}
autostart_running() {  # 0 if an entry would start the agent at boot (enabled unit, active cron/rc.local line).
  local i
  for ((i = 0; i < ${#AS_KIND[@]}; i++)); do
    case ${AS_KIND[i]}:${AS_STATE[i]} in
      unit:enabled|unit:enabled-runtime|crontab:on|cronfile:on|rclocal:on|shared:on) return 0 ;;
    esac
  done
  return 1
}
autostart_found() {  # 0 if the scan found the agent's own autostart (any state), not only unknown/other entries.
  local i
  for ((i = 0; i < ${#AS_KIND[@]}; i++)); do
    case ${AS_KIND[i]} in unit|crontab|cronfile|rclocal|shared) return 0 ;; esac
  done
  return 1
}
autostart_has_unknown() {
  local i
  for ((i = 0; i < ${#AS_KIND[@]}; i++)); do [[ ${AS_KIND[i]} != unknown ]] || return 0; done
  return 1
}
unit_state_ru() {  # Russian words for is-enabled / ActiveState.
  case $1 in
    enabled|enabled-runtime) printf 'автозапуск включён' ;;
    disabled) printf 'автозапуск выключен' ;;
    masked|masked-runtime) printf 'замаскирована' ;;
    *) printf 'состояние %s' "$1" ;;
  esac
}
autostart_show() {  # autostart_show WHAT [off]: list the entries; with 'off' the ones that cannot be switched off are [НЕТ].
  local what=$1 mode=${2:-} i l own=0
  if autostart_found; then own=1; fi
  for ((i = 0; i < ${#AS_KIND[@]}; i++)); do
    case ${AS_KIND[i]}:${AS_STATE[i]} in
      unit:enabled|unit:enabled-runtime|unit:disabled|unit:masked|unit:masked-runtime|unit:linked|unit:linked-runtime|unit:transient)
        info "Автозапуск ${what}: служба ${AS_NAME[i]} ($(unit_state_ru "${AS_STATE[i]}"), сейчас ${AS_ACT[i]:-?})" ;;
      unit:*)
        if [[ $mode == off ]]; then
          bad "Автозапуск ${what}: служба ${AS_NAME[i]} в состоянии ${AS_STATE[i]} - скрипт не умеет его отключать. Отключите вручную"
        else
          info "Автозапуск ${what}: служба ${AS_NAME[i]} (состояние ${AS_STATE[i]}, сейчас ${AS_ACT[i]:-?})"
        fi ;;
      crontab:on|cronfile:on|rclocal:on)
        info "Автозапуск ${what}: $([[ ${AS_KIND[i]} == crontab ]] && printf 'crontab пользователя %s' "${AS_NAME[i]}" || printf '%s' "${AS_NAME[i]}"):"
        while IFS= read -r l; do info "  ${l#*:*:}"; done <<< "${AS_LINES[i]}" ;;
      crontab:off|cronfile:off|rclocal:off)
        info "Выключено раньше этими скриптами ($([[ ${AS_KIND[i]} == crontab ]] && printf 'crontab %s' "${AS_NAME[i]}" || printf '%s' "${AS_NAME[i]}")):"
        while IFS= read -r l; do info "  ${l#*:*:}"; done <<< "${AS_LINES[i]}" ;;
      shared:*)
        l="Автозапуск ${what}: строка в $([[ ${AS_ACT[i]} == crontab ]] && printf 'crontab пользователя %s' "${AS_NAME[i]}" || printf '%s' "${AS_NAME[i]}") запускает и его, и другого агента - скрипт её не меняет"
        if [[ $mode == off ]]; then bad "${l}. Выключите в ней только этого агента вручную:"; else warn "$l:"; fi
        while IFS= read -r l; do info "  ${l#*:*:}"; done <<< "${AS_LINES[i]}" ;;
      unknown:*)
        l="Найден автозапуск agent.sh, каталог которого скрипт определить не может ($([[ ${AS_STATE[i]} == unit ]] && printf 'служба %s' "${AS_NAME[i]}" || printf '%s' "${AS_NAME[i]}"))"
        if [[ $mode == off ]] && ((own == 0)); then bad "${l}. Если это автозапуск ${what} - выключите его сами и запустите скрипт снова:"; else warn "${l}:"; fi
        info "  ${AS_LINES[i]}"
        if [[ ${AS_STATE[i]} == unit ]]; then info "  выключить: sudo systemctl disable ${AS_NAME[i]%.service}"; fi ;;
      other:*)
        if [[ $mode == off && ( ${AS_NAME[i]} == supervisor || ${AS_NAME[i]} == user-unit* ) ]]; then
          bad "Автозапуск ${what}: через ${AS_NAME[i]%% *} - скрипт его не отключает. Отключите вручную:"
        else
          warn "Упоминание каталога ${what} (скрипт это не меняет, проверьте сами):"
        fi
        while IFS= read -r l; do info "  $l"; done <<< "${AS_LINES[i]}" ;;
    esac
  done
}
AS_RESTART=''   # set while the agent still finishes a build: its unit stays "active" after it exits
unit_back_cmd() {  # The command that switches unit $1 back on and starts it ('enable --now' does not start a SysV script).
  local n=${1%.service}
  if [[ -n $AS_RESTART ]]; then
    printf 'sudo systemctl enable %s; sudo systemctl restart %s\n' "$n" "$n"
  elif [[ -n $(unit_show "$1" SourcePath) ]]; then
    printf 'sudo systemctl enable %s; sudo systemctl start %s\n' "$n" "$n"
  else
    printf 'sudo systemctl enable --now %s\n' "$n"
  fi
}
BK_DIR=/var/backups/teamcity-agent-linux
backup_file() {  # backup_file NAME: path for a new backup file in BK_DIR (mode 700).
  install -d -m 700 -- "$BK_DIR" && printf '%s/%s.%s\n' "$BK_DIR" "$1" "$(date +%Y%m%d-%H%M%S)"
}
comment_out() {  # comment_out LINES: stdin -> stdout; active lines whose text is one of LINES ('FILE:N:TEXT') get OFF_MARK.
  L=$1 M=$OFF_MARK LC_ALL=C awk '
    BEGIN { m = ENVIRON["M"]; n = split(ENVIRON["L"], a, "\n")
            for (i = 1; i <= n; i++) { t = a[i]; if (sub(/^[^:]*:[0-9]+:/, "", t)) want[t] = 1 } }
    { line = $0; sub(/\r$/, "", line) }
    (line in want) && line !~ /^[ \t]*[#;]/ { $0 = m $0 }
    { print }'
}
autostart_off() {  # autostart_off DIR: switch off every entry that starts the agent (prints, pushes undo, sets AS_BACK).
  local dir=$1 i n f bk tmp sh now
  AS_BACK=()
  for ((i = 0; i < ${#AS_KIND[@]}; i++)); do
    n=${AS_NAME[i]}
    case ${AS_KIND[i]}:${AS_STATE[i]} in
      unit:enabled|unit:enabled-runtime)
        if [[ ${AS_STATE[i]} == enabled ]]; then f=''; else f=--runtime; fi
        if systemctl disable ${f:+"$f"} -- "$n" >/dev/null 2>&1 && [[ $(unit_enabled "$n") != enabled* ]]; then
          ok "Автозапуск службы $n выключен"
          undo_push "автозапуск службы $n" systemctl enable ${f:+"$f"} -- "$n"
          if [[ ${AS_ACT[i]} == active ]]; then   # may stay "active (exited)": a plain start would do nothing
            AS_BACK+=("$(AS_RESTART=1 unit_back_cmd "$n")")
          else
            AS_BACK+=("$(unit_back_cmd "$n")")
          fi
        else
          bad "Не удалось выключить автозапуск службы $n: systemctl disable $n"; return 1
        fi ;;
      crontab:on)
        bk=$(backup_file "crontab-$n") || { bad "Не удалось создать каталог $BK_DIR"; return 1; }
        if crontab -u "$n" -l > "$bk" 2>/dev/null &&
           comment_out "${AS_LINES[i]}" < "$bk" | crontab -u "$n" - && now=$(crontab -u "$n" -l 2>/dev/null) &&
           [[ $(comment_out "${AS_LINES[i]}" <<< "$now") == "$now" && $now != "$(cat -- "$bk")" ]]; then
          ok "Строки автозапуска в crontab пользователя $n закомментированы (копия: $bk)"
          undo_push "crontab пользователя $n" crontab -u "$n" "$bk"
          AS_BACK+=("sudo crontab -u $n $bk")
        else
          bad "Не удалось изменить crontab пользователя $n"; return 1
        fi ;;
      cronfile:on|rclocal:on)
        bk=$(backup_file "${n//\//_}") || { bad "Не удалось создать каталог $BK_DIR"; return 1; }
        tmp=$(mktemp) || return 1
        cp -p -- "$n" "$bk" && comment_out "${AS_LINES[i]}" < "$n" > "$tmp" || { rm -f -- "$tmp"; bad "Не удалось прочитать $n"; return 1; }
        if [[ ${AS_KIND[i]} == rclocal ]]; then
          sh='sh'; if head -n 1 "$n" | grep -q bash; then sh=bash; fi
          if ! "$sh" -n "$tmp" 2>/dev/null; then
            rm -f -- "$tmp"
            bad "Если закомментировать строки агента в $n, сломается синтаксис файла - не меняю. Отключите вручную:"
            while IFS= read -r f; do info "  ${f#*:*:}"; done <<< "${AS_LINES[i]}"
            return 1
          fi
        fi
        if cat "$tmp" > "$n" && [[ $(comment_out "${AS_LINES[i]}" < "$n") == "$(cat -- "$n")" ]]; then
          rm -f -- "$tmp"
          ok "Строки автозапуска в $n закомментированы (копия: $bk)"
          undo_push "$n" cp -p -- "$bk" "$n"
          AS_BACK+=("sudo cp -p $bk $n")
        else
          rm -f -- "$tmp"; bad "Не удалось записать $n"; return 1
        fi ;;
    esac
  done
  return 0
}
line_key() {  # line_key TEXT: what names the agent in an autostart line: <dir>/bin/agent.sh, the folder of 'cd <dir>/bin', or the wrapper.
  local k
  k=$(LC_ALL=C grep -oE -- "${PATH_RE}/bin/agent\\.sh" <<< "$1" | head -n 1) || k=''
  if [[ -z $k ]]; then k=$(LC_ALL=C grep -oE -- "cd[[:space:]]+[\"']?${PATH_RE}" <<< "$1" | head -n 1 | sed -E "s#^cd[[:space:]]+[\"']?##") || k=''; fi
  if [[ -z $k ]]; then k=$(wrappers_of "$1" | head -n 1) || k=''; fi
  if [[ -z $k ]]; then k=$(LC_ALL=C grep -oE -- "$PATH_RE" <<< "$1" | head -n 1) || k=''; fi
  printf '%s\n' "$k"
}
off_sed() {  # off_sed LINES: sed arguments that switch back on only these lines (by what names the agent in them).
  local l k out=''
  local -A done_k=()
  while IFS= read -r l; do
    l=${l#*:*:}; l=${l#"$OFF_MARK"}
    k=$(line_key "$l")
    [[ -n $k && -z ${done_k[$k]-} ]] || continue
    done_k[$k]=1
    k=$(sed 's/[].[*^$\\|]/\\&/g' <<< "$k")
    out+="${out:+ }-e '\\|^${OFF_MARK}.*${k}|s|^${OFF_MARK}||'"
  done <<< "$1"
  printf '%s\n' "$out"
}
autostart_back_cmds() {  # Commands that switch the autostart found by autostart_scan back on (one per line).
  local i n r e
  for ((i = 0; i < ${#AS_KIND[@]}; i++)); do
    n=${AS_NAME[i]} r=$AS_RESTART
    if [[ ${AS_ACT[i]} == active ]]; then r=1; fi   # "active (exited)" with the agent gone: start would do nothing
    case ${AS_KIND[i]}:${AS_STATE[i]} in
      unit:disabled) AS_RESTART=$r unit_back_cmd "$n" ;;
      unit:masked|unit:masked-runtime) printf 'sudo systemctl unmask %s; ' "${n%.service}"; AS_RESTART=$r unit_back_cmd "$n" ;;
      crontab:off) e=$(off_sed "${AS_LINES[i]}"); printf 'sudo crontab -u %s -l | sed %s | sudo crontab -u %s -\n' "$n" "$e" "$n" ;;
      cronfile:off|rclocal:off) e=$(off_sed "${AS_LINES[i]}"); printf 'sudo sed -i %s %s\n' "$e" "$n" ;;
    esac
  done
}

# ---------------------------------------------------------------- one agent: how it runs, graceful stop
RUN_PIDS='' RUN_LAUNCHER='' RUN_USER='' RUN_JRE='' RUN_HOW='' RUN_UNIT=''
RUN_ENV=()
agent_runinfo() {  # agent_runinfo DIR: RUN_* = how the agent in DIR runs now (RUN_PIDS empty: not running).
  local p how
  RUN_PIDS='' RUN_LAUNCHER='' RUN_USER='' RUN_JRE='' RUN_HOW='' RUN_UNIT='' RUN_ENV=()
  proc_scan
  RUN_PIDS=$(agent_jvms_in "$1" | tr '\n' ' ') || RUN_PIDS=''
  RUN_PIDS=${RUN_PIDS% }
  [[ -n $RUN_PIDS ]] || return 0
  RUN_LAUNCHER=${RUN_PIDS%% *}
  for p in $RUN_PIDS; do
    if [[ $(jvm_role "$p") == launcher ]]; then RUN_LAUNCHER=$p; break; fi
  done
  RUN_USER=$(proc_user "$RUN_LAUNCHER") || RUN_USER=''
  RUN_JRE=$(java_home_of "$RUN_LAUNCHER") || RUN_JRE=''
  mapfile -d '' -t RUN_ENV < <(env_of "$RUN_LAUNCHER" || true)
  how=$(started_by "$RUN_LAUNCHER") || how=''
  RUN_HOW=$how
  if [[ $how == system\ * ]]; then
    RUN_UNIT=${how#system }
    # A process in the cgroup of a unit that does not start the agent (e.g. ssh.service on a host
    # without pam_systemd) was started by hand from there: that unit is not the agent's.
    case $RUN_UNIT in
      cron.service|rc-local.service) ;;
      *) if ! unit_maybe_runs "$RUN_UNIT" "$1"; then RUN_HOW="in $RUN_UNIT" RUN_UNIT=''; fi ;;
    esac
  fi
  return 0
}
run_how_ru() {  # Russian description of RUN_HOW.
  case $RUN_HOW in
    'system cron.service') printf 'запущен из cron' ;;
    'system rc-local.service') printf 'запущен из /etc/rc.local' ;;
    system\ *) printf 'запущен службой %s' "${RUN_HOW#system }" ;;
    in\ *) printf 'запущен вручную (процесс в службе %s)' "${RUN_HOW#in }" ;;
    user\ *) printf 'запущен пользовательской службой systemd %s' "${RUN_HOW##* }" ;;
    session\ *) printf 'запущен вручную (сеанс %s)' "${RUN_HOW#session }" ;;
    *) printf 'запущен вручную' ;;
  esac
}
autostart_missing() {  # autostart_missing DIR MODE: after agent_runinfo/autostart_show - nothing found that starts the
  # running agent. From cron or rc.local: the line was not found ([НЕТ] with MODE off); by hand: it does not come back.
  [[ -n $RUN_PIDS ]] || return 0
  if autostart_running || autostart_found; then return 0; fi
  case $RUN_HOW in
    'system cron.service'|'system rc-local.service')
      if [[ $2 == off ]]; then
        bad "Агент $1 $(run_how_ru), но строка автозапуска не найдена - выключите её сами и запустите скрипт снова"
      else
        warn "Агент $1 $(run_how_ru), но строка автозапуска не найдена"
      fi
      info "  Где искать: sudo crontab -u ${RUN_USER:-<пользователь>} -l; /etc/crontab; /etc/cron.d; /etc/rc.local" ;;
    *)
      if ! autostart_has_unknown; then
        warn "Автозапуск агента $1 не найден - похоже, он $(run_how_ru) (после перезагрузки сам не запустится)"
      fi ;;
  esac
}
start_cmd() {  # start_cmd DIR USER JRE: the command that starts that agent by hand (to print).
  local e extra=''
  for e in "${RUN_ENV[@]}"; do
    case $e in JAVA_HOME=*|JRE_HOME=*) extra+=" $e" ;; esac
  done
  printf 'sudo runuser -u %s -- env%s TEAMCITY_JRE=%s bash %s/bin/agent.sh start\n' "$2" "$extra" "$3" "$1"
}
stop_agent() {  # stop_agent DIR WAIT FORCE [UNIT]: graceful stop of the agent in DIR (after agent_runinfo, autostart_scan).
  # 'agent.sh stop' cannot be taken back, so without FORCE it is sent only once two checks in a row
  # (2-4 s apart) see no build: neither build processes nor a build the agent log shows as not finished.
  # 0 = stopped (or was not running); 1 = failed (printed); 3 = a build still runs after WAIT seconds and
  # nothing was sent or changed; 4 = sent, but a build started meanwhile and still runs after WAIT seconds:
  # the agent exits after it (the runtime drop-in stays so that its unit does not restart it).
  # Pushes the undo that starts it again as before (through UNIT if given, else through its active units,
  # else by hand with its old environment).
  local dir=$1 wait_s=$2 force=$3 again=${4:-} i u rc=0 p n0 n1 t0 next=0 idle=0
  local -a units=() snap=()
  [[ -n $RUN_PIDS ]] || return 0
  if [[ $force != 1 ]]; then
    t0=$SECONDS
    while :; do
      proc_scan
      p=$(agent_jvms_in "$dir" | tr '\n' ' ')
      [[ -n ${p// /} ]] || break   # it exited by itself
      # shellcheck disable=SC2086
      if ! agent_busy "$dir" $p; then
        idle=$((idle + 1))
        if ((idle >= 2)); then break; fi   # no build in two checks in a row
        sleep 2; continue
      fi
      idle=0
      if ((SECONDS - t0 >= wait_s)); then return 3; fi
      if ((SECONDS - t0 >= next)); then
        if ((next == 0)); then
          info "На агенте $dir идёт сборка (${BUSY}) - жду её окончания (до ${wait_s} с), команду остановки пока не отправляю"
        else
          info "ждём окончания сборки на агенте ${dir}: $((SECONDS - t0)) с"
        fi
        next=$((next + 60))
      fi
      sleep 3
    done
    wait_s=$((wait_s - (SECONDS - t0)))
    if ((wait_s < 60)); then wait_s=60; fi
  fi
  for ((i = 0; i < ${#AS_KIND[@]}; i++)); do
    if [[ ${AS_KIND[i]} == unit && ${AS_ACT[i]} == active ]]; then units+=("${AS_NAME[i]}"); fi
  done
  n0=${#UNDO[@]}
  for u in "${units[@]}"; do
    if ! dropin_add "$u"; then bad "Не удалось добавить временную настройку службе $u (/run/systemd/system/$u.d)"; return 1; fi
    undo_push "служба $u: прежние настройки" dropin_del "$u"
  done
  n1=${#UNDO[@]}
  if [[ -n $again ]]; then
    undo_push "запуск агента $dir (служба $again)" unit_start_again "$again" "$dir"
  elif ((${#units[@]} > 0)); then
    for u in "${units[@]}"; do undo_push "запуск агента $dir (служба $u)" unit_start_again "$u" "$dir"; done
  else
    undo_push "запуск агента $dir (как раньше, от $RUN_USER)" start_manual "$dir" "$RUN_USER" "$RUN_JRE" "${RUN_ENV[@]}"
  fi
  proc_scan
  # shellcheck disable=SC2046
  for p in $(build_pids $(agent_jvms_in "$dir")); do snap+=("$p:${P_START[$p]}"); done
  agent_stop_request "$dir" || rc=$?
  if ((rc == 0)); then
    ok "Агенту $dir отправлена команда штатной остановки (agent.sh stop от $RUN_USER, Java $RUN_JRE)"
    if ((${#snap[@]} > 0)) || log_build "$dir" >/dev/null; then
      if [[ $force == 1 ]]; then
        info "На агенте идёт сборка - --force: жду до ${wait_s} с, потом прерываю её"
      else
        info "Как раз началась сборка - агент остановится после неё (жду до ${wait_s} с)"
      fi
    fi
  elif ((rc == 2)); then
    if [[ $force != 1 ]]; then
      UNDO=("${UNDO[@]:0:n0}")   # nothing was sent: no need to start it again or to keep the drop-ins
      for u in "${units[@]}"; do dropin_del "$u" || true; done
      bad "Агент $dir не остановлен: $STOP_WHY"; return 1
    fi
    warn "$STOP_WHY - --force: завершаю процессы агента"
  fi
  if ((rc != 2)) && wait_agent_gone "$dir" "$wait_s" "${snap[@]}"; then
    ok "Агент $dir остановлен"
  elif [[ $force != 1 ]]; then
    return 4
  else
    warn "--force: прерываю агента $dir и его сборку"
    if ! force_stop "$dir"; then bad "Агент $dir не остановился даже после KILL"; return 1; fi
    ok "Агент $dir остановлен (сборка прервана)"
  fi
  for u in "${units[@]}"; do
    if systemctl stop -- "$u" 2>/dev/null; then ok "Служба $u остановлена"; else warn "systemctl stop $u не прошла"; fi
    dropin_del "$u" || true   # the agent is gone: the unit gets its own Restart=/ExecStop back
  done
  UNDO=("${UNDO[@]:0:n0}" "${UNDO[@]:n1}")   # those drop-ins are removed already
  return 0
}
dropin_cleanup_cmds() {  # Commands that remove the runtime drop-ins left on the units of a draining agent.
  local i
  for ((i = 0; i < ${#AS_KIND[@]}; i++)); do
    if [[ ${AS_KIND[i]} == unit && -e /run/systemd/system/${AS_NAME[i]}.d/$DROPIN_NAME ]]; then
      printf 'sudo rm /run/systemd/system/%s.d/%s; sudo systemctl daemon-reload\n' "${AS_NAME[i]}" "$DROPIN_NAME"
    fi
  done
}
# ==== end of shared helpers ====

[[ ${BASH_SOURCE[0]} == "$0" ]] || return 0   # sourced by the tests: helpers only

SCRIPT=teamcity-agent-linux-disable-old.sh
usage() {
  cat >&2 <<'EOF'
Использование: sudo bash teamcity-agent-linux-disable-old.sh [параметры]
  --check          только показать состояние и план; ничего не менять
  --yes            не спрашивать подтверждение
  --old-dir DIR    каталог старого агента (по умолчанию /opt/buildAgent)
  --new-dir DIR    каталог нового агента - его не трогать (по умолчанию /opt/buildAgent2026)
  --service NAME   служба нового агента - её не трогать (по умолчанию teamcity-agent2026)
  --server URL     адрес нового TeamCity (по умолчанию http://172.17.6.61:8111)
  --force          если сборка не закончилась за --wait секунд - прервать её
  --wait SEC       сколько ждать окончания текущей сборки (по умолчанию 600)
EOF
  exit "${1:-1}"
}

rerun=''   # the options as given, for the printed "run it again" commands (without --check/--yes)
for a in "$@"; do case $a in --check|--yes) ;; *) printf -v a ' %q' "$a"; rerun+=$a ;; esac; done
check=0 yes=0 force=0 wait_s=600
old_dir=/opt/buildAgent new_dir=/opt/buildAgent2026 service=teamcity-agent2026 server=http://172.17.6.61:8111
while (($# > 0)); do
  case $1 in
    --check) check=1 ;;
    --yes) yes=1 ;;
    --force) force=1 ;;
    --wait) [[ ${2:-} =~ ^[0-9]+$ ]] || usage; wait_s=$2; shift ;;
    --old-dir|--new-dir|--service|--server)
      (($# >= 2)) || usage
      safe_arg "$1" "$2"
      case $1 in --old-dir) old_dir=$2 ;; --new-dir) new_dir=$2 ;; --service) service=$2 ;; --server) server=$2 ;; esac
      shift ;;
    -h|--help) usage 0 ;;
    *) usage ;;
  esac
  shift
done
[[ $EUID -eq 0 ]] || die "запустите через sudo: sudo bash $SCRIPT --check"
server=$(norm_url "$server") service=${service%.service}
old_dir=$(canon "$old_dir") new_dir=$(canon "$new_dir")
old_conf=$old_dir/conf/buildAgent.properties
MARKER=.teamcity-agent-linux-migrate
have_systemd=0
if [[ -d /run/systemd/system ]]; then have_systemd=1; fi

printf '\nСтарый агент: %s (каталог и настройки не меняются)\nНовый агент:  %s, служба %s (не трогается)\n' "$old_dir" "$new_dir" "$service"

section 'Проверка'
# The folder given as the old agent must not be the new one.
if [[ ! -f $old_conf ]]; then
  bad "Не найден старый агент: нет $old_conf. Укажите: --old-dir /путь/к/агенту"
else
  why=''
  unit_d=''
  if ((have_systemd)); then unit_d=$(unit_dir "$service.service") || unit_d=''; fi
  if is_within "$old_dir" "$new_dir" || is_within "$new_dir" "$old_dir"; then
    why="совпадает с каталогом нового агента $new_dir или вложен в него"
  elif [[ -n $unit_d ]] && { is_within "$old_dir" "$unit_d" || is_within "$unit_d" "$old_dir"; }; then
    why="это каталог службы нового агента $service ($unit_d)"
  elif [[ -f $old_dir/$MARKER ]]; then
    why="в нём метка нового агента $MARKER"
  elif [[ $(norm_url "$(prop "$old_conf" serverUrl)") == "$server" ]]; then
    why="его serverUrl - новый сервер $server"
  elif b=$(build_of "$old_dir") && [[ -n $b ]] && ((b >= NEW_MIN_BUILD)); then
    why="это агент сборки $b, то есть 2026.x"
  fi
  if [[ -n $why ]]; then
    bad "--old-dir $old_dir - это новый агент ($why), не выключаю"
  else
    ok "Старый агент: $old_dir (serverUrl $(prop "$old_conf" serverUrl), name $(prop "$old_conf" name))"
  fi
fi

agents_scan
if [[ -n $AG_CONTAINER ]]; then info "Агенты TeamCity в контейнерах (PID $AG_CONTAINER) - не трогаю"; fi
agent_runinfo "$old_dir"
was_user=$RUN_USER was_jre=$RUN_JRE
was_env=("${RUN_ENV[@]}")
if [[ -n $RUN_PIDS ]]; then
  ok "Старый агент работает: PID $RUN_PIDS, пользователь ${RUN_USER:-?}, $(run_how_ru)"
  if [[ -n $RUN_JRE ]]; then
    info "Java старого агента: $RUN_JRE (для штатной остановки)"
  else
    bad "Не удалось определить Java старого агента (нужна для его штатной остановки)"
  fi
  if [[ -z $RUN_USER || $RUN_USER =~ ^[0-9]+$ ]]; then bad "Не удалось определить пользователя старого агента"; fi
  builds=''
  # shellcheck disable=SC2086
  if agent_busy "$old_dir" $RUN_PIDS; then builds=$BUSY; fi
  if [[ -n $builds ]]; then
    warn "На старом агенте идёт сборка: ${builds}"
    if ((force)); then
      info "С --force: скрипт попросит агента остановиться после сборки и прервёт её, если она не закончится за ${wait_s} с"
    else
      info "Скрипт дождётся окончания сборки (до ${wait_s} с) и только потом остановит агента. Не закончится - выход с кодом 3, ничего не прервано и не выключено"
    fi
  fi
else
  ok "Процессов старого агента нет"
fi
if ((have_systemd)); then autostart_scan "$old_dir" "$RUN_UNIT"; else autostart_scan "$old_dir"; fi
autostart_show 'старого агента' off
autostart_missing "$old_dir" off
steps=()
for ((i = 0; i < ${#AS_KIND[@]}; i++)); do
  case ${AS_KIND[i]}:${AS_STATE[i]} in
    unit:enabled|unit:enabled-runtime) steps+=("Выключить автозапуск службы ${AS_NAME[i]} (было: включён)") ;;
    crontab:on) steps+=("Закомментировать строки автозапуска в crontab пользователя ${AS_NAME[i]} (с копией)") ;;
    cronfile:on|rclocal:on) steps+=("Закомментировать строки автозапуска в ${AS_NAME[i]} (с копией)") ;;
  esac
done
if [[ -n $RUN_PIDS ]]; then
  steps=("Остановить старого агента штатно: agent.sh stop от ${RUN_USER:-?} с его Java (после текущей сборки, до ${wait_s} с)" "${steps[@]}")
  steps+=("Проверить, что процессов старого агента не осталось")
fi
for d in "${!AG_PIDS[@]}"; do
  if [[ $d != "$old_dir" ]]; then info "Не трогаю: агент $d (PID ${AG_PIDS[$d]})"; fi
done

start_line() {  # How to start the old agent by hand again (it was started by hand).
  local u=$was_user j=$was_jre x
  if [[ -z $j && -f $new_dir/$MARKER ]]; then j=$(prop "$new_dir/$MARKER" old_java); fi
  if [[ -z $j ]]; then   # the Java its last start used, from its own logs (read only)
    x=$({ grep -hoE "/[^ '\"]*/bin/java" -- "$old_dir"/logs/{launcher,error,output}.log 2>/dev/null || true; } | tail -n 1)
    if [[ -n $x && -x $x ]]; then j=${x%/bin/java}; fi
  fi
  if [[ -z $u && -f $new_dir/$MARKER ]]; then u=$(prop "$new_dir/$MARKER" old_user); fi
  if [[ -z $u ]]; then u=$(stat -c %U -- "$old_dir/logs" 2>/dev/null) || u='<пользователь>'; fi
  RUN_ENV=("${was_env[@]}")
  start_cmd "$old_dir" "$u" "${j:-<Java старого агента>}"
}
back_lines() {  # The way back to the old agent: its autostart, and a start by hand unless a unit starts it.
  local l started=0
  info "Включить старого агента обратно:"
  while IFS= read -r l; do
    [[ -n $l ]] || continue
    info "  $l"
    if [[ $l == *'systemctl enable --now'* || $l == *'systemctl start'* || $l == *'systemctl restart'* ]]; then started=1; fi
  done < <(printf '%s\n' "${AS_BACK[@]}"; autostart_back_cmds)
  if ((started == 0)); then info "  $(start_line)"; fi
}

section 'Что будет сделано'
if ((problems == 0 && ${#steps[@]} == 0)); then
  info "Старый агент уже выключен: процессов нет, автозапуск выключен. Ничего не изменено."
  section 'Итог'
  back_lines
  exit 0
fi
for ((i = 0; i < ${#steps[@]}; i++)); do info "$((i + 1)). ${steps[i]}"; done
info "Не меняется: каталог старого агента и его настройки, новый агент ($service, $new_dir), серверы TeamCity."
if ((problems > 0)); then
  printf '\nЕсть пункты [НЕТ] (%s) - исправьте их и запустите снова. Ничего не изменено.\n' "$problems"
  exit 2
fi
if ((check)); then
  printf '\nРежим --check: ничего не изменено.\n'
  exit 0
fi
if ((yes == 0)) && ! confirm 'Выключить старого агента?'; then
  printf 'Отменено, ничего не изменено.\n'
  exit 0
fi

section 'Что сделано'
agent_runinfo "$old_dir"
if ((have_systemd)); then autostart_scan "$old_dir" "$RUN_UNIT"; else autostart_scan "$old_dir"; fi
rc=0
if [[ -n $RUN_PIDS ]]; then
  was_user=$RUN_USER was_jre=$RUN_JRE was_env=("${RUN_ENV[@]}")
  stop_agent "$old_dir" "$wait_s" "$force" || rc=$?
fi
if ((rc == 3)); then
  warn "На старом агенте всё ещё идёт сборка (дольше ${wait_s} с) - агента не останавливаю, сборку не прерываю"
  section 'Итог'
  info "Ничего не изменено: агент работает, автозапуск не выключен."
  info "Запустите скрипт снова после окончания сборки (или с --force, чтобы прервать её): sudo bash $SCRIPT${rerun}"
  exit 3
fi
if ((rc == 4)); then
  # 'agent.sh stop' was sent and cannot be taken back: switch the autostart off now as well.
  warn "Старый агент доделывает сборку, которая началась перед остановкой: он остановится после неё (сборка не прервана)"
  AS_RESTART=1
  autostart_off "$old_dir" || true
  section 'Итог'
  info "Агент остановится сам после окончания сборки. Проверить потом: sudo bash $SCRIPT${rerun} --check"
  while IFS= read -r l; do if [[ -n $l ]]; then info "Временная настройка его службы (убрать после остановки): $l"; fi; done < <(dropin_cleanup_cmds)
  back_lines
  exit 3
fi
if ((rc == 0)); then autostart_off "$old_dir" || true; fi
proc_scan
left=$(agent_jvms_in "$old_dir" | tr '\n' ' ')
if [[ -n ${left// /} ]]; then bad "Процессы старого агента ещё работают: PID $left"; else ok "Процессов старого агента нет"; fi

section 'Итог'
if ((problems == 0)); then
  info "Старый агент выключен. В старом TeamCity он будет показан как Disconnected."
else
  info "Есть пункты [НЕТ] ($problems) - см. выше."
fi
back_lines
((problems == 0)) || exit 1
exit 0
