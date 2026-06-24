# co-proc: named zsh coprocesses.
#
# Source this file from zsh:
#
#   source /path/to/co-proc.zsh
#
# Native `coproc ...` syntax remains native.  co-proc adds explicit commands:
#
#   co-proc start NAME COMMAND [ARG...]
#   co-proc send NAME TEXT...
#   co-proc read [-t SECONDS] [NAME]
#   co-proc list
#   co-proc stop NAME
#
# Interactive users may opt into the ZLE integration with:
#
#   co-proc enable-zle
#
# That widget rewrites simple extended forms such as `coproc calc bc -l` into
# `co-proc start calc -- bc -l` before the line is accepted.

typeset -g CO_PROC_VERSION=${CO_PROC_VERSION:-0.1.0}
typeset -g CO_PROC_CURRENT=${CO_PROC_CURRENT:-}
typeset -g CO_PROC_START_SETTLE=${CO_PROC_START_SETTLE:-0.02}
typeset -g CO_PROC_STOP_GRACE=${CO_PROC_STOP_GRACE:-0.05}

typeset -gA CO_PROC_IN
typeset -gA CO_PROC_OUT
typeset -gA CO_PROC_PID
typeset -gA CO_PROC_CMD
typeset -gA CO_PROC_STARTED
typeset -gA CO_PROC_EXIT

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
  co-proc list
  co-proc info NAME
  co-proc stop [-f] NAME
  co-proc send NAME TEXT...
  co-proc read [-t SECONDS] [NAME]
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
    co_proc__err "unknown coprocess '$name'"
    return 66
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
    (( quiet )) || co_proc__err "unknown coprocess '$name'"
    return 66
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
  local name state marker

  for name in ${(ok)CO_PROC_PID}; do
    state=$(co_proc__state "$name")
    marker=
    [[ $name == "$CO_PROC_CURRENT" ]] && marker=" current"
    print -r -- "$name pid=${CO_PROC_PID[$name]} in=${CO_PROC_IN[$name]} out=${CO_PROC_OUT[$name]} state=$state$marker"
  done
}

co_proc_info() {
  emulate -L zsh
  local name=${1:-} state

  if [[ -z $name ]]; then
    co_proc__err "info requires NAME"
    return 64
  fi

  if ! co_proc__exists "$name"; then
    co_proc__err "unknown coprocess '$name'"
    return 66
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
  local name pid rc infd outfd

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
    list|ls|info|stop|send|read|switch|current|wait|prune|help|version|enable-zle|disable-zle)
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

  zle .accept-line
}

co_proc_enable_zle() {
  emulate -L zsh

  if [[ -z ${ZLE_VERSION-} ]]; then
    co_proc__err "ZLE is not available in this shell"
    return 69
  fi

  zle -N co_proc_accept_line
  zle -A .accept-line co_proc_native_accept_line 2>/dev/null || :
  zle -N accept-line co_proc_accept_line
}

co_proc_disable_zle() {
  emulate -L zsh

  if [[ -z ${ZLE_VERSION-} ]]; then
    return 0
  fi

  if zle -lL co_proc_native_accept_line >/dev/null 2>&1; then
    zle -A co_proc_native_accept_line accept-line 2>/dev/null || :
    zle -D co_proc_native_accept_line 2>/dev/null || :
  else
    zle -D accept-line 2>/dev/null || :
  fi
}

co-proc() {
  emulate -L zsh
  local command=${1:-help}

  [[ $# -gt 0 ]] && shift

  case "$command" in
    start|new)
      co_proc_start "$@"
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
