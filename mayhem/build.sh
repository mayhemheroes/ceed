#!/usr/bin/env bash
#
# mayhem/build.sh — build the Ceed fuzz harness(es) + the functional oracle binary.
#
# Ceed is a tiny C compiler (flex scanner + bison grammar + a hand-written x86 code
# generator emitting a 32-bit ELF/PE). We build three things, all ADDITIVE — no
# upstream source is edited; the only accommodations are BUILD FLAGS:
#
#   /mayhem/fuzz_ceed             in-process libFuzzer harness (mayhem/fuzz_ceed.c) that
#                                 drives lex -> parse -> code-gen on fuzzer bytes.
#   /mayhem/fuzz_ceed-standalone  the same harness linked against the standalone driver
#                                 (run-once reproducer; no libFuzzer runtime).
#   /mayhem/ceed-oracle           the stock `ceed` compiler, built with the project's own
#                                 flags — the functional oracle mayhem/test.sh runs.
#
# Toolchain accommodations (Ceed targets a ~2017 gcc; the base ships clang-19/gcc-14):
#   * src/makefile forces -std=c99, under which the flex-generated scanner calls fileno()
#     with no visible prototype. -std=gnu99 exposes the POSIX prototype. (Same intent as
#     upstream's c99, with GNU/POSIX visibility.)
#   * gcc-14/clang-19 promote K&R-era constructs to hard errors by default
#     (implicit-function-declaration, incompatible-pointer-types, int-conversion). We
#     downgrade exactly those three back to warnings (-Wno-error=...) and -w-silence them,
#     matching the makefile's own `-w`. -fcommon restores pre-gcc-10 tentative-definition
#     merging the code relies on. None of this changes emitted code.
#
# fuzz-build-only tricks (do NOT touch upstream files):
#   * ceedcmpl.c is compiled with -Dstatic= so the harness can reset the file-static
#     CODE/RDATA position counters between iterations.
#   * ceed.tab.c (the bison output, which carries Ceed's own main() from ceed.y's epilogue)
#     is compiled with -Dmain=ceed_cli_main so its main() doesn't collide with the
#     libFuzzer / standalone driver main().
#   * the fuzz/standalone links use -Wl,--wrap=exit (the harness turns a mid-compile
#     exit(-1) into a longjmp instead of killing the worker).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}"
: "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
export SANITIZER_FLAGS DEBUG_FLAGS CC LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

SRCDIR="$SRC/src"
BUILD="$SRC/mayhem/_build"
rm -rf "$BUILD"
mkdir -p "$BUILD"

# Toolchain-compat flags (see header) — applied to the UPSTREAM C sources only.
COMPAT="-std=gnu99 -w -fcommon \
  -Wno-error=implicit-function-declaration \
  -Wno-error=incompatible-pointer-types \
  -Wno-error=int-conversion"

# 0) Generate the flex scanner + bison parser (bison/flex ship in the base image; offline).
#    Output lands in $BUILD so the upstream src/ tree is never mutated (idempotent re-runs).
bison -d -o "$BUILD/ceed.tab.c" "$SRCDIR/ceed.y"
flex  -o "$BUILD/lex.yy.c" "$SRCDIR/ceed.l"

# The generated scanner #includes "ceed.tab.h"; keep the include path pointing at $BUILD.
INC="-I$SRCDIR -I$BUILD"

# Upstream translation units, shared by the oracle and the fuzz target.
UPSTREAM_C=( "$SRCDIR/ceedelf.c" "$SRCDIR/ceedpe.c" "$SRCDIR/ceedrtl.c" )

# ---------------------------------------------------------------------------
# 1) Functional oracle: the stock compiler, built with the project's own flags
#    (NOT sanitized — an honest behavioral oracle; +$COVERAGE_FLAGS when set).
# ---------------------------------------------------------------------------
$CC $COMPAT $COVERAGE_FLAGS $INC \
    "$BUILD/lex.yy.c" "$BUILD/ceed.tab.c" \
    "$SRCDIR/ceedcmpl.c" "${UPSTREAM_C[@]}" \
    -o /mayhem/ceed-oracle

