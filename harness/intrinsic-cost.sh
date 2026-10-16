#!/usr/bin/env bash
# Part of the LVX project, under the Apache License v2.0 with LLVM Exceptions.
# See LICENSE.TXT in the root of this repository for license information.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

# What an SSE intrinsic costs on LVX, per intrinsic, in instructions.
#
#   ./harness/intrinsic-cost.sh
#   ./harness/intrinsic-cost.sh --csw /path/to/lvx-csw
#
# Answers "is this intrinsic native here, or is SIMDe emulating it" with a
# number, which is the question that keeps recurring on this port: the
# _mm_movemask_epi8 gap, the signed-saturating-byte gap, and the PSHUFB gap
# were all found this way, and two of the three are now closed.
#
# COUNTED PER SYMBOL FROM objdump, not from the .s file.  An awk range over
# assembly bleeds across function boundaries, and skipping `get'/`set' lines
# undercounts because those are real LVX instructions.  Both mistakes were made
# while finding the saturating gap, in both sessions working on it, and they
# produced numbers wrong in both directions -- an inflated 24 and 14 for the
# epi8 pair, a spurious 12 for adds_epu16.  This form is the one that survived,
# and committing it rather than leaving it in a scratch directory is the point:
# an uncommitted measurement script is how a method gets lost and a wrong
# number gets repeated.
#
# HOW TO READ THE COLUMNS, and the one trap in them:
#
#   NATIVE    the default build: SIMDE_LVX_NATIVE is on, so SIMDe uses its LVX
#             branch wherever it has one.
#   PORTABLE  built with -DSIMDE_LVX_NO_NATIVE, which disables EVERY LVX
#             branch, not just a recently added one.
#
# So PORTABLE is "what this would cost with no LVX support at all".  It equals
# the pre-fix cost only for an intrinsic that had no native branch before the
# change you are judging -- for one whose branch pre-existed, a large
# PORTABLE -> NATIVE gap credits work done earlier, not the change in front of
# you.  Say which is which when quoting this table; an unmarked one silently
# attributes every past fix to whoever ran it last.
#
# A gap here is not always a compiler or SIMDe bug.  Two different causes, and
# the fix differs completely:
#   - the instruction EXISTS and SIMDe has no LVX branch reaching it (the
#     signed-saturating-byte case: addsbx and sbfsbx were in lvx-opc.c all
#     along) -- fixable in SIMDe, and was.
#   - the ISA has no such instruction (the PSHUFB case: LVX has structured
#     permutes only, no runtime-indexed byte gather) -- not fixable in SIMDe or
#     GCC at all; it needs an ISA change in lvx-mds.  Nothing in the toolchain
#     can move that number, which is why lvx-inter.c's inter-gather row exists
#     as a standing series instead.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(dirname "$here")"

CSW_ARG=
while [ $# -gt 0 ]; do
    case "$1" in
        --csw)     CSW_ARG=${2:?--csw needs a path}; shift 2 ;;
        --csw=*)   CSW_ARG=${1#--csw=}; shift ;;
        -h|--help) sed -n '6,50p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)         echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

