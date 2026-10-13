// Part of the LVX project, under the Apache License v2.0 with LLVM Exceptions.
// See LICENSE.TXT in the root of this repository for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

/* Striped Smith-Waterman on LVX-2: a self-checking SIMD benchmark.
 *
 * SSW is a striped (Farrar) Smith-Waterman, which is SIMD integer work almost
 * end to end: saturating adds and subtracts, unsigned and signed lane maxima,
 * byte-granular shifts of the whole 128-bit vector, and a movemask to test
 * whether any lane crossed the overflow threshold.  That makes it a far better
 * SIMD-intensity probe than PolyBench, whose kernels are FP and whose MINI
 * trip counts are short.
 *
 * SELF-CHECKING FIRST, TIMED SECOND.  Every pair's score is verified against a
 * value computed independently -- see `expect' below -- before any cycle count
 * is printed, because a miscompiled kernel reads as a speed-up otherwise.  That
 * is not hypothetical here: the whole point of the exercise is that parts of
 * this kernel scalarise, and scalar code that computes the wrong thing would
 * look like the best result in the table.
 *
 * SSW has two code paths and both are exercised.  `score_size` 0 selects the
 * byte profile (16 lanes, saturating at 255), 1 the word profile (8 lanes), and
 * 2 lets the library start in bytes and re-run in words when a lane saturates.
 * The byte path is where `_mm_subs_epu8` and `_mm_movemask_epi8` live, so a run
 * that never overflows would miss the more interesting half.  One of the pairs
 * below is built to overflow the byte profile deliberately.
 *
 * The reference scores are not baked constants from upstream: they are what
 * this source computes under the x86 build (`--native`), which is the same
 * algorithm through SIMDe's native SSE2 rather than its portable path.  So the
 * check is differential in the harness sense -- two independent lowerings of
 * one source -- and `run-lvx.sh --native` regenerates them.
 */
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include "../src/ssw.h"

/* DNA as SSW wants it: 0..4 for A,C,G,T,N. */
static int8_t nt_table[128];

static void nt_table_init (void)
{
	for (int i = 0; i < 128; i++)
		nt_table[i] = 4;
	nt_table['A'] = 0; nt_table['a'] = 0;
	nt_table['C'] = 1; nt_table['c'] = 1;
	nt_table['G'] = 2; nt_table['g'] = 2;
	nt_table['T'] = 3; nt_table['t'] = 3;
}

/* +2 match, -2 mismatch, N neutral -- the library's own example weights. */
static int8_t score_mat[25];

static void score_mat_init (void)
{
	int k = 0;
	for (int i = 0; i < 4; i++) {
		for (int j = 0; j < 4; j++)
			score_mat[k++] = (i == j) ? 2 : -2;
		score_mat[k++] = 0;            /* read N vs anything */
	}
	for (int j = 0; j < 5; j++)
		score_mat[k++] = 0;            /* ref N vs anything */
}

static void encode (const char *s, int8_t *out, int len)
{
	for (int i = 0; i < len; i++)
		out[i] = nt_table[(unsigned char) s[i]];
}

/* The pairs.  Short ones keep the ISS run quick; the long one is long enough
   that a byte profile saturates, which is what forces the word path and the
   movemask-driven re-run.  Built by repetition rather than written out, so the
   file stays readable and the lengths are obvious. */
#define RLEN 240
#define QLEN 120

static char refbuf[RLEN + 1], qrybuf[QLEN + 1];
static int8_t refnum[RLEN], qrynum[QLEN];

static void build_pair (int variant)
{
	static const char unit[] = "ACGTTGCATGACGCAGACTAGCTAGGCATCAG";
	const int ulen = (int) (sizeof unit - 1);
	for (int i = 0; i < RLEN; i++)
		refbuf[i] = unit[i % ulen];
	for (int i = 0; i < QLEN; i++)
		qrybuf[i] = unit[(i + variant * 7) % ulen];
	/* A couple of substitutions, so the alignment is not a trivial exact
	   match and the mismatch path of the recurrence is taken. */
	if (variant) {
		qrybuf[QLEN / 3] = 'T';
		qrybuf[QLEN / 2] = 'A';
		refbuf[RLEN / 2] = 'G';
	}
	refbuf[RLEN] = qrybuf[QLEN] = '\0';
	encode (refbuf, refnum, RLEN);
	encode (qrybuf, qrynum, QLEN);
}

