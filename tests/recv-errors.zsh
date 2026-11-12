# Pump-assisted recv must distinguish rejected output from a quiet channel.
# Removing pump-status propagation makes the error cases return 1 instead.
test_recv_pump_status_case() {
  emulate -L zsh
  local mode=$1 expected=$2 test_root runtime rc got
  local frame='{"version":1,"type":"ready","id":"ok"}'
  local CO_PROC_MAX_FRAME_BYTES=64 CO_PROC_MAX_BUFFER_BYTES=128

  test_root=$(mktemp -d "${TMPDIR:-/tmp}/co-proc-test.XXXXXX") || return 1
  runtime="$test_root/runtime"
  CO_PROC_RUNTIME_ROOT=$runtime
  {
    co-proc spawn receiver cat || return 1
    # Public pump establishes the persistent channel without consuming output.
    co-proc pump -t 0 receiver >/dev/null 2>&1
    assert_eq 1 "$?" "empty initial pump times out" || return 1
    case $mode in
      malformed) print -r -- invalid >"$runtime/receiver/output" ;;
      oversized) print -r -- "${(l:65::x:)}" >"$runtime/receiver/output" ;;
      capacity) print -rn -- "${(l:129::x:)}" >"$runtime/receiver/output" ;;
      partial) print -rn -- '{"version":1,' >"$runtime/receiver/output" ;;
      valid_then_bad) print -rn -- "$frame"$'\ninvalid\n' >"$runtime/receiver/output" ;;
      valid) print -r -- "$frame" >"$runtime/receiver/output" ;;
      timeout|bad_timeout) ;;
    esac
    if [[ $mode == bad_timeout ]]; then
      co-proc recv -t invalid receiver >"$test_root/received" 2>/dev/null
    else
      co-proc recv -t 0.1 receiver >"$test_root/received" 2>/dev/null
    fi
    rc=$?
    assert_eq "$expected" "$rc" "$mode receive status" || return 1
    got=$(<"$test_root/received")
    if [[ $mode == valid || $mode == valid_then_bad ]]; then
      assert_eq "$frame" "$got" "valid receive output" || return 1
    else
      assert_eq '' "$got" "failed receive emits no frame" || return 1
    fi
    if [[ $mode == partial ]]; then
      print -r -- '"type":"ready","id":"ok"}' >"$runtime/receiver/output" || return 1
      co-proc recv -t 0.1 receiver >"$test_root/received" || return 1
      assert_eq "$frame" "$(<"$test_root/received")" "partial frame survives empty receive" || return 1
    fi
    if [[ $mode == malformed || $mode == oversized ]]; then
      print -r -- "$frame" >"$runtime/receiver/output" || return 1
      co-proc recv -t 0.1 receiver >"$test_root/received" || return 1
      assert_eq "$frame" "$(<"$test_root/received")" "subsequent valid frame remains receivable" || return 1
    fi
  } always {
    co-proc stop --force --quiet receiver >/dev/null 2>&1 || :
    rm -f "$test_root/received"
    rmdir "$runtime" "$test_root" 2>/dev/null || :
  }
}

test_recv_pump_malformed_status() { test_recv_pump_status_case malformed 65 }
test_recv_pump_oversized_status() { test_recv_pump_status_case oversized 75 }
test_recv_pump_capacity_status() { test_recv_pump_status_case capacity 75 }
test_recv_pump_timeout_status() { test_recv_pump_status_case timeout 1 }
test_recv_pump_partial_status() { test_recv_pump_status_case partial 1 }
test_recv_pump_valid_status() { test_recv_pump_status_case valid 0 }
test_recv_pump_bad_timeout_status() { test_recv_pump_status_case bad_timeout 64 }

test_recv_pump_valid_then_bad_status() { test_recv_pump_status_case valid_then_bad 0 }
