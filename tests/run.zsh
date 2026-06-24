#!/usr/bin/env zsh

emulate -R zsh
setopt pipe_fail no_unset

typeset -r ROOT=${0:A:h:h}
typeset -r SRC="$ROOT/src/co-proc.zsh"

typeset -gi TEST_COUNT=0
typeset -gi TEST_FAILED=0
typeset -ga TEST_FAILURES=()

fail() {
  emulate -L zsh
  print -ru2 -- "    $*"
  return 1
}

assert_eq() {
  emulate -L zsh
  local expected=$1 actual=$2 message=${3:-values differ}

  if [[ $actual != "$expected" ]]; then
    fail "$message: expected ${(qq)expected}, got ${(qq)actual}"
    return 1
  fi
}

assert_match() {
  emulate -L zsh
  local pattern=$1 actual=$2 message=${3:-pattern did not match}

  if [[ ! $actual =~ $pattern ]]; then
    fail "$message: pattern ${(qq)pattern}, got ${(qq)actual}"
    return 1
  fi
}

assert_success() {
  emulate -L zsh
  "$@"
}

assert_failure() {
  emulate -L zsh

  if "$@" >/dev/null 2>&1; then
    fail "expected failure: $*"
    return 1
  fi
}

test_basic_start_send_read_stop() {
  emulate -L zsh
  local got

  co-proc start alpha cat || return 1
  co-proc send alpha "hello world" || return 1
  got=$(co-proc read -t 1 alpha) || return 1
  assert_eq "hello world" "$got" "cat echo" || return 1
  co-proc stop alpha || return 1
  assert_eq "" "$(co-proc list)" "registry should be empty after stop"
}

test_multiple_two_processes_are_isolated() {
  emulate -L zsh
  local got_a got_b

  co-proc start a cat || return 1
  co-proc start b cat || return 1

  co-proc send a "from-a" || return 1
  co-proc send b "from-b" || return 1

  got_a=$(co-proc read -t 1 a) || return 1
  got_b=$(co-proc read -t 1 b) || return 1

  assert_eq "from-a" "$got_a" "a should receive only a data" || return 1
  assert_eq "from-b" "$got_b" "b should receive only b data"
}

test_many_simultaneous_processes_have_unique_fds() {
  emulate -L zsh
  local i name got
  typeset -A seen_fds=()

  for i in {1..20}; do
    name="cp$i"
    co-proc start "$name" cat || return 1
    if [[ -n ${seen_fds[${CO_PROC_IN[$name]}]-} ]]; then
      fail "fd collision on ${CO_PROC_IN[$name]}"
      return 1
    fi
    seen_fds[${CO_PROC_IN[$name]}]=1
    if [[ -n ${seen_fds[${CO_PROC_OUT[$name]}]-} ]]; then
      fail "fd collision on ${CO_PROC_OUT[$name]}"
      return 1
    fi
    seen_fds[${CO_PROC_OUT[$name]}]=1
  done

  for i in {1..20}; do
    name="cp$i"
    co-proc send "$name" "msg-$i" || return 1
  done

  for i in {1..20}; do
    name="cp$i"
    got=$(co-proc read -t 1 "$name") || return 1
    assert_eq "msg-$i" "$got" "$name should echo its own message" || return 1
  done
}

test_duplicate_invalid_and_missing_inputs_fail() {
  emulate -L zsh

  assert_failure co-proc start || return 1
  assert_failure co-proc start missing_command || return 1
  assert_failure co-proc start 1bad cat || return 1
  assert_failure co-proc start bad not-a-command || return 1

  co-proc start dup cat || return 1
  assert_failure co-proc start dup cat || return 1
}

test_process_exit_and_prune() {
  emulate -L zsh
  local got

  co-proc start short zsh -fc 'read -r line; print done; exit 7' || return 1
  co-proc send short trigger || return 1
  got=$(co-proc read -t 1 short) || return 1
  assert_eq "done" "$got" "short process response" || return 1

  sleep 0.05
  co-proc prune
  assert_eq "" "${CO_PROC_PID[short]-}" "dead process should be pruned"
  assert_eq "7" "${CO_PROC_EXIT[short]-}" "exit status should be retained"
}

test_native_coproc_simple_command_remains_native() {
  emulate -L zsh
  local outfd infd pid line

  coproc cat
  pid=$!
  exec {outfd}<&p
  exec {infd}>&p

  print -r -- native >&$infd
  IFS= read -r -t 1 line <&$outfd || return 1
  assert_eq native "$line" "native coproc cat" || return 1

  exec {infd}>&- 2>/dev/null
  exec {outfd}<&- 2>/dev/null
  kill "$pid" 2>/dev/null || :
  wait "$pid" 2>/dev/null || :
}

test_native_coproc_group_remains_native() {
  emulate -L zsh
  local outfd infd pid line

  coproc { cat }
  pid=$!
  exec {outfd}<&p
  exec {infd}>&p

  print -r -- grouped >&$infd
  IFS= read -r -t 1 line <&$outfd || return 1
  assert_eq grouped "$line" "native coproc group" || return 1

  exec {infd}>&- 2>/dev/null
  exec {outfd}<&- 2>/dev/null
  kill "$pid" 2>/dev/null || :
  wait "$pid" 2>/dev/null || :
}

test_named_process_survives_later_native_coproc() {
  emulate -L zsh
  local outfd infd pid native_line named_line

  co-proc start named cat || return 1

  coproc cat
  pid=$!
  exec {outfd}<&p
  exec {infd}>&p

  print -r -- native >&$infd
  IFS= read -r -t 1 native_line <&$outfd || return 1
  assert_eq native "$native_line" "native process after named start" || return 1

  co-proc send named saved || return 1
  named_line=$(co-proc read -t 1 named) || return 1
  assert_eq saved "$named_line" "named descriptors should survive p retargeting" || return 1

  exec {infd}>&- 2>/dev/null
  exec {outfd}<&- 2>/dev/null
  kill "$pid" 2>/dev/null || :
  wait "$pid" 2>/dev/null || :
}

