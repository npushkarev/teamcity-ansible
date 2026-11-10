#!/usr/bin/env bash
# Move a Debian 12 TeamCity build agent to the new TeamCity server.
#
# First shows what is missing and the exact plan; after confirmation installs a NEW agent
# next to the old one (own folder /opt/buildAgent2026, own systemd unit teamcity-agent2026,
# Java 21 from /opt/teamcity-agent-jdk21), copies the old agent's system.*/env.* parameters,
# stops the old agent gracefully (after its current build), switches its autostart off and
# checks that the new agent runs and registers. If the new agent does not come up, the old
# one is started again automatically. An agent already unpacked into the new folder by hand
# is taken over (its name and authorization are kept). The old agent's folder is never changed.
#
#   sudo bash teamcity-agent-linux-migrate.sh --check
#   sudo bash teamcity-agent-linux-migrate.sh
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

SCRIPT=teamcity-agent-linux-migrate.sh
usage() {
  cat >&2 <<'EOF'
Использование: sudo bash teamcity-agent-linux-migrate.sh [параметры]
  --check          только показать, чего не хватает, и план; ничего не менять
  --yes            не спрашивать подтверждение
  --server URL     адрес нового TeamCity (по умолчанию http://172.17.6.61:8111)
  --zip FILE       buildAgentFull.zip нового сервера (по умолчанию ищется рядом со скриптом,
                   в текущем каталоге и в ~/Downloads, иначе скачивается с сервера)
  --jdk DIR        Java 21 для агента (по умолчанию /opt/teamcity-agent-jdk21)
  --old-dir DIR    каталог старого агента (по умолчанию /opt/buildAgent)
  --new-dir DIR    каталог нового агента (по умолчанию /opt/buildAgent2026)
  --name NAME      имя нового агента (по умолчанию имя старого + -2026)
  --service NAME   служба systemd нового агента (по умолчанию teamcity-agent2026)
  --user USER      пользователь нового агента (по умолчанию тот же, что у старого)
  --keep-old       не останавливать старого агента; новый получит порт 9091
  --force          если сборка не закончилась за --wait секунд - прервать её
  --wait SEC       сколько ждать окончания текущей сборки (по умолчанию 600)
EOF
  exit "${1:-1}"
}

rerun=''   # the options as given, for the printed "run it again" commands (without --check/--yes)
for a in "$@"; do case $a in --check|--yes) ;; *) printf -v a ' %q' "$a"; rerun+=$a ;; esac; done
check=0 yes=0 keep_old=0 force=0 wait_s=600
server=http://172.17.6.61:8111 zip='' jdk=/opt/teamcity-agent-jdk21
old_dir=/opt/buildAgent new_dir=/opt/buildAgent2026 name='' service=teamcity-agent2026 user=''
while (($# > 0)); do
  case $1 in
    --check) check=1 ;;
    --yes) yes=1 ;;
    --keep-old) keep_old=1 ;;
    --force) force=1 ;;
    --wait) [[ ${2:-} =~ ^[0-9]+$ ]] || usage; wait_s=$2; shift ;;
    --server|--zip|--jdk|--old-dir|--new-dir|--name|--service|--user)
      (($# >= 2)) || usage
      safe_arg "$1" "$2"
      case $1 in
        --server) server=$2 ;; --zip) zip=$2 ;; --jdk) jdk=$2 ;; --old-dir) old_dir=$2 ;;
        --new-dir) new_dir=$2 ;; --name) name=$2 ;; --service) service=$2 ;; --user) user=$2 ;;
      esac
      shift ;;
    -h|--help) usage 0 ;;
    *) usage ;;
  esac
  shift
done
[[ $EUID -eq 0 ]] || die "запустите через sudo: sudo bash $SCRIPT --check"
[[ -d /run/systemd/system ]] || die "systemd не запущен - скрипт создаёт службу systemd для нового агента"

