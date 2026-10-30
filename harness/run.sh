#!/usr/bin/env bash
# SSW on LVX: SIMD performance tracking, with a correctness gate.
#
#   ./harness/run.sh                      # both benches, lvx-2, -O2, under the ISS
#   ARCH=lvx-1 ./harness/run.sh
#   OPT=O3 ./harness/run.sh
#   BENCH=inter ./harness/run.sh          # just one of them
#   BENCH='inter inter-gather' ./harness/run.sh
#   STATIC_ONLY=1 ./harness/run.sh        # build + static metrics, no ISS
#   COMPILER=clang ./harness/run.sh       # lvx-llvm instead of lvx-gcc
#   ./harness/run.sh --csw /path/to/lvx-csw
#   ./harness/compare.sh results/A.tsv results/B.tsv
#
# Writes one TSV row per benchmark to results/<arch>-<opt>.tsv and a human
# summary to stdout.  Commit the results: the series is the point.
#
# COMPILER=clang writes results/<arch>-clang-<opt>.tsv instead: the compiler is
# part of the configuration name, because a GCC row and a clang row of one
# benchmark are two series, not two samples of one.  GCC stays unmarked so the
# series that predates clang keeps its name.
#
# TWO BENCHMARKS, ONE SUITE.  `striped' and `inter' are both Smith-Waterman and
# deliberately NOT comparable to each other as a speed contest -- they are
# different algorithms with different ceilings (striped lands on the word path
# for this query, 8 lanes; inter stays on the byte path, 16).  They are tracked
# as separate ROWS of one series because what matters is each one's movement
# over time, and because a compiler change can move one and not the other.
# See the header of lvx/lvx-inter.c for why both exist.
#
# THE MEASUREMENT LIVES IN lvx/run-lvx.sh, not here.  That script resolves
# lvx-csw, builds, and runs; this one loops over configurations, gates
# correctness and formats.  Keeping the toolchain knowledge in one place is why
# this harness is short.
#
# CORRECTNESS IS GATED TWICE, and neither gate is optional.  Each driver
# self-checks first -- lvx-inter.c against a scalar oracle, lvx-bench.c against
# SSW's own three profiles -- and refuses to print a cycle count if that fails.
# Then this harness compares the printed checksum against the committed value
# in harness/reference-checksums.tsv, which is what catches a change in WHAT is
# computed rather than in whether it is self-consistent.  A row whose `correct'
# column is not `ok' is not a performance result: on this target a miscompile
# reads as a large speed-up, so an ungated number is worse than no number.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(dirname "$here")"

ARCH=${ARCH:-lvx-2}
OPT=${OPT:-O2}
STATIC_ONLY=${STATIC_ONLY:-0}
BENCHES=${BENCH:-"striped inter inter-gather"}
COMPILER=${COMPILER:-gcc}
case "$COMPILER" in
    gcc)   ctag="" ;;
    clang) ctag="-clang" ;;
    *) echo "COMPILER must be gcc or clang (got $COMPILER)" >&2; exit 2 ;;
esac

# --csw is not interpreted here; it is passed straight through to run-lvx.sh,
# which owns the resolution chain.
csw_args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --csw)   csw_args+=(--csw "${2:?--csw needs a path}"); shift 2 ;;
        --csw=*) csw_args+=("$1"); shift ;;
        *)       echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

case "$ARCH" in lvx-1|lvx-2) ;; *) echo "ARCH must be lvx-1 or lvx-2 (got $ARCH)" >&2; exit 2 ;; esac

outdir="$repo/results"; mkdir -p "$outdir"
tsv="$outdir/$ARCH$ctag-$OPT.tsv"
refs="$here/reference-checksums.tsv"
work=$(mktemp -d); trap 'rm -rf "$work"' 0 1 2 3 15

