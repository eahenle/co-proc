# Attachable frame regressions. Sourced by tests/run.zsh.

assert_invalid_frame() {
  emulate -L zsh
  local frame=$1 rc
  co_proc__validate_frame "$frame" >/dev/null 2>&1
  rc=$?
  assert_eq 65 "$rc" "invalid JSON/envelope ${(qq)frame}"
}

test_frame_rejects_trailing_comma() {
  assert_invalid_frame '{"version":1,"type":"ready","id":"one",}'
}

test_frame_rejects_nested_only_envelope() {
  assert_invalid_frame '{"payload":{"version":1,"type":"ready","id":"one"}}'
}

test_frame_rejects_nested_version_impostor() {
  assert_invalid_frame '{"version":2,"type":"ready","id":"one","payload":{"version":1}}'
}

test_frame_rejects_invalid_json_and_root_fields() {
  emulate -L zsh
  local frame
  local -a frames=(
    '' 'null' 'true' '1' '"text"' '[]' '{}'
    '[{"version":1,"type":"ready","id":"one"}]'
    '{"version":1,"type":"ready","id":"one"} {}'
    '{"version":1,"type":"ready","id":"one"} trailing'
    '{"version":1,"type":"ready","id":"one"'
    '{"version":01,"type":"ready","id":"one"}'
    '{"version":+1,"type":"ready","id":"one"}'
    '{"version":1,"type":"ready","id":"one" /* comment */}'
    '{"version":1,"type":"ready","id":"one","data":[1,]}'
    '{"version":1,"type":"ready","id":"one","data":undefined}'
    '{"version":1,"type":"ready","id":"one","data":NaN}'
    '{"version":1,"type":"ready","id":"one","data":Infinity}'
    '{"version":1,"type":"ready","id":"one","data":-Infinity}'
    '{"version":1,"type":"ready","id":"one","data":"\x41"}'
    '{"version":1,"type":"ready","id":"one","data":"\uZZZZ"}'
    '{"version":1,"type":"ready","id":"one","data":"\ud800"}'
    '{"version":1,"type":"ready","id":"one","\udfff":0}'
    '{"version":1,"type":"ready","id":"one","data":"\ude80\ud83d"}'
    '{"version":true,"type":"ready","id":"one"}'
    '{"version":"1","type":"ready","id":"one"}'
    '{"version":1.0,"type":"ready","id":"one"}'
    '{"version":1e0,"type":"ready","id":"one"}'
    '{"version":null,"type":"ready","id":"one"}'
    '{"version":[],"type":"ready","id":"one"}'
    '{"version":{},"type":"ready","id":"one"}'
    '{"type":"ready","id":"one","payload":{"version":1}}'
    '{"version":1,"id":"one","payload":{"type":"ready"}}'
    '{"version":1,"type":"ready","payload":{"id":"one"}}'
    '{"version":1,"type":"","id":"one"}'
    '{"version":1,"type":false,"id":"one"}'
    '{"version":1,"type":1,"id":"one"}'
    '{"version":1,"type":[],"id":"one"}'
    '{"version":1,"type":{},"id":"one"}'
    '{"version":1,"type":null,"id":"one"}'
    '{"version":1,"type":"ready","id":""}'
    '{"version":1,"type":"ready","id":false}'
    '{"version":1,"type":"ready","id":1}'
    '{"version":1,"type":"ready","id":[]}'
    '{"version":1,"type":"ready","id":{}}'
    '{"version":1,"type":"ready","id":null}'
    $'{"version":1,"type":"ready","id":"raw\tcontrol"}'
    $'{"version":1,"type":"ready","id":"raw\0nul"}'
    $'{"version":1,"type":"ready",\n"id":"one"}'
    $'{"version":1,"type":"ready","id":"one"}\r'
    $'{"version":1,"type":"ready","id":"one"}\n'
    $'{"version":1,"type":"ready","id":"\xc0\xaf"}'
    $'{"version":1,"type":"ready","id":"\xff"}'
  )
  for frame in "${frames[@]}"; do
    assert_invalid_frame "$frame" || return 1
  done
}

