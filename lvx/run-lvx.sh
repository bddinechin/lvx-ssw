#!/usr/bin/env bash
# Striped Smith-Waterman on LVX, through SIMDe's SSE2.  See README.md.
#
#   ./run-lvx.sh              lvx-2 -O2 under gem5, timed
#   MARCH=lvx-1 ./run-lvx.sh  the scalar core
#   OPT=O3 ./run-lvx.sh
#   ./run-lvx.sh --native     the x86 oracle, same source, native SSE2
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
CSW=$(cd "$HERE/.." && pwd)
MARCH=${MARCH:-lvx-2}
OPT=${OPT:-O2}
SIMDE=$CSW/lvx-simde

if [ "${1:-}" = "--native" ]; then
	cc -$OPT -I"$HERE/src" -I"$SIMDE" -o /tmp/ssw-native \
	   "$HERE/lvx/lvx-bench.c" "$HERE/src/ssw.c" -lm || exit 1
	exec /tmp/ssw-native t
fi

BIN=$CSW/lvx-toolchain/bin
case $MARCH in lvx-1) GEM5BIN=gem5-lvx1.opt ;; lvx-2) GEM5BIN=gem5-lvx2.opt ;; esac
WD=$(mktemp -d); trap 'rm -rf "$WD"' EXIT

# Freestanding, like validation/: newlib's malloc/printf are not needed -- the
# driver writes through crt.S's sys_write -- but SSW itself calls malloc/calloc
# and memset, so link newlib's libc for those.
CF="-$OPT -march=$MARCH -I$HERE/src -I$SIMDE -DSIMDE_ENABLE_NATIVE_ALIASES -ffreestanding -fno-strict-aliasing"
for src in "$HERE/lvx/lvx-bench.c" "$HERE/src/ssw.c" "$HERE/lvx/lvx-shim.c"; do
	o=$WD/$(basename "$src" .c).o
	"$BIN/lvx-mbr-gcc" $CF -c "$src" -o "$o" || { echo "COMPILE FAIL: $src"; exit 1; }
done
"$BIN/lvx-mbr-as" -march="$MARCH" "$CSW/validation/lib/crt.S" -o "$WD/crt.o" || exit 1
"$BIN/lvx-mbr-gcc" -march="$MARCH" -nostartfiles -nostdlib \
	-Wl,-e,_start -Wl,-Ttext=0x10000 \
	"$WD/crt.o" "$WD"/lvx-bench.o "$WD"/ssw.o "$WD"/lvx-shim.o -lgcc -o "$WD/ssw.elf" \
	|| { echo "LINK FAIL"; exit 1; }

echo "== $MARCH -$OPT =="
"$BIN/lvx-mbr-objdump" -d "$WD/ssw.elf" | awk '
  match($0, /\<(maxu?(bx|ho)|addu?s(bx|ho)|sbfu?s(bx|ho)|srlq|sllq|compbx|splat[bhwd]q)\>/) {
    m = substr($0, RSTART, RLENGTH); c[m]++ }
  END { printf "   SIMD mnemonics:"; for (k in c) printf " %s=%d", k, c[k]; print "" }'
LVX_CPU=${LVX_CPU:-minor} timeout ${TMO:-900} \
	"$CSW/lvx-gem5/build/$GEM5BIN" --outdir="$WD/m5out" \
	"$CSW/lvx-gem5/tests/lvx/run_lvx.py" "$WD/ssw.elf" 2>&1 |
	grep -E "^checksum|^queries|^ref_len|^cells|^cycles|^acc|^alignments|^acc|^cycles|^ok|^FAIL|^MISMATCH|target exited"
