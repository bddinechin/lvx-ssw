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

    ./harness/run.sh                   # both benchmarks, lvx-2, -O2, under the ISS
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

| | striped | inter-sequence |
|---|---|---|
| LVX-2 | 11.386 | **2.850** |
| native x86 (RDTSC, base clock) | ~1.14 | ~0.52 |
| lanes timed | 8 (word path) | 16 (byte path) |

They are **not a speed contest with each other** — different algorithms, and
different ceilings because the striped byte path cannot hold this query's score
in 8 bits while the inter-sequence one is sized so it can. What the pair is for
is that a compiler change can move one and not the other.

## GAPS this benchmark exposes

**Saturating packed arithmetic — FIXED for unsigned, still open for signed
bytes.** This entry previously read "is scalarised", and that is no longer
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

So the remaining gap is specifically **signed saturation at byte width**, and
it is SIMDe's rather than the back end's: `addsbx` and `sbfsbx` both exist in
`lvx-binutils`' `lvx-opc.c`, and SIMDe's `simde_mm_adds_epi8` carries native
paths for NEON (`vqaddq_s8`) and WASM but none for LVX, so it falls to a scalar
loop. The signed *16-bit* equivalent is 2 instructions, which is what localises
the problem to the byte-width case. Same shape as the `_mm_movemask_epi8` gap
that was closed by wiring a native path, and fixable the same way.

`lvx/lvx-inter.c` is built on the unsigned formulation for exactly this reason
— using the signed one would make its headline figure a measurement of a
missing SIMDe path rather than of the ISA.

**`_mm_shuffle_epi8` costs 22 instructions.** Measured the same day. LVX has
only *structured* permutes — `vector.md`'s UZP/ZIP-style lane shuffles and
`lvx_expand_vec_perm_shuffle` — not a runtime-indexed byte gather, so PSHUFB
goes through SIMDe's portable path.

This is why `lvx-inter.c` uses a **database score profile** rather than
SWIMM2.0's PSHUFB score gather: a kernel built on a 22-instruction intrinsic
measures emulation. The profile layout is not a workaround invented here, it is
SWIMM's own `-p S` mode as against `-p Q`. Worth revisiting if a byte-permute
is ever added to the ISA, since the gather formulation needs no precomputed
profile and so has a much smaller working set.
