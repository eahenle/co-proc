# co-proc: named zsh coprocesses.
#
# Source this file from zsh:
#
#   source /path/to/co-proc.zsh
#
# Native `coproc ...` syntax remains native.  co-proc adds explicit commands:
#
#   co-proc start NAME COMMAND [ARG...]
#   co-proc spawn NAME COMMAND [ARG...]
#   co-proc attach NAME
#   co-proc send NAME TEXT...
#   co-proc read [-t SECONDS] [NAME]
#   co-proc recv [-t SECONDS] NAME
#   co-proc list
#   co-proc stop NAME
#
# Interactive users may opt into the ZLE integration with:
#
#   co-proc enable-zle
#
# That widget rewrites simple extended forms such as `coproc calc bc -l` into
# `co-proc start calc -- bc -l` before the line is accepted.

typeset -g CO_PROC_VERSION=${CO_PROC_VERSION:-0.2.0}
typeset -g CO_PROC_CURRENT=${CO_PROC_CURRENT:-}
typeset -g CO_PROC_START_SETTLE=${CO_PROC_START_SETTLE:-0.02}
typeset -g CO_PROC_STOP_GRACE=${CO_PROC_STOP_GRACE:-0.05}
typeset -g CO_PROC_RUNTIME_ROOT=${CO_PROC_RUNTIME_ROOT:-${TMPDIR:-/tmp}/co-proc-${EUID}}
typeset -gi CO_PROC_MAX_FRAME_BYTES=${CO_PROC_MAX_FRAME_BYTES:-4095}
typeset -gi CO_PROC_MAX_BUFFER_BYTES=${CO_PROC_MAX_BUFFER_BYTES:-65536}
typeset -gi CO_PROC_ZLE_ENABLED=${CO_PROC_ZLE_ENABLED:-0}

typeset -gA CO_PROC_IN
typeset -gA CO_PROC_OUT
typeset -gA CO_PROC_PID
typeset -gA CO_PROC_CMD
typeset -gA CO_PROC_STARTED
typeset -gA CO_PROC_EXIT
typeset -gA CO_PROC_ATTACH_IN
typeset -gA CO_PROC_ATTACH_OUT
typeset -gA CO_PROC_ATTACH_PID
typeset -gA CO_PROC_PUMP_FD
typeset -gA CO_PROC_PUMP_NAME
typeset -gA CO_PROC_PUMP_BUFFER
typeset -gA CO_PROC_PUMP_QUEUE

co_proc__err() {
  emulate -L zsh
  print -ru2 -- "co-proc: $*"
}

co_proc__usage() {
  emulate -L zsh
  cat <<'EOF'
co-proc: named zsh coprocesses

Usage:
  co-proc start NAME COMMAND [ARG...]
  co-proc spawn NAME COMMAND [ARG...]
  co-proc attach NAME
  co-proc list
  co-proc info NAME
  co-proc stop [-f] NAME
  co-proc send NAME TEXT...
  co-proc read [-t SECONDS] [NAME]
  co-proc recv [-t SECONDS] NAME
  co-proc pump [-t SECONDS] [NAME...]
  co-proc switch NAME
  co-proc current
  co-proc wait NAME
  co-proc prune
  co-proc enable-zle
  co-proc disable-zle

Convenience aliases:
  cpsend, cpread, cplist, cpstop

Compatibility:
  Native zsh `coproc ...` is not replaced. Use `co-proc enable-zle`
  to opt into interactive rewriting for `coproc NAME COMMAND...`.
EOF
}

