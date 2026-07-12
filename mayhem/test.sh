#!/usr/bin/env bash
#
# mayhem/test.sh — behavioral oracle for the Ceed compiler (built by mayhem/build.sh as
# /mayhem/ceed-oracle). Ceed ships NO assertion-based test suite — its tst/ dir holds three
# example programs (hello.e, math.e, loop.e) and there is no make check / ctest / unit runner.
# So this is a genuine behavioral oracle (NOT "exit 0"): it COMPILES programs with ceed-oracle
# and asserts on the produced 32-bit ELF/PE and, for deterministic programs, the exact stdout of
# the generated executable. A patch that neuters the compiler (or breaks code-gen) makes the
# generated program vanish / print the wrong bytes, so these assertions FAIL.
#
# Cases (10):
#   Exact-output KATs (compile, run the emitted ELF, diff stdout):
#     hello.e (upstream fixture) -> "Hello world!"    int-add -> "5"   int-sub -> "5"
#     if/compare -> "yes"        function call -> "hi"
#   Compile-to-valid-ELF KATs (upstream fixtures that are interactive/recursive — assert the
#   compiler produces a valid 32-bit ELF, don't pin runtime I/O):  math.e, loop.e
#   PE backend KAT:  hello.e -pe -> a.exe begins with the "MZ" DOS signature
#   Negative KATs (the compiler must REJECT bad input with a non-zero exit):  garbage, empty
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

CEED=/mayhem/ceed-oracle
TST="$SRC/tst"
WORK="$(mktemp -d /tmp/ceed-oracle.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

PASS=0; FAIL=0
ok()   { echo "PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

[ -x "$CEED" ] || bad "ceed-oracle missing ($CEED) — build.sh did not produce it"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# is_elf32 <file> : true iff file starts with the ELF magic and is 32-bit (EI_CLASS==1)
is_elf32() {
  [ -s "$1" ] || return 1
  local sig cls
  sig="$(head -c4 "$1" | od -An -tx1 | tr -d ' \n')"
  [ "$sig" = "7f454c46" ] || return 1        # \x7fELF
  cls="$(dd if="$1" bs=1 skip=4 count=1 2>/dev/null | od -An -tu1 | tr -d ' \n')"
  [ "$cls" = "1" ]                           # ELFCLASS32
}

# compile_run <label> <expected-stdout> < program-on-stdin
compile_run() {
  local label="$1" want="$2"
  rm -f a.out
  "$CEED" >/dev/null 2>&1 || { bad "$label: compiler exited non-zero"; return; }
  is_elf32 a.out || { bad "$label: no valid 32-bit ELF produced"; return; }
  chmod +x a.out
  local got; got="$(./a.out 2>/dev/null)"
  if [ "$got" = "$want" ]; then ok "$label: stdout == [$want]"; else bad "$label: stdout [$got] != [$want]"; fi
}

# compile_elf <label> < program-on-stdin  (assert a valid 32-bit ELF is emitted)
compile_elf() {
  local label="$1"
  rm -f a.out
  "$CEED" >/dev/null 2>&1 || { bad "$label: compiler exited non-zero"; return; }
  is_elf32 a.out && ok "$label: emitted a valid 32-bit ELF" || bad "$label: no valid 32-bit ELF produced"
}

# expect_reject <label> < program-on-stdin  (compiler must exit non-zero on bad input)
expect_reject() {
  local label="$1"
  rm -f a.out
  if "$CEED" >/dev/null 2>&1; then bad "$label: compiler accepted invalid input (exit 0)"; else ok "$label: rejected (non-zero exit)"; fi
}

if [ -x "$CEED" ]; then
  # --- exact-output KATs -------------------------------------------------------
  compile_run "hello.e"    "Hello world!" < "$TST/hello.e"
  compile_run "int-add"    "5"            <<< '_a { A = 2 + 3; wi(A); nl(); }'
  compile_run "int-sub"    "5"            <<< '_a { A = 9 - 4; wi(A); nl(); }'
  compile_run "if-compare" "yes"          <<< '_a { x = 7; if (x > 3) { ws("yes"); nl(); } }'
  compile_run "func-call"  "hi"           <<< '_b { ws("hi"); nl(); } _a { _b(); }'

  # --- compile-to-valid-ELF KATs (interactive / recursive upstream fixtures) ---
  compile_elf "math.e" < "$TST/math.e"
  compile_elf "loop.e" < "$TST/loop.e"

  # --- PE backend KAT ----------------------------------------------------------
  rm -f a.exe
  if "$CEED" -pe < "$TST/hello.e" >/dev/null 2>&1 && [ "$(head -c2 a.exe 2>/dev/null)" = "MZ" ]; then
    ok "pe-backend: hello.e -pe emits an MZ (PE) image"
  else
    bad "pe-backend: hello.e -pe did not emit an MZ image"
  fi

  # --- negative KATs -----------------------------------------------------------
  expect_reject "reject-garbage" <<< '@#$ not valid ceed'
  expect_reject "reject-empty"   < /dev/null
fi

emit_ctrf "ceed-oracle" "$PASS" "$FAIL"
