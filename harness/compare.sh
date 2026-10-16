#!/usr/bin/env bash
# Compare two SSW harness runs, per benchmark.
#
#   ./harness/compare.sh results/lvx-2-O2.tsv /path/to/older/lvx-2-O2.tsv
#
# Reports every metric that moved by more than THRESH (default 2%) and every
# change in the correctness column.  Per benchmark, deliberately: `striped' and
# `inter' are different algorithms and an aggregate over them would be
# meaningless rather than merely coarse.
#
# A correctness change is reported first and loudly, because a cycle count from
# a run whose checksum moved is not a performance result.  A benchmark that
# "got 40% faster" and stopped matching its reference checksum did not get
# faster -- on this target a miscompile is exactly what that looks like.
#
# Unlike lvx-polybench's compare.sh there is no fp-N tolerance class here:
# these kernels are integer, their scores are exact, and a checksum either
# matches or does not.
set -u
THRESH=${THRESH:-2}
[ $# -eq 2 ] || { sed -n '2,18p' "$0"; exit 2; }

awk -v thresh="$THRESH" -v oldf="$1" -v newf="$2" '
function pct(o, n) { return (o == 0 || o == "") ? 0 : (n - o) * 100.0 / o }
BEGIN {
    FS = "\t"
    while ((getline line < oldf) > 0) {
        split(line, f, FS); if (f[1] == "bench" || f[1] == "") continue
        oc[f[1]]=f[4]; ocy[f[1]]=f[5]; ocpc[f[1]]=f[7]; ok_[f[1]]=f[9]
        otx[f[1]]=f[10]; oin[f[1]]=f[11]; obd[f[1]]=f[12]; osd[f[1]]=f[13]
    }
    nb = 0
    while ((getline line < newf) > 0) {
        split(line, f, FS); if (f[1] == "bench" || f[1] == "") continue
        order[++nb]=f[1]
        nc[f[1]]=f[4]; ncy[f[1]]=f[5]; ncpc[f[1]]=f[7]; nk[f[1]]=f[9]
        ntx[f[1]]=f[10]; nin[f[1]]=f[11]; nbd[f[1]]=f[12]; nsd[f[1]]=f[13]
    }

    print "CORRECTNESS:"
    any = 0
    for (i = 1; i <= nb; i++) {
        b = order[i]
        if (!(b in oc)) { printf "  %-10s NEW (%s)\n", b, nc[b]; any=1; continue }
        if (oc[b] != nc[b]) { printf "  %-10s %s -> %s\n", b, oc[b], nc[b]; any=1 }
        else if (ok_[b] != nk[b])
            printf "  %-10s checksum %s -> %s  (verdict still %s -- the reference moved with it?)\n", \
                   b, ok_[b], nk[b], nc[b], any=1
    }
    if (!any) print "  (no change)"

    printf "\nMETRICS (only moves beyond %s%%):\n", thresh
    moved = 0
    for (i = 1; i <= nb; i++) {
        b = order[i]
        if (!(b in oc)) continue
        line = ""
        d = pct(ocy[b],  ncy[b]);  if (d >  thresh || d < -thresh) line = line sprintf("  cycles %+.1f%%", d)
        d = pct(otx[b],  ntx[b]);  if (d >  thresh || d < -thresh) line = line sprintf("  text %+.1f%%", d)
        d = pct(oin[b],  nin[b]);  if (d >  thresh || d < -thresh) line = line sprintf("  insns %+.1f%%", d)
        d = pct(obd[b],  nbd[b]);  if (d >  thresh || d < -thresh) line = line sprintf("  bundles %+.1f%%", d)
        d = pct(osd[b],  nsd[b]);  if (d >  thresh || d < -thresh) line = line sprintf("  simd %+.1f%%", d)
        if (line != "") { printf "  %-10s%s\n", b, line; moved = 1 }
    }
    if (!moved) print "  (nothing moved beyond the threshold)"

    printf "\nCYCLES PER CELL (the headline, lower is better):\n"
    for (i = 1; i <= nb; i++) {
        b = order[i]
        printf "  %-10s %8s -> %-8s %s\n", b, (b in oc) ? ocpc[b] : "-", ncpc[b], \
               (nc[b] == "ok") ? "" : "  (" nc[b] " -- NOT a performance result)"
    }
}'