# ---------------------------------------------------------------------------
# 2) Fuzz target: compile every TU with $SANITIZER_FLAGS + $DEBUG_FLAGS so the
#    fuzzed compiler code is instrumented AND carries DWARF < 4 symbols.
# ---------------------------------------------------------------------------
# UBSan's `function` sub-check (indirect-call type match) fires on nearly EVERY input:
# ceedcmpl.c calls the ELF/PE backend through pfn_get_va (declared `void *(*)(void *)`),
# but elf_get_code_va/elf_get_data_va/... are defined returning `u32` (the same 32-bit VA,
# just typed as an int instead of a pointer). That mismatch is the very
# -Wincompatible-pointer-types we down-graded to build at all — it's a benign type-modeling
# artifact of a 32-bit-target codegen, NOT a memory-safety bug. Left on, it halts the harness
# on the first program that emits a data section, so the fuzzer never gets past ~0 edges. We
# therefore drop ONLY `-fno-sanitize=function`; ASan (address) and ALL other UBSan checks stay
# on and HALTING, so a genuine OOB write into CODE/RDATA or any other UB is still a crash.
# -fsanitize=fuzzer-no-link embeds SanitizerCoverage (trace-pc-guard) into EVERY compiled
# upstream TU so libFuzzer gets edge feedback on the fuzzed compiler (not just the harness).
# Without it the objects carry no coverage counters and the run sits at 0 edges. The final
# link adds $LIB_FUZZING_ENGINE (-fsanitize=fuzzer) to pull in the driver.
FUZZ_SAN="$SANITIZER_FLAGS -fno-sanitize=function"
CFLAGS_FUZZ="$FUZZ_SAN -fsanitize=fuzzer-no-link $DEBUG_FLAGS $COMPAT $INC"

$CC $CFLAGS_FUZZ -Dstatic= -c "$SRCDIR/ceedcmpl.c" -o "$BUILD/ceedcmpl.o"
$CC $CFLAGS_FUZZ -Dmain=ceed_cli_main -c "$BUILD/ceed.tab.c" -o "$BUILD/ceed.tab.o"
$CC $CFLAGS_FUZZ -c "$BUILD/lex.yy.c" -o "$BUILD/lex.yy.o"
$CC $CFLAGS_FUZZ -c "$SRCDIR/ceedelf.c" -o "$BUILD/ceedelf.o"
$CC $CFLAGS_FUZZ -c "$SRCDIR/ceedpe.c"  -o "$BUILD/ceedpe.o"
$CC $CFLAGS_FUZZ -c "$SRCDIR/ceedrtl.c" -o "$BUILD/ceedrtl.o"
$CC $CFLAGS_FUZZ -c "$SRC/mayhem/fuzz_ceed.c" -o "$BUILD/fuzz_ceed.o"

OBJS=( "$BUILD/ceedcmpl.o" "$BUILD/ceed.tab.o" "$BUILD/lex.yy.o" \
       "$BUILD/ceedelf.o" "$BUILD/ceedpe.o" "$BUILD/ceedrtl.o" "$BUILD/fuzz_ceed.o" )

# 2a) libFuzzer binary.
$CC $FUZZ_SAN $DEBUG_FLAGS $LIB_FUZZING_ENGINE -Wl,--wrap=exit \
    "${OBJS[@]}" -o /mayhem/fuzz_ceed

# 2b) standalone run-once reproducer (StandaloneFuzzTargetMain.c supplies main()).
#     -fsanitize=fuzzer-no-link pulls in the SanCov runtime stubs the instrumented objects
#     reference, WITHOUT the libFuzzer driver main() (which the standalone driver provides).
$CC $FUZZ_SAN -fsanitize=fuzzer-no-link $DEBUG_FLAGS -Wl,--wrap=exit \
    "$STANDALONE_FUZZ_MAIN" "${OBJS[@]}" -o /mayhem/fuzz_ceed-standalone

echo "build.sh: built /mayhem/fuzz_ceed, /mayhem/fuzz_ceed-standalone, /mayhem/ceed-oracle"
