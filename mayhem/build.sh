#!/usr/bin/env bash
#
# ffms2/mayhem/build.sh — build FFMS/ffms2's OSS-Fuzz harness as a sanitized libFuzzer target
# (+ a standalone reproducer), AND ffms2's own gtest suite (for mayhem/test.sh).
#
# Fuzzed surface: ffms2 is a thin C++ wrapper over FFmpeg that INDEXES + DECODES media files.
#   ffms2_fuzzer — writes the input bytes to a temp file, then drives
#       FFMS_CreateIndexer -> FFMS_DoIndexing2 -> FFMS_GetFirstTrackOfType.
#     i.e. it exercises ffms2's container probing / indexing path (src/core/indexing.cpp,
#     filehandle.cpp, track.cpp, zipfile.cpp) on attacker-controlled media containers
#     (MP4/MOV/ISOBMFF, Matroska/WebM, ...). The input IS a raw media file.
#
# Build contract from the org base ENV: CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC/OUT/
# STANDALONE_FUZZ_MAIN. We compile ffms2's OWN library sources with $SANITIZER_FLAGS so the
# indexer/decoder code under test is instrumented (ASan+UBSan, halting). FFmpeg itself is the
# system package (apt libav*-dev 7.1.x = the n7.1 series OSS-Fuzz pins) — a dependency, not the
# code under test; building it from source with sanitizers would cost 30+ min and GBs for no gain
# in the fuzzed surface. ffms2's autoconf requires libavformat>=61.7 etc. which 7.1.x satisfies.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${SRC:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
: "${OUT:=/mayhem}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE STANDALONE_FUZZ_MAIN MAYHEM_JOBS SRC OUT

mkdir -p "$OUT"
cd "$SRC"

HARNESS_DIR="$SRC/mayhem/harnesses"
FFMPEG_CFLAGS="$(pkg-config --cflags libavformat libavcodec libavutil libswscale libswresample)"
FFMPEG_LIBS="$(pkg-config --libs libavformat libavcodec libavutil libswscale libswresample)"

# ffms2's own compile flags (mirrors Makefile.am AM_CPPFLAGS / AM_CXXFLAGS, minus -fvisibility=hidden
# so the harness can resolve the FFMS_* symbols when linked statically).
FFMS_CPPFLAGS="-I$SRC -I$SRC/include -I$SRC/src/config \
  -D_FILE_OFFSET_BITS=64 -DFFMS_EXPORTS -D__STDC_CONSTANT_MACROS"

# ── 1) Generate config.h via autoconf (ffms.cpp etc. -include config.h) ───────────────────────────
# Run configure with the SAME ffmpeg the harness links, but do NOT use its build (we compile the
# library sources ourselves with sanitizers). NOCONFIGURE keeps autogen from building.
if [ ! -f "$SRC/src/config/config.h" ]; then
  NOCONFIGURE=1 ./autogen.sh
  # configure only to materialise config.h; compilers point at clang so feature tests match.
  ./configure CC="$CC" CXX="$CXX" --disable-avisynth --disable-vapoursynth >/dev/null 2>&1 \
    || ./configure CC="$CC" CXX="$CXX" >/dev/null 2>&1 || true
  # autoconf writes config.h at the top level; ffms expects it on the include path. Mirror to src/config.
  mkdir -p "$SRC/src/config"
  [ -f "$SRC/config.h" ] && cp "$SRC/config.h" "$SRC/src/config/config.h" || true
fi
[ -f "$SRC/src/config/config.h" ] || { echo "config.h not generated" >&2; exit 1; }

# ── 2) Compile ffms2's library sources WITH sanitizers into a static archive ──────────────────────
BUILD="$SRC/mayhem-build"
mkdir -p "$BUILD"
LIB_SRCS="
  src/core/audiosource.cpp
  src/core/ffms.cpp
  src/core/filehandle.cpp
  src/core/indexing.cpp
  src/core/track.cpp
  src/core/utils.cpp
  src/core/videosource.cpp
  src/core/videoutils.cpp
  src/core/zipfile.cpp
  src/vapoursynth/vapoursource4.cpp
  src/vapoursynth/vapoursynth4.cpp
"
# Two archives: one with SanitizerCoverage (-fsanitize=fuzzer-no-link) for the libFuzzer target so
# the fuzzer SEES ffms2's indexer/decoder edges (not just the harness); one without, for the
# standalone reproducer (which has no libFuzzer runtime to satisfy the coverage callbacks).
OBJS=(); OBJS_SA=()
for s in $LIB_SRCS; do
  base="$(echo "$s" | tr '/' '_' | sed 's/\.cpp$//')"
  obj="$BUILD/${base}.o"; obj_sa="$BUILD/${base}.sa.o"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -std=c++11 $FFMS_CPPFLAGS $FFMPEG_CFLAGS \
    -include "$SRC/src/config/config.h" -c "$s" -o "$obj"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS -std=c++11 $FFMS_CPPFLAGS $FFMPEG_CFLAGS \
    -include "$SRC/src/config/config.h" -c "$s" -o "$obj_sa"
  OBJS+=("$obj"); OBJS_SA+=("$obj_sa")