# lvx-csw holds the toolchain and SIMDe; its location is a parameter, resolved
# by the same chain everything else here uses.
CSW=${LVX_CSW:-${CSW_ARG:-}}
[ -n "$CSW_ARG" ] && CSW=$CSW_ARG
if [ -z "$CSW" ]; then
    super=$(git -C "$repo" rev-parse --show-superproject-working-tree 2>/dev/null) || super=
    for c in ${super:+"$super/lvx-csw.path"} ; do
        [ -r "$c" ] && CSW=$(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$c" | grep -v '^[[:space:]]*$' | head -1)
    done
    case ${CSW:-} in ''|/*) ;; *) CSW=$super/$CSW ;; esac
fi
if [ -z "${CSW:-}" ]; then
    for c in "$repo/../../lvx-csw" "$repo/../lvx-csw" "$HOME/lvx-csw"; do
        [ -d "$c/lvx-mds" ] || [ -d "$c/validation" ] || continue
        CSW=$(cd "$c" && pwd); break
    done
fi
[ -n "${CSW:-}" ] || { echo "cannot find lvx-csw; pass --csw or set LVX_CSW" >&2; exit 2; }

# Distinguish "not lvx-csw" from "lvx-csw but not built" -- the second is the
# ordinary state of a fresh clone and wants a different instruction.
if [ ! -d "$CSW/lvx-mds" ] && [ ! -d "$CSW/validation" ]; then
    echo "error: $CSW does not look like an lvx-csw checkout" >&2
    echo "       expected lvx-mds/ and validation/ inside it" >&2
    exit 2
fi

G=$CSW/lvx-toolchain/bin/lvx-mbr-gcc
OD=$CSW/lvx-toolchain/bin/lvx-mbr-objdump
for t in "$G" "$OD"; do
    [ -x "$t" ] || {
        echo "error: $CSW has no built toolchain -- missing $t" >&2
        echo "       build it:  make -C '$CSW' install-minimal-toolchain" >&2
        exit 2; }
done
[ -r "$CSW/lvx-simde/simde/x86/sse4.1.h" ] || {
    echo "no SIMDe headers under $CSW/lvx-simde" >&2; exit 2; }

W=$(mktemp -d); trap 'rm -rf "$W"' 0 1 2 3 15

# The surface worth watching: everything lvx-ssw's two kernels depend on, plus
# the three intrinsics whose cost has moved during this port.  Add a line here
# when a kernel starts using something new -- an audit has to enumerate the
# surface rather than count what is already known, which is the lesson the
# movemask and saturating gaps both taught.
cat > "$W/t.c" <<'SRC'
#include <simde/x86/sse4.1.h>
#include <simde/x86/ssse3.h>
/* unsigned saturating bytes: the inter-sequence kernel is built on these */
__m128i k_adds_epu8 (__m128i a,__m128i b){return _mm_adds_epu8(a,b);}
__m128i k_subs_epu8 (__m128i a,__m128i b){return _mm_subs_epu8(a,b);}
__m128i k_max_epu8  (__m128i a,__m128i b){return _mm_max_epu8(a,b);}
__m128i k_min_epu8  (__m128i a,__m128i b){return _mm_min_epu8(a,b);}
/* 16-bit: the striped kernel's word path */
__m128i k_adds_epi16(__m128i a,__m128i b){return _mm_adds_epi16(a,b);}
__m128i k_subs_epu16(__m128i a,__m128i b){return _mm_subs_epu16(a,b);}
__m128i k_max_epu16 (__m128i a,__m128i b){return _mm_max_epu16(a,b);}
__m128i k_max_epi16 (__m128i a,__m128i b){return _mm_max_epi16(a,b);}
/* signed saturating bytes: was 11 instructions, fixed in lvx-simde 369752db */
__m128i k_adds_epi8 (__m128i a,__m128i b){return _mm_adds_epi8(a,b);}
__m128i k_subs_epi8 (__m128i a,__m128i b){return _mm_subs_epi8(a,b);}
__m128i k_subs_epi16(__m128i a,__m128i b){return _mm_subs_epi16(a,b);}
__m128i k_adds_epu16(__m128i a,__m128i b){return _mm_adds_epu16(a,b);}
__m128i k_max_epi8  (__m128i a,__m128i b){return _mm_max_epi8(a,b);}
/* lane shifts and masks: the striped kernel's lazy-F loop */
__m128i k_slli_si128(__m128i a){return _mm_slli_si128(a,1);}
__m128i k_srli_si128(__m128i a){return _mm_srli_si128(a,1);}
__m128i k_cmpeq_epi8(__m128i a,__m128i b){return _mm_cmpeq_epi8(a,b);}
int     k_movemask  (__m128i a){return _mm_movemask_epi8(a);}
/* the one that needs an ISA change, not a SIMDe branch */
__m128i k_shuffle   (__m128i a,__m128i b){return _mm_shuffle_epi8(a,b);}
SRC

count() {
    "$G" -O2 -march=lvx-2 -I"$CSW/lvx-simde" -DSIMDE_ENABLE_NATIVE_ALIASES \
         -ffreestanding -fno-strict-aliasing ${1:+$1} -c "$W/t.c" -o "$W/t.o" 2>"$W/err" || {
        echo "build failed${1:+ ($1)}:" >&2; sed -n '1,5p' "$W/err" >&2; return 1; }
    "$OD" -d "$W/t.o" | awk '
        /^[0-9a-f]+ <k_[a-z0-9_]+>:$/ { sym=$2; gsub(/[<>:]/,"",sym); n[sym]=0; next }
        /^[[:space:]]+[0-9a-f]+:/ && sym!="" { n[sym]++ }
        END { for (s in n) print s, n[s] }' | sort
}

count ""                      > "$W/native"   || exit 1
count "-DSIMDE_LVX_NO_NATIVE" > "$W/portable" || exit 1

echo "lvx-csw: $CSW"
echo "simde:   $(git -C "$CSW/lvx-simde" describe --always --dirty 2>/dev/null || echo unknown)"
echo "gcc:     $("$G" -dumpversion 2>/dev/null) at $(git -C "$CSW/lvx-gcc/gcc" describe --always 2>/dev/null || echo unknown)"
echo
printf '%-14s %9s %9s   %s\n' INTRINSIC PORTABLE NATIVE NOTE
join "$W/portable" "$W/native" | while read -r sym p n; do
    if   [ "$n" -gt 2 ] && [ "$p" -eq "$n" ]; then note="emulated, no native path"
    elif [ "$p" -eq "$n" ];                  then note=""
    elif [ "$n" -lt "$p" ];                  then note="native branch saves $((p - n))"
    else                                          note="NATIVE WORSE -- look at this"; fi
    printf '%-14s %9s %9s   %s\n' "${sym#k_}" "$p" "$n" "$note"
done
echo
echo "PORTABLE disables every LVX branch, so it is pre-fix cost only for an"
echo "intrinsic that had no branch before the change you are judging."
