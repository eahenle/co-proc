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

test_accept_line_delegates_to_saved_widget() {
  emulate -L zsh
  local BUFFER="coproc list"
  local -a zle_calls=()

  zle() {
    zle_calls+=("$*")
    return 0
  }

  co_proc_accept_line || return 1
  assert_eq "co-proc list" "$BUFFER" "accept-line should rewrite buffer" || return 1
  assert_eq "co_proc_native_accept_line" "$zle_calls[-1]" "accept-line should delegate to saved widget"
}

test_enable_zle_in_interactive_shell() {
  emulate -L zsh
  local output probe shell=${commands[zsh]:-zsh}

  probe="pre_existing_accept_line() { zle .accept-line; }; zle -N accept-line pre_existing_accept_line"
  probe+="; source ${(q)SRC}; co-proc enable-zle; print -r -- enable=\$? state=\$CO_PROC_ZLE_ENABLED"
  probe+="; print -r -- accept=\"\$(zle -lL accept-line 2>/dev/null)\""
  probe+="; print -r -- native=\"\$(zle -lL co_proc_native_accept_line 2>/dev/null)\""
  probe+="; later_accept_line() { zle .accept-line; }; zle -N accept-line later_accept_line"
  probe+="; co-proc disable-zle; print -r -- passive_disable=\$? state=\$CO_PROC_ZLE_ENABLED"
  probe+="; print -r -- passive_accept=\"\$(zle -lL accept-line 2>/dev/null)\""
  probe+="; co-proc enable-zle; print -r -- reenable=\$? state=\$CO_PROC_ZLE_ENABLED"
  probe+="; print -r -- reaccept=\"\$(zle -lL accept-line 2>/dev/null)\""
  probe+="; print -r -- renative=\"\$(zle -lL co_proc_native_accept_line 2>/dev/null)\""
  probe+="; co-proc disable-zle; print -r -- disable=\$? state=\$CO_PROC_ZLE_ENABLED"
  probe+="; print -r -- disabled=\"\$(zle -lL accept-line 2>/dev/null)\""
  probe+="; zle -A accept-line __co_proc_probe_accept; print -r -- accept_alias=\$?"

  output=$("$shell" -fic "$probe" 2>&1) || return 1
  assert_eq $'enable=0 state=1\naccept=zle -N accept-line co_proc_accept_line\nnative=zle -N co_proc_native_accept_line pre_existing_accept_line\npassive_disable=0 state=0\npassive_accept=zle -N accept-line later_accept_line\nreenable=0 state=1\nreaccept=zle -N accept-line co_proc_accept_line\nrenative=zle -N co_proc_native_accept_line later_accept_line\ndisable=0 state=0\ndisabled=zle -N accept-line later_accept_line\naccept_alias=0' "$output" "enable-zle should install, reinstall, and restore accept-line"
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

  listing=$(eval 'cplist') || return 1
  assert_match '^docs pid=[0-9]+ in=[0-9]+ out=[0-9]+ state=running current$' "$listing" "list should show descriptor registry details" || return 1

  info=$(co-proc info docs) || return 1
  assert_match $'name=docs\npid=[0-9]+\nin=[0-9]+\nout=[0-9]+\nstate=running\ncurrent=yes\nstarted=[0-9]+\ncommand=cat' "$info" "info should describe the registered coprocess" || return 1

  eval 'cpsend docs "via alias"' || return 1
  got=$(eval 'cpread -t 1 docs') || return 1
  assert_eq "via alias" "$got" "send/read aliases should proxy documented commands" || return 1

  eval 'cpstop docs' || return 1
  assert_eq "" "$(co-proc list)" "stop alias should remove the coprocess"
}

test_attachable_cross_process_round_trip() {
  emulate -L zsh
  local test_root runtime frame got info shell=${commands[zsh]:-zsh}

  test_root=$(mktemp -d "${TMPDIR:-/tmp}/co-proc-test.XXXXXX") || return 1
  runtime="$test_root/runtime"
  CO_PROC_RUNTIME_ROOT=$runtime
  {
    co-proc spawn echo_agent zsh -fc 'while IFS= read -r line; do print -r -- "$line"; done' || return 1
    frame='{"version":1,"type":"gen","id":"round-trip"}'

    CO_PROC_RUNTIME_ROOT="$runtime" TEST_SRC="$SRC" FRAME="$frame" "$shell" -fc 'source "$TEST_SRC"; co-proc send echo_agent "$FRAME"' || return 1
    got=$(CO_PROC_RUNTIME_ROOT="$runtime" TEST_SRC="$SRC" "$shell" -fc 'source "$TEST_SRC"; co-proc recv -t 1 echo_agent') || return 1
    assert_eq "$frame" "$got" "independent clients should round-trip one frame" || return 1

    info=$(CO_PROC_RUNTIME_ROOT="$runtime" TEST_SRC="$SRC" "$shell" -fc 'source "$TEST_SRC"; co-proc attach echo_agent') || return 1
    assert_match $'name=echo_agent\npid=[0-9]+\ninput=.*/echo_agent/input\noutput=.*/echo_agent/output\nstate=running' "$info" "attach should discover the live endpoint" || return 1
    assert_eq 700 "$(co_proc__stat_mode "$runtime")" "runtime mode" || return 1
    assert_eq 700 "$(co_proc__stat_mode "$runtime/echo_agent")" "endpoint directory mode" || return 1
    assert_eq 600 "$(co_proc__stat_mode "$runtime/echo_agent/input")" "input FIFO mode" || return 1
    assert_eq 600 "$(co_proc__stat_mode "$runtime/echo_agent/output")" "output FIFO mode"
  } always {
    co-proc stop --force --quiet echo_agent >/dev/null 2>&1 || :
    rmdir "$runtime" "$test_root" 2>/dev/null || :
  }
}