server=$(norm_url "$server")
[[ $server =~ ^https?://[^[:space:]/]+(/[^[:space:]]*)?$ ]] || die "--server: нужен адрес вида http://172.17.6.61:8111"
service=${service%.service}
[[ $service =~ ^[A-Za-z0-9_.@-]+$ ]] || die "--service: имя службы из латиницы, цифр и . _ - @"
new_given=$new_dir
old_dir=$(canon "$old_dir") new_dir=$(canon "$new_dir")
jdk=${jdk%/}
unit_file=/etc/systemd/system/$service.service
UNIT_MARK='# Created by teamcity-agent-linux-migrate.sh'
MARKER=.teamcity-agent-linux-migrate
here=$(cd "$(dirname "$0")" && pwd -P)
rn_args=''   # options for the other two scripts when not the defaults
[[ $new_dir == /opt/buildAgent2026 ]] || rn_args+=" --new-dir $new_dir"
[[ $service == teamcity-agent2026 ]] || rn_args+=" --service $service"
[[ $old_dir == /opt/buildAgent ]] || rn_args+=" --old-dir $old_dir"
[[ $server == http://172.17.6.61:8111 ]] || rn_args+=" --server $server"
work=$(mktemp -d /var/tmp/tcagent-migrate.XXXXXX)
phase=check

# ---------------------------------------------------------------- network, zip
http_code() {  # http_code URL: HTTP status of a HEAD request, 000 = no answer (curl, wget, python3 or bash).
  local url=$1 code='' hp host port path
  if command -v curl >/dev/null 2>&1; then
    code=$(curl -s -I -o /dev/null -w '%{http_code}' --connect-timeout 10 -m 20 "$url" 2>/dev/null) || true
  elif command -v wget >/dev/null 2>&1; then
    code=$(wget -S --spider -T 15 -t 1 "$url" 2>&1 | LC_ALL=C awk '$1 ~ /^HTTP\// { c = $2 } END { print c }') || true
  elif command -v python3 >/dev/null 2>&1; then
    code=$(python3 -I -c 'import sys, urllib.request, urllib.error
try:
    print(urllib.request.urlopen(urllib.request.Request(sys.argv[1], method="HEAD"), timeout=15).status)
except urllib.error.HTTPError as e:
    print(e.code)
except Exception:
    print("000")' "$url" 2>/dev/null) || true
  elif [[ $url == http://* ]]; then
    hp=${url#http://} path=/
    if [[ $hp == */* ]]; then path=/${hp#*/}; hp=${hp%%/*}; fi
    host=${hp%:*} port=80
    if [[ $hp == *:* ]]; then port=${hp##*:}; fi
    code=$(timeout 15 bash -c 'exec 3<>"/dev/tcp/$1/$2" || exit 1
      printf "HEAD %s HTTP/1.0\r\nHost: %s\r\nConnection: close\r\n\r\n" "$3" "$1" >&3
      read -r _ c _ <&3 && printf "%s\n" "$c"' _ "$host" "$port" "$path" 2>/dev/null) || true
  fi
  [[ $code =~ ^[0-9]{3}$ ]] || code=000
  printf '%s\n' "$code"
}
fetch() {  # fetch URL FILE: curl, else wget, else python3; no partial file is left on failure.
  local rc=0
  if command -v curl >/dev/null 2>&1; then curl -fsSL --connect-timeout 15 -o "$2" "$1" || rc=$?
  elif command -v wget >/dev/null 2>&1; then wget -q -T 30 -O "$2" "$1" || rc=$?
  elif command -v python3 >/dev/null 2>&1; then
    python3 -I -c 'import shutil, sys, urllib.request
with urllib.request.urlopen(sys.argv[1], timeout=30) as r, open(sys.argv[2], "wb") as f:
    shutil.copyfileobj(r, f)' "$1" "$2" || rc=$?
  else
    rc=127
  fi
  if ((rc != 0)); then rm -f -- "$2"; fi
  return "$rc"
}
zip_tool() {  # The tool that can list and unpack a zip here: unzip, python3, or the JDK's jar.
  if command -v unzip >/dev/null 2>&1; then echo unzip
  elif command -v python3 >/dev/null 2>&1; then echo python3
  elif [[ -x $jdk/bin/jar ]]; then echo jar
  else return 1; fi
}
zip_list() {  # zip_list ZIP: 'K NAME' per entry (K: l = symlink, - = other).
  case $(zip_tool) in
    unzip) unzip -Z1 "$1" | sed 's/^/- /'
           unzip -Z "$1" | LC_ALL=C awk '/^l/ { print "l " $NF }' ;;
    python3) python3 -I -c 'import stat, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    for i in z.infolist():
        print(("l " if stat.S_ISLNK(i.external_attr >> 16) else "- ") + i.filename)' "$1" ;;
    jar) "$jdk/bin/jar" tf "$1" | sed 's/^/- /' ;;
    *) return 1 ;;
  esac
}
ZIP_BUILD=''
zip_check() {  # zip_check ZIP: it is a TeamCity agent distribution that is safe to unpack (reason printed).
  local list
  ZIP_BUILD=''
  if ! list=$(zip_list "$1" 2>/dev/null) || [[ -z $list ]]; then
    bad "Архив $1 не читается как zip (скачан не до конца? указатель Git LFS?)"; return 1
  fi
  if ! grep -qx -- '- bin/agent.sh' <<< "$list" || ! grep -qx -- '- conf/buildAgent.dist.properties' <<< "$list"; then
    bad "Архив $1 - не дистрибутив агента TeamCity (нет bin/agent.sh и conf/buildAgent.dist.properties в корне)"; return 1
  fi
  if grep -qE '^. (/|(.*/)?\.\.(/|$))' <<< "$list" || grep -q '^l ' <<< "$list"; then
    bad "Архив $1 содержит абсолютные пути, '..' или ссылки - распаковывать не буду"; return 1
  fi
  ZIP_BUILD=$(sed -n 's#^- BUILD_\([0-9][0-9]*\)$#\1#p' <<< "$list" | head -n 1)
  if [[ -z $ZIP_BUILD ]] || ((ZIP_BUILD < NEW_MIN_BUILD)); then
    bad "Архив $1 - агент сборки ${ZIP_BUILD:-неизвестной} (нет BUILD_* 2026.x) - это не агент нового сервера (скачан со старого?)"; return 1
  fi
  return 0
}
unzip_to() {  # unzip_to ZIP DIR, then restore the exec bits jar/python3 do not keep.
  case $(zip_tool) in
    unzip) unzip -q -n "$1" -d "$2" ;;
    python3) python3 -I -c 'import os, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    for i in z.infolist():
        p = z.extract(i, sys.argv[2])
        mode = (i.external_attr >> 16) & 0o777
        if mode and not i.is_dir():
            os.chmod(p, mode)' "$1" "$2" ;;
    jar) (cd -- "$2" && "$jdk/bin/jar" xf "$1") ;;
    *) return 1 ;;
  esac || return 1
  chmod 755 "$2"/bin/*.sh 2>/dev/null || true
  chmod 755 "$2"/launcher/bin/* 2>/dev/null || true
}
zip_dist() {  # zip_dist ZIP FILE: extract conf/buildAgent.dist.properties to FILE.
  case $(zip_tool) in
    unzip) unzip -p "$1" conf/buildAgent.dist.properties > "$2" ;;
    python3) python3 -I -c 'import sys, zipfile
sys.stdout.buffer.write(zipfile.ZipFile(sys.argv[1]).read("conf/buildAgent.dist.properties"))' "$1" > "$2" ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------- settings of the new agent
compare() {  # compare NEWCONF OLDCONF: $work/report (ADD/DIFF/SAME/OTHER) and $work/add (raw old lines to add).
  LC_ALL=C awk -v addf="$work/add" -v rep="$work/report" "$AWK_LIB"'
    BEGIN { printf "" > addf; printf "" > rep }
    FNR == 1 { cont = 0; out = 0 }
    { sub(/\r$/, "") }
    NR == FNR {
      if (!cont && !skip($0) && (k = k_of($0)) != "") val[k] = v_of($0)
      cont = /\\$/; next
    }
    cont { if (out) print > addf; cont = /\\$/; next }
    {
      out = 0; k = skip($0) ? "" : k_of($0)
      if (k != "") {
        v = v_of($0)
        if (k ~ /^(system|env)\./) {
          if (!(k in val)) { out = 1; print "ADD\t" k "\t" v > rep; print > addf }
          else if (val[k] != v) print "DIFF\t" k "\t" v "\t" val[k] > rep
          else print "SAME\t" k > rep
        } else if (k !~ /^(serverUrl|name|authorizationToken)$/ && (!(k in val) || val[k] != v)) {
          print "OTHER\t" k "\t" v "\t" ((k in val) ? val[k] : "-") > rep
        }
      }
      cont = /\\$/
    }
  ' "$1" "$2"
}
count() { LC_ALL=C awk -F'\t' -v k="$1" '$1 == k { n++ } END { print n + 0 }' "$work/report"; }
keys() { LC_ALL=C awk -F'\t' -v k="$1" '$1 == k { printf "%s%s", sep, $2; sep = " " }' "$work/report"; }
set_props() {  # set_props FILE KEY=VALUE...: FILE with the first active line of each KEY replaced
  # (later active lines of it commented out) or KEY=VALUE appended; to stdout.
  local f=$1
  shift
  printf '%s\n' "$@" > "$work/set"
  LC_ALL=C awk "$AWK_LIB"'
    NR == FNR { i = index($0, "="); k = substr($0, 1, i - 1); want[k] = substr($0, i + 1); order[++n] = k; next }
    { line = $0; sub(/\r$/, "", line) }
    cont { if (!drop) print line; cont = line ~ /\\$/; next }
    {
      drop = 0; k = skip(line) ? "" : k_of(line)
      if (k != "" && (k in want)) {
        if (!(k in done)) { print k "=" want[k]; done[k] = 1 } else print "#" line
        drop = 1
      } else print line
      cont = line ~ /\\$/
    }
    END { for (j = 1; j <= n; j++) if (!(order[j] in done)) print order[j] "=" want[order[j]] }
  ' "$work/set" "$f"
}
unit_text() {  # The systemd unit of the new agent.
  cat <<EOF
$UNIT_MARK
# Agent folder: $new_dir (remove with teamcity-agent-linux-remove-new.sh)
# Type=oneshot + RemainAfterExit as in the JetBrains example unit: the agent's own restarts and
# upgrades stay inside the unit. 'agent.sh stop' only asks the agent to exit after the current
# build, so ExecStop waits until it has exited; it is skipped when no agent runs from this
# folder, because agent.sh stop would then reach another agent on port 9090.
[Unit]
Description=TeamCity Build Agent ($new_dir)
Wants=network-online.target
After=network-online.target docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
User=$user
Group=$group
Environment=TEAMCITY_JRE=$jdk
ExecStart=/bin/bash $new_dir/bin/agent.sh start
ExecStop=-/bin/bash -c 'd=$new_dir; p=\$\$(cat "\$\$d/logs/buildAgent.pid" 2>/dev/null); [ -n "\$\$p" ] && [ -f "\$\$d/logs/buildAgent.xmlRpcPort" ] && [ "\$\$(readlink /proc/\$\$p/cwd)" = "\$\$d/bin" ] || exit 0; /bin/bash "\$\$d/bin/agent.sh" stop; while [ -e /proc/\$\$p ]; do sleep 2; done'
SuccessExitStatus=0 143
TimeoutStartSec=5min
TimeoutStopSec=10min

[Install]
WantedBy=multi-user.target
EOF
}
root_owned() {  # root_owned PATH: PATH and every folder above it belong to root and are not writable by others.
  local p u m
  p=$(realpath -e -- "$1" 2>/dev/null) || return 1
  while :; do
    read -r u m < <(stat -c '%u %a' -- "$p" 2>/dev/null) || return 1
    [[ $u == 0 ]] && (((8#$m & 8#022) == 0)) || return 1
    [[ $p != / ]] || return 0
    p=$(dirname -- "$p")
  done
}
java_version() {  # java_version HOME: version of that Java for messages. From HOME/release; 'java -version'
  # runs as root only for a Java that only root can change (the old agent's Java is never run).
  local v i
  v=$(sed -n 's/^JAVA_VERSION="\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "$1/release" 2>/dev/null | head -n 1) || v=''
  i=$(sed -n 's/^IMPLEMENTOR="\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "$1/release" 2>/dev/null | head -n 1) || i=''
  if [[ -n $v ]]; then printf 'версия %s%s\n' "$v" "${i:+, $i}"
  elif root_owned "$1/bin/java"; then "$1/bin/java" -version 2>&1 | head -n 1 || true
  else printf 'версия не известна\n'
  fi
}
java_major() {  # 8, 11, 21 ... of the Java in home $1 (empty if unknown or it does not run)
  local v
  [[ -x $1/bin/java ]] || return 0
  v=$(java_home_major "$1")
  if [[ -z $v ]] && root_owned "$1/bin/java"; then
    v=$("$1/bin/java" -version 2>&1 | head -n 1) || v=''
    [[ $v == *\"* ]] || return 0
    v=${v#*\"}; v=${v%%\"*}
    if [[ $v == 1.* ]]; then v=${v#1.}; fi
    v=${v%%[!0-9]*}
  fi
  if [[ -n $v ]]; then printf '%s\n' "$v"; fi
}
log_size() { stat -c %s -- "$1" 2>/dev/null || echo 0; }
log_new() {  # log_new FILE OFFSET: what was written to FILE after OFFSET bytes (all of it after a rotation).
  local size
  size=$(log_size "$1")
  if ((size < $2)); then cat -- "$1" 2>/dev/null || true; else tail -c +"$(($2 + 1))" -- "$1" 2>/dev/null || true; fi
}
show_tail() {  # show_tail FILE N: the last N lines of FILE, masked and indented.
  if [[ -s $1 ]]; then
    info "Последние строки $1:"
    tail -n "$2" -- "$1" 2>/dev/null | mask | cut -c1-220 | sed 's/^/           /'
  fi
}
wait_new_jvm() {  # wait_new_jvm SECONDS: NEW_PID = the agent JVM (not the launcher) running from new_dir.
  local left=$1 p
  NEW_PID=''
  while :; do
    proc_scan
    for p in $(agent_jvms_in "$new_dir"); do
      if [[ $(jvm_role "$p") == agent ]]; then NEW_PID=$p; return 0; fi
    done
    ((left > 0)) || return 1
    sleep 3; left=$((left - 3))
  done
}
ENV_SKIP='^(_|PWD|OLDPWD|SHLVL|HOME|USER|LOGNAME|SHELL|MAIL|TERM|COLORTERM|LANG|LANGUAGE|LC_[A-Z]+|SUDO_[A-Z]+|SSH_[A-Z_]+|XDG_[A-Z_]+|DBUS_[A-Z_]+|LS_COLORS|LESSOPEN|LESSCLOSE|HIST[A-Z]*|DISPLAY|MOTD_SHOWN|INVOCATION_ID|JOURNAL_STREAM|SYSTEMD_EXEC_PID|MANAGERPID|NOTIFY_SOCKET|TEAMCITY_JRE|JAVA_MAIN_CLASS_[0-9]+|PATH)$'
env_extra() {  # Variables of the old agent process (RUN_ENV) a systemd unit does not have; PATH only if it has more.
  local e n p extra
  local -a parts
  for e in "${RUN_ENV[@]}"; do
    n=${e%%=*}
    if [[ $n == PATH ]]; then
      extra=''
      IFS=: read -r -a parts <<< "${e#PATH=}"
      for p in "${parts[@]}"; do
        if [[ :/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin: != *:"$p":* ]]; then
          extra+="${extra:+:}$p"
        fi
      done
      if [[ -n $extra ]]; then printf 'PATH=...:%s\n' "$extra"; fi
    elif [[ ! $n =~ $ENV_SKIP ]]; then
      printf '%s=%s\n' "$n" "$(show "$n" "${e#*=}")"
    fi
  done
}
kit_trusted() {  # kit_trusted FILE: FILE and its folder belong to root or to the user who ran sudo, and nobody else
  # can replace it (root installs the .deb and unpacks the zip): not group/world-writable, or a sticky folder like /tmp.
  local f d u m own=" 0 ${SUDO_UID:-0} "
  f=$(realpath -e -- "$1" 2>/dev/null) || return 1
  d=$(dirname -- "$f")
  read -r u m < <(stat -c '%u %a' -- "$f" 2>/dev/null) || return 1
  [[ $own == *" $u "* ]] && (((8#$m & 8#022) == 0)) || return 1
  read -r u m < <(stat -c '%u %a' -- "$d" 2>/dev/null) || return 1
  [[ $own == *" $u "* ]] && (((8#$m & 8#022) == 0 || (8#$m & 8#1000) != 0))
}
newest() {  # newest FILE...: the most recently modified of the existing trusted files (others: warned about).
  local f best='' bt=-1 t
  for f in "$@"; do
    [[ -f $f ]] || continue
    if ! kit_trusted "$f"; then
      warn "Пропускаю $f: файл или его каталог может изменить другой пользователь ($(stat -c '%U %A' -- "$f"))" >&2
      continue
    fi
    t=$(stat -c %Y -- "$f") || continue
    if ((t > bt)); then best=$f bt=$t; fi
  done
  if [[ -n $best ]]; then printf '%s\n' "$best"; fi
}
listeners() {  # listeners PORT: 'PID comm (user)' of the processes listening on TCP PORT.
  local i p
  for i in $(port_inodes "$1"); do
    for p in $(socket_pids "$i"); do printf '%s %s (%s)\n' "$p" "${P_COMM[$p]-?}" "$(proc_user "$p" || echo '?')"; done
  done | sort -u
}

cleanup() {
  local rc=$?
  trap - EXIT
  if [[ $phase == act ]]; then
    trap '' INT HUP TERM
    set +e
    bad "Остановлено на неожиданной ошибке или сигнале"
    rollback
    summary
    rc=1
  fi
  rm -rf -- "$work"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 129' HUP
trap 'exit 143' TERM

printf '\nСтарый агент: %s (каталог и настройки не меняются)\nНовый агент:  %s, служба %s\nНовый сервер: %s\n' \
  "$old_dir" "$new_dir" "$service" "$server"

# ================================================================ diagnostics
section 'Проверка: чего не хватает'

# ---- old agent
old_conf=$old_dir/conf/buildAgent.properties old_ok=0 old_url='' old_name=''
if [[ -f $old_conf && -r $old_conf ]]; then
  old_ok=1
  old_url=$(prop "$old_conf" serverUrl) old_name=$(prop "$old_conf" name)
  old_build=$(build_of "$old_dir")
  ok "Старый агент: $old_dir (сборка ${old_build:-?}, serverUrl ${old_url:-не задан}, name ${old_name:-не задан})"
  if [[ $(norm_url "$old_url") == "$server" ]]; then
    bad "У агента $old_dir serverUrl нового сервера - это не старый агент. Укажите старый: --old-dir /путь"
  elif [[ -n $old_build ]] && ((old_build >= NEW_MIN_BUILD)); then
    bad "Агент $old_dir сборки $old_build - это агент 2026.x, а не старый. Укажите старый: --old-dir /путь"
  fi
else
  bad "Не найден старый агент: нет $old_conf. Укажите: --old-dir /путь/к/агенту"
fi
agents_scan
for d in "${!AG_PIDS[@]}"; do
  if ((old_ok == 0)) && [[ $d != "$new_dir" ]]; then info "Работает агент TeamCity: $d (PID ${AG_PIDS[$d]})"; fi
done
if [[ -n $AG_CONTAINER ]]; then info "Агенты TeamCity в контейнерах (PID $AG_CONTAINER) - не трогаю"; fi
agent_runinfo "$old_dir"
old_pids=$RUN_PIDS old_user=$RUN_USER old_jre=$RUN_JRE old_unit=$RUN_UNIT old_how=$(run_how_ru)
old_env=("${RUN_ENV[@]}")
old_builds=''
if [[ -n $old_pids ]]; then
  ok "Старый агент работает: PID $old_pids, пользователь ${old_user:-?}, ${old_how}"
  if [[ -n $old_jre ]]; then
    info "Java старого агента: $old_jre ($(java_version "$old_jre"))"
  else
    bad "Не удалось определить Java старого агента (нужна для его штатной остановки)"
  fi
  # shellcheck disable=SC2086
  if agent_busy "$old_dir" $old_pids; then old_builds=$BUSY; fi
  if [[ -n $old_builds ]] && ((keep_old == 0)); then
    warn "На старом агенте идёт сборка: ${old_builds}"
    if ((force)); then
      info "С --force: скрипт попросит агента остановиться после сборки и прервёт её, если она не закончится за ${wait_s} с"
    else
      info "Скрипт дождётся окончания сборки (до ${wait_s} с) и только потом остановит агента. Не закончится - выход с кодом 3, ничего не прервано и не выключено"
    fi
  fi
else
  info "Старый агент сейчас не запущен"
fi
autostart_scan "$old_dir" "$old_unit"
if ((keep_old)); then
  autostart_show 'старого агента'; autostart_missing "$old_dir" show
else
  autostart_show 'старого агента' off; autostart_missing "$old_dir" off
fi
old_off=()
for ((i = 0; i < ${#AS_KIND[@]}; i++)); do
  case ${AS_KIND[i]}:${AS_STATE[i]} in
    unit:enabled|unit:enabled-runtime) old_off+=("служба ${AS_NAME[i]}") ;;
    crontab:on) old_off+=("crontab ${AS_NAME[i]}") ;;
    cronfile:on|rclocal:on) old_off+=("${AS_NAME[i]}") ;;
  esac
done
if ((${#old_off[@]} == 0)) && [[ -z $old_pids ]] && ! autostart_found && ! autostart_has_unknown; then
  info "Автозапуска у старого агента нет"
fi

# ---- user of the new agent
if [[ -n $user ]]; then
  getent passwd "$user" >/dev/null || bad "Нет пользователя $user (--user)"
elif [[ -n $old_pids ]]; then
  if [[ -n $old_user && $old_user != root && ! $old_user =~ ^[0-9]+$ ]]; then user=$old_user; fi
else
  for f in "$old_dir/logs" "$old_conf" "$old_dir"; do
    u=$(stat -c %U -- "$f" 2>/dev/null) || u=''
    if [[ -n $u && $u != root && $u != UNKNOWN ]]; then user=$u; break; fi
  done
fi
group=''
if [[ -z $user ]]; then
  bad "Не понятно, от какого пользователя запускать нового агента (старый работает от root или его каталог принадлежит root) - укажите: --user <имя>"
elif ! getent passwd "$user" >/dev/null; then
  :
elif [[ $(id -u "$user") == 0 ]]; then
  bad "Агент не должен работать от root - укажите обычного пользователя: --user <имя>"
else
  group=$(id -gn "$user")
  info "Новый агент будет работать от пользователя ${user} (группа ${group})"
  if [[ -n $old_user && $old_user != "$user" ]]; then
    warn "Старый агент работает от ${old_user}, новый будет от ${user} - права и доступ к Docker могут отличаться"
  fi
fi
user_ok=0
if [[ -n $group ]]; then user_ok=1; fi

# ---- new server
code=$(http_code "$server/login.html")
if [[ $code == 000 ]]; then
  bad "Новый TeamCity недоступен с этой машины: $server (сеть/firewall/адрес)"
else
  ok "Новый TeamCity отвечает: $server (HTTP $code)"
fi

# ---- Java 21 for the new agent
jdk_ok=0 deb=''
major=$(java_major "$jdk")
if [[ -n $major ]] && ((major >= 21 && major < 26)); then
  jdk_ok=1
  ok "Java $major для нового агента: $jdk ($(java_version "$jdk"))"
elif [[ -e $jdk/bin/java ]]; then
  bad "В $jdk Java ${major:-неизвестной версии} ($(java_version "$jdk")), а агенту 2026.2 нужна 21-25"
else
  deb=$(newest "$here"/teamcity-agent-jdk21_*.deb "$PWD"/teamcity-agent-jdk21_*.deb)
  if [[ -n $deb && $jdk == /opt/teamcity-agent-jdk21 ]]; then
    if [[ $(dpkg-deb -f "$deb" Package 2>/dev/null) != teamcity-agent-jdk21 ]]; then
      bad "$deb - не пакет .deb (указатель Git LFS? скачайте файл кнопкой Download в GitLab)"; deb=''
    elif [[ $(dpkg-deb -f "$deb" Architecture 2>/dev/null) != "$(dpkg --print-architecture)" ]]; then
      bad "$deb - пакет для другой архитектуры ($(dpkg-deb -f "$deb" Architecture))"; deb=''
    elif need=$(dpkg-deb -f "$deb" Depends 2>/dev/null | sed -n 's/.*libc6 (>= \([^)]*\)).*/\1/p') &&
         have=$(dpkg-query -W -f='${Version}' libc6 2>/dev/null) && [[ -n $need && -n $have ]] &&
         ! dpkg --compare-versions "$have" ge "$need"; then
      bad "$deb требует libc6 >= $need, а в системе $have: нужен пакет для старого Debian - teamcity-agent-jdk21_*~deb9_amd64.deb (files/teamcity-agent-jdk21/debian9-amd64)"; deb=''
    else
      fix "Нет Java 21 в $jdk - будет установлен пакет $deb (dpkg -i; системная Java не меняется)"
    fi
  else
    bad "Нет Java 21 в $jdk: установите пакет teamcity-agent-jdk21 (docs/teamcity-agent-jdk21-debian12.md) или положите teamcity-agent-jdk21_*.deb рядом со скриптом"
  fi
fi
[[ $jdk =~ ^/[A-Za-z0-9/._+-]+$ ]] || bad "Путь Java $jdk - нужен без пробелов и спецсимволов (он пишется в службу systemd)"

# ---- folder of the new agent
mode='' new_conf=$new_dir/conf/buildAgent.properties new_url='' new_name='' foreign=''
if path_has_link "$new_given"; then
  bad "В пути $new_given есть символическая ссылка (он ведёт в $new_dir). Укажите настоящий каталог: --new-dir $new_dir"
elif is_within "$new_dir" "$old_dir" || is_within "$old_dir" "$new_dir"; then
  bad "Каталоги старого ($old_dir) и нового ($new_dir) агента совпадают или вложены друг в друга"
elif why=$(protected_reason "$new_dir"); then
  bad "Каталог нового агента $new_dir: ${why} - туда не ставлю. Укажите другой: --new-dir"
elif [[ ! $new_dir =~ ^/[A-Za-z0-9/._+-]+$ ]]; then
  bad "Каталог нового агента $new_dir - нужен путь без пробелов и спецсимволов (он пишется в службу systemd)"
elif [[ -e $new_dir && ! -d $new_dir ]]; then
  bad "$new_dir уже есть, и это не каталог"
elif [[ ! -d $new_dir || -z $(ls -A -- "$new_dir") ]]; then
  mode=fresh
  ok "Каталог $new_dir свободен - новый агент будет распакован туда"
else
  foreign=$(foreign_entries "$new_dir")
  mnts=$(mounts_inside "$new_dir" || true)
  if [[ -n $mnts ]]; then
    bad "В $new_dir смонтировано: $(tr '\n' ' ' <<< "$mnts")- не трогаю"
  elif [[ -f $new_dir/bin/agent.sh && -f $new_conf ]]; then   # extra folders (nuget-cache of builds) stay as they are
    new_url=$(prop "$new_conf" serverUrl) new_name=$(prop "$new_conf" name)
    links=$(find "$new_dir" -mindepth 1 -maxdepth 1 -type l -printf '%f ' 2>/dev/null) || links=''
    links=${links% }
    if [[ -n $links || -L $new_dir/conf/buildAgent.properties || $(canon "$new_conf") != "$new_dir/conf/buildAgent.properties" ]]; then
      bad "В $new_dir есть символические ссылки (${links:-conf/buildAgent.properties}) - настройки записались бы в чужой каталог, не беру. Уберите ссылки или укажите другой каталог: --new-dir"
    elif [[ $(norm_url "$new_url") == "$server" ]]; then
      mode=adopt
      ok "В $new_dir уже есть агент нового сервера (сборка $(build_of "$new_dir"), name ${new_name:-не задан}) - беру его: настройки, имя и авторизацию не меняю"
      if [[ -n $name && $name != "$new_name" ]]; then warn "--name $name не применяю: агент уже называется ${new_name:-по имени машины}"; fi
      name=$new_name
      if [[ -n $(prop "$new_conf" authorizationToken) ]]; then info "Агент уже регистрировался на сервере (токен есть, значение не показываю)"; fi
      if [[ -n $foreign ]]; then info "Другие папки в $new_dir не трогаю: $(head -n 10 <<< "$foreign" | tr '\n' ' ')"; fi
    else
      bad "В $new_dir агент другого сервера (serverUrl ${new_url:-не задан}) - не трогаю. Укажите другой каталог: --new-dir"
    fi
  elif [[ -f $new_dir/$MARKER && -z $foreign ]]; then
    bad "$new_dir - незавершённая установка этого скрипта. Уберите её и запустите снова: sudo bash teamcity-agent-linux-remove-new.sh${rn_args}"
  else
    bad "Каталог $new_dir уже существует и не пуст - не перезаписываю. Укажите другой: --new-dir"
    if [[ -n $foreign ]]; then info "Там есть, например: $(head -n 10 <<< "$foreign" | tr '\n' ' ')"; fi
  fi
fi

# ---- the new agent if it already runs
new_pids='' new_user='' new_jre='' new_unit='' new_stop=0 new_ok=0 new_builds=''
if [[ $mode == adopt ]]; then
  agent_runinfo "$new_dir"
  new_pids=$RUN_PIDS new_user=$RUN_USER new_jre=$RUN_JRE new_unit=$RUN_UNIT
  if [[ -n $new_pids ]]; then
    java_same=0
    if [[ -n $new_jre && $(realpath -m -- "$new_jre/bin/java") == "$(realpath -m -- "$jdk/bin/java")" ]]; then java_same=1; fi
    if [[ $new_unit == "$service.service" ]]; then
      if ((java_same)) && [[ $new_user == "$user" ]]; then
        new_ok=1
        ok "Новый агент работает через службу $service (PID $new_pids, пользователь $new_user, Java $new_jre)"
      else
        new_stop=1
        fix "Новый агент работает через службу $service, но от ${new_user} на Java ${new_jre:-?} - будет перезапущен"
      fi
    elif [[ $new_unit == '' || $new_unit == cron.service || $new_unit == rc-local.service ]]; then
      new_stop=1
      fix "Новый агент работает (PID $new_pids, пользователь ${new_user:-?}, $(run_how_ru)) - будет остановлен штатно и запущен через службу $service"
    else
      bad "Новый агент запущен службой $new_unit - остановите и отключите её сами, этот скрипт ставит свою службу $service"
    fi
    if ((new_stop)); then
      [[ -n $new_jre ]] || bad "Не удалось определить Java нового агента (нужна для его штатной остановки)"
      # shellcheck disable=SC2086
      if agent_busy "$new_dir" $new_pids; then new_builds=$BUSY; fi
      if [[ -n $new_builds ]]; then
        warn "На новом агенте идёт сборка: ${new_builds} - скрипт дождётся её окончания (до ${wait_s} с), иначе выйдет с кодом 3"
      fi
    fi
  fi
  mapfile -t copies < <(agent_dirs_on_disk)
  for d in "${copies[@]}"; do
    [[ $d != "$new_dir" && $d != "$old_dir" ]] || continue
    if same_token "$d/conf/buildAgent.properties" "$new_conf"; then
      warn "Копия нового агента с тем же токеном: $d - не запускайте её вместе с новым (скрипт её не трогает)"
    fi
  done
fi

# ---- other agents on this machine
for d in "${!AG_PIDS[@]}"; do
  [[ $d != "$old_dir" && $d != "$new_dir" ]] || continue
  p=${AG_PIDS[$d]%% *}
  u=$(proc_user "$p") || u='<пользователь>'
  j=$(java_home_of "$p") || j='<Java этого агента>'
  bad "Работает ещё один агент TeamCity: $d (PID ${AG_PIDS[$d]}, пользователь $u) - пока он работает, нового не запускаю"
  info "Остановите его: sudo runuser -u $u -- env TEAMCITY_JRE=$j bash $d/bin/agent.sh stop"
done
if [[ -n $AG_UNKNOWN ]]; then bad "Работает агент TeamCity (PID $AG_UNKNOWN), его каталог не определить - остановите его"; fi

# ---- systemd unit of the new agent
unit_action='' unit_en=''
if ((user_ok)); then unit_text > "$work/unit"; fi
if [[ -e $unit_file || -L $unit_file ]]; then
  if [[ $(head -n 1 -- "$unit_file" 2>/dev/null) == "$UNIT_MARK" ]]; then
    ud=$(sed -n 's/^# Agent folder: \([^ ]*\).*/\1/p' "$unit_file" | head -n 1)
    if [[ $ud != "$new_dir" ]]; then
      bad "Служба $service уже создана этим скриптом для каталога ${ud:-?} - укажите другое имя: --service"
    elif ((user_ok)) && cmp -s -- "$work/unit" "$unit_file"; then
      ok "Служба $service уже есть и настроена так, как нужно"
    else
      unit_action=rewrite
      fix "Служба $service есть, но настроена иначе - будет перезаписана"
      if ((new_ok)); then new_ok=0 new_stop=1; fi
    fi
  else
    bad "Служба $service уже есть ($unit_file), её создал не этот скрипт - укажите другое имя: --service"
  fi
elif [[ $(unit_show "$service.service" LoadState) == loaded ]]; then
  bad "Служба $service уже есть ($(unit_where "$service.service")) - укажите другое имя: --service"
else
  unit_action=create
fi
unit_en=$(unit_enabled "$service.service")

# ---- port of the new agent's web server (localhost only)
if ((keep_old)) && [[ $mode == fresh ]]; then
  l=$(listeners 9091)
  if [[ -n $l ]]; then bad "Порт 9091 занят: $(tr '\n' ' ' <<< "$l")- он нужен новому агенту при --keep-old"; fi
elif [[ $mode == fresh || ( $mode == adopt && -z $(prop "$new_conf" ownPort) ) ]]; then
  l=''
  # shellcheck disable=SC2086
  own=" $old_pids $new_pids $(proc_desc $old_pids $new_pids | tr '\n' ' ') "
  for p in $(port_inodes 9090); do
    for q in $(socket_pids "$p"); do
      if [[ $own != *" $q "* ]]; then l+="$q ${P_COMM[$q]-?} ($(proc_user "$q" || echo '?')) "; fi
    done
  done
  if [[ -n $l ]]; then warn "Порт 9090 занят: ${l}- новый агент возьмёт следующий свободный порт (9091...)"; fi
fi

# ---- docker
if ((user_ok)) && { command -v docker >/dev/null 2>&1 || getent group docker >/dev/null; }; then
  if [[ " $(id -nG "$user") " == *" docker "* ]]; then
    ok "Пользователь $user в группе docker"
  else
    warn "Пользователь $user не в группе docker - сборки с Docker на новом агенте не пойдут"
    info "Добавить (это даёт права root через Docker, решите осознанно): sudo usermod -aG docker $user"
  fi
fi

# ---- distribution of the new agent
zip_src='' download=0 zip_url=$server/update/buildAgentFull.zip zip_later=0
if [[ $mode == fresh ]]; then
  if [[ -n $zip ]]; then
    zip_src=$(canon "$zip")
    [[ -f $zip_src ]] || { bad "Нет файла $zip (--zip)"; zip_src=''; }
  else
    sudo_home=''
    if [[ -n ${SUDO_USER:-} ]]; then sudo_home=$(getent passwd "$SUDO_USER" | cut -d: -f6) || sudo_home=''; fi
    zip_src=$(newest "$here"/buildAgent*.zip "$PWD"/buildAgent*.zip ${sudo_home:+"$sudo_home"/Downloads/buildAgent*.zip})
  fi
  if ! zip_tool >/dev/null && [[ -n $deb ]]; then
    zip_later=1   # no unzip/python3: the JDK's jar after the .deb is installed
  elif ! zip_tool >/dev/null; then
    bad "Нечем распаковать zip: нет unzip, python3 и $jdk/bin/jar"
  fi
  if [[ -n $zip_src ]]; then
    if ((zip_later)); then
      info "Дистрибутив агента: $zip_src - будет проверен после установки Java (распаковка через jar)"
    elif zip_tool >/dev/null && zip_check "$zip_src"; then
      ok "Дистрибутив агента: $zip_src${ZIP_BUILD:+ (сборка $ZIP_BUILD)}"
    fi
  elif [[ -z $zip ]]; then
    code=$(http_code "$zip_url")
    if [[ $code != 200 ]]; then
      bad "Нет buildAgentFull.zip: скачайте в новом TeamCity Agents -> Install Build Agents -> Zip file distribution и положите рядом со скриптом"
    elif ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
      bad "Нет buildAgentFull.zip, а скачать нечем (нет curl, wget, python3) - положите его рядом со скриптом"
    else
      download=1
      fix "Нет buildAgentFull.zip рядом со скриптом - будет скачан с нового сервера: $zip_url"
    fi
  fi
  p=$new_dir
  while [[ ! -d $p ]]; do p=$(dirname -- "$p"); done
  free_kb=$(df -Pk -- "$p" 2>/dev/null | LC_ALL=C awk 'NR == 2 { print $4 }') || free_kb=''
  if [[ ! $free_kb =~ ^[0-9]+$ ]]; then
    :
  elif ((free_kb < 1048576)); then
    bad "Мало места в $p: $((free_kb / 1024)) МБ, новому агенту нужен хотя бы 1 ГБ"
  elif ((free_kb < 3145728)); then
    warn "В $p свободно $((free_kb / 1024)) МБ - для самообновления агента TeamCity нужно 3 ГБ"
  fi
  if ((download)); then
    free_kb=$(df -Pk -- "$work" 2>/dev/null | LC_ALL=C awk 'NR == 2 { print $4 }') || free_kb=''
    if [[ $free_kb =~ ^[0-9]+$ ]] && ((free_kb < 512000)); then bad "Мало места в $work для скачивания архива: $((free_kb / 1024)) МБ"; fi
  fi
fi

# ---- parameters of the old agent
base=$work/base
if [[ $mode == adopt ]]; then
  cp -- "$new_conf" "$base"
elif [[ -n $zip_src ]] && ((zip_later == 0)) && zip_dist "$zip_src" "$base" 2>/dev/null; then
  :
else
  printf 'serverUrl=\nname=\nworkDir=../work\ntempDir=../temp\nsystemDir=../system\nauthorizationToken=\n' > "$base"
fi
: > "$work/report"; : > "$work/add"
if ((old_ok)); then compare "$base" "$old_conf"; fi
added=$(count ADD) differ=$(count DIFF) same=$(count SAME) other=$(count OTHER) add_keys=$(keys ADD)
if ((added > 0)); then
  fix "Новому агенту нужны параметры старого ($added) - по ним сборки выбирают агента:"
  while IFS=$'\t' read -r kind key a _; do
    if [[ $kind == ADD ]]; then info "- $key = $(show "$key" "$a")"; fi
  done < "$work/report"
elif ((old_ok && same > 0)); then
  ok "Все параметры system.*/env.* старого агента уже есть у нового ($same)"
elif ((old_ok)); then
  ok "Дополнительных параметров system.*/env.* у старого агента нет"
fi
if ((differ > 0)); then
  warn "Различаются значения (у нового оставляю его значение):"
  while IFS=$'\t' read -r kind key a b; do
    if [[ $kind == DIFF ]]; then info "- $key: старый = $(show "$key" "$a"), новый = $(show "$key" "$b")"; fi
  done < "$work/report"
fi
# work/temp/system folders outside the old agent's own folder (a bigger disk, /data/work) are
# taken over as they are: the old agent no longer runs, and its free-space cleaning worked there
dir_props=() dir_new=()
if ((old_ok && keep_old == 0)); then
  for k in workDir tempDir systemDir; do
    v=$(prop "$old_conf" "$k"); v=${v%/}
    [[ $v == /?* ]] || continue                         # relative: inside the old agent's folder
    if is_within "$v" "$old_dir"; then continue; fi
    [[ $(prop "$base" "$k") != "$v" ]] || continue      # already set
    if [[ ! $v =~ ^/[A-Za-z0-9/._+-]+$ ]]; then bad "$k старого агента $v - нужен путь без пробелов и спецсимволов"; continue; fi
    if [[ -e $v && ! -d $v ]]; then bad "$k старого агента $v - это не каталог"; continue; fi
    if [[ -d $v ]] && ((user_ok)) && [[ $(stat -c %U -- "$v") != "$user" ]]; then
      bad "$k старого агента $v принадлежит $(stat -c %U -- "$v"), а новый агент работает от $user - отдайте каталог: sudo chown -R $user: $v"; continue
    fi
    if [[ ! -d $v ]]; then
      if why=$(protected_reason "$v"); then bad "$k старого агента $v: $why - не создаю"; continue; fi
      dir_new+=("$v")
    fi
    dir_props+=("$k=$v")
  done
fi
if ((${#dir_props[@]} > 0)); then
  fix "Рабочие папки - как у старого агента (там место и его очистка): ${dir_props[*]}"
  if ((${#dir_new[@]} > 0)); then info "Будут созданы (владелец $user): ${dir_new[*]}"; fi
  info "Старый агент после переноса выключен; при его возврате он снова будет работать в этих папках"
  if ((new_ok)); then
    new_ok=0 new_stop=1
    # shellcheck disable=SC2086
    if agent_busy "$new_dir" $new_pids; then
      new_builds=$BUSY
      warn "На новом агенте идёт сборка: ${new_builds} - для смены папок скрипт перезапустит агента после неё (до ${wait_s} с), иначе выйдет с кодом 3"
    fi
  fi
fi
other_keys=" ${dir_props[*]%%=*} "
if ((other > 0)); then
  warn "Прочие настройки старого агента не переносятся (пути и порты у нового свои):"
  while IFS=$'\t' read -r kind key a b; do
    if [[ $other_keys == *" $key "* ]]; then continue; fi
    if [[ $kind == OTHER ]]; then
      if [[ $b == - ]]; then info "- $key = $(show "$key" "$a")"; else info "- $key = $(show "$key" "$a") (у нового: $(show "$key" "$b"))"; fi
    fi
  done < "$work/report"
fi
if [[ -n $old_pids ]] && ((${#old_env[@]} > 0)); then
  RUN_ENV=("${old_env[@]}")
  extra=$(env_extra | mask)
  shown=''
  while IFS= read -r l; do
    [[ -n $l ]] || continue
    if [[ $l != PATH=* && -n $(prop "$old_conf" "env.${l%%=*}") ]]; then continue; fi
    shown+="$l"$'\n'
  done <<< "$extra"
  if [[ -n $shown ]]; then
    warn "У процесса старого агента есть переменные окружения, которых у службы не будет (сборки видят их как env.*):"
    while IFS= read -r l; do if [[ -n $l ]]; then info "- $l"; fi; done <<< "$(head -n 20 <<< "$shown")"
    info "  Если они нужны сборкам, добавьте их в $new_conf как env.ИМЯ=значение"
  fi
fi

# ---- name of the new agent
if [[ $mode == fresh ]]; then
  if [[ -z $name ]]; then
    if [[ -n $old_name ]]; then name=$old_name-2026; else name=$(hostname -s)-2026; fi
  fi
  if [[ $name =~ ^[A-Za-z0-9._-]+$ ]]; then
    info "Имя нового агента: $name"
  else
    bad "Имя нового агента '$name' - нужно из латиницы, цифр и . _ -: --name ИМЯ"
  fi
fi

# ---- what the new folder still needs
owner_fix=0 marker_fix=0 perm_fix=0
open_copies=()   # older copies of the conf (backups of copy-settings, by hand) that other users can read
if [[ $mode == fresh ]]; then
  owner_fix=1 marker_fix=1
elif [[ $mode == adopt ]]; then
  m=$(stat -c %a -- "$new_conf" 2>/dev/null) || m=600
  if (((8#$m & 8#077) != 0)); then
    perm_fix=1
    fix "$new_conf могут читать другие пользователи (права $m), а в нём токен агента - права будут 600"
  fi
  # Regular files only (find does not follow symlinks): a link may point anywhere.
  mapfile -t open_copies < <(find "$new_dir/conf" -mindepth 1 -maxdepth 1 -type f -name 'buildAgent.properties?*' -perm /077 2>/dev/null | sort)
  if ((${#open_copies[@]} > 0)); then
    fix "Копии настроек в $new_dir/conf могут читать другие пользователи, а в них может быть токен агента - доступ будет закрыт (chmod go-rwx):"
    for f in "${open_copies[@]}"; do info "  ${f##*/} (права $(stat -c %a -- "$f"))"; done
  fi
  if ((user_ok)) && [[ -n $(find "$new_dir" -xdev ! -user "$user" -print -quit 2>/dev/null) ]]; then
    if [[ -n $foreign ]]; then
      warn "В $new_dir есть файлы не пользователя $user, но там и другие папки ($(head -n 3 <<< "$foreign" | tr '\n' ' ')) - chown не делаю. Если нужно: sudo chown -R $user: $new_dir"
    else
      owner_fix=1
      fix "В $new_dir есть файлы не пользователя $user - каталог будет отдан ему (chown -R, только этот каталог)"
    fi
  fi
  if [[ ! -f $new_dir/$MARKER ]]; then marker_fix=1; fi
fi

# ================================================================ plan
old_start=''   # how the old agent was started: unit:NAME, manual, or empty (not running)
if [[ -n $old_pids ]]; then
  old_start=manual
  for ((i = 0; i < ${#AS_KIND[@]}; i++)); do
    if [[ ${AS_KIND[i]} == unit && ${AS_ACT[i]} == active ]]; then old_start=unit:${AS_NAME[i]}; break; fi
  done
fi
do_start=0
if ((new_ok == 0)); then do_start=1; fi

section 'Что будет сделано'
steps=()
if ((user_ok == 0)); then user='<пользователь>' group='<группа>'; fi   # the run is refused anyway
if [[ -n $deb ]] && ((jdk_ok == 0)); then
  steps+=("Установить Java 21: dpkg -i $deb (каталог $jdk; системная Java не меняется)")
fi
if [[ $mode == fresh ]]; then
  if ((download)); then steps+=("Скачать $zip_url и распаковать агента в $new_dir")
  else steps+=("Распаковать агента из ${zip_src:-архива} в $new_dir"); fi
fi
if ((new_stop)); then
  steps+=("Остановить штатно нового агента, который уже работает (PID $new_pids; после текущей сборки, до ${wait_s} с)")
fi
if ((${#dir_new[@]} > 0)); then steps+=("Создать рабочие папки нового агента: ${dir_new[*]} (владелец $user)"); fi
if [[ $mode == fresh ]]; then
  s="Настроить $new_conf: serverUrl=$server, name=$name"
  if ((added > 0)); then s+=", + $added параметр(ов) старого агента"; fi
  if ((${#dir_props[@]} > 0)); then s+=", рабочие папки как у старого: ${dir_props[*]}"; fi
  if ((keep_old)); then s+=", ownPort=9091"; fi
  steps+=("$s")
elif ((added > 0 || ${#dir_props[@]} > 0)); then
  s="Записать в $new_conf (с резервной копией):"
  if ((${#dir_props[@]} > 0)); then s+=" рабочие папки как у старого агента: ${dir_props[*]};"; fi
  if ((added > 0)); then s+=" параметры старого агента ($added): $add_keys"; fi
  steps+=("${s%;}")
  if ((marker_fix)); then steps+=("Записать метку $new_dir/$MARKER (по ней teamcity-agent-linux-remove-new.sh узнаёт этого агента)"); fi
elif ((marker_fix)); then
  steps+=("Записать метку $new_dir/$MARKER (по ней teamcity-agent-linux-remove-new.sh узнаёт этого агента)")
fi
if ((perm_fix)); then steps+=("Закрыть $new_conf от других пользователей: chmod 600 (в нём токен агента)"); fi
if ((${#open_copies[@]} > 0)); then
  steps+=("Закрыть от других пользователей копии настроек в $new_dir/conf (${#open_copies[@]}): chmod go-rwx")
fi
if ((owner_fix)); then steps+=("Отдать каталог $new_dir пользователю $user (chown -R $user:$group, только этот каталог)"); fi
case $unit_action in
  create) steps+=("Создать службу $service (systemd): пользователь $user, Java $jdk (TEAMCITY_JRE), автозапуск при загрузке") ;;
  rewrite) steps+=("Перезаписать службу $service (systemd): пользователь $user, Java $jdk (TEAMCITY_JRE), автозапуск при загрузке") ;;
  *) if [[ $unit_en != enabled ]]; then steps+=("Включить автозапуск службы $service"); fi ;;
esac
off_text=$(IFS=,; printf '%s' "${old_off[*]}"); off_text=${off_text//,/, }
if ((keep_old == 0)); then
  if [[ -n $old_pids && -n $off_text ]]; then
    steps+=("Только после этого остановить старого агента штатно (после текущей сборки, до ${wait_s} с) и выключить его автозапуск: $off_text")
  elif [[ -n $old_pids ]]; then
    steps+=("Только после этого остановить старого агента штатно (после текущей сборки, до ${wait_s} с)")
  elif [[ -n $off_text ]]; then
    steps+=("Выключить автозапуск старого агента: $off_text")
  fi
fi
if ((do_start)); then
  s="Запустить службу $service и проверить: агент от $user на Java $jdk, регистрация на сервере"
  if ((keep_old == 0)) && [[ -n $old_pids || -n $off_text ]]; then s+=". Если не выйдет - вернуть старого агента автоматически"; fi
  steps+=("$s")
fi
for ((i = 0; i < ${#steps[@]}; i++)); do info "$((i + 1)). ${steps[i]}"; done
if ((${#steps[@]} > 0)); then
  if ((keep_old)); then info "Старый агент остаётся работать (--keep-old)."; fi
  info "Не меняется: каталог старого агента и его настройки, серверы TeamCity, системная Java, другие агенты."
fi

# ================================================================ helpers of the actions
old_touched=0 old_draining=0 rolled_back=0 conf_bk='' adopt_token=0
if [[ $mode == adopt && -n $(prop "$new_conf" authorizationToken) ]]; then adopt_token=1; fi
marker_write() {  # The marker tells teamcity-agent-linux-remove-new.sh which folder is the new agent.
  local f=$new_dir/$MARKER ou=$old_user oj=$old_jre os=$old_start oe='' e tmp
  for e in "${old_env[@]}"; do
    case $e in JAVA_HOME=*|JRE_HOME=*) oe+="${oe:+ }$e" ;; esac
  done
  if [[ -f $f ]]; then   # keep what an earlier run knew about the old agent
    [[ -n $ou ]] || ou=$(prop "$f" old_user)
    [[ -n $oj ]] || oj=$(prop "$f" old_java)
    [[ -n $os ]] || os=$(prop "$f" old_start)
    [[ -n $os && -n $oe ]] || oe=$(prop "$f" old_env)
  fi
  tmp=$(mktemp "$new_dir/.marker.XXXXXX") || return 1   # a new file: never written through a symlink
  {
    printf '%s: the new TeamCity agent (teamcity-agent-linux-remove-new.sh relies on this file)\n' "$UNIT_MARK"
    printf 'service=%s\nserver=%s\nold_dir=%s\nold_user=%s\nold_java=%s\nold_start=%s\nold_env=%s\ndate=%s\n' \
      "$service" "$server" "$old_dir" "$ou" "$oj" "$os" "$oe" "$(date '+%F %T')"
  } > "$tmp" && chmod 644 -- "$tmp" && mv -f -T -- "$tmp" "$f" || { rm -f -- "$tmp"; return 1; }
  if ((user_ok)); then chown -- "$user:$group" "$f"; fi
}
diag() {  # Why the new agent does not run: systemd and the agent's own logs (masked).
  info "systemctl status $service:"
  { systemctl status --no-pager -n 0 -- "$service.service" 2>&1 || true; } | sed '/CGroup:/,$d' | mask | head -n 8 | sed 's/^/           /'
  info "journalctl -u $service:"
  { journalctl -u "$service.service" -n 15 --no-pager 2>&1 || true; } | mask | cut -c1-220 | sed 's/^/           /'
  for f in error.log output.log launcher.log teamcity-agent.log; do show_tail "$new_dir/logs/$f" 8; done
}
NEW_STATE=''
new_state() {  # NEW_STATE = how the new agent is left after an undo: running (how), stopped; its unit enabled or not
  # (after autostart_scan of the old agent: both start at boot when its autostart is on too).
  local p='' how en i
  for ((i = 0; i < 3; i++)); do   # an agent started again by the undo shows up within a second or two
    proc_scan
    p=$(agent_jvms_in "$new_dir") || p=''
    p=${p%%$'\n'*}
    if [[ -n $p ]]; then break; fi
    sleep 1
  done
  en=$(unit_enabled "$service.service") || en=''
  if [[ -z $p ]]; then
    NEW_STATE='не запущен'
  else
    how=$(started_by "$p") || how=''
    if [[ $how == "system $service.service" ]]; then NEW_STATE="работает через службу $service"
    else NEW_STATE='работает, запущен вручную, как и был'; fi
  fi
  if [[ $en == enabled ]]; then
    NEW_STATE+=", автозапуск службы $service включён (был включён и до запуска скрипта)"
    if autostart_running; then NEW_STATE+=" - после перезагрузки запустятся оба агента"; fi
    NEW_STATE+=". Выключить его: sudo systemctl disable $service"
  else
    NEW_STATE+=", служба $service выключена"
  fi
}
back_lines() {  # How to switch back to the old agent (printed in the summary).
  local l ou oj os
  if ((keep_old)); then
    info "Старый агент оставлен работать. Выключить его позже: sudo bash teamcity-agent-linux-disable-old.sh${rn_args}"
    info "Убрать нового агента: sudo bash teamcity-agent-linux-remove-new.sh${rn_args}"
    return 0
  fi
  info "Вернуть старого агента:"
  info "  sudo systemctl disable --now $service"
  if ((${#AS_BACK[@]} > 0)); then
    for l in "${AS_BACK[@]}"; do info "  $l"; done
  else
    while IFS= read -r l; do if [[ -n $l ]]; then info "  $l"; fi; done < <(autostart_back_cmds)
  fi
  ou=$old_user oj=$old_jre os=$old_start
  if [[ -f $new_dir/$MARKER ]]; then
    [[ -n $os ]] || os=$(prop "$new_dir/$MARKER" old_start)
    [[ -n $ou ]] || ou=$(prop "$new_dir/$MARKER" old_user)
    [[ -n $oj ]] || oj=$(prop "$new_dir/$MARKER" old_java)
  fi
  if [[ $os == manual && -n $ou && -n $oj ]]; then
    RUN_ENV=("${old_env[@]}")
    if ((${#RUN_ENV[@]} == 0)) && [[ -f $new_dir/$MARKER ]]; then read -r -a RUN_ENV <<< "$(prop "$new_dir/$MARKER" old_env)"; fi
    info "  $(start_cmd "$old_dir" "$ou" "$oj")"
  fi
}
summary() {
  section 'Итог'
  if ((problems == 0)); then
    if ((adopt_token)); then
      info "Готово. Агент ${name:-$new_dir} уже был зарегистрирован: проверьте в новом TeamCity, что он авторизован и в нужном пуле (Agents -> ${name:-агент})."
    else
      info "Готово. В новом TeamCity: Agents -> Unauthorized -> ${name:-агент} -> Authorize, затем назначьте пул."
    fi
  else
    info "Есть пункты [НЕТ] ($problems) - см. выше."
  fi
  if ((old_draining)); then
    info "Старый агент доделывает сборку и остановится сам после неё (сборку скрипт не прерывал). Команды возврата - после этого."
    while IFS= read -r l; do if [[ -n $l ]]; then info "Временная настройка его службы (убрать после остановки): $l"; fi; done < <(dropin_cleanup_cmds)
  fi
  if [[ $STOP_SENT == *" $old_dir "* ]]; then old_touched=1; fi
  if ((rolled_back == 0 && (problems == 0 || old_touched == 1))); then back_lines; fi
  if [[ -n $conf_bk ]]; then info "Откат настроек нового агента: sudo cp -p $conf_bk $new_conf"; fi
}
rollback() {  # A step failed: undo in reverse order (the old agent first gets its autostart back and is started).
  rolled_back=1
  if ((${#UNDO[@]} > 0)); then
    info "Возвращаю как было:"
    undo_run
  fi
  if ((old_touched == 0)) && [[ $STOP_SENT != *" $old_dir "* ]]; then info "Старый агент не тронут."; fi
  if [[ $mode == fresh && -d $new_dir ]]; then
    info "Убрать незавершённую установку нового агента, чтобы запустить скрипт снова: sudo bash teamcity-agent-linux-remove-new.sh${rn_args}"
  elif [[ $mode == adopt ]]; then
    info "Новый агент остаётся в $new_dir$( ((new_stop)) && printf ' (запущен снова так же, как был)')."
  fi
}
fail() {  # fail MESSAGE: a step did not work - put things back, print the summary, exit 1.
  trap '' INT HUP TERM
  set +e
  bad "$*"
  rollback
  phase=end
  summary
  exit 1
}

# ================================================================ gates
if ((problems > 0)); then
  printf '\nЕсть пункты [НЕТ] (%s) - исправьте их и запустите снова. Ничего не изменено.\n' "$problems"
  exit 2
fi
if ((${#steps[@]} == 0)); then
  info "Ничего делать не нужно: перенос уже выполнен."
  summary
  exit 0
fi
if ((check)); then
  printf '\nРежим --check: ничего не изменено.\n'
  exit 0
fi
if ((yes == 0)) && ! confirm 'Выполнить?'; then
  printf 'Отменено, ничего не изменено.\n'
  exit 0
fi

# ================================================================ actions
phase=act
section 'Что сделано'

# 1. Java 21
deb_done=0
if [[ -n $deb ]] && ((jdk_ok == 0)); then
  deb_done=1
  if ! out=$(dpkg -i -- "$deb" 2>&1); then
    printf '%s\n' "$out" | tail -n 5 | sed 's/^/           /'
    fail "Пакет $deb не установился"
  fi
  major=$(java_major "$jdk")
  if [[ -n $major ]] && ((major >= 21 && major < 26)); then
    ok "Java установлена: $jdk ($(java_version "$jdk")). Удалить пакет: sudo dpkg -r teamcity-agent-jdk21"
  else
    fail "После установки $deb в $jdk нет работающей Java 21"
  fi
fi

# 2. the agent distribution
if [[ $mode == fresh ]]; then
  if ((download)); then
    info "Скачиваю $zip_url ..."
    zip_src=$work/buildAgentFull.zip
    fetch "$zip_url" "$zip_src" || fail "Не удалось скачать $zip_url"
    ok "Скачан дистрибутив агента ($(du -h -- "$zip_src" | cut -f1))"
  fi
  zip_tool >/dev/null || fail "Нечем распаковать zip: нет unzip, python3 и $jdk/bin/jar"
  zip_check "$zip_src" || fail "Дистрибутив не подходит - каталог $new_dir не создан"
  why=$(protected_reason "$new_dir") && fail "Каталог $new_dir: $why"
  mkdir -p -- "$new_dir"
  marker_write || fail "Не удалось записать $new_dir/$MARKER"
  if ! unzip_to "$zip_src" "$new_dir" > "$work/unzip.log" 2>&1; then
    tail -n 5 "$work/unzip.log" | sed 's/^/           /'
    fail "Не удалось распаковать $zip_src в $new_dir"
  fi
  [[ -f $new_dir/bin/agent.sh && -f $new_dir/conf/buildAgent.dist.properties ]] || fail "После распаковки в $new_dir нет bin/agent.sh"
  ok "Агент распакован в $new_dir (сборка $(build_of "$new_dir"))"
fi

# 3. stop the new agent that already runs (it is started again by the unit below)
if ((new_stop)); then
  agent_runinfo "$new_dir"
  AS_KIND=() AS_NAME=() AS_STATE=() AS_ACT=() AS_LINES=()   # no drop-in on its units: our unit keeps its ExecStop
  again=''
  if [[ $RUN_UNIT == "$service.service" ]]; then again=$RUN_UNIT; fi
  rc=0
  stop_agent "$new_dir" "$wait_s" "$force" "$again" || rc=$?
  if ((rc == 3 || rc == 4)); then
    if ((rc == 3)); then
      warn "На новом агенте всё ещё идёт сборка (дольше ${wait_s} с) - его не останавливаю, сборку не прерываю"
      info "Запустите скрипт снова после окончания сборки (или с --force, чтобы прервать её): sudo bash $SCRIPT${rerun}"
    else
      warn "Новый агент доделывает сборку: ему отправлена команда остановиться после неё (сборка не прервана)"
      info "Когда он остановится, запустите скрипт снова: sudo bash $SCRIPT${rerun} - он продолжит с этого места."
    fi
    UNDO=() phase=end
    section 'Итог'
    if ((deb_done)); then info "Кроме установки Java, ничего не менялось. Старый агент не тронут."; else info "Ничего больше не менялось. Старый агент не тронут."; fi
    exit 3
  fi
  ((rc == 0)) || fail "Новый агент не остановлен"
fi

# 4. settings of the new agent
# writes into an existing conf folder run as its owner: a symlink swapped in there by that user
# then reaches only files the user could change anyway
conf_owner=$(stat -c %U -- "$new_dir/conf" 2>/dev/null) || conf_owner=root
as_conf_owner() { if [[ $conf_owner == root ]]; then "$@"; else runuser -u "$conf_owner" -- "$@"; fi; }
hdr="# Copied from $old_conf on $(date '+%F %T') by $SCRIPT"
for d in "${dir_new[@]}"; do
  [[ -d $d ]] || install -d -o "$user" -g "$group" -- "$d" || fail "Не удалось создать $d"
  ok "Создан каталог $d (владелец $user)"
done
dirs_ok() { local kv; for kv in "${dir_props[@]}"; do [[ $(prop "$new_conf" "${kv%%=*}") == "${kv#*=}" ]] || return 1; done; }
if [[ $mode == fresh ]]; then
  props=("serverUrl=$server" "name=$name" "${dir_props[@]}")
  if ((keep_old)); then props+=("ownPort=9091"); fi
  set_props "$new_dir/conf/buildAgent.dist.properties" "${props[@]}" > "$work/conf"
  if ((added > 0)); then { printf '\n%s\n' "$hdr"; cat -- "$work/add"; } >> "$work/conf"; fi
  install -m 600 -o "$user" -g "$group" -- "$work/conf" "$new_conf"   # the agent writes its token there
  compare "$new_conf" "$old_conf"
  if [[ $(norm_url "$(prop "$new_conf" serverUrl)") == "$server" && $(prop "$new_conf" name) == "$name" &&
        $(count ADD) -eq 0 && ( $keep_old -eq 0 || $(prop "$new_conf" ownPort) == 9091 ) ]] && dirs_ok; then
    s="serverUrl, name"
    if ((added > 0)); then s+=", + $added параметр(ов) старого агента"; fi
    if ((${#dir_props[@]} > 0)); then s+=", ${dir_props[*]}"; fi
    if ((keep_old)); then s+=", ownPort=9091"; fi
    ok "Настройки записаны и проверены: $new_conf ($s)"
  else
    fail "Настройки в $new_conf не совпали с ожидаемыми"
  fi
elif ((added > 0 || ${#dir_props[@]} > 0)); then
  bk=$new_conf.bak-$(date +%Y%m%d-%H%M%S)
  if [[ -e $bk || -L $bk ]]; then fail "$bk уже есть - резервную копию поверх не пишу"; fi
  as_conf_owner cp -p --no-clobber -- "$new_conf" "$bk" && as_conf_owner chmod go-rwx -- "$bk" &&
    [[ -f $bk && ! -L $bk ]] || fail "Не удалось сделать резервную копию $new_conf"
  conf_bk=$bk   # the Итог prints the restore command only for a backup that was really made
  ok "Резервная копия настроек: $conf_bk"
  if ((${#dir_props[@]} > 0)); then
    set_props "$new_conf" "${dir_props[@]}" > "$work/conf2" || fail "Не удалось подготовить $new_conf"
    as_conf_owner tee -- "$new_conf" < "$work/conf2" > /dev/null || fail "Не удалось записать $new_conf. Откат: sudo cp -p $conf_bk $new_conf"
    dirs_ok || fail "Рабочие папки не записались в $new_conf. Откат: sudo cp -p $conf_bk $new_conf"
    ok "Рабочие папки - как у старого агента: ${dir_props[*]}"
  fi
  if ((added > 0)); then
    if [[ -s $new_conf && $(tail -c 1 -- "$new_conf" | wc -l) -eq 0 ]]; then printf '\n' | as_conf_owner tee -a -- "$new_conf" > /dev/null; fi
    { printf '\n%s\n' "$hdr"; cat -- "$work/add"; } | as_conf_owner tee -a -- "$new_conf" > /dev/null
  fi
  compare "$new_conf" "$old_conf"
  if (($(count ADD) == 0)); then
    if ((added > 0)); then ok "Добавлено и проверено параметров: $added ($add_keys)"; fi
  else
    fail "Параметры не записались в $new_conf. Откат: sudo cp -p $conf_bk $new_conf"
  fi
fi
if ((perm_fix)); then
  as_conf_owner chmod go-rwx -- "$new_conf" || fail "chmod 600 $new_conf не прошёл"
  ok "Права $new_conf: $(stat -c %a -- "$new_conf") (только пользователь агента)"
fi
for f in "${open_copies[@]}"; do
  if [[ -f $f && ! -L $f ]]; then as_conf_owner chmod go-rwx -- "$f" || fail "chmod go-rwx $f не прошёл"; fi
done
if ((${#open_copies[@]} > 0)); then ok "Копии настроек закрыты от других пользователей: ${#open_copies[@]}"; fi
if [[ $mode == adopt ]]; then marker_write || fail "Не удалось записать $new_dir/$MARKER"; fi

# 5. owner of the new folder (only it)
if ((owner_fix)); then
  why=$(protected_reason "$new_dir") && fail "Каталог $new_dir: $why - chown не делаю"
  chown -R -- "$user:$group" "$new_dir" || fail "chown -R $user:$group $new_dir не прошёл"
  if [[ -n $(find "$new_dir" -xdev ! -user "$user" -print -quit 2>/dev/null) ]]; then fail "В $new_dir остались файлы не пользователя $user"; fi
  ok "Каталог $new_dir принадлежит пользователю $user"
fi

# 6. systemd unit (enabled, not started yet)
if [[ -n $unit_action ]]; then
  tmp=$(mktemp "$unit_file.XXXXXX")
  cat -- "$work/unit" > "$tmp" && chmod 644 -- "$tmp" && mv -f -- "$tmp" "$unit_file" || { rm -f -- "$tmp"; fail "Не удалось записать $unit_file"; }
  systemctl daemon-reload
  if [[ $(unit_show "$service.service" LoadState) != loaded || $(unit_show "$service.service" FragmentPath) != "$unit_file" ]]; then
    fail "systemd не принял $unit_file: $(systemd-analyze verify "$unit_file" 2>&1 | head -n 3 | tr '\n' ' ')"
  fi
  if [[ $unit_action == create ]]; then ok "Служба $service создана: $unit_file"; else ok "Служба $service перезаписана: $unit_file"; fi
fi
dropin_del "$service.service"
if [[ $(unit_enabled "$service.service") != enabled ]]; then
  systemctl enable -- "$service.service" >/dev/null 2>&1 || fail "systemctl enable $service не прошёл"
  undo_push "автозапуск службы $service выключен" systemctl disable -- "$service.service"
  ok "Автозапуск службы $service включён (служба пока не запущена)"
fi

# 7. the old agent: graceful stop, then its autostart off
if ((keep_old == 0)); then
  agent_runinfo "$old_dir"
  autostart_scan "$old_dir" "$RUN_UNIT"
  if [[ -n $RUN_PIDS ]]; then
    rc=0
    stop_agent "$old_dir" "$wait_s" "$force" || rc=$?
    if ((rc == 3)); then
      # Nothing was sent: the old agent and its autostart stay as they are, the new one as it was before this run.
      trap '' INT HUP TERM
      warn "На старом агенте всё ещё идёт сборка (дольше ${wait_s} с) - старого агента не останавливаю, сборку не прерываю"
      if ((${#UNDO[@]} > 0)); then info "Возвращаю как было:"; undo_run; fi
      phase=end
      section 'Итог'
      new_state
      info "Новый агент в ${new_dir}: ${NEW_STATE}. Старый агент и его автозапуск не тронуты."
      info "Запустите скрипт снова после окончания сборки (или с --force, чтобы прервать её): sudo bash $SCRIPT${rerun}"
      exit 3
    elif ((rc == 4)); then
      # 'agent.sh stop' was sent and cannot be taken back: the old agent exits after this build anyway.
      old_touched=1 old_draining=1 AS_RESTART=1
      warn "Старый агент доделывает сборку, которая началась перед остановкой: он остановится после неё (сборка не прервана)"
      info "Новый агент запускаю рядом (у него свой порт), старый остановится сам."
    elif ((rc != 0)); then
      fail "Старый агент не остановлен"
    else
      old_touched=1
    fi
  fi
  if autostart_running; then
    old_touched=1
    autostart_off "$old_dir" || fail "Автозапуск старого агента не выключен"
  fi
fi

# 8. start the new agent and check it
log=$new_dir/logs/teamcity-agent.log
if ((do_start)); then
  proc_scan
  if [[ -n $(agent_jvms_in "$new_dir") ]]; then fail "Агент из $new_dir уже работает - второй экземпляр не запускаю"; fi
  off=$(log_size "$log")
  cmd=start
  if [[ $(unit_show "$service.service" ActiveState) == active ]]; then cmd=restart; fi
  undo_push "служба $service остановлена" systemctl stop -- "$service.service"
  if ! out=$(systemctl "$cmd" -- "$service.service" 2>&1); then
    printf '%s\n' "$out" | mask | sed 's/^/           /'
    diag
    fail "systemctl $cmd $service не прошёл"
  fi
  if ! wait_new_jvm 120; then
    diag
    fail "Процесс агента не появился за 120 с"
  fi
  new_user=$(proc_user "$NEW_PID") || new_user=''
  new_jre=$(java_home_of "$NEW_PID") || new_jre=''
  how=$(started_by "$NEW_PID") || how=''
  if [[ $new_user != "$user" ]]; then diag; fail "Агент работает от ${new_user:-?}, а не от $user"; fi
  if [[ $(realpath -m -- "$new_jre/bin/java") != "$(realpath -m -- "$jdk/bin/java")" ]]; then diag; fail "Агент запущен не на Java $jdk, а на ${new_jre:-?}"; fi
  if [[ $how != "system $service.service" ]]; then warn "Процесс агента не в службе $service (${how:-?})"; fi
  ok "Служба $service работает: агент PID $NEW_PID, пользователь $user, Java $jdk"
  info "Жду регистрации агента на сервере (до 120 с)..."
  left=120 longer=0 text=''
  while :; do
    text=$(log_new "$log" "$off")
    if grep -q 'Registered on server' <<< "$text"; then break; fi
    if ((longer == 0)) && grep -qi 'upgrad' <<< "$text"; then
      longer=1 left=$((left + 480)); info "Агент обновляется с сервера - жду дольше (до 10 мин)"
    fi
    if ((left <= 0)); then break; fi
    sleep 3; left=$((left - 3))
  done
  lines=$(grep -E 'Registered on server|Registering on server|Error registering|unauthorized|Agent Web server started|[Uu]pgrad|ERROR' <<< "$text" | tail -n 6 || true)
  if [[ -n $lines ]]; then
    info "Записи журнала агента ($log):"
    printf '%s\n' "$lines" | mask | cut -c1-220 | sed 's/^/           /'
  fi
  if grep -q 'Registered on server' <<< "$text"; then
    ok "Агент зарегистрировался на сервере $server"
  else
    diag
    fail "Агент не зарегистрировался на сервере за отведённое время"
  fi
else
  ok "Новый агент уже работает через службу $service - не перезапускаю"
fi
phase=end
UNDO=()
summary
((problems == 0)) || exit 1
exit 0
