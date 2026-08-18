#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh)
# PLUS a KAT (known-answer-test) probe. exit 0 = pass. PATCH-grade oracle: after an agent
# patches the source, the grader rebuilds (build.sh) then runs this. Emits a CTRF summary
# (file + stdout marker).
#
# Why the KAT probe, on top of `cargo test`: `cargo test` alone is NOT a reliable behavioral
# oracle here — its harness binary's relationship to the sabotage shim used to prove
# "test.sh fails when the program is neutered" is unlike an ordinary dynamically-linked CLI
# binary, so a real regression could in principle survive it. mayhem/kat/ is a small,
# ordinary, dynamically linked binary invoked directly from bash; its stdout is asserted
# against exact expected values computed from the real apollo-parser/apollo-compiler API, so
# sabotage (or a real functional regression) is caught unconditionally.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
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

TOTAL_PASSED=0
TOTAL_FAILED=0
TOTAL_IGNORED=0

# ── 1. Upstream's own suite, exactly as upstream CI does (.circleci/config.yml:
#      `cargo test --all-features`), pre-built by mayhem/build.sh via
#      `cargo +stable test --workspace --all-features --no-run`. This covers every
#      unit/integration test across the workspace (apollo-parser, apollo-compiler,
#      apollo-smith, the fuzz crate and xtask). ──────────────────────────────────────
LOG=/tmp/cargo-test-output.log
cargo +stable test --workspace --all-features --no-fail-fast 2>&1 | tee "$LOG"

# Sum every `test result:` line: "test result: ok. 26 passed; 0 failed; 0 ignored; ..."
read -r CARGO_PASSED CARGO_FAILED CARGO_IGNORED <<< "$(awk '/^test result:/ {
  for (i=1;i<=NF;i++) { if ($(i+1)=="passed;") p+=$i; if ($(i+1)=="failed;") f+=$i; if ($(i+1)=="ignored;") g+=$i }
} END { printf "%d %d %d", p, f, g }' "$LOG")"
echo "cargo test: passed=$CARGO_PASSED failed=$CARGO_FAILED ignored=$CARGO_IGNORED"
TOTAL_PASSED=$(( TOTAL_PASSED + CARGO_PASSED ))
TOTAL_FAILED=$(( TOTAL_FAILED + CARGO_FAILED ))
TOTAL_IGNORED=$(( TOTAL_IGNORED + CARGO_IGNORED ))
[ "$CARGO_PASSED" -gt 0 ] || { echo "ERROR: 0 tests ran — suite collapsed (missing context/fixtures?)" >&2; TOTAL_FAILED=$(( TOTAL_FAILED + 1 )); }

# ── 2. KAT probe: fixed inputs -> exact expected values, via a real dynamically linked
#      binary bash invokes directly. A neutered/missing binary prints NOTHING (the
#      sabotage shim _exit(0)s its constructor before main runs), so every grep below
#      fails loudly instead of silently skipping. ────────────────────────────────────
KAT_BIN="$SRC/apollo-rs-kat"
KAT_OUT="$(mktemp)"
KAT_FAILED=0
if [ -x "$KAT_BIN" ]; then
  "$KAT_BIN" > "$KAT_OUT" 2>&1
  KAT_EXIT=$?
else
  echo "ERROR: KAT probe binary missing at $KAT_BIN" >&2
  KAT_EXIT=127
  : > "$KAT_OUT"
fi
cat "$KAT_OUT"

check_kat() {
  local label="$1" expected="$2"
  if ! grep -qxF "$expected" "$KAT_OUT"; then
    echo "KAT ASSERT FAILED ($label): expected line '$expected' not found in KAT probe output" >&2
    KAT_FAILED=1
  fi
}
check_kat "parser-zero-errors"        "KAT1 parser_errors=0"
check_kat "schema-field-count"        "KAT2 query_fields=2"
check_kat "schema-rejects-undefined"  "KAT3 bad_schema=REJECTED"
check_kat "coordinate-roundtrip"      "KAT4 coordinate=Query.hello"
check_kat "probe-completed"           "KAT OK"
[ "$KAT_EXIT" -eq 0 ] || { echo "KAT ASSERT FAILED: probe exited $KAT_EXIT" >&2; KAT_FAILED=1; }
rm -f "$KAT_OUT"

if [ "$KAT_FAILED" -eq 0 ]; then
  echo "KAT probe: PASSED (4 known-answer assertions)"
  TOTAL_PASSED=$(( TOTAL_PASSED + 1 ))
else
  echo "KAT probe: FAILED"
  TOTAL_FAILED=$(( TOTAL_FAILED + 1 ))
fi

emit_ctrf "cargo-test+kat" "$TOTAL_PASSED" "$TOTAL_FAILED" "$TOTAL_IGNORED"
