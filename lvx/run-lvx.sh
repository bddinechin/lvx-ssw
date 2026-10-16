#!/usr/bin/env bash
# Striped Smith-Waterman on LVX, through SIMDe's SSE2.  See README.md.
#
#   ./run-lvx.sh              lvx-2 -O2 under gem5, timed
#   MARCH=lvx-1 ./run-lvx.sh  the scalar core
#   OPT=O3 ./run-lvx.sh
#   ./run-lvx.sh --native     the x86 oracle, same source, native SSE2
#   BENCH=inter ./run-lvx.sh  the inter-sequence kernel instead of striped
#   BENCH=inter-gather ...    the same kernel fetching scores with PSHUFB
#
# BENCH selects which of the two Smith-Waterman shapes to measure:
#   striped (default)  lvx-bench.c over upstream src/ssw.c -- Farrar striped,
#                      one query across sixteen strided lanes, with the lazy-F
#                      fix-up loop and its data-dependent early exit.
#   inter              lvx-inter.c -- Rognes/SWIPE inter-sequence, sixteen
#                      independent database sequences, no lazy-F, no branch in
#                      the inner loop.  Scores come from a precomputed database
#                      profile (SWIMM's `-p S').
#   inter-gather       the SAME kernel, one _mm_shuffle_epi8 per cell-vector
#                      instead of the profile load.  Identical in every other
#                      respect, so the difference between the two
#                      cycles-per-cell figures IS the cost of PSHUFB on this
#                      ISA -- 22 instructions as of 2026-10-16, since LVX has
#                      no runtime-indexed byte gather.  Both must produce the
#                      same checksum.
# They measure different things on purpose; see the header of lvx-inter.c.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
# --- Locating lvx-csw ------------------------------------------------------
#
# This benchmark measures a toolchain that is a BUILD PRODUCT of a *built*
# lvx-csw checkout: lvx-toolchain/bin and lvx-gem5/build are in nobody's git.
# So lvx-csw's location is a PARAMETER of this harness, never an assumption.
#
# It used to be "$HERE/..", which held only while this repository was a
# submodule of lvx-csw. It is a submodule of lvx-perf now, so that guess
# resolved to lvx-perf -- which has no toolchain in it at all.
#
# Precedence, highest first:
#   --csw <path>                explicit, for a one-off or a CI job
#   $LVX_CSW                    environment, for a shell session
#   <lvx-perf>/lvx-csw.path     one line, per machine, not committed
#   <lvx-perf>/../lvx-csw       the default: the two checkouts as siblings
#   <this repo>/../lvx-csw      same idea, for a standalone clone
#
# A path given explicitly is never silently replaced by a fallback: name a
# tree and get told which mechanism named it, rather than measuring another
# checkout's compiler by accident.

csw_from=
csw_path=
_rest=()
while [ $# -gt 0 ]; do
    case "$1" in
        --csw)   [ $# -ge 2 ] || { echo "--csw needs a path" >&2; exit 2; }
                 csw_path=$2; csw_from='--csw'; shift 2 ;;
        --csw=*) csw_path=${1#--csw=}; csw_from='--csw'; shift ;;
        *)       _rest+=("$1"); shift ;;
    esac
done
set -- ${_rest[@]+"${_rest[@]}"}

_super=$(git -C "$HERE" rev-parse --show-superproject-working-tree 2>/dev/null) || _super=
[ -n "${_super:-}" ] || _super=

if [ -z "$csw_path" ] && [ -n "${LVX_CSW:-}" ]; then
    csw_path=$LVX_CSW; csw_from='$LVX_CSW'
