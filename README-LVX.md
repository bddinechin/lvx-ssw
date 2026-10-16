# lvx-ssw — Smith-Waterman as an LVX-2 SIMD benchmark

Two benchmarks, two algorithm shapes, one suite: **striped** (`lvx/lvx-bench.c`
over upstream `src/ssw.c`) and **inter-sequence** (`lvx/lvx-inter.c`). See
`lvx/lvx-inter.c`'s header for why both exist and what each one measures; the
short version is that striped is dominated by a data-dependent early exit and
inter-sequence has no branch in its inner loop at all, so a compiler change can
move one and not the other.

Upstream: https://github.com/mengyao/complete-striped-smith-waterman-library

**Why this one.** It is real-world (bioinformatics, widely deployed), it is
*entirely* SIMD integer, and its intrinsic surface is tiny — eighteen distinct
`_mm_*` — with a single-instruction LVX-2 equivalent for every one.  Two are
worth the trouble by themselves: `_mm_movemask_epi8` is one `compbx` here,
where NEON needs a multi-instruction reduction, and `_mm_srli_si128`/
`_mm_slli_si128` are one `srlq`/`sllq`.

**How it is ported.** Upstream already has the seam: `ssw.c`/`ssw.h` select
`sse2neon.h` under `__ARM_NEON` and `<emmintrin.h>` otherwise.  We take neither
and point the include at SIMDe's SSE2 instead, which is two `sed` lines and the
only change to upstream source:

    #include <simde/x86/sse2.h>

SIMDe over a hand-written `sse2lvx.h` deliberately.  SIMDe is already a
validated dependency here — `validation/run-simde.sh SET=x86` and its SSE2
conformance file passes 235/235 on lvx-2 — and a hand shim would hide the
compiler gap this benchmark exists to expose (see GAPS below).

## Build and run

Tracking, one TSV row per benchmark — this is the usual entry point:

    ./harness/run.sh                   # all three rows, lvx-2, -O2, under the ISS
    ./harness/intrinsic-cost.sh        # what an SSE intrinsic costs here
    ARCH=lvx-1 ./harness/run.sh        # the scalar core, for the lowering comparison
    STATIC_ONLY=1 ./harness/run.sh     # build + static metrics, seconds, no ISS
    ./harness/compare.sh results/lvx-2-O2.tsv /path/to/older.tsv
    ./harness/make-reference.sh        # regenerate the committed checksums

It writes `results/<arch>-<opt>.tsv`. Commit the results: the series is the
point, and `lvx-perf`'s `bin/lvx-perf-import` snapshots them with the toolchain
revisions that produced them.

One run, for iterating:

    ./lvx/run-lvx.sh                   # striped, lvx-2, -O2, under gem5
    BENCH=inter ./lvx/run-lvx.sh       # the inter-sequence kernel
    MARCH=lvx-1 ./lvx/run-lvx.sh       # the scalar core
    ./lvx/run-lvx.sh --native          # the x86 oracle, same source
    ./lvx/run-lvx.sh --csw /path/to/lvx-csw

`lvx-csw`'s location is a parameter, not an assumption — it holds the toolchain,
the ISS and SIMDe, none of which are in this repository. Resolution order:
`--csw`, `$LVX_CSW`, `<lvx-perf>/lvx-csw.path`, then `../lvx-csw`.

### Both benchmarks are correctness-gated, twice

Each driver self-checks before printing a single cycle count — `lvx-inter.c`
against a scalar Gotoh oracle in the same file, `lvx-bench.c` against SSW's own
three profiles — and the harness then compares the printed checksum against
`harness/reference-checksums.tsv`, which is generated from the **native x86**
builds. A reference taken from the target could only perpetuate a target
miscompile, never detect one.

That matters more here than it sounds: on this target a miscompile reads as a
large speed-up, so a row whose `correct` column is not `ok` is not a
performance result. Cycles come from `$frcc` around the kernel only; profile
construction and allocation are hoisted out.

### The headline numbers

Cycles per cell update, so both are comparable to published GCUPS figures with
the clock divided out. Measured 2026-10-16, lvx-2 `-O2`, `LVX_CPU=minor`,
lvx-gcc `127ff2d12aa`:

| | striped | inter-sequence | inter-gather |
|---|---|---|---|
| LVX-2 | 11.386 | **2.850** | see `results/` |
| native x86 (RDTSC, base clock) | ~1.14 | ~0.52 | |
| lanes timed | 8 (word path) | 16 (byte path) | 16 (byte path) |
| score fetch | query profile | database profile | `_mm_shuffle_epi8` |