test_frame_rejects_duplicate_keys() {
  emulate -L zsh
  local frame
  local -a frames=(
    '{"version":1,"version":2,"type":"ready","id":"one"}'
    '{"version":2,"version":1,"type":"ready","id":"one"}'
    '{"version":1,"version":1,"type":"ready","id":"one"}'
    '{"version":1,"type":"ready","type":"other","id":"one"}'
    '{"version":1,"type":"ready","id":"one","id":"two"}'
    '{"version":1,"type":"ready","id":"one","\u0069d":"two"}'
    '{"version":1,"type":"ready","id":"one","payload":{"a":1,"a":2}}'
    '{"version":1,"type":"ready","id":"one","payload":[{"a":1,"\u0061":1}]}'
  )
  for frame in "${frames[@]}"; do
    assert_invalid_frame "$frame" || return 1
  done
}

test_frame_accepts_json_strings_unicode_and_payloads() {
  emulate -L zsh
  local frame
  local -a frames=(
    '{"version":1,"type":"ready","id":"one"}'
    ' { "id": "one two", "type": " ", "version": 1 } '
    '{"version":1,"type":"quote\"slash\\solidus\/","id":"\b\f\n\r\t\u0000"}'
    '{"version":1,"type":"résultat","id":"東京🚀"}'
    '{"version":1,"type":"\u0072eady","id":"\ud83d\ude80"}'
    '{"\u0076ersion":1,"\u0074ype":"ready","\u0069d":"one"}'
    '{"version":1,"type":"ready","id":"one","payload":{"version":2,"id":"","nested":[null,true,false,-12,1.5,1e9999,{"x":[]}],"text":"{\"version\":2}"}}'
  )
  for frame in "${frames[@]}"; do
    co_proc__validate_frame "$frame" || return 1
  done
}