fi
if [ -z "$csw_path" ] && [ -n "$_super" ] && [ -r "$_super/lvx-csw.path" ]; then
    # One path per file, '#' comments allowed; a relative path is relative to
    # lvx-perf, so a committed-by-accident file still means the same thing.
    csw_path=$(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$_super/lvx-csw.path" \
               | grep -v '^[[:space:]]*$' | head -1)
    if [ -n "$csw_path" ]; then
        csw_from="$_super/lvx-csw.path"
        case $csw_path in /*) ;; *) csw_path=$_super/$csw_path ;; esac
    fi
fi
if [ -z "$csw_path" ]; then
    for _c in ${_super:+"$_super/../lvx-csw"} "$HERE/../lvx-csw"; do
        if [ -d "$_c/lvx-mds" ] || [ -d "$_c/validation" ]; then
            csw_path=$_c; csw_from='default sibling'; break
        fi
    done
fi

if [ -z "$csw_path" ]; then
    _hint=${_super:-<lvx-perf>}
    cat >&2 <<EOM
error: cannot find lvx-csw, and this benchmark cannot run without it: it
       measures the toolchain that lvx-csw builds.

Name a location -- highest precedence first:
    $(basename "$0") --csw /path/to/lvx-csw
    LVX_CSW=/path/to/lvx-csw $(basename "$0")
    echo /path/to/lvx-csw > $_hint/lvx-csw.path
or put the two checkouts side by side, which is the default:
    $_hint/../lvx-csw
EOM
    exit 2
fi

[ -d "$csw_path" ] || {
    echo "error: lvx-csw path does not exist: $csw_path  (from $csw_from)" >&2
    exit 2
}
CSW=$(cd "$csw_path" && pwd)
if [ ! -d "$CSW/lvx-mds" ] && [ ! -d "$CSW/validation" ]; then
    echo "error: $CSW does not look like an lvx-csw checkout  (from $csw_from)" >&2
    echo "       expected lvx-mds/ and validation/ inside it" >&2
    exit 2
fi
# lvx-toolchain/ is a build product and is not versioned, so "there but not
# built" is the ordinary failure here, not a broken tree. Say which it is.
#
# --native is exempt: the x86 oracle builds with the host cc and needs only
# SIMDe's headers from lvx-csw, so requiring a cross-toolchain for it would
# take away the one thing that still works without a built tree.
if [ "${1:-}" != "--native" ] \
   && [ -z "${LVX_TOOLS:-}" ] && [ ! -x "$CSW/lvx-toolchain/bin/lvx-mbr-gcc" ]; then
    echo "error: $CSW has no built cross-toolchain  (from $csw_from)" >&2
    echo "       expected lvx-toolchain/bin/lvx-mbr-gcc" >&2
    echo "       build it:  make -C '$CSW' install-minimal-toolchain" >&2
    echo "       or point past it:  LVX_TOOLS=<dir>" >&2
    exit 2
fi
# Children and recursive invocations inherit the decision rather than redoing
# it -- a child must not re-resolve to a different tree midway.
export LVX_CSW="$CSW"
# --- end locating lvx-csw --------------------------------------------------
MARCH=${MARCH:-lvx-2}
OPT=${OPT:-O2}
BENCH=${BENCH:-striped}
BENCH_CF=""
case $BENCH in
    striped) SRCS="$HERE/lvx/lvx-bench.c $HERE/src/ssw.c $HERE/lvx/lvx-shim.c" ;;
    # lvx-inter.c is self-contained: its own kernel, its own scalar oracle, and
    # no upstream ssw.c, so it needs no allocator shim either -- every buffer
    # is static.  That is why lvx-shim.c is absent here rather than forgotten.
    inter)        SRCS="$HERE/lvx/lvx-inter.c" ;;
    inter-gather) SRCS="$HERE/lvx/lvx-inter.c"; BENCH_CF="-DISB_GATHER" ;;
    *) echo "error: unknown BENCH='$BENCH' (expected striped, inter or inter-gather)" >&2; exit 2 ;;
esac
SIMDE=$CSW/lvx-simde

if [ "${1:-}" = "--native" ]; then
	case $BENCH in
		striped) nsrc="$HERE/lvx/lvx-bench.c $HERE/src/ssw.c" ;;
		*)       nsrc="$HERE/lvx/lvx-inter.c" ;;
	esac
	# -mssse3 only natively, and only for the gather: _mm_shuffle_epi8 is SSSE3
	# and x86-64's baseline stops at SSE2, so the host cc refuses to inline it
	# without the flag.  The LVX build needs nothing -- SIMDe provides it.
	nflags=""
	[ "$BENCH" = inter-gather ] && nflags="-mssse3"
	# shellcheck disable=SC2086
	cc -$OPT $nflags $BENCH_CF -I"$HERE/src" -I"$SIMDE" -o /tmp/ssw-native-$BENCH $nsrc -lm || exit 1
	exec /tmp/ssw-native-$BENCH t
fi

BIN=$CSW/lvx-toolchain/bin
# SIMDe is a cross-project dependency the split created: lvx-simde stays a
# submodule of lvx-csw while this benchmark compiles through it. Only the LVX
# build needs it -- ssw.c selects <simde/x86/sse2.h> on __lvx__ and real
# <emmintrin.h> otherwise, which is why --native above is the x86 oracle and
# does not want these headers -- so check it here rather than at resolution.
[ -r "$SIMDE/simde/x86/sse2.h" ] || {
    echo "error: no SIMDe headers at $SIMDE  (lvx-csw from $csw_from)" >&2
    echo "       expected simde/x86/sse2.h; this benchmark reaches LVX" >&2
    echo "       through SIMDe's SSE2 layer and cannot build without it" >&2
    echo "       fix:  git -C '$CSW' submodule update --init lvx-simde" >&2
    exit 2
}
case $MARCH in
    lvx-1) GEM5BIN=gem5-lvx1.opt ;;
    lvx-2) GEM5BIN=gem5-lvx2.opt ;;
    # Wrong-core runs are SILENT: lvx-2 code under gem5-lvx1.opt does not
    # error, it returns wrong answers. An unknown MARCH must therefore stop
    # here rather than leave GEM5BIN unset for `set -u` to catch later, or
    # worse, default to a core that does not match the code.
    *) echo "error: unknown MARCH='$MARCH' (expected lvx-1 or lvx-2)" >&2; exit 2 ;;
esac
[ "${STATIC_ONLY:-0}" = 1 ] || [ -x "$CSW/lvx-gem5/build/$GEM5BIN" ] || {
    echo "error: missing ISS for $MARCH: $CSW/lvx-gem5/build/$GEM5BIN" >&2
    echo "       (lvx-csw from $csw_from) -- build it in lvx-gem5" >&2
    exit 2
}
WD=$(mktemp -d); trap 'rm -rf "$WD"' EXIT

# Freestanding, like validation/: newlib's malloc/printf are not needed -- the
# driver writes through crt.S's sys_write -- but SSW itself calls malloc/calloc
# and memset, so link newlib's libc for those.
CF="-$OPT -march=$MARCH $BENCH_CF -I$HERE/src -I$SIMDE -DSIMDE_ENABLE_NATIVE_ALIASES -ffreestanding -fno-strict-aliasing"
objs=""
for src in $SRCS; do
	o=$WD/$(basename "$src" .c).o
	"$BIN/lvx-mbr-gcc" $CF -c "$src" -o "$o" || { echo "COMPILE FAIL: $src"; exit 1; }
	objs="$objs $o"
done
"$BIN/lvx-mbr-as" -march="$MARCH" "$CSW/validation/lib/crt.S" -o "$WD/crt.o" || exit 1
"$BIN/lvx-mbr-gcc" -march="$MARCH" -nostartfiles -nostdlib \
	-Wl,-e,_start -Wl,-Ttext=0x10000 \
	"$WD/crt.o" $objs -lgcc -o "$WD/ssw.elf" \
	|| { echo "LINK FAIL"; exit 1; }

echo "== $BENCH $MARCH -$OPT =="

# Static metrics, in the same key-value shape as the driver's own output so a
# caller parses ONE stream.  Counted exactly as lvx-polybench's harness counts
# them, so a number here means the same thing as a number there: instructions
# are disassembly lines, bundles are `;;' stops, and SIMD instructions are
# recognised by their lane-shape suffix (dp=2x64, wq=4x32, ho=8x16, bx=16x8 --
# all 128 bits, the letter being the lane width).
"$BIN/lvx-mbr-objdump" -d "$WD/ssw.elf" > "$WD/dis.txt" 2>/dev/null
echo "text_bytes $("$BIN/lvx-mbr-size" -A "$WD/ssw.elf" | awk '$1==".text"{print $2}')"
echo "insns_static $(grep -cE '^[[:space:]]+[0-9a-f]+:' "$WD/dis.txt")"
echo "bundles_static $(grep -c ';;' "$WD/dis.txt")"
echo "simd_insns $(grep -coE '\b[a-z]+(dp|wq|ho|bx)\b' "$WD/dis.txt" || true)"
"$BIN/lvx-mbr-objdump" -d "$WD/ssw.elf" | awk '
  match($0, /\<(maxu?(bx|ho)|addu?s(bx|ho)|sbfu?s(bx|ho)|srlq|sllq|compbx|splat[bhwd]q)\>/) {
    m = substr($0, RSTART, RLENGTH); c[m]++ }
  END { printf "   SIMD mnemonics:"; for (k in c) printf " %s=%d", k, c[k]; print "" }'
# STATIC_ONLY builds and reports static metrics without running the ISS --
# the quick check that codegen still looks right, and the only mode that works
# without a built gem5.
if [ "${STATIC_ONLY:-0}" = 1 ]; then
	exit 0
fi

LVX_CPU=${LVX_CPU:-minor} timeout ${TMO:-900} \
	"$CSW/lvx-gem5/build/$GEM5BIN" --outdir="$WD/m5out" \
	"$CSW/lvx-gem5/tests/lvx/run_lvx.py" "$WD/ssw.elf" 2>&1 |
	grep -E "^checksum|^queries|^ref_len|^sequences|^db_len|^query_len|^lanes|^cells|^cycles|^acc|^alignments|^ok|^note|^FAIL|^MISMATCH|^OVERFLOW|target exited"