co_proc__valid_name() {
  emulate -L zsh
  [[ $# -eq 1 && $1 =~ '^[A-Za-z_][A-Za-z0-9_-]*$' ]]
}

co_proc__exists() {
  emulate -L zsh
  [[ $# -eq 1 && -n ${CO_PROC_PID[$1]-} ]]
}

co_proc__state() {
  emulate -L zsh
  local name=$1 pid=${CO_PROC_PID[$1]-}

  if [[ -z $pid ]]; then
    print -- "missing"
    return 1
  fi

  if kill -0 "$pid" 2>/dev/null; then
    print -- "running"
  else
    print -- "exited"
  fi
}

co_proc__command_available() {
  emulate -L zsh
  [[ -n ${1:-} ]] || return 1
  whence -w -- "$1" >/dev/null 2>&1
}

co_proc__resolve_name() {
  emulate -L zsh
  local requested=${1:-}
  local -a names

  if [[ -n $requested ]]; then
    print -- "$requested"
    return 0
  fi

  if [[ -n $CO_PROC_CURRENT && -n ${CO_PROC_PID[$CO_PROC_CURRENT]-} ]]; then
    print -- "$CO_PROC_CURRENT"
    return 0
  fi

  names=(${(k)CO_PROC_PID})
  if (( ${#names} == 1 )); then
    print -- "$names[1]"
    return 0
  fi

  co_proc__err "missing NAME and no unambiguous current coprocess"
  return 64
}

co_proc__now() {
  emulate -L zsh
  zmodload zsh/datetime 2>/dev/null
  print -- "${EPOCHSECONDS:-0}"
}

co_proc__stat_owner() {
  emulate -L zsh
  local target=$1 owner

  owner=$(stat -f '%u' "$target" 2>/dev/null) || owner=$(stat -c '%u' -- "$target" 2>/dev/null) || return 1
  print -r -- "$owner"
}

co_proc__stat_mode() {
  emulate -L zsh
  local target=$1 mode

  mode=$(stat -f '%Lp' "$target" 2>/dev/null) || mode=$(stat -c '%a' -- "$target" 2>/dev/null) || return 1
  print -r -- "$mode"
}

co_proc__secure_runtime_root() {
  emulate -L zsh
  local root=$CO_PROC_RUNTIME_ROOT owner mode

  if [[ $root == *$'\n'* || $root == *$'\r'* || $root == *'"'* || $root == *'\\'* ]]; then
    co_proc__err "runtime root contains characters that cannot be represented safely in metadata"
    return 65
  fi

  if [[ -L $root ]]; then
    co_proc__err "unsafe runtime root is a symlink: $root"
    return 73
  fi

  if [[ ! -e $root ]]; then
    (umask 077 && mkdir -p "$root") || {
      co_proc__err "cannot create runtime root: $root"
      return 73
    }
  fi

  if [[ ! -d $root ]]; then
    co_proc__err "runtime root is not a directory: $root"
    return 73
  fi

  owner=$(co_proc__stat_owner "$root") || return 73
  mode=$(co_proc__stat_mode "$root") || return 73
  if [[ $owner != "$EUID" || $mode != 700 ]]; then
    co_proc__err "runtime root must be owned by uid $EUID with mode 700: $root"
    return 73
  fi
}

co_proc__endpoint_dir() {
  emulate -L zsh
  local name=$1

  co_proc__valid_name "$name" || return 65
  print -r -- "$CO_PROC_RUNTIME_ROOT/$name"
}

co_proc__discover_attachable() {
  emulate -L zsh
  local name=$1 dir metadata content metadata_name pid owner endpoint_path path_owner path_mode

  if ! co_proc__valid_name "$name"; then
    co_proc__err "invalid name '$name' (use [A-Za-z_][A-Za-z0-9_-]*)"
    return 65
  fi

  co_proc__secure_runtime_root || return $?
  dir=$(co_proc__endpoint_dir "$name") || return $?
  metadata="$dir/metadata.json"

  if [[ -L $dir || ! -d $dir || -L $metadata || ! -f $metadata ]]; then
    co_proc__err "unknown attachable coprocess '$name'"
    return 66
  fi

  path_owner=$(co_proc__stat_owner "$dir") || return 73
  path_mode=$(co_proc__stat_mode "$dir") || return 73
  if [[ $path_owner != "$EUID" || $path_mode != 700 ]]; then
    co_proc__err "unsafe endpoint directory for '$name'"
    return 73
  fi

  for endpoint_path in "$metadata" "$dir/input" "$dir/output"; do
    if [[ -L $endpoint_path ]]; then
      co_proc__err "unsafe endpoint path for '$name': $endpoint_path"
      return 73
    fi
    path_owner=$(co_proc__stat_owner "$endpoint_path") || return 73
    path_mode=$(co_proc__stat_mode "$endpoint_path") || return 73
    if [[ $path_owner != "$EUID" || $path_mode != 600 ]]; then
      co_proc__err "unsafe endpoint ownership or permissions for '$name': $endpoint_path"
      return 73
    fi
  done

  if [[ ! -p $dir/input || ! -p $dir/output ]]; then
    co_proc__err "attachable endpoint for '$name' is not a FIFO pair"
    return 73
  fi

  content=$(<"$metadata") || return 74
  if [[ $content =~ '"name"[[:space:]]*:[[:space:]]*"([A-Za-z_][A-Za-z0-9_-]*)"' ]]; then
    metadata_name=$match[1]
  fi
  if [[ $content =~ '"pid"[[:space:]]*:[[:space:]]*([0-9]+)' ]]; then
    pid=$match[1]
  fi
  if [[ $content =~ '"owner_uid"[[:space:]]*:[[:space:]]*([0-9]+)' ]]; then
    owner=$match[1]
  fi

  if [[ $metadata_name != "$name" || $owner != "$EUID" || -z $pid ]]; then
    co_proc__err "invalid metadata for attachable coprocess '$name'"
    return 74
  fi

  CO_PROC_ATTACH_IN[$name]="$dir/input"
  CO_PROC_ATTACH_OUT[$name]="$dir/output"
  CO_PROC_ATTACH_PID[$name]=$pid
}

co_proc__attachable_state() {
  emulate -L zsh
  local name=$1 pid=${CO_PROC_ATTACH_PID[$name]-}

  [[ -n $pid ]] || co_proc__discover_attachable "$name" >/dev/null || {
    print -r -- missing
    return 1
  }
  pid=${CO_PROC_ATTACH_PID[$name]}
  if kill -0 "$pid" 2>/dev/null; then
    print -r -- running
  else
    print -r -- exited
  fi
}

co_proc__validate_frame() {
  emulate -L zsh
  local LC_ALL=C frame=$1

  if [[ -z $frame || $frame == *$'\n'* || $frame == *$'\r'* ]]; then
    co_proc__err "frame must be one non-empty NDJSON line"
    return 65
  fi
  if (( ${#frame} > CO_PROC_MAX_FRAME_BYTES )); then
    co_proc__err "frame exceeds CO_PROC_MAX_FRAME_BYTES=$CO_PROC_MAX_FRAME_BYTES"
    return 75
  fi
  if [[ ! $frame =~ '^\{.*\}$' || ! $frame =~ '"version"[[:space:]]*:[[:space:]]*1([[:space:]]*[,}])' || ! $frame =~ '"type"[[:space:]]*:[[:space:]]*"[^"[:space:]]+"' || ! $frame =~ '"id"[[:space:]]*:[[:space:]]*"[^"[:space:]]+"' ]]; then
    co_proc__err "frame must be a version 1 JSON object with non-empty type and id"
    return 65
  fi
}

co_proc_spawn() {
  emulate -L zsh
  setopt no_nomatch
  local name dir input output metadata metadata_tmp error_log child_pid_file broker_pid pid started attempt
  local -a command

  name=${1:-}
  [[ -n $name ]] || {
    co_proc__err "spawn requires NAME"
    return 64
  }
  shift
  co_proc__valid_name "$name" || {
    co_proc__err "invalid name '$name' (use [A-Za-z_][A-Za-z0-9_-]*)"
    return 65
  }
  [[ ${1:-} == -- ]] && shift
  (( $# > 0 )) || {
    co_proc__err "spawn requires COMMAND"
    return 64
  }
  command=("$@")
  co_proc__command_available "$command[1]" || {
    co_proc__err "command not found: $command[1]"
    return 127
  }

  co_proc__secure_runtime_root || return $?
  dir=$(co_proc__endpoint_dir "$name") || return $?
  if [[ -e $dir || -L $dir ]]; then
    co_proc__err "attachable coprocess '$name' already exists; stop or prune it first"
    return 65
  fi

  (umask 077 && mkdir "$dir") || return 73
  input="$dir/input"
  output="$dir/output"
  metadata="$dir/metadata.json"
  metadata_tmp="$dir/.metadata.$$.tmp"
  error_log="$dir/stderr.log"
  child_pid_file="$dir/child.pid"
  if ! mkfifo "$input" "$output" || ! chmod 600 "$input" "$output" || ! : >| "$error_log" || ! chmod 600 "$error_log"; then
    co_proc__err "failed to create attachable endpoints for '$name'"
    co_proc__remove_attachable_dir "$name" >/dev/null 2>&1 || :
    return 73
  fi

  (
    emulate -L zsh
    trap '' HUP
    exec 3<>"$input"
    exec 4<>"$output"
    "$@" <&3 >&4 2>>"$error_log" &
    local child_pid=$!
    print -r -- "$child_pid" >| "$child_pid_file"
    chmod 600 "$child_pid_file"
    trap 'kill -TERM "$child_pid" 2>/dev/null || :; wait "$child_pid" 2>/dev/null || :; exit 0' TERM INT
    wait "$child_pid"
  ) &!
  broker_pid=$!
  for attempt in {1..20}; do
    [[ -s $child_pid_file ]] && break
    kill -0 "$broker_pid" 2>/dev/null || break
    sleep 0.005 2>/dev/null || :
  done
  pid=$(<"$child_pid_file") 2>/dev/null || pid=
  sleep "$CO_PROC_START_SETTLE" 2>/dev/null || :
  if [[ -z $pid ]] || ! kill -0 "$pid" 2>/dev/null; then
    co_proc__err "command for attachable coprocess '$name' exited during startup"
    kill -TERM "$broker_pid" 2>/dev/null || :
    co_proc__remove_attachable_dir "$name" >/dev/null 2>&1 || :
    return 70
  fi

  started=$(co_proc__now)
  {
    print -r -- '{'
    print -r -- '  "version": 1,'
    print -r -- "  \"name\": \"$name\","
    print -r -- "  \"pid\": $pid,"
    print -r -- "  \"owner_uid\": $EUID,"
    print -r -- "  \"started\": $started,"
    print -r -- "  \"input\": \"$input\","
    print -r -- "  \"output\": \"$output\""
    print -r -- '}'
  } >| "$metadata_tmp" || {
    kill -TERM "$pid" 2>/dev/null || :
    co_proc__remove_attachable_dir "$name" >/dev/null 2>&1 || :
    return 74
  }
  chmod 600 "$metadata_tmp" || {
    kill -TERM "$pid" 2>/dev/null || :
    co_proc__remove_attachable_dir "$name" >/dev/null 2>&1 || :
    return 73
  }
  mv "$metadata_tmp" "$metadata" || {
    kill -TERM "$pid" 2>/dev/null || :
    co_proc__remove_attachable_dir "$name" >/dev/null 2>&1 || :
    return 74
  }

  CO_PROC_ATTACH_IN[$name]=$input
  CO_PROC_ATTACH_OUT[$name]=$output
  CO_PROC_ATTACH_PID[$name]=$pid
}

co_proc_attach() {
  emulate -L zsh
  local name=${1:-} buffered

  [[ -n $name ]] || {
    co_proc__err "attach requires NAME"
    return 64
  }
  co_proc__discover_attachable "$name" || return $?
  print -r -- "name=$name"
  print -r -- "pid=${CO_PROC_ATTACH_PID[$name]}"
  print -r -- "input=${CO_PROC_ATTACH_IN[$name]}"
  print -r -- "output=${CO_PROC_ATTACH_OUT[$name]}"
  print -r -- "state=$(co_proc__attachable_state "$name")"
  buffered=${CO_PROC_PUMP_QUEUE[$name]-}${CO_PROC_PUMP_BUFFER[$name]-}
  print -r -- "buffered_bytes=${#buffered}"
}

co_proc_send_attachable() {
  emulate -L zsh
  local name=$1 frame=$2 state

  co_proc__discover_attachable "$name" || return $?
  state=$(co_proc__attachable_state "$name")
  [[ $state == running ]] || {
    co_proc__err "attachable coprocess '$name' is not running"
    return 69
  }
  co_proc__validate_frame "$frame" || return $?
  print -r -- "$frame" >"${CO_PROC_ATTACH_IN[$name]}"
}

co_proc_recv() {
  emulate -L zsh
  local timeout= name line rc state
  local -a read_args

  while (( $# > 0 )); do
    case $1 in
      -t|--timeout)
        shift
        [[ -n ${1:-} ]] || {
          co_proc__err "recv -t requires SECONDS"
          return 64
        }
        timeout=$1
        ;;
      --)
        shift
        break
        ;;
      -*)
        co_proc__err "unknown recv option '$1'"
        return 64
        ;;
      *)
        break
        ;;
    esac
    shift
  done

  name=${1:-}
  [[ -n $name ]] || {
    co_proc__err "recv requires NAME"
    return 64
  }
  co_proc__discover_attachable "$name" || return $?

  if [[ -n ${CO_PROC_PUMP_FD[$name]-} ]]; then
    if co_proc__pop_buffered_frame "$name"; then
      return 0
    fi
    if [[ -n $timeout ]]; then
      co_proc_pump -t "$timeout" "$name" >/dev/null || :
    else
      co_proc_pump "$name" >/dev/null || :
    fi
    co_proc__pop_buffered_frame "$name"
    return $?
  fi

  read_args=(-r)
  [[ -n $timeout ]] && read_args+=(-t "$timeout")
  IFS= read "${read_args[@]}" line <"${CO_PROC_ATTACH_OUT[$name]}"
  rc=$?
  if (( rc == 0 )); then
    if (( ${#line} > CO_PROC_MAX_FRAME_BYTES )); then
      co_proc__err "received frame exceeds CO_PROC_MAX_FRAME_BYTES=$CO_PROC_MAX_FRAME_BYTES"
      return 75
    fi
    co_proc__validate_frame "$line" || return $?
    print -r -- "$line"
  else
    state=$(co_proc__attachable_state "$name")
    [[ $state == running ]] || co_proc__err "attachable coprocess '$name' exited"
  fi
  return "$rc"
}

co_proc__open_pump_fd() {
  emulate -L zsh
  local name=$1 pump_fd

  co_proc__discover_attachable "$name" || return $?
  if [[ -n ${CO_PROC_PUMP_FD[$name]-} ]]; then
    return 0
  fi
  exec {pump_fd}<>"${CO_PROC_ATTACH_OUT[$name]}" || {
    co_proc__err "cannot open attachable output for '$name'"
    return 74
  }
  CO_PROC_PUMP_FD[$name]=$pump_fd
  CO_PROC_PUMP_NAME[$pump_fd]=$name
  CO_PROC_PUMP_BUFFER[$name]=${CO_PROC_PUMP_BUFFER[$name]-}
  CO_PROC_PUMP_QUEUE[$name]=${CO_PROC_PUMP_QUEUE[$name]-}
}

co_proc__queue_pump_chunk() {
  emulate -L zsh
  local LC_ALL=C name=$1 chunk=$2 buffer line queue rc

  buffer=${CO_PROC_PUMP_BUFFER[$name]-}$chunk
  queue=${CO_PROC_PUMP_QUEUE[$name]-}
  if (( ${#buffer} + ${#queue} > CO_PROC_MAX_BUFFER_BYTES )); then
    co_proc__err "buffer for '$name' exceeds CO_PROC_MAX_BUFFER_BYTES=$CO_PROC_MAX_BUFFER_BYTES"
    return 75
  fi

  while [[ $buffer == *$'\n'* ]]; do
    line=${buffer%%$'\n'*}
    buffer=${buffer#*$'\n'}
    co_proc__validate_frame "$line" || {
      rc=$?
      CO_PROC_PUMP_BUFFER[$name]=$buffer
      return "$rc"
    }
    CO_PROC_PUMP_QUEUE[$name]+="$line"$'\n'
  done
  CO_PROC_PUMP_BUFFER[$name]=$buffer
}

co_proc__pop_buffered_frame() {
  emulate -L zsh
  local name=$1 queue line

  queue=${CO_PROC_PUMP_QUEUE[$name]-}
  [[ $queue == *$'\n'* ]] || return 1
  line=${queue%%$'\n'*}
  CO_PROC_PUMP_QUEUE[$name]=${queue#*$'\n'}
  print -r -- "$line"
}

co_proc_pump() {
  emulate -L zsh
  setopt null_glob
  zmodload zsh/zselect 2>/dev/null || {
    co_proc__err "zsh/zselect is unavailable"
    return 69
  }
  zmodload zsh/system 2>/dev/null || {
    co_proc__err "zsh/system is unavailable"
    return 69
  }

  local timeout= name dir fd chunk
  integer timeout_cs=0 count=0 bytes=0
  local -a names endpoint_dirs fds
  local -A ready

  while (( $# > 0 )); do
    case $1 in
      -t|--timeout)
        shift
        [[ -n ${1:-} ]] || {
          co_proc__err "pump -t requires SECONDS"
          return 64
        }
        timeout=$1
        ;;
      --)
        shift
        break
        ;;
      -*)
        co_proc__err "unknown pump option '$1'"
        return 64
        ;;
      *)
        break
        ;;
    esac
    shift
  done
  names=("$@")

  if [[ -n $timeout ]]; then
    [[ $timeout =~ '^[0-9]+([.][0-9]+)?$' ]] || {
      co_proc__err "pump timeout must be a non-negative number"
      return 64
    }
    timeout_cs=$(( timeout * 100 ))
  fi

  if (( ${#names} == 0 )); then
    if co_proc__secure_runtime_root >/dev/null 2>&1; then
      endpoint_dirs=("$CO_PROC_RUNTIME_ROOT"/*(/N))
      for dir in "${endpoint_dirs[@]}"; do
        names+=("${dir:t}")
      done
    fi
  fi
  (( ${#names} > 0 )) || {
    co_proc__err "pump found no attachable coprocesses"
    return 66
  }

  for name in "${names[@]}"; do
    co_proc__open_pump_fd "$name" || return $?
    fds+=("${CO_PROC_PUMP_FD[$name]}")
  done

  if [[ -n $timeout ]]; then
    zselect -A ready -t "$timeout_cs" -r "${fds[@]}" || return 1
  else
    zselect -A ready -r "${fds[@]}" || return 1
  fi

  for fd in ${(k)ready}; do
    [[ ${ready[$fd]} == *r* ]] || continue
    name=${CO_PROC_PUMP_NAME[$fd]-}
    [[ -n $name ]] || continue
    while sysread -i "$fd" -s 8192 -t 0 -c bytes chunk; do
      (( bytes > 0 )) || break
      co_proc__queue_pump_chunk "$name" "$chunk" || return $?
      (( count += bytes ))
      (( bytes < 8192 )) && break
    done
  done
  REPLY=$count
  (( count > 0 ))
}

co_proc__remove_attachable_dir() {
  emulate -L zsh
  setopt null_glob
  local name=$1 dir

  co_proc__valid_name "$name" || return 65
  if [[ -n ${CO_PROC_PUMP_FD[$name]-} ]]; then
    local pump_fd=${CO_PROC_PUMP_FD[$name]}
    exec {pump_fd}>&- 2>/dev/null || :
    unset "CO_PROC_PUMP_NAME[$pump_fd]"
  fi
  dir=$(co_proc__endpoint_dir "$name") || return $?
  [[ $dir == "$CO_PROC_RUNTIME_ROOT/$name" && -d $dir && ! -L $dir ]] || return 73
  command rm -f "$dir/input" "$dir/output" "$dir/metadata.json" "$dir/stderr.log" "$dir/child.pid" "$dir"/.metadata.*.tmp 2>/dev/null || :
  rmdir "$dir" 2>/dev/null || return 73
  unset "CO_PROC_ATTACH_IN[$name]" "CO_PROC_ATTACH_OUT[$name]" "CO_PROC_ATTACH_PID[$name]"
  unset "CO_PROC_PUMP_FD[$name]" "CO_PROC_PUMP_BUFFER[$name]" "CO_PROC_PUMP_QUEUE[$name]"
}

co_proc_stop_attachable() {
  emulate -L zsh
  local force=$1 quiet=$2 name=$3 pid

  if ! co_proc__discover_attachable "$name" >/dev/null 2>&1; then
    (( quiet )) || co_proc__err "unknown coprocess '$name'"
    return 66
  fi
  pid=${CO_PROC_ATTACH_PID[$name]}
  if kill -0 "$pid" 2>/dev/null; then
    if (( force )); then
      kill -KILL "$pid" 2>/dev/null || :
    else
      kill -TERM "$pid" 2>/dev/null || :
      sleep "$CO_PROC_STOP_GRACE" 2>/dev/null || :
      kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || :
    fi
  fi
  co_proc__remove_attachable_dir "$name"
}

co_proc_start() {
  emulate -L zsh
  setopt no_nomatch

  local name
  local outfd infd pid
  local -a command

  if [[ ${1:-} == "--" ]]; then
    shift
  fi

  name=${1:-}
  if [[ -z $name ]]; then
    co_proc__err "start requires NAME"
    return 64
  fi
  shift

  if ! co_proc__valid_name "$name"; then
    co_proc__err "invalid name '$name' (use [A-Za-z_][A-Za-z0-9_-]*)"
    return 65
  fi

  if co_proc__exists "$name"; then
    co_proc__err "coprocess '$name' already exists"
    return 65
  fi

  if [[ ${1:-} == "--" ]]; then
    shift
  fi

  if (( $# == 0 )); then
    co_proc__err "start requires COMMAND"
    return 64
  fi

  command=("$@")

  if ! co_proc__command_available "$command[1]"; then
    co_proc__err "command not found: $command[1]"
    return 127
  fi

  coproc "$@" || {
    co_proc__err "failed to start '$name'"
    return 70
  }
  pid=$!

  if ! exec {outfd}<&p; then
    co_proc__err "failed to capture stdout fd for '$name'"
    return 70
  fi

  if ! exec {infd}>&p; then
    exec {outfd}<&- 2>/dev/null
    co_proc__err "failed to capture stdin fd for '$name'"
    return 70
  fi

  # Give immediate exec failures a chance to surface.  A process that exits
  # before it can exchange data is not useful as a registered coprocess.
  sleep "$CO_PROC_START_SETTLE" 2>/dev/null || :
  if ! kill -0 "$pid" 2>/dev/null; then
    local rc
    wait "$pid" 2>/dev/null
    rc=$?
    exec {infd}>&- 2>/dev/null
    exec {outfd}<&- 2>/dev/null
    co_proc__err "command for '$name' exited during startup (status $rc)"
    return "$rc"
  fi

  CO_PROC_OUT[$name]=$outfd
  CO_PROC_IN[$name]=$infd
  CO_PROC_PID[$name]=$pid
  CO_PROC_CMD[$name]="${(j: :)${(q)command}}"
  CO_PROC_STARTED[$name]="$(co_proc__now)"
  unset "CO_PROC_EXIT[$name]"
  CO_PROC_CURRENT=$name
}

co_proc_send() {
  emulate -L zsh
  local name=${1:-}
  local fd

  if [[ -z $name ]]; then
    co_proc__err "send requires NAME"
    return 64
  fi
  shift

  if ! co_proc__exists "$name"; then
    if (( $# != 1 )); then
      co_proc__err "attachable send requires exactly one NDJSON frame"
      return 64
    fi
    co_proc_send_attachable "$name" "$1"
    return $?
  fi

  if [[ $(co_proc__state "$name") != running ]]; then
    co_proc__err "coprocess '$name' is not running"
    return 69
  fi

  fd=${CO_PROC_IN[$name]}
  print -r -- "$*" >&$fd
}

co_proc_read() {
  emulate -L zsh
  local timeout= name line rc fd
  local -a read_args

  while (( $# > 0 )); do
    case $1 in
      -t|--timeout)
        shift
        if [[ -z ${1:-} ]]; then
          co_proc__err "read -t requires SECONDS"
          return 64
        fi
        timeout=$1
        ;;
      --)
        shift
        break
        ;;
      -*)
        co_proc__err "unknown read option '$1'"
        return 64
        ;;
      *)
        break
        ;;
    esac
    shift
  done

  name=$(co_proc__resolve_name "${1:-}") || return $?

  if ! co_proc__exists "$name"; then
    co_proc__err "unknown coprocess '$name'"
    return 66
  fi

  fd=${CO_PROC_OUT[$name]}
  read_args=(-r)
  if [[ -n $timeout ]]; then
    read_args+=(-t "$timeout")
  fi

  IFS= read "${read_args[@]}" line <&$fd
  rc=$?
  if (( rc == 0 )); then
    print -r -- "$line"
  elif [[ $(co_proc__state "$name") != running ]]; then
    co_proc__err "coprocess '$name' exited"
  fi
  return "$rc"
}

co_proc_stop() {
  emulate -L zsh
  local force=0 quiet=0 name pid infd outfd

  while (( $# > 0 )); do
    case $1 in
      -f|--force)
        force=1
        ;;
      -q|--quiet)
        quiet=1
        ;;
      --)
        shift
        break
        ;;
      -*)
        co_proc__err "unknown stop option '$1'"
        return 64
        ;;
      *)
        break
        ;;
    esac
    shift
  done

  name=$(co_proc__resolve_name "${1:-}") || return $?

  if ! co_proc__exists "$name"; then
    co_proc_stop_attachable "$force" "$quiet" "$name"
    return $?
  fi

  pid=${CO_PROC_PID[$name]}
  infd=${CO_PROC_IN[$name]}
  outfd=${CO_PROC_OUT[$name]}

  [[ -n $infd ]] && exec {infd}>&- 2>/dev/null
  [[ -n $outfd ]] && exec {outfd}<&- 2>/dev/null

  if kill -0 "$pid" 2>/dev/null; then
    if (( force )); then
      kill -KILL "$pid" 2>/dev/null || :
    else
      kill -TERM "$pid" 2>/dev/null || :
      sleep "$CO_PROC_STOP_GRACE" 2>/dev/null || :
      if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || :
      fi
    fi
  fi

  wait "$pid" 2>/dev/null || :

  unset "CO_PROC_IN[$name]" "CO_PROC_OUT[$name]" "CO_PROC_PID[$name]"
  unset "CO_PROC_CMD[$name]" "CO_PROC_STARTED[$name]" "CO_PROC_EXIT[$name]"
  if [[ $CO_PROC_CURRENT == "$name" ]]; then
    CO_PROC_CURRENT=
  fi
}

co_proc_wait() {
  emulate -L zsh
  local name=${1:-} pid rc infd outfd

  if [[ -z $name ]]; then
    co_proc__err "wait requires NAME"
    return 64
  fi

  if ! co_proc__exists "$name"; then
    co_proc__err "unknown coprocess '$name'"
    return 66
  fi

  pid=${CO_PROC_PID[$name]}
  wait "$pid"
  rc=$?

  infd=${CO_PROC_IN[$name]}
  outfd=${CO_PROC_OUT[$name]}
  [[ -n $infd ]] && exec {infd}>&- 2>/dev/null
  [[ -n $outfd ]] && exec {outfd}<&- 2>/dev/null

  CO_PROC_EXIT[$name]=$rc
  unset "CO_PROC_IN[$name]" "CO_PROC_OUT[$name]" "CO_PROC_PID[$name]"
  unset "CO_PROC_CMD[$name]" "CO_PROC_STARTED[$name]"
  if [[ $CO_PROC_CURRENT == "$name" ]]; then
    CO_PROC_CURRENT=
  fi
  return "$rc"
}

co_proc_list() {
  emulate -L zsh
  setopt null_glob
  local name state marker dir
  local -a endpoint_dirs

  for name in ${(ok)CO_PROC_PID}; do
    state=$(co_proc__state "$name")
    marker=
    [[ $name == "$CO_PROC_CURRENT" ]] && marker=" current"
    print -r -- "$name pid=${CO_PROC_PID[$name]} in=${CO_PROC_IN[$name]} out=${CO_PROC_OUT[$name]} state=$state$marker"
  done

  if co_proc__secure_runtime_root >/dev/null 2>&1; then
    endpoint_dirs=("$CO_PROC_RUNTIME_ROOT"/*(/N))
    for dir in "${endpoint_dirs[@]}"; do
      name=${dir:t}
      [[ -n ${CO_PROC_PID[$name]-} ]] && continue
      co_proc__discover_attachable "$name" >/dev/null 2>&1 || continue
      state=$(co_proc__attachable_state "$name")
      print -r -- "$name pid=${CO_PROC_ATTACH_PID[$name]} input=${CO_PROC_ATTACH_IN[$name]} output=${CO_PROC_ATTACH_OUT[$name]} state=$state attachable"
    done
  fi
}

co_proc_info() {
  emulate -L zsh
  local name=${1:-} state

  if [[ -z $name ]]; then
    co_proc__err "info requires NAME"
    return 64
  fi

  if ! co_proc__exists "$name"; then
    co_proc_attach "$name"
    return $?
  fi

  state=$(co_proc__state "$name")
  print -r -- "name=$name"
  print -r -- "pid=${CO_PROC_PID[$name]}"
  print -r -- "in=${CO_PROC_IN[$name]}"
  print -r -- "out=${CO_PROC_OUT[$name]}"
  print -r -- "state=$state"
  print -r -- "current=$([[ $name == "$CO_PROC_CURRENT" ]] && print yes || print no)"
  print -r -- "started=${CO_PROC_STARTED[$name]-}"
  print -r -- "command=${CO_PROC_CMD[$name]-}"
}

co_proc_switch() {
  emulate -L zsh
  local name=${1:-}

  if [[ -z $name ]]; then
    co_proc__err "switch requires NAME"
    return 64
  fi

  if ! co_proc__exists "$name"; then
    co_proc__err "unknown coprocess '$name'"
    return 66
  fi

  CO_PROC_CURRENT=$name
}

co_proc_prune() {
  emulate -L zsh
  setopt null_glob
  local name pid rc infd outfd dir
  local -a endpoint_dirs

  for name in ${(k)CO_PROC_PID}; do
    pid=${CO_PROC_PID[$name]}
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null
      rc=$?
      infd=${CO_PROC_IN[$name]}
      outfd=${CO_PROC_OUT[$name]}
      [[ -n $infd ]] && exec {infd}>&- 2>/dev/null
      [[ -n $outfd ]] && exec {outfd}<&- 2>/dev/null
      CO_PROC_EXIT[$name]=$rc
      unset "CO_PROC_IN[$name]" "CO_PROC_OUT[$name]" "CO_PROC_PID[$name]"
      unset "CO_PROC_CMD[$name]" "CO_PROC_STARTED[$name]"
      if [[ $CO_PROC_CURRENT == "$name" ]]; then
        CO_PROC_CURRENT=
      fi
    fi
  done


  if co_proc__secure_runtime_root >/dev/null 2>&1; then
    endpoint_dirs=("$CO_PROC_RUNTIME_ROOT"/*(/N))
    for dir in "${endpoint_dirs[@]}"; do
      name=${dir:t}
      co_proc__discover_attachable "$name" >/dev/null 2>&1 || continue
      pid=${CO_PROC_ATTACH_PID[$name]}
      if ! kill -0 "$pid" 2>/dev/null; then
        co_proc__remove_attachable_dir "$name" || return $?
      fi
    done
  fi
}

co_proc_cleanup() {
  emulate -L zsh
  local name

  for name in ${(k)CO_PROC_PID}; do
    co_proc_stop --force --quiet "$name" || :
  done
}

co_proc_install_hooks() {
  emulate -L zsh
  autoload -Uz add-zsh-hook 2>/dev/null || return 0
  add-zsh-hook -d zshexit co_proc_cleanup 2>/dev/null || :
  add-zsh-hook zshexit co_proc_cleanup 2>/dev/null || :
}

co_proc__is_registry_command() {
  emulate -L zsh
  case ${1:-} in
    list|ls|info|stop|send|read|recv|pump|attach|spawn|switch|current|wait|prune|help|version|enable-zle|disable-zle)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

co_proc__is_native_start_word() {
  emulate -L zsh
  case ${1:-} in
    "{"|"("|while|until|for|if|case|repeat|time|function|exec|command|builtin|do|done|then|else|elif|fi|esac|select|foreach)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

co_proc__is_operator_token() {
  emulate -L zsh
  setopt extendedglob
  local token=${1:-}

  case $token in
    "|"|"||"|"&"|"&&"|";"|";;"|";&"|";|"|"("|")"|"{"|"}"|"<"|">"|"<<"|">>"|"<>"|"<&"|">&"|"&>"|"&>>"|">|")
      return 0
      ;;
    *)
      [[ $token =~ '^[0-9]+[<>]' ]]
      return $?
      ;;
  esac
}

co_proc__line_has_operators() {
  emulate -L zsh
  local word

  for word in "$@"; do
    if co_proc__is_operator_token "$word"; then
      return 0
    fi
  done
  return 1
}

co_proc__rewrite_line() {
  emulate -L zsh
  setopt no_nomatch

  local line=${1-}
  local name tail command_tail
  local -a words

  words=(${(z)line}) || {
    print -r -- "$line"
    return 1
  }

  if (( ${#words} < 2 )) || [[ ${words[1]} != coproc ]]; then
    print -r -- "$line"
    return 1
  fi

  if co_proc__line_has_operators "${words[@]}"; then
    print -r -- "$line"
    return 1
  fi

  if co_proc__is_registry_command "${words[2]}"; then
    tail=${(j: :)words[2,-1]}
    print -r -- "co-proc $tail"
    return 0
  fi

  name=${words[2]}
  if (( ${#words} < 3 )) || co_proc__is_native_start_word "$name" || ! co_proc__valid_name "$name"; then
    print -r -- "$line"
    return 1
  fi

  command_tail=${(j: :)words[3,-1]}
  print -r -- "co-proc start ${(q)name} -- $command_tail"
}

co_proc_accept_line() {
  emulate -L zsh
  local rewritten

  rewritten=$(co_proc__rewrite_line "$BUFFER")
  if [[ $rewritten != "$BUFFER" ]]; then
    BUFFER=$rewritten
    CURSOR=${#BUFFER}
  fi

  if co_proc__zle_widget_exists co_proc_native_accept_line; then
    zle co_proc_native_accept_line
  else
    zle .accept-line
  fi
}

co_proc__zle_widget_exists() {
  emulate -L zsh
  local widget=${1:-}

  [[ -n $widget ]] || return 1
  zle -A "$widget" co_proc__zle_probe_widget 2>/dev/null || return 1
  zle -D co_proc__zle_probe_widget 2>/dev/null || :
}

co_proc__zle_accept_line_is_ours() {
  emulate -L zsh
  local spec

  spec=$(zle -lL accept-line 2>/dev/null) || return 1
  [[ $spec == "zle -N accept-line co_proc_accept_line" ]]
}

co_proc_enable_zle() {
  emulate -L zsh

  if [[ ! -o interactive ]]; then
    co_proc__err "ZLE is not available in this shell"
    return 69
  fi

  if co_proc__zle_accept_line_is_ours; then
    CO_PROC_ZLE_ENABLED=1
    return 0
  fi

  zle -N co_proc_accept_line || return $?
  zle -A accept-line co_proc_native_accept_line 2>/dev/null || \
    zle -A .accept-line co_proc_native_accept_line 2>/dev/null || return $?
  zle -N accept-line co_proc_accept_line || return $?
  CO_PROC_ZLE_ENABLED=1
}

co_proc_disable_zle() {
  emulate -L zsh

  if [[ ! -o interactive ]]; then
    return 0
  fi

  (( CO_PROC_ZLE_ENABLED )) || return 0

  if ! co_proc__zle_accept_line_is_ours; then
    CO_PROC_ZLE_ENABLED=0
    return 0
  fi

  zle -A co_proc_native_accept_line accept-line 2>/dev/null || \
    zle -A .accept-line accept-line 2>/dev/null || :
  zle -D co_proc_native_accept_line 2>/dev/null || :
  zle -D co_proc_accept_line 2>/dev/null || :
  CO_PROC_ZLE_ENABLED=0
}

co-proc() {
  emulate -L zsh
  local command=${1:-help}

  [[ $# -gt 0 ]] && shift

  case "$command" in
    start|new)
      co_proc_start "$@"
      ;;
    spawn)
      co_proc_spawn "$@"
      ;;
    attach)
      co_proc_attach "$@"
      ;;
    list|ls)
      co_proc_list "$@"
      ;;
    info)
      co_proc_info "$@"
      ;;
    stop|rm|remove)
      co_proc_stop "$@"
      ;;
    send|write)
      co_proc_send "$@"
      ;;
    read)
      co_proc_read "$@"
      ;;
    recv|receive)
      co_proc_recv "$@"
      ;;
    pump)
      co_proc_pump "$@"
      ;;
    switch|use)
      co_proc_switch "$@"
      ;;
    current)
      if [[ -n $CO_PROC_CURRENT ]]; then
        print -r -- "$CO_PROC_CURRENT"
      fi
      ;;
    wait)
      co_proc_wait "$@"
      ;;
    prune)
      co_proc_prune "$@"
      ;;
    cleanup)
      co_proc_cleanup "$@"
      ;;
    enable-zle)
      co_proc_enable_zle "$@"
      ;;
    disable-zle)
      co_proc_disable_zle "$@"
      ;;
    version|--version|-V)
      print -r -- "$CO_PROC_VERSION"
      ;;
    help|-h|--help)
      co_proc__usage
      ;;
    *)
      co_proc__err "unknown command '$command'"
      co_proc__usage >&2
      return 64
      ;;
  esac
}

alias cpsend='co-proc send'
alias cpread='co-proc read'
alias cplist='co-proc list'
alias cpstop='co-proc stop'

co_proc_install_hooks
