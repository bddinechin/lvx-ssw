// Part of the LVX project, under the Apache License v2.0 with LLVM Exceptions.
// See LICENSE.TXT in the root of this repository for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

/* INTER-SEQUENCE Smith-Waterman on LVX-2: the complement to lvx-bench.c.
 *
 * WHY A SECOND SMITH-WATERMAN.  lvx-bench.c is Farrar striped: sixteen lanes
 * hold sixteen STRIDED POSITIONS OF ONE QUERY, which breaks the F recurrence
 * across lanes and so needs the lazy-F fix-up loop with its data-dependent
 * early exit (src/ssw.c, the `goto end' on movemask == 0xffff).  Profiling in
 * lvx-csw's docs/ssw-profile.md measured that loop at 43.4% of the run, taking
 * MORE iterations per column than the striped loop itself (67.21 against
 * 63.00), and concluded the lever is the LOOP-EXIT DEPENDENCY CHAIN at ~10
 * cycles per step rather than instruction count at ~1.3 cycles per bundle.
 *
 * This file is the other family -- Rognes/SWIPE inter-sequence, as used by
 * SWIMM2.0 -- where each lane holds a DIFFERENT DATABASE SEQUENCE.  Every lane
 * is then an independent alignment, there is no cross-lane dependency to
 * repair, and the lazy-F loop does not exist.  The inner loop is straight-line
 * saturating arithmetic with NO data-dependent control flow at all.
 *
 * So the pair instruments two different things on the same ISA: lvx-bench.c
 * measures unpredictable early exits and cross-lane shifts, this measures
 * SIMD throughput and the saturating-arithmetic path.  A compiler change can
 * move one and not the other, which is the point -- PolyBench showed on
 * 2026-10-16 that a breadth gate can be entirely blind to a change (240
 * kernel-measurements, codegen-identical across the vector-comparison work),
 * so coverage of DIFFERENT SHAPES matters more than more kernels of one shape.
 *
 * THE METRIC IS CYCLES PER CELL UPDATE, as in lvx-bench.c, so the two numbers
 * are directly comparable and both compare to published GCUPS figures with the
 * clock divided out.  Sixteen lanes of 8-bit means 16 cells/cycle is the
 * ceiling here -- and unlike the striped byte path this benchmark stays ON the
 * byte path by construction (see OVERFLOW below), so the ceiling is real.
 *
 * TWO DELIBERATE DEPARTURES FROM SWIMM, both measured rather than assumed:
 *
 *   1. NO _mm_shuffle_epi8.  SWIMM gathers each lane's substitution score with
 *      PSHUFB over a 16-byte score row.  Measured on this toolchain
 *      (2026-10-16, lvx-gcc 127ff2d12aa) _mm_shuffle_epi8 lowers to 22
 *      instructions -- SIMDe's portable path, since LVX has only structured
 *      permutes (vector.md's UZP/ZIP-style shuffles and
 *      lvx_expand_vec_perm_shuffle), not a runtime-indexed byte gather.  A
 *      kernel built on it would measure emulation, not the ISA.  So this uses
 *      the DATABASE SCORE PROFILE instead: dbprof[j][sym] is precomputed, and
 *      the inner loop does a plain aligned load indexed by the query residue.
 *      That is not a workaround invented here -- it is SWIMM's own `-p S'
 *      Score Profile mode, as against `-p Q' Query Profile.
 *
 *   2. UNSIGNED saturating bytes, not signed.  Measured the same day:
 *      _mm_adds_epu8 / _mm_subs_epu8 / _mm_max_epu8 are 2 instructions each
 *      and native, while _mm_adds_epi8 / _mm_subs_epi8 are 10 -- although
 *      addsbx and sbfsbx both exist in lvx-binutils' lvx-opc.c.  The gap is
 *      SIMDe's: it has NEON and WASM native paths for signed saturating bytes
 *      and no LVX one, so it falls to a scalar loop.  Same shape as the
 *      _mm_movemask_epi8 gap that was already closed, and the 16-bit signed
 *      equivalents (_mm_adds_epi16) are 2 instructions, so this is specifically
 *      signed-at-byte-width.  Recorded in GAPS.md; using the unsigned
 *      formulation here keeps the headline figure a measurement of the ISA
 *      rather than of a known-missing SIMDe path.
 *
 * The unsigned formulation is standard and exact, not an approximation: scores
 * are stored biased by BIAS so every profile byte is non-negative, and
 * subs_epu8 then does double duty as "remove the bias" and as local
 * alignment's max(0, .) clamp, because unsigned saturation at zero IS that
 * clamp.  See the inner loop.
 *
 * OVERFLOW IS DESIGNED OUT, THEN CHECKED.  The byte path saturates at 255 and
 * lvx-bench.c runs into exactly that -- its 500-base query scores past 255, so
 * SSW refuses the byte profile and the word path is what gets timed (8
 * cells/cycle, not 16).  Here the DATABASE sequences are 64 bases, so an
 * optimal local score cannot exceed 2*64 = 128 whatever the query length, with
 * gaps only ever reducing it.  That keeps all sixteen lanes live and the
 * ceiling at 16.  It is still asserted at the end rather than trusted.
 *
 * SELF-CHECKING FIRST, with a scalar oracle.  Every sequence's score is also
 * computed by a plain scalar Gotoh recurrence in this file and must agree.
 * That is a stronger gate than lvx-bench.c's three-profile agreement -- it
 * compares against a different ALGORITHM rather than another vector width --
 * and it is what catches the failure mode this port actually has: a
 * mis-lowered saturating operation is invisible until a lane's score is wrong.
 * A miscompile reading as a speed-up is the specific thing being guarded
 * against; see lvx-csw's docs/libgcc-stale-after-isa-change.md for the time it
 * happened for real.
 */