They are **not a speed contest with each other** — different algorithms, and
different ceilings because the striped byte path cannot hold this query's score
in 8 bits while the inter-sequence one is sized so it can. What the pair is for
is that a compiler change can move one and not the other.

## GAPS this benchmark exposes

Two gaps are listed below and they have **different causes, needing different
fixes** — worth stating up front, because an instruction-count gap looks the
same from the outside either way:

- the instruction **exists** and SIMDe has no LVX branch reaching it. Fixable
  in SIMDe, and both such gaps found on this port are now closed
  (`_mm_movemask_epi8`, then signed saturating bytes in `lvx-simde 369752db`).
- the **ISA has no such instruction**. Not fixable in SIMDe or GCC at all; it
  needs an ISA change in `lvx-mds`. `_mm_shuffle_epi8` is this case.

`harness/intrinsic-cost.sh` distinguishes them: a gap between its PORTABLE and
NATIVE columns means a native branch exists and is earning its keep, while
equal columns above 2 mean nothing in the toolchain can reach the operation.

**Saturating packed arithmetic — FIXED for unsigned and for signed bytes.** This entry previously read "is scalarised", and that is no longer
true: re-measured 2026-10-16 against lvx-gcc `127ff2d12aa`, the striped
kernel's ~14 saturating uses now yield 14 saturating instructions
(`addusbx`=1, `sbfusbx`=7, `sbfusho`=5, `addsho`=1), and the unsigned
primitives lower 1:1 at two instructions each:

| intrinsic | instructions | |
|---|---|---|
| `_mm_adds_epu8`, `_mm_subs_epu8`, `_mm_max_epu8`, `_mm_min_epu8` | **2** | native |
| `_mm_adds_epu16`, `_mm_subs_epu16`, `_mm_max_epu16` | **2** | native |
| `_mm_adds_epi16`, `_mm_max_epi16`, `_mm_max_epi8` | **2** | native |
| **`_mm_adds_epi8`, `_mm_subs_epi8`** | **10** | SIMDe portable loop |

**Signed saturation at byte width was the remaining gap, and it is now closed.**
It was SIMDe's, not the back end's: `addsbx` and `sbfsbx` were in
`lvx-binutils`' `lvx-opc.c` all along, while `simde_mm_adds_epi8` carried
native paths for NEON (`vqaddq_s8`) and WASM and none for LVX, so it fell to a
scalar loop. Fixed in `lvx-simde 369752db` by adding the LVX branch, the same
way the `movemask` gap was closed:

| intrinsic | before | after | reaches |
|---|---|---|---|
| `_mm_adds_epi8` | 11 | **2** | `addsbx` |
| `_mm_subs_epi8` | 11 | **2** | `sbfsbx` |
| `_mm_subs_epi16` | 11 | **2** | `sbfsho` |

`lvx/lvx-inter.c` is still built on the *unsigned* formulation, and that is now
a free choice rather than a forced one — it is exact (unsigned saturation at
zero is local alignment's `max(0, ·)` clamp, so one `subs_epu8` both removes
the bias and applies the clamp) and it keeps the kernel on SSE2 only.

The lesson that outlived the fix: **the four saturating intrinsics that were
already native were exactly the four `lvx-ssw` used.** An audit has to
enumerate the surface rather than count what is already known to work.

**`_mm_shuffle_epi8` costs 22 instructions, and no compiler change can help.**
LVX has only *structured* permutes — `vector.md`'s UZP/ZIP-style lane shuffles
and `lvx_expand_vec_perm_shuffle` — and **no runtime-indexed byte gather at
all**, so there is no instruction for a SIMDe branch to reach. Both columns of
`intrinsic-cost.sh` read 22. Closing this is an **ISA change in `lvx-mds`**,
not a toolchain one.

Which is why it gets a benchmark rather than a bug report. The `inter-gather`
row is `lvx-inter.c` built with `-DISB_GATHER`: the same kernel with one line
changed, fetching each lane's score with `_mm_shuffle_epi8` instead of loading
it from the precomputed profile. Everything else is held constant — same data,
same scores, same oracle, same cell count — so the difference between the two
rows' cycles-per-cell **is** the cost of PSHUFB in a real kernel, per cell
rather than per instruction.

Both builds must produce the identical checksum, and
`harness/make-reference.sh` asserts that before writing a reference: it is the
correctness argument for the gather, not a coincidence to note.

So this is a **standing series**, and the right instrument for a gap nothing in
GCC or SIMDe can move: the day a byte-permute lands in the ISA, the two rows
converge and the series shows it. Note also that the gather has the smaller
working set — a 16-byte score row per query symbol plus one residue vector per
database position, against the profile's `DBLEN * ALPHA` vectors per block — so
on a machine where the permute is cheap it is the better algorithm, not merely
the equal one.