test_frame_byte_limits() {
  emulate -L zsh
  local LC_ALL=C frame padding rc
  local prefix='{"version":1,"type":"ready","id":"🚀","data":"'
  local suffix='"}'
  padding=${(l:CO_PROC_MAX_FRAME_BYTES - ${#prefix} - ${#suffix}::x:)}
  frame="$prefix$padding$suffix"
  assert_eq 4095 "${#frame}" "test frame exactly meets byte limit" || return 1
  co_proc__validate_frame "$frame" || return 1
  co_proc__validate_frame "$frame " >/dev/null 2>&1
  rc=$?
  assert_eq 75 "$rc" "one extra byte is oversized" || return 1
  # The replacement is one character but adds three UTF-8 bytes.
  frame="$prefix${padding[2,-1]}🚀$suffix"
  co_proc__validate_frame "$frame" >/dev/null 2>&1
  rc=$?
  assert_eq 75 "$rc" "multibyte payload must not evade the byte limit"
}

test_frame_parser_missing_is_explicit() {
  emulate -L zsh
  local PATH='' got rc
  got=$(co_proc__validate_frame '{"version":1,"type":"ready","id":"one"}' 2>&1)
  rc=$?
  assert_eq 69 "$rc" "missing parser must fail closed" || return 1
  assert_match 'python3.*required' "$got" "missing parser explains the requirement"
}

test_frame_validation_does_not_depend_on_cwd() {
  emulate -L zsh
  cd / || return 1
  co_proc__validate_frame '{"version":1,"type":"ready","id":"elsewhere"}'
}

test_frame_contract_on_send_recv_and_pump() {
  emulate -L zsh
  local test_root runtime invalid valid got rc
  local -a invalid_frames=(
    '{"version":1,"type":"ready","id":"one",}'
    '{"payload":{"version":1,"type":"ready","id":"one"}}'
    '{"version":2,"type":"ready","id":"one","payload":{"version":1}}'
    '{"version":1,"type":"ready","id":"one","id":"two"}'
  )
  valid='{"version":1,"type":"résultat","id":"escaped\"🚀","payload":{"version":2}}'
  test_root=$(mktemp -d "${TMPDIR:-/tmp}/co-proc-test.XXXXXX") || return 1
  runtime="$test_root/runtime"
  CO_PROC_RUNTIME_ROOT=$runtime
  {
    co-proc spawn validation cat || return 1
    for invalid in "${invalid_frames[@]}"; do
      co-proc send validation "$invalid" >/dev/null 2>&1
      rc=$?
      assert_eq 65 "$rc" "send rejects invalid frame" || return 1
    done
    co-proc send validation "$valid" || return 1
    got=$(co-proc recv -t 1 validation) || return 1
    assert_eq "$valid" "$got" "invalid sends must not reach the peer" || return 1

    for invalid in "${invalid_frames[@]}"; do
      # Bypass send validation to represent malformed output from a real peer.
      print -r -- "$invalid" >"$runtime/validation/input"
      got=$(co-proc recv -t 1 validation 2>/dev/null)
      rc=$?
      assert_eq 65 "$rc" "direct recv rejects invalid frame" || return 1
      assert_eq '' "$got" "direct recv must not emit an invalid frame" || return 1
    done
    co-proc send validation "$valid" || return 1
    got=$(co-proc recv -t 1 validation) || return 1
    assert_eq "$valid" "$got" "direct recv preserves valid bytes after rejection" || return 1

    co_proc__open_pump_fd validation || return 1
    for invalid in "${invalid_frames[@]}"; do
      print -r -- "$invalid" >"$runtime/validation/input"
      co-proc pump -t 1 validation >/dev/null 2>&1
      rc=$?
      assert_eq 65 "$rc" "pump rejects invalid frame" || return 1
      assert_eq '' "${CO_PROC_PUMP_QUEUE[validation]-}" "invalid frame must not enter the queue" || return 1
      got=$(co-proc recv -t 0.01 validation 2>/dev/null)
      rc=$?
      assert_eq 1 "$rc" "rejected frame cannot be received successfully" || return 1
      assert_eq '' "$got" "pumped recv must not emit an invalid frame" || return 1
    done
    # Also cover recv invoking pump itself with an already-open pump FD.
    print -r -- "$invalid_frames[1]" >"$runtime/validation/input"
    got=$(co-proc recv -t 1 validation 2>/dev/null)
    rc=$?
    assert_eq 1 "$rc" "recv must not hide invalid pump output as success" || return 1
    assert_eq '' "$got" "recv auto-pump emits no invalid frame" || return 1
    co-proc send validation "$valid" || return 1
    co-proc pump -t 1 validation || return 1
    got=$(co-proc recv -t 0 validation) || return 1
    assert_eq "$valid" "$got" "pumped recv preserves valid bytes after rejection"
  } always {
    co-proc stop --force --quiet validation >/dev/null 2>&1 || :
    rmdir "$runtime" "$test_root" 2>/dev/null || :
  }
}


test_frame_parser_missing_helper_is_explicit() {
  emulate -L zsh
  local CO_PROC_FRAME_VALIDATOR=/nonexistent/co-proc/validate-frame.py got rc
  got=$(co_proc__validate_frame '{"version":1,"type":"ready","id":"one"}' 2>&1)
  rc=$?
  assert_eq 69 "$rc" "incomplete installation must fail closed" || return 1
  assert_match 'validator is unavailable' "$got" "missing helper explains the failure"
}

test_native_coproc_without_python() {
  emulate -L zsh
  local cat_bin=${commands[cat]} got
  local PATH=''
  co-proc start without_python "$cat_bin" || return 1
  co-proc send without_python 'plain text, not JSON' || return 1
  got=$(co-proc read -t 1 without_python) || return 1
  assert_eq 'plain text, not JSON' "$got" "native API does not need the JSON parser" || return 1
  co-proc stop --force without_python
}

test_frame_parser_bounds_nesting() {
  emulate -L zsh
  local opens=${(l:1500::[:)} closes=${(l:1500::]:)} got rc
  got=$(co_proc__validate_frame '{"version":1,"type":"ready","id":"deep","payload":'"$opens"'0'"$closes"'}' 2>&1)
  rc=$?
  # Decoder nesting limits differ across Python versions. Valid bounded JSON
  # may pass, or fail cleanly, but must never crash or print a traceback/frame.
  case $rc in
    0) assert_eq '' "$got" "accepted deep frame produces no validator output" ;;
    65)
      assert_match '^co-proc: frame must be' "$got" "deep frame fails cleanly" || return 1
      [[ $got != *Traceback* ]]
      ;;
    *) fail "deep frame produced unexpected status $rc: $got" ;;
  esac
}