#include <stdint.h>
#include "data.h"
#include "lvx-io.h"

#if defined(__lvx__)
#include <simde/x86/sse2.h>
#else
#include <emmintrin.h>
#endif

/* ---- shape ----------------------------------------------------------------
 * LANES is the ISA's: sixteen 8-bit lanes in a 128-bit V128.  DBLEN is chosen
 * to keep the byte path valid (see OVERFLOW above).  NSEQ must be a multiple
 * of LANES -- a partial block would need lane masking, which would put a
 * select in the inner loop and measure something else.
 */
#define LANES    16
#define ALPHA     5            /* A C G T N, so a profile row is 5 vectors */
#define DBLEN    64
#define NSEQ     64
#define NBLOCK   (NSEQ / LANES)
#define BIAS      2            /* |most negative substitution score| */
#define GAP_O     3            /* same penalties lvx-bench.c passes ssw_align */
#define GAP_E     1

static int8_t nt_table[128];
static int8_t score_mat[ALPHA * ALPHA];

static void tables_init (void)
{
	for (int i = 0; i < 128; i++)
		nt_table[i] = 4;
	nt_table['A'] = nt_table['a'] = 0;
	nt_table['C'] = nt_table['c'] = 1;
	nt_table['G'] = nt_table['g'] = 2;
	nt_table['T'] = nt_table['t'] = 3;

	/* +2 match, -2 mismatch, N neutral -- upstream's own example weights,
	   and the same ones lvx-bench.c uses, so the two benchmarks score the
	   same alignments the same way. */
	int k = 0;
	for (int i = 0; i < 4; i++) {
		for (int j = 0; j < 4; j++)
			score_mat[k++] = (i == j) ? 2 : -2;
		score_mat[k++] = 0;
	}
	for (int j = 0; j < ALPHA; j++)
		score_mat[k++] = 0;
}

/* The database: NSEQ windows of the baked reference, taken at a fixed stride.
 * Derived from data.h rather than baked separately, so there is one place the
 * input provenance lives (mkdata.py names its upstream FASTA files).
 *
 * Equal lengths deliberately.  Inter-sequence throughput degrades with LENGTH
 * VARIANCE, because every lane in a block must step together and a block costs
 * its longest member -- which is why SWIMM sorts its database by length before
 * searching.  Equal-length blocks therefore measure the achievable ceiling,
 * the case the real implementations engineer toward.  A variance tier is the
 * obvious next one to add, and it belongs as a separate series rather than
 * folded in, for the same reason RESTRICT is separate in lvx-polybench: it
 * changes what is being measured.
 */
static int8_t db[NSEQ][DBLEN];
static int8_t qnum[SSW_MAX_QLEN];
static int qlen;

