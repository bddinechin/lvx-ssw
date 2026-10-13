# lvx-ssw — striped Smith-Waterman as an LVX-2 SIMD benchmark

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

    ./run-lvx.sh              # lvx-2, -O2, under gem5
    MARCH=lvx-1 ./run-lvx.sh  # the scalar core, for the lowering comparison
    ./run-lvx.sh --native     # the x86 oracle, same source

`lvx-bench.c` is self-checking: it aligns baked sequence pairs and verifies the
Smith-Waterman scores before reporting cycles, so a miscompile cannot be read
as a speed-up.  Cycles come from `$frcc` around the aligned region only.

## GAPS this benchmark exposes

**Saturating packed arithmetic is scalarised.** The kernel's ~14 uses of
`_mm_subs_epu8`/`_mm_subs_epu16`/`_mm_adds_epu8`/`_mm_adds_epi16` yield almost
no `sbfus*`/`addus*`/`adds*`.  The port is not at fault: `vector.md` defines
`ssadd`/`usadd`/`ussub`/`sssub` over `V128J` on the `ss_plus`/`us_minus` RTL
codes, and the ISA has the instructions.  SIMDe's portable path is a scalar
loop over `simde_math_subs_u8`, so reaching them needs GCC to *recognise* the
saturation idiom (`.SAT_ADD`/`.SAT_SUB`) and route it to the optab.  The
saturating-instruction count in the object is the metric for that work.