test_rewrite_token_inspection() {
  emulate -L zsh
  local got

  got=$(co_proc__rewrite_line "coproc calc bc -l")
  assert_eq "co-proc start calc -- bc -l" "$got" "named start rewrite" || return 1

  got=$(co_proc__rewrite_line "coproc list")
  assert_eq "co-proc list" "$got" "registry command rewrite" || return 1

  got=$(co_proc__rewrite_line "coproc send calc 1 + 1")
  assert_eq "co-proc send calc 1 + 1" "$got" "send rewrite" || return 1

  got=$(co_proc__rewrite_line "coproc py python -c 'print(1)'")
  assert_eq "co-proc start py -- python -c 'print(1)'" "$got" "quoted command rewrite" || return 1

  got=$(co_proc__rewrite_line "coproc { print hi }")
  assert_eq "coproc { print hi }" "$got" "native group should not rewrite" || return 1

  got=$(co_proc__rewrite_line "coproc while read line; do print \$line; done")
  assert_eq "coproc while read line; do print \$line; done" "$got" "native while should not rewrite" || return 1

  got=$(co_proc__rewrite_line "coproc calc cat >x")
  assert_eq "coproc calc cat >x" "$got" "redirection should not rewrite"
}

test_switch_and_default_read() {
  emulate -L zsh
  local got

  co-proc start a cat || return 1
  co-proc start b cat || return 1
  co-proc switch a || return 1

  co-proc send a one || return 1
  got=$(co-proc read -t 1) || return 1
  assert_eq one "$got" "default read should use current coprocess" || return 1

  co-proc switch b || return 1
  co-proc send b two || return 1
  got=$(co-proc read -t 1) || return 1
  assert_eq two "$got" "switch should update current coprocess"
}

test_documented_introspection_and_aliases() {
  emulate -L zsh
  local current listing info got

  co-proc start docs cat || return 1

  current=$(co-proc current) || return 1
  assert_eq docs "$current" "current should report the most recent coprocess" || return 1

  listing=$(cplist) || return 1
  assert_match '^docs pid=[0-9]+ in=[0-9]+ out=[0-9]+ state=running current$' "$listing" "list should show descriptor registry details" || return 1

  info=$(co-proc info docs) || return 1
  assert_match $'name=docs\npid=[0-9]+\nin=[0-9]+\nout=[0-9]+\nstate=running\ncurrent=yes\nstarted=[0-9]+\ncommand=cat' "$info" "info should describe the registered coprocess" || return 1

  eval 'cpsend docs "via alias"' || return 1
  got=$(eval 'cpread -t 1 docs') || return 1
  assert_eq "via alias" "$got" "send/read aliases should proxy documented commands" || return 1

  eval 'cpstop docs' || return 1
  assert_eq "" "$(co-proc list)" "stop alias should remove the coprocess"
}

test_stress_create_destroy_hundreds() {
  emulate -L zsh
  local i name got before after

  before=$(co-proc list | wc -l | tr -d ' ')
  for i in {1..200}; do
    name="stress_$i"
    co-proc start "$name" cat || return 1
    co-proc send "$name" "$i" || return 1
    got=$(co-proc read -t 1 "$name") || return 1
    assert_eq "$i" "$got" "stress echo $i" || return 1
    co-proc stop "$name" || return 1
  done
  after=$(co-proc list | wc -l | tr -d ' ')
  assert_eq "$before" "$after" "stress should leave no registered processes"
}

run_test() {
  emulate -L zsh
  local name=$1 fn=$2

  (( TEST_COUNT++ ))
  print -r -- "# $name"

  (
    emulate -R zsh
    setopt pipe_fail
    source "$SRC"
    CO_PROC_START_SETTLE=0.001
    CO_PROC_STOP_GRACE=0.001

    {
      "$fn"
    } always {
      co_proc_cleanup >/dev/null 2>&1 || :
    }
  )

  if (( $? == 0 )); then
    print -r -- "ok $TEST_COUNT - $name"
  else
    print -r -- "not ok $TEST_COUNT - $name"
    TEST_FAILURES+=("$name")
    (( TEST_FAILED++ ))
  fi
}

run_test "basic start/send/read/stop" test_basic_start_send_read_stop
run_test "two simultaneous coprocesses are isolated" test_multiple_two_processes_are_isolated
run_test "twenty simultaneous coprocesses have unique fds" test_many_simultaneous_processes_have_unique_fds
run_test "duplicate, invalid, and missing inputs fail" test_duplicate_invalid_and_missing_inputs_fail
run_test "unexpected process exit can be pruned" test_process_exit_and_prune
run_test "native simple coproc remains native" test_native_coproc_simple_command_remains_native
run_test "native grouped coproc remains native" test_native_coproc_group_remains_native
run_test "named process survives later native coproc" test_named_process_survives_later_native_coproc
run_test "interactive rewrite uses token inspection" test_rewrite_token_inspection
run_test "switch and default read use current coprocess" test_switch_and_default_read
run_test "documented introspection commands and aliases work" test_documented_introspection_and_aliases
run_test "stress create and destroy hundreds" test_stress_create_destroy_hundreds

if (( TEST_FAILED > 0 )); then
  print -ru2 -- "$TEST_FAILED/$TEST_COUNT tests failed: ${(j:, :)TEST_FAILURES}"
  exit 1
fi

print -r -- "$TEST_COUNT tests passed"