static void encode_all (void)
{
	const int stride = (SSW_REF_LEN - DBLEN) / (NSEQ - 1);
	for (int s = 0; s < NSEQ; s++)
		for (int j = 0; j < DBLEN; j++)
			db[s][j] = nt_table[(unsigned char) ssw_ref[s * stride + j]];

	qlen = ssw_query_len[0];
	for (int i = 0; i < qlen; i++)
		qnum[i] = nt_table[(unsigned char) ssw_query[0][i]];
}

/* ---- the kernel -----------------------------------------------------------
 * One block of LANES sequences against the query.  Returns nothing; per-lane
 * best scores are written to out[].
 *
 * dbprof is the database score profile for this block: dbprof[j * ALPHA + sym]
 * holds, for database position j, the substitution score of query symbol `sym'
 * against each lane's residue at j, biased by BIAS so it is non-negative.
 * Built by the caller, outside the timed region -- it is O(DBLEN * ALPHA) and
 * a real database search builds it once and runs many queries through it, the
 * same reason lvx-bench.c hoists ssw_init.
 */
/* All NBLOCK profiles are resident at once -- 20 KB total -- so the timed
 * loop never builds one.  A single shared buffer would have forced a rebuild
 * between blocks inside the measurement, which is exactly the O(n) cost that
 * has no business in an O(q*n) figure. */
static __m128i dbprof[NBLOCK][DBLEN * ALPHA] __attribute__((aligned (16)));
static __m128i Hrow[DBLEN]                   __attribute__((aligned (16)));
static __m128i Erow[DBLEN]                   __attribute__((aligned (16)));

static void build_profile (int block)
{
	for (int j = 0; j < DBLEN; j++) {
		for (int sym = 0; sym < ALPHA; sym++) {
			int8_t v[LANES];
			for (int L = 0; L < LANES; L++) {
				int r = db[block * LANES + L][j];
				v[L] = (int8_t) (score_mat[sym * ALPHA + r] + BIAS);
			}
			__builtin_memcpy (&dbprof[block][j * ALPHA + sym], v, LANES);
		}
	}
}

static void kernel_block (int block, unsigned char out[LANES])
{
	const __m128i zero  = _mm_setzero_si128 ();
	const __m128i vBias = _mm_set1_epi8 (BIAS);
	const __m128i vGapO = _mm_set1_epi8 (GAP_O);
	const __m128i vGapE = _mm_set1_epi8 (GAP_E);
	__m128i vMax = zero;

	for (int j = 0; j < DBLEN; j++) { Hrow[j] = zero; Erow[j] = zero; }

	/* Gotoh local alignment, per lane, independently:
	 *   H(i,j) = max(0, H(i-1,j-1) + s, E(i,j), F(i,j))
	 *   E(i,j) = max(H(i-1,j) - GAP_O, E(i-1,j) - GAP_E)   gap along the db
	 *   F(i,j) = max(H(i,j-1) - GAP_O, F(i,j-1) - GAP_E)   gap along the query
	 *
	 * E comes from the previous query row, so it lives in Erow[].  F is
	 * carried along the inner loop in a register -- and THAT is the whole
	 * difference from the striped kernel: because lanes are independent
	 * sequences rather than strided positions of one, F needs no fix-up
	 * pass, and the loop below has no branch in it.
	 */
	for (int i = 0; i < qlen; i++) {
		const __m128i *prow = &dbprof[block][qnum[i]];
		__m128i diag = zero;             /* H(i-1,-1) */
		__m128i vF   = zero;             /* F(i,-1) */

		for (int j = 0; j < DBLEN; j++) {
			__m128i vP = _mm_load_si128 (&prow[j * ALPHA]);
			__m128i hd = Hrow[j];        /* H(i-1,j), also next diag */
			__m128i ep = Erow[j];        /* E(i-1,j) */

			/* max(0, diag + s): the bias makes vP non-negative so
			   adds_epu8 is safe, and subs_epu8 removes the bias and
			   clamps at zero in one operation -- unsigned saturation
			   at zero IS local alignment's max(0, .). */
			__m128i vH = _mm_subs_epu8 (_mm_adds_epu8 (diag, vP), vBias);

			__m128i vE = _mm_max_epu8 (_mm_subs_epu8 (hd, vGapO),
						   _mm_subs_epu8 (ep, vGapE));
			vH   = _mm_max_epu8 (vH, vE);
			vH   = _mm_max_epu8 (vH, vF);
			vMax = _mm_max_epu8 (vMax, vH);

			Hrow[j] = vH;
			Erow[j] = vE;
			diag    = hd;
			vF      = _mm_max_epu8 (_mm_subs_epu8 (vH, vGapO),
						_mm_subs_epu8 (vF, vGapE));
		}
	}
	_mm_store_si128 ((__m128i *) out, vMax);
}

