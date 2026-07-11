#!/usr/bin/env bash
#
# ffms2/mayhem/test.sh — RUN ffms2's OWN gtest suite (built by mayhem/build.sh with normal flags)
# against the vendored sample media in mayhem/test-samples/, and emit a CTRF summary.
# exit 0 iff no test failed.
#
# PATCH-grade golden oracle: these are upstream's real tests. indexer.cpp indexes each sample with
# ffms2 and asserts FFMS_GetVideoProperties->NumFrames and, per frame, the decoded plane SHA256
# against the golden per-frame data baked into test/data/*.cpp. hdr.cpp asserts mastering-display /
# light-level metadata; display_matrix.cpp asserts the rotation matrix. They check EXACT decoded
# bytes / metadata, so a no-op or "return early" patch to the indexer/decoder cannot pass. This
# script only RUNS the pre-built binaries; it never compiles.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$SRC"

TESTBUILD="$SRC/mayhem-tests"

# emit_ctrf <tool> <passed> <failed> [skipped]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}"
  local tests=$(( passed + failed + skipped ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": 0,
      "skipped": $skipped,
      "other": 0
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":0,"skipped":%d,"other":0}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$skipped"
  [ "$failed" -eq 0 ]
}

if [ ! -d "$TESTBUILD" ]; then
  echo "missing $TESTBUILD — run mayhem/build.sh first" >&2
  emit_ctrf "ffms2-gtest" 0 1 0; exit 2
fi

TOTAL_PASS=0; TOTAL_FAIL=0
ran_any=0
for t in indexer hdr display_matrix; do
  bin="$TESTBUILD/$t"
  [ -x "$bin" ] || { echo "WARN: $t binary missing — skipping" >&2; continue; }
  ran_any=1
  echo "=== running $t ==="
  out="$("$bin" 2>&1)"; rc=$?
  echo "$out"
  # gtest prints "[  PASSED  ] N test(s)." and "[  FAILED  ] N test(s)," lines.
  p=$(printf '%s\n' "$out" | sed -n 's/.*\[  PASSED  \] \([0-9][0-9]*\) test.*/\1/p' | tail -1)
  f=$(printf '%s\n' "$out" | sed -n 's/.*\[  FAILED  \] \([0-9][0-9]*\) test.*/\1/p' | tail -1)
  : "${p:=0}" "${f:=0}"
  # If gtest produced no parseable summary, fall back to the exit code.
  if [ "$p" -eq 0 ] && [ "$f" -eq 0 ]; then
    if [ "$rc" -eq 0 ]; then p=1; else f=1; fi
  fi
  echo "$t: passed=$p failed=$f (rc=$rc)"
  TOTAL_PASS=$(( TOTAL_PASS + p ))
  TOTAL_FAIL=$(( TOTAL_FAIL + f ))
done

if [ "$ran_any" -eq 0 ]; then
  echo "no test binaries were runnable" >&2
  emit_ctrf "ffms2-gtest" 0 1 0; exit 2
fi

emit_ctrf "ffms2-gtest" "$TOTAL_PASS" "$TOTAL_FAIL" 0