test_attachable_rejects_invalid_and_oversized_frames() {
  emulate -L zsh
  local test_root runtime padding oversized

  test_root=$(mktemp -d "${TMPDIR:-/tmp}/co-proc-test.XXXXXX") || return 1
  runtime="$test_root/runtime"
  CO_PROC_RUNTIME_ROOT=$runtime
  {
    co-proc spawn frame_agent cat || return 1
    assert_failure co-proc send frame_agent not-json || return 1
    assert_failure co-proc send frame_agent '{"version":2,"type":"gen","id":"wrong-version"}' || return 1
    assert_failure co-proc send frame_agent '{"version":1,"type":"gen","id":""}' || return 1
    assert_failure co-proc send frame_agent $'{"version":1,"type":"gen",\n"id":"multiline"}' || return 1
    padding=${(l:CO_PROC_MAX_FRAME_BYTES + 1::x:)}
    oversized="{\"version\":1,\"type\":\"gen\",\"id\":\"oversized\",\"data\":\"$padding\"}"
    assert_failure co-proc send frame_agent "$oversized"
  } always {
    co-proc stop --force --quiet frame_agent >/dev/null 2>&1 || :
    rmdir "$runtime" "$test_root" 2>/dev/null || :
  }
}

test_attachable_simultaneous_clients_are_atomic() {
  emulate -L zsh
  local test_root runtime first second combined shell=${commands[zsh]:-zsh} sender_one sender_two

  test_root=$(mktemp -d "${TMPDIR:-/tmp}/co-proc-test.XXXXXX") || return 1
  runtime="$test_root/runtime"
  CO_PROC_RUNTIME_ROOT=$runtime
  {
    co-proc spawn fan_in cat || return 1
    CO_PROC_RUNTIME_ROOT="$runtime" TEST_SRC="$SRC" "$shell" -fc 'source "$TEST_SRC"; co-proc send fan_in '\''{"version":1,"type":"ack","id":"one"}'\''' &
    sender_one=$!
    CO_PROC_RUNTIME_ROOT="$runtime" TEST_SRC="$SRC" "$shell" -fc 'source "$TEST_SRC"; co-proc send fan_in '\''{"version":1,"type":"ack","id":"two"}'\''' &
    sender_two=$!
    wait "$sender_one" || return 1
    wait "$sender_two" || return 1

    first=$(co-proc recv -t 1 fan_in) || return 1
    second=$(co-proc recv -t 1 fan_in) || return 1
    combined="$first"$'\n'"$second"
    if [[ $combined != $'{"version":1,"type":"ack","id":"one"}\n{"version":1,"type":"ack","id":"two"}' && $combined != $'{"version":1,"type":"ack","id":"two"}\n{"version":1,"type":"ack","id":"one"}' ]]; then
      fail "simultaneous frames should remain complete: ${(qq)combined}"
      return 1
    fi
  } always {
    co-proc stop --force --quiet fan_in >/dev/null 2>&1 || :
    rmdir "$runtime" "$test_root" 2>/dev/null || :
  }
}

test_attachable_permissions_and_stale_pruning() {
  emulate -L zsh
  local test_root runtime

  test_root=$(mktemp -d "${TMPDIR:-/tmp}/co-proc-test.XXXXXX") || return 1
  runtime="$test_root/runtime"
  CO_PROC_RUNTIME_ROOT=$runtime
  {
    mkdir "$runtime" || return 1
    chmod 755 "$runtime" || return 1
    assert_failure co-proc spawn unsafe cat || return 1
    chmod 700 "$runtime" || return 1

    co-proc spawn stale zsh -fc 'sleep 0.03' || return 1
    sleep 0.06
    co-proc prune || return 1
    [[ ! -e $runtime/stale ]] || {
      fail "prune should remove a stale owned endpoint"
      return 1
    }

    co-proc spawn tampered cat || return 1
    chmod 644 "$runtime/tampered/input" || return 1
    assert_failure co-proc attach tampered || return 1
    chmod 600 "$runtime/tampered/input" || return 1
  } always {
    co-proc stop --force --quiet tampered >/dev/null 2>&1 || :
    co-proc stop --force --quiet stale >/dev/null 2>&1 || :
    rmdir "$runtime" "$test_root" 2>/dev/null || :
  }
}