done
LIBFFMS="$BUILD/libffms2.a"
LIBFFMS_SA="$BUILD/libffms2_sa.a"
rm -f "$LIBFFMS" "$LIBFFMS_SA"
ar rcs "$LIBFFMS" "${OBJS[@]}"
ar rcs "$LIBFFMS_SA" "${OBJS_SA[@]}"
echo "built sanitized libffms2.a ($(du -h "$LIBFFMS" | cut -f1)) + standalone variant"

# ── 3) Build the OSS-Fuzz harness: libFuzzer target + standalone reproducer ───────────────────────
# The harness includes <ffms.h> and overrides atexit(); compile as C++.
for harness in ffms2_fuzzer; do
  # libFuzzer target -> $OUT/<name>
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS -std=c++11 -I"$SRC/include" \
    "$HARNESS_DIR/$harness.cc" $LIB_FUZZING_ENGINE "$LIBFFMS" $FFMPEG_LIBS -lz -lpthread \
    -o "$OUT/$harness"

  # standalone reproducer (no libFuzzer runtime; reads one input file) -> $OUT/<name>-standalone.
  # Compile the harness .cc and the .c driver as separate objects, then link with clang++ so the
  # C++ runtime is pulled in. The .c driver calls LLVMFuzzerTestOneInput with C linkage; the harness
  # defines it `extern "C"`, so the symbols match. (Avoid putting the .a after -x c++ — clang would
  # try to parse the archive as a source file.)
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS -std=c++11 -I"$SRC/include" -c "$HARNESS_DIR/$harness.cc" -o "$BUILD/${harness}_h.o"
  $CC  $SANITIZER_FLAGS $DEBUG_FLAGS -c "$HARNESS_DIR/${harness}_standalone.c" -o "$BUILD/${harness}_sa.o"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS \
    "$BUILD/${harness}_h.o" "$BUILD/${harness}_sa.o" \
    "$LIBFFMS_SA" $FFMPEG_LIBS -lz -lpthread \
    -o "$OUT/$harness-standalone"

  echo "built $harness (+ standalone)"
done

# ── 4) Build ffms2's OWN gtest suite with NORMAL flags (test.sh only RUNS it) ─────────────────────
# Uses system gtest (apt libgtest-dev) so we don't need the googletest submodule. The library here
# is built with NORMAL flags (no sanitizers) so test.sh is an honest golden/PATCH oracle: the tests
# index the vendored sample media and assert frame count + decoded-plane SHA256 against the per-frame
# golden data embedded in test/data/*.cpp. A no-op patch cannot reproduce those exact bytes.
TESTBUILD="$SRC/mayhem-tests"
mkdir -p "$TESTBUILD"
SAMPLES_DIR="$SRC/mayhem/test-samples"

# Library, normal flags.
TOBJS=()
for s in $LIB_SRCS; do
  obj="$TESTBUILD/$(echo "$s" | tr '/' '_' | sed 's/\.cpp$/.o/')"
  $CXX -O2 -g -std=c++11 $FFMS_CPPFLAGS $FFMPEG_CFLAGS \
    -include "$SRC/src/config/config.h" -c "$s" -o "$obj"
  TOBJS+=("$obj")
done
ar rcs "$TESTBUILD/libffms2_test.a" "${TOBJS[@]}"

# Each upstream test .cpp ships its OWN int main() (InitGoogleTest + RUN_ALL_TESTS), so we link
# only -lgtest (no gtest_main). Only indexer.cpp uses CheckFrame() from tests.cpp.
GTEST_CFLAGS="$(pkg-config --cflags gtest 2>/dev/null || echo -I/usr/include)"
GTEST_LIBS="$(pkg-config --libs gtest 2>/dev/null || echo -lgtest)"
TEST_CPPFLAGS="-I$SRC/include -I$SRC/test -D_FILE_OFFSET_BITS=64 -DFFMS_EXPORTS \
  -D__STDC_CONSTANT_MACROS -DSAMPLES_DIR=$SAMPLES_DIR"

# gtest 1.16 (Debian trixie) headers require C++14+ (std::index_sequence). The test .cpp only use
# ffms2's C API + gtest, so compile them at c++17 even though the library is c++11.
for t in indexer hdr display_matrix; do
  extra=""
  [ "$t" = indexer ] && extra="$SRC/test/tests.cpp"
  $CXX -O2 -g -std=c++17 -pthread $TEST_CPPFLAGS $FFMPEG_CFLAGS $GTEST_CFLAGS \
    "$SRC/test/$t.cpp" $extra \
    "$TESTBUILD/libffms2_test.a" $FFMPEG_LIBS -lz $GTEST_LIBS -pthread \
    -o "$TESTBUILD/$t" \
    || { echo "WARNING: failed to build test '$t'" >&2; }
done
echo "built ffms2 gtest suite in $TESTBUILD/"

echo "build.sh complete:"
ls -la "$OUT/ffms2_fuzzer" "$OUT/ffms2_fuzzer-standalone" 2>&1 || true