# lvx-perf's bin/lvx-rev-stamp owns the provenance columns, and is called
# rather than copied -- this suite is MIT, lvx-perf is Apache-2.0 WITH
# LLVM-exception, and executing a script is not deriving from it. A standalone
# checkout with no superproject records `unknown' rather than failing.
#
# Per row, not per sweep: the hazard is a toolchain reinstalled in place while
# a sweep is running, which a once-per-sweep stamp cannot show.
super=$(git -C "$repo" rev-parse --show-superproject-working-tree 2>/dev/null) || super=
STAMP=
[ -n "$super" ] && [ -x "$super/bin/lvx-rev-stamp" ] && STAMP="$super/bin/lvx-rev-stamp"

# Say up front whether these numbers will be attributable. A sweep here is
# minutes to hours, and learning afterwards that every row stamped `-dirty'
# wastes all of it -- which happened three times in two days before this
# check existed. It WARNS and continues: measuring against your own dirty
# backend to see whether a change helped is the normal development loop, and
# bin/lvx-perf-import is the thing that refuses to record it as a series.
if [ -n "$STAMP" ]; then
    _cswarg=()
    [ -n "${CSW:-}" ] && _cswarg=(--csw "$CSW")
    if ! _q=$("$STAMP" --check ${_cswarg[@]+"${_cswarg[@]}"} 2>&1); then
        {
            echo "warning: not provenance-clean -- these rows will not be importable"
            printf '%s\n' "$_q"
        } >&2
    fi
fi
stamp_cols=(csw_rev gcc_rev gem5_rev cc_mtime)
stamp_header() {
    if [ -n "$STAMP" ]; then "$STAMP" --tsv-header
    else (IFS=$'\t'; printf '%s\n' "${stamp_cols[*]}"); fi
}
stamp_row() {
    if [ -n "$STAMP" ]; then "$STAMP" --tsv-row ${CSW:+--csw "$CSW"}
    else
        local u=() c
        for c in "${stamp_cols[@]}"; do u+=(unknown); done
        (IFS=$'\t'; printf '%s\n' "${u[*]}")
    fi
}

# cpu_model is APPENDED, not inserted: harness/compare.sh and lvx-perf's tools
# read earlier columns by position, and inserting would silently shift them.
HEADER='bench\tarch\topt\tcorrect\tcycles\tcells\tcycles_per_cell\tcells_per_cycle\tchecksum\ttext_bytes\tinsns_static\tbundles_static\tsimd_insns\tcpu_model'
HEADER="$HEADER\t$(stamp_header | sed 's/\t/\\t/g')"
# The field count the merge below pads carried-over rows up to.
want_fields=$(printf "$HEADER\n" | awk -F'\t' '{print NF}')

# Rows are collected and merged into $tsv at the end rather than written
# straight to it.  A BENCH=inter re-run would otherwise open the same path --
# it depends only on arch and opt -- and truncate the other benchmark's row.
# That exact mistake cost lvx-mibench a 13-row baseline on 2026-10-09.
rows="$work/rows.tsv"; : > "$rows"
printf '%-10s %-12s %12s %14s %16s %10s %8s\n' \
       BENCH CORRECT CYCLES CELLS CYCLES/CELL TEXT SIMD

field() { sed -n "s/^$2 \(.*\)$/\1/p" "$1" | tail -1; }