/* ---- the oracle -----------------------------------------------------------
 * The same recurrence, scalar, one sequence at a time.  A different algorithm
 * shape from the vector kernel on purpose: it shares no intrinsic with it, so
 * a mis-lowered saturating operation cannot agree with it by construction.
 */
static int scalar_score (const int8_t *seq)
{
	int H[DBLEN + 1], E[DBLEN + 1];
	int best = 0;
	for (int j = 0; j <= DBLEN; j++) { H[j] = 0; E[j] = 0; }

	for (int i = 0; i < qlen; i++) {
		int diag = 0, F = 0;
		for (int j = 0; j < DBLEN; j++) {
			int hd = H[j], ep = E[j];
			int h = diag + score_mat[qnum[i] * ALPHA + seq[j]];
			if (h < 0) h = 0;
			int e = hd - GAP_O; if (ep - GAP_E > e) e = ep - GAP_E;
			if (e < 0) e = 0;
			if (e > h) h = e;
			if (F > h) h = F;
			if (h > best) best = h;
			H[j] = h; E[j] = e; diag = hd;
			/* F(i,j+1) = max(H(i,j) - GAP_O, F(i,j) - GAP_E) */
			int fo = h - GAP_O, fe = F - GAP_E;
			F = fo > fe ? fo : fe;
			if (F < 0) F = 0;
		}
	}
	return best;
}

int main (void)
{
	tables_init ();
	encode_all ();

	unsigned char got[NBLOCK][LANES] __attribute__((aligned (16)));

	/* ---- correctness, before any cycle count prints ---- */
	for (int b = 0; b < NBLOCK; b++) {
		build_profile (b);
		kernel_block (b, got[b]);
	}
	long long checksum = 0;
	for (int s = 0; s < NSEQ; s++) {
		int want = scalar_score (db[s]);
		int have = got[s / LANES][s % LANES];
		if (want != have) {
			putnum ("MISMATCH seq ", s);
			putnum ("  vector ", have);
			putnum ("  scalar ", want);
			puts_ ("FAIL: vector kernel disagrees with the scalar oracle\n");
			return 1;
		}
		if (have >= 255) {
			putnum ("OVERFLOW seq ", s);
			puts_ ("FAIL: byte path saturated -- DBLEN too large for 8-bit\n");
			return 1;
		}
		/* Reduced mod a prime: with NSEQ sequences a plain 131-power
		   mix overflows long long, and signed overflow is undefined, so
		   the value would be neither portable nor reproducible.  This
		   stays positive and comparable across hosts, which matters
		   because it is what the TSV harness gates `correct' on. */
		checksum = (checksum * 131 + have) % 1000000007;
	}
	putnum ("checksum ", checksum);

	/* ---- timed: the kernel only.  Every profile was built above and all
	   NBLOCK stay resident, so nothing O(n) is inside the clock. ---- */
	long long acc = 0;
	unsigned long long t0 = cyc ();
	for (int b = 0; b < NBLOCK; b++)
		kernel_block (b, got[b]);
	unsigned long long t1 = cyc ();

	for (int b = 0; b < NBLOCK; b++)
		for (int L = 0; L < LANES; L++)
			acc += got[b][L];

	long long cells = (long long) qlen * DBLEN * NSEQ;
	unsigned long long cycles = t1 - t0;
	putnum ("sequences ", NSEQ);
	putnum ("db_len ", DBLEN);
	putnum ("query_len ", qlen);
	putnum ("lanes ", LANES);
	putnum ("acc ", acc);
	putnum ("cells ", cells);
	putnum ("cycles ", (long long) cycles);
	putfix ("cycles_per_cell ", cycles * 1000ull / (unsigned long long) cells);
	putfix ("cells_per_cycle ", (unsigned long long) cells * 1000ull / cycles);
	puts_ ("ok\n");
	return 0;
}