test_frame_pump_assembles_split_unicode() {
  emulate -L zsh
  local LC_ALL=C frame part_one part_two got
  local prefix='{"version":1,"type":"ready","id":"'
  frame="$prefix"'🚀\"end"}'
  # End the first chunk in the middle of the four-byte UTF-8 character.
  part_one=${frame[1,${#prefix}+1]}
  part_two=${frame[${#prefix}+2,-1]}
  co_proc__queue_pump_chunk split_unicode "$part_one" || return 1
  assert_eq '' "${CO_PROC_PUMP_QUEUE[split_unicode]-}" "incomplete UTF-8 frame is not queued" || return 1
  co_proc__queue_pump_chunk split_unicode "$part_two"$'\n' || return 1
  got=$(co_proc__pop_buffered_frame split_unicode) || return 1
  assert_eq "$frame" "$got" "split UTF-8 and escaped quote survive unchanged"
}

test_frame_transport_byte_limits() {
  emulate -L zsh
  local LC_ALL=C test_root runtime frame padding got rc
  local prefix='{"version":1,"type":"ready","id":"🚀","data":"'
  local suffix='"}'
  padding=${(l:CO_PROC_MAX_FRAME_BYTES - ${#prefix} - ${#suffix}::x:)}
  frame="$prefix$padding$suffix"
  test_root=$(mktemp -d "${TMPDIR:-/tmp}/co-proc-test.XXXXXX") || return 1
  runtime="$test_root/runtime"
  CO_PROC_RUNTIME_ROOT=$runtime
  {
    co-proc spawn boundary cat || return 1
    co-proc send boundary "$frame " >/dev/null 2>&1
    rc=$?
    assert_eq 75 "$rc" "send rejects one byte over limit" || return 1
    co-proc send boundary "$frame" || return 1
    got=$(co-proc recv -t 1 boundary) || return 1
    assert_eq "$frame" "$got" "direct recv preserves exactly 4095 UTF-8 bytes" || return 1
    print -r -- "$frame " >"$runtime/boundary/input"
    got=$(co-proc recv -t 1 boundary 2>/dev/null)
    rc=$?
    assert_eq 75 "$rc" "direct recv rejects one byte over limit" || return 1
    assert_eq '' "$got" "direct recv emits no oversized frame" || return 1

    co_proc__open_pump_fd boundary || return 1
    print -r -- "$frame " >"$runtime/boundary/input"
    co-proc pump -t 1 boundary >/dev/null 2>&1
    rc=$?
    assert_eq 75 "$rc" "pump rejects one byte over limit" || return 1
    assert_eq '' "${CO_PROC_PUMP_QUEUE[boundary]-}" "pump queues no oversized frame" || return 1
    co-proc send boundary "$frame" || return 1
    co-proc pump -t 1 boundary || return 1
    got=$(co-proc recv -t 0 boundary) || return 1
    assert_eq "$frame" "$got" "pumped recv preserves exactly 4095 UTF-8 bytes"
  } always {
    co-proc stop --force --quiet boundary >/dev/null 2>&1 || :
    rmdir "$runtime" "$test_root" 2>/dev/null || :
  }
}

run_test "frame rejects trailing-comma JSON" test_frame_rejects_trailing_comma
run_test "frame requires root envelope fields" test_frame_rejects_nested_only_envelope
run_test "frame rejects unsupported root version with nested version 1" test_frame_rejects_nested_version_impostor
run_test "frame rejects invalid JSON, encoding, and root field types" test_frame_rejects_invalid_json_and_root_fields
run_test "frame rejects duplicate decoded object keys" test_frame_rejects_duplicate_keys
run_test "frame accepts escaped strings, Unicode, and nested payloads" test_frame_accepts_json_strings_unicode_and_payloads
run_test "frame limits count UTF-8 bytes" test_frame_byte_limits
run_test "frame parser fails clearly when unavailable" test_frame_parser_missing_is_explicit
run_test "frame validation is independent of working directory" test_frame_validation_does_not_depend_on_cwd
run_test "send, direct recv, and pump enforce one frame contract" test_frame_contract_on_send_recv_and_pump

run_test "frame parser fails clearly for an incomplete installation" test_frame_parser_missing_helper_is_explicit
run_test "native coprocess API works without Python" test_native_coproc_without_python
run_test "frame parser handles deep JSON without a traceback" test_frame_parser_bounds_nesting
run_test "pump assembles split UTF-8 without changing bytes" test_frame_pump_assembles_split_unicode
run_test "send, recv, and pump enforce UTF-8 byte boundaries" test_frame_transport_byte_limits