rc=0
for bench in $BENCHES; do
    case "$bench" in striped|inter|inter-gather) ;; *) echo "unknown BENCH '$bench'" >&2; exit 2 ;; esac
    log="$work/$bench.log"
    if BENCH="$bench" MARCH="$ARCH" OPT="$OPT" STATIC_ONLY="$STATIC_ONLY" COMPILER="$COMPILER" \
       "$repo/lvx/run-lvx.sh" "${csw_args[@]+"${csw_args[@]}"}" > "$log" 2>&1
    then run_ok=1; else run_ok=0; fi

    cycles=$(field "$log" cycles)
    cells=$(field "$log" cells)
    cpc=$(field "$log" cycles_per_cell)
    cyc_per=$(field "$log" cells_per_cycle)
    cks=$(field "$log" checksum)
    text=$(field "$log" text_bytes)
    insns=$(field "$log" insns_static)
    bund=$(field "$log" bundles_static)
    simd=$(field "$log" simd_insns)
    cpu=$(field "$log" cpu_model)

    # The driver's own verdict comes first: it refuses to print cycles when its
    # self-check fails, so a missing checksum with a FAIL line is that, not a
    # parse problem.
    if grep -q '^MISMATCH' "$log"; then correct=MISMATCH
    elif grep -q '^OVERFLOW' "$log"; then correct=OVERFLOW
    elif grep -qE '^(FAIL|COMPILE FAIL|LINK FAIL)' "$log"; then correct=BUILD_OR_SELFCHECK
    elif [ "$run_ok" != 1 ]; then correct=RUN_FAIL
    elif [ "$STATIC_ONLY" = 1 ]; then correct=static
    elif [ -z "$cks" ]; then correct=NO_CHECKSUM
    else
        want=$(awk -F'\t' -v b="$bench" '$1==b{print $2}' "$refs" 2>/dev/null)
        if   [ -z "$want" ];        then correct=noref
        elif [ "$want" = "$cks" ];  then correct=ok
        else correct=CHECKSUM; fi
    fi
    case "$correct" in ok|static|noref) ;; *) rc=1 ;; esac

    printf '%-10s %-12s %12s %14s %16s %10s %8s\n' \
           "$bench" "$correct" "${cycles:--}" "${cells:--}" "${cpc:--}" "${text:--}" "${simd:--}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
           "$bench" "$ARCH" "$OPT" "$correct" "${cycles:-}" "${cells:-}" \
           "${cpc:-}" "${cyc_per:-}" "${cks:-}" "${text:-}" "${insns:-}" \
           "${bund:-}" "${simd:-}" "${cpu:-}" "$(stamp_row)" >> "$rows"
    # Dump the log only for an actual problem. `static' and `noref' are
    # ordinary states -- a build-only run, and a benchmark with no committed
    # reference checksum yet -- and echoing the whole log for them buries the
    # one case worth reading.
    case "$correct" in
        ok|static|noref) ;;
        *) echo "  --- $bench: $correct ---"; sed -n '1,14p' "$log" | sed 's/^/  | /' ;;
    esac
done

# Merge: replace the rows this run produced, keep every other row.
merged="$work/merged.tsv"
printf "$HEADER\n" > "$merged"
if [ -f "$tsv" ]; then
    awk -F'\t' -v OFS='\t' -v ab="$(echo $BENCHES | tr ' ' '|')" \
        -v want="$want_fields" '
        NR==1 && $1=="bench" {next}
        { split(ab, k, "|"); for (i in k) if ($1 == k[i]) next
          # A row written before the provenance columns existed is shorter
          # than the header. Pad it, so re-running one benchmark cannot leave
          # the file ragged -- an empty stamp reads as "not recorded", which
          # bin/lvx-stamp-check treats as unverifiable rather than as a
          # disagreement.
          for (i = NF + 1; i <= want; i++) $i = ""
          print }
    ' "$tsv" >> "$merged"
fi
cat "$rows" >> "$merged"
# Stable order: striped, inter, inter-gather, whatever order they were run in,
# so a diff of two TSVs is a diff of numbers rather than of row order.
{ head -1 "$merged"; tail -n +2 "$merged" \
    | awk -F'\t' '{o=($1=="striped")?0:($1=="inter")?1:2; print o"\t"$0}' \
    | sort -k1,1n | cut -f2-; } > "$tsv"

echo
echo "wrote $tsv"
[ "$rc" = 0 ] || echo "NOT ALL ROWS ARE PERFORMANCE RESULTS -- see the correct column" >&2
exit $rc
