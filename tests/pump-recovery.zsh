# Rejected lines must not strand frames that the pump has already read.

test_pump_recovers_complete_frames_and_partial_tail() {
  emulate -L zsh
  local first='{"version":1,"type":"ready","id":"first"}'
  local second='{"version":1,"type":"ready","id":"second"}'
  local third='{"version":1,"type":"ready","id":"third"}'
  local partial='{"version":1,"type":"ready","id":"par'
  local complete='{"version":1,"type":"ready","id":"partial"}'
  local rc

  co_proc__queue_pump_chunk recovery "$first"$'\n' || return 1
  co_proc__queue_pump_chunk recovery $'invalid\n'"$second"$'\n\n'"$third"$'\n'"$partial" 2>/dev/null
  rc=$?
  assert_eq 65 "$rc" "rejected frames remain visible to the caller" || return 1
  assert_eq "$first"$'\n'"$second"$'\n'"$third"$'\n' "${CO_PROC_PUMP_QUEUE[recovery]-}" "valid frames remain ordered around rejected lines" || return 1
  assert_eq "$partial" "${CO_PROC_PUMP_BUFFER[recovery]-}" "only the incomplete tail remains buffered" || return 1
  co_proc__queue_pump_chunk recovery $'tial"}\n' || return 1
  assert_eq "$first"$'\n'"$second"$'\n'"$third"$'\n'"$complete"$'\n' "${CO_PROC_PUMP_QUEUE[recovery]-}" "later bytes complete the preserved tail"
}

test_pump_recovery_preserves_first_error_and_limits() {
  emulate -L zsh
  local CO_PROC_MAX_FRAME_BYTES=64 CO_PROC_MAX_BUFFER_BYTES=256
  local oversized=${(l:65::x:)}
  local valid='{"version":1,"type":"ready","id":"ok"}'
  local rc

  co_proc__queue_pump_chunk recovery "$oversized"$'\ninvalid\n'"$valid"$'\n' 2>/dev/null
  rc=$?
  assert_eq 75 "$rc" "the first rejection status is retained" || return 1
  assert_eq "$valid"$'\n' "${CO_PROC_PUMP_QUEUE[recovery]-}" "valid frame survives distinct rejection reasons" || return 1
  assert_eq '' "${CO_PROC_PUMP_BUFFER[recovery]-}" "all complete lines were examined" || return 1

  CO_PROC_MAX_BUFFER_BYTES=${#valid}
  co_proc__queue_pump_chunk recovery "$valid"$'\n' 2>/dev/null
  rc=$?
  assert_eq 75 "$rc" "recovery never bypasses the combined buffer ceiling" || return 1
  assert_eq "$valid"$'\n' "${CO_PROC_PUMP_QUEUE[recovery]-}" "overflow preserves previously queued frames"
}

test_pump_recovers_real_fifos_without_further_writes() {
  emulate -L zsh
  local test_root runtime name rc got
  local first='{"version":1,"type":"ready","id":"first"}'
  local second='{"version":1,"type":"ready","id":"second"}'
  local -a names=(recovery_a recovery_b recovery_c)

  test_root=$(mktemp -d "${TMPDIR:-/tmp}/co-proc-test.XXXXXX") || return 1
  runtime="$test_root/runtime"
  CO_PROC_RUNTIME_ROOT=$runtime
  {
    for name in "${names[@]}"; do
      co-proc spawn "$name" cat || return 1
      co_proc__open_pump_fd "$name" || return 1
      # Write peer output directly so every FIFO is ready before the pump.
      # Each single small write contains bad and good frames together.
      print -rn -- $'invalid\n'"$first"$'\n'"$second"$'\n' >"$runtime/$name/output" || return 1
    done
    co-proc pump -t 0.2 "${names[@]}" 2>/dev/null
    rc=$?
    assert_eq 65 "$rc" "pump reports malformed peer output" || return 1
    for name in "${names[@]}"; do
      assert_eq "$first"$'\n'"$second"$'\n' "${CO_PROC_PUMP_QUEUE[$name]-}" "every ready channel is drained after a rejection" || return 1
      assert_eq '' "${CO_PROC_PUMP_BUFFER[$name]-}" "complete frames cannot remain stranded" || return 1
      # Redirect in the current shell: command substitution would copy queues.
      co-proc recv -t 0 "$name" >"$test_root/received" || return 1
      got=$(<"$test_root/received")
      assert_eq "$first" "$got" "first frame is immediately available" || return 1
      co-proc recv -t 0 "$name" >"$test_root/received" || return 1
      got=$(<"$test_root/received")
      assert_eq "$second" "$got" "next frame needs no additional peer write" || return 1
      assert_eq '' "${CO_PROC_PUMP_QUEUE[$name]-}" "frames are consumed once" || return 1
    done
  } always {
    for name in "${names[@]}"; do
      co-proc stop --force --quiet "$name" >/dev/null 2>&1 || :
    done
    rm -f "$test_root/received"
    rmdir "$runtime" "$test_root" 2>/dev/null || :
  }
}

run_test "pump retains valid frames and partial tails after rejected lines" test_pump_recovers_complete_frames_and_partial_tail
run_test "pump recovery retains rejection status and buffer limits" test_pump_recovery_preserves_first_error_and_limits
run_test "pump drains every ready FIFO after malformed output" test_pump_recovers_real_fifos_without_further_writes