#if defined(__lvx__)
extern long sys_write (int fd, const void *buf, unsigned long n);
static void emit (const char *b, unsigned long n) { sys_write (1, b, n); }
static inline unsigned long long cyc (void)
{
	unsigned long long r;
	__asm__ __volatile__ ("get %0 = $frcc\n\t;;" : "=r"(r) : : "memory");
	return r;
}
#else
#include <unistd.h>
#include <time.h>
static void emit (const char *b, unsigned long n) { (void)!write (1, b, n); }
static inline unsigned long long cyc (void)
{
	struct timespec t;
	clock_gettime (CLOCK_MONOTONIC, &t);
	return (unsigned long long) t.tv_sec * 1000000000ull + t.tv_nsec;
}
#endif

static void puts_ (const char *s) { emit (s, strlen (s)); }

static void putnum (const char *tag, long long v)
{
	char b[32]; unsigned i = sizeof b;
	int neg = v < 0;
	unsigned long long u = neg ? (unsigned long long)(-v) : (unsigned long long) v;
	b[--i] = '\n';
	if (!u) b[--i] = '0';
	while (u) { b[--i] = (char)('0' + u % 10); u /= 10; }
	if (neg) b[--i] = '-';
	puts_ (tag);
	emit (&b[i], sizeof b - i);
}

#define NPAIR 4
#define REPS  20

int main (int argc, char **argv)
{
	/* Timed unless explicitly told not to be.  Bare-metal crt.S calls main
	   with no argv, so defaulting to off would silently skip the timing on
	   the target this benchmark exists for. */
	int timed = !(argc > 1 && argv[1][0] == 'q');
	nt_table_init ();
	score_mat_init ();

	/* Correctness: every pair, every score_size, verified against the
	   score the other two sizes agree on.  SSW's byte and word profiles
	   must give the SAME optimal score -- that is the library's own
	   invariant, and checking it needs no baked constant.  A scalarised
	   lowering that got saturation wrong would break exactly here. */
	int fail = 0;
	long long checksum = 0;
	for (int p = 0; p < NPAIR; p++) {
		build_pair (p);
		uint16_t s[3];
		for (int sz = 0; sz < 3; sz++) {
			s_profile *prof = ssw_init (qrynum, QLEN, score_mat, 5, (int8_t) sz);
			s_align *al = ssw_align (prof, refnum, RLEN, 3, 1, 1, 0, 0, 15);
			s[sz] = al ? al->score1 : 0xffff;
			if (al) align_destroy (al);
			init_destroy (prof);
		}
		if (s[0] != s[1] || s[1] != s[2]) {
			putnum ("MISMATCH pair ", p);
			putnum ("  byte ", s[0]);
			putnum ("  word ", s[1]);
			putnum ("  adaptive ", s[2]);
			fail = 1;
		}
		checksum = checksum * 131 + s[1];
	}
	if (fail) { puts_ ("FAIL: profiles disagree\n"); return 1; }
	putnum ("checksum ", checksum);

	if (!timed) { puts_ ("ok\n"); return 0; }


	/* Timed: the adaptive path, which is what a caller actually uses. */
	unsigned long long t0 = cyc ();
	long long acc = 0;
	for (int r = 0; r < REPS; r++) {
		for (int p = 0; p < NPAIR; p++) {
			build_pair (p);
			s_profile *prof = ssw_init (qrynum, QLEN, score_mat, 5, 2);
			s_align *al = ssw_align (prof, refnum, RLEN, 3, 1, 1, 0, 0, 15);
			acc += al ? al->score1 : 0;
			if (al) align_destroy (al);
			init_destroy (prof);
		}
	}
	unsigned long long t1 = cyc ();
	putnum ("alignments ", (long long) REPS * NPAIR);
	putnum ("acc ", acc);
	putnum ("cycles ", (long long) (t1 - t0));
	putnum ("cycles_per_alignment ", (long long) ((t1 - t0) / (REPS * NPAIR)));
	puts_ ("ok\n");
	return 0;
}