test_pump_buffers_partial_frames() {
  emulate -L zsh
  local test_root runtime frame part_one part_two got

  test_root=$(mktemp -d "${TMPDIR:-/tmp}/co-proc-test.XXXXXX") || return 1
  runtime="$test_root/runtime"
  CO_PROC_RUNTIME_ROOT=$runtime
  frame='{"version":1,"type":"result","id":"partial"}'
  part_one=${frame[1,20]}
  part_two=${frame[21,-1]}
  {
    co-proc spawn partial zsh -fc 'print -rn -- "$1"; IFS= read -r _; print -r -- "$2"' -- "$part_one" "$part_two" || return 1
    co-proc pump -t 0.2 partial || return 1
    assert_eq "$part_one" "${CO_PROC_PUMP_BUFFER[partial]-}" "pump should retain the partial prefix" || return 1
    assert_eq "" "${CO_PROC_PUMP_QUEUE[partial]-}" "pump should not queue an unterminated frame" || return 1
    co-proc send partial '{"version":1,"type":"ack","id":"continue"}' || return 1
    co-proc pump -t 0.2 partial || return 1
    got=$(co-proc recv -t 0 partial) || return 1
    assert_eq "$frame" "$got" "pump should assemble a frame across reads"
  } always {
    co-proc stop --force --quiet partial >/dev/null 2>&1 || :
    rmdir "$runtime" "$test_root" 2>/dev/null || :
  }
}

test_pump_multiplexes_channels_and_bounds_buffers() {
  emulate -L zsh
  local test_root runtime frame_a frame_b got_a got_b i old_limit payload

  test_root=$(mktemp -d "${TMPDIR:-/tmp}/co-proc-test.XXXXXX") || return 1
  runtime="$test_root/runtime"
  CO_PROC_RUNTIME_ROOT=$runtime
  frame_a='{"version":1,"type":"ready","id":"channel-a"}'
  frame_b='{"version":1,"type":"busy","id":"channel-b"}'
  {
    co-proc spawn channel_a cat || return 1
    co-proc spawn channel_b cat || return 1
    co-proc send channel_a "$frame_a" || return 1
    co-proc send channel_b "$frame_b" || return 1
    for i in {1..4}; do
      co-proc pump -t 0.1 channel_a channel_b >/dev/null || :
    done
    got_a=$(co-proc recv -t 0 channel_a) || return 1
    got_b=$(co-proc recv -t 0 channel_b) || return 1
    assert_eq "$frame_a" "$got_a" "pump channel a" || return 1
    assert_eq "$frame_b" "$got_b" "pump channel b" || return 1

    old_limit=$CO_PROC_MAX_BUFFER_BYTES
    CO_PROC_MAX_BUFFER_BYTES=64
    payload=${(l:80::x:)}
    co-proc spawn overflow zsh -fc 'print -rn -- "$1"; sleep 1' -- "$payload" || return 1
    assert_failure co-proc pump -t 0.2 overflow || return 1
    CO_PROC_MAX_BUFFER_BYTES=$old_limit
  } always {
    CO_PROC_MAX_BUFFER_BYTES=${old_limit:-65536}
    co-proc stop --force --quiet channel_a >/dev/null 2>&1 || :
    co-proc stop --force --quiet channel_b >/dev/null 2>&1 || :
    co-proc stop --force --quiet overflow >/dev/null 2>&1 || :
    rmdir "$runtime" "$test_root" 2>/dev/null || :
  }
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
run_test "accept-line delegates to saved widget" test_accept_line_delegates_to_saved_widget
run_test "enable-zle works in an interactive shell" test_enable_zle_in_interactive_shell
run_test "switch and default read use current coprocess" test_switch_and_default_read
run_test "documented introspection commands and aliases work" test_documented_introspection_and_aliases
run_test "attachable coprocesses round-trip across independent clients" test_attachable_cross_process_round_trip
run_test "attachable coprocesses reject invalid and oversized frames" test_attachable_rejects_invalid_and_oversized_frames
run_test "simultaneous attachable clients preserve atomic frames" test_attachable_simultaneous_clients_are_atomic
run_test "attachable endpoints enforce permissions and prune stale processes" test_attachable_permissions_and_stale_pruning
run_test "pump buffers partial frames" test_pump_buffers_partial_frames
run_test "pump multiplexes channels and bounds buffers" test_pump_multiplexes_channels_and_bounds_buffers
run_test "stress create and destroy hundreds" test_stress_create_destroy_hundreds

if (( TEST_FAILED > 0 )); then
  print -ru2 -- "$TEST_FAILED/$TEST_COUNT tests failed: ${(j:, :)TEST_FAILURES}"
  exit 1
fi

print -r -- "$TEST_COUNT tests passed"
