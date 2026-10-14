// Part of the LVX project, under the Apache License v2.0 with LLVM Exceptions.
// See LICENSE.TXT in the root of this repository for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

/* Striped Smith-Waterman on LVX-2: a self-checking SIMD benchmark whose
 * headline figure is comparable to other machines.
 *
 * THE METRIC IS CYCLES PER CELL UPDATE.  The Smith-Waterman literature reports
 * GCUPS -- giga cell updates per second, a cell being one (query, reference)
 * position -- so cycles/cell is the same quantity with the clock divided out,
 * and that is what makes a number here comparable to a published figure for
 * another CPU rather than only to our own history.  For orientation: the byte
 * path processes 16 lanes at once, so 16 cells/cycle is the ceiling, and
 * Farrar-style SSE2 implementations land around 1-2 cells/cycle on x86.
 *
 * THE INPUT IS THE ONE UPSTREAM SHIPS, and its shape matters more than its
 * size.  Cells scale as query x reference while profile construction scales as
 * query alone, so a SHORT QUERY AGAINST A LONG REFERENCE is what makes the
 * kernel dominate -- and it is also the real use case, mapping short reads to
 * a long reference.  An earlier version of this benchmark used a 120-base
 * query against a 240-base synthetic reference and measured 89 cycles/cell,
 * about a hundred times off the achievable figure: at that shape the O(q)
 * setup swamps the O(q*r) kernel, so it was reporting profile construction.
 * lvx/data.h is baked from demo/1k.fa and demo/54mer_hap1_1.100.fa by
 * lvx/mkdata.py; regenerate it against 10k.fa or 100k.fa for the slower tiers.
 *
 * ONLY ssw_align IS TIMED.  ssw_init builds the query profile and is hoisted
 * out of the loop, which is both what a real caller does -- one profile, many
 * references -- and what keeps an O(q) cost out of an O(q*r) measurement.
 * Allocation is outside too; the bump allocator in lvx-shim.c exists so it
 * cannot intrude.
 *
 * SELF-CHECKING FIRST.  Every query runs through all three of SSW's profiles --
 * byte (16 lanes, saturating at 255), word (8 lanes), adaptive -- and they must
 * agree before any cycle count prints.  That is the library's own invariant, so
 * it needs no baked expected score, and it breaks exactly where this port is
 * weak: a mis-lowered saturating subtract makes the byte profile disagree with
 * the word one.  Without it a miscompile reads as a speed-up, which matters
 * because partial scalarisation is the thing under study.
 */
#include <stdlib.h>
#include <stdint.h>
#include "../src/ssw.h"
#include "data.h"

static int8_t nt_table[128];
static int8_t score_mat[25];

static void tables_init (void)
{
	for (int i = 0; i < 128; i++)
		nt_table[i] = 4;
	nt_table['A'] = nt_table['a'] = 0;
	nt_table['C'] = nt_table['c'] = 1;
	nt_table['G'] = nt_table['g'] = 2;
	nt_table['T'] = nt_table['t'] = 3;

	/* +2 match, -2 mismatch, N neutral -- upstream's own example weights. */
	int k = 0;
	for (int i = 0; i < 4; i++) {
		for (int j = 0; j < 4; j++)
			score_mat[k++] = (i == j) ? 2 : -2;
		score_mat[k++] = 0;
	}
	for (int j = 0; j < 5; j++)
		score_mat[k++] = 0;
}

static int8_t refnum[SSW_REF_LEN];
/* sized from the data, not a guess: QLEN mode makes queries far longer
   than the 54-base reads, and a fixed 64 would silently overrun. */
static int8_t qrynum[SSW_NQUERY][SSW_MAX_QLEN];

static void encode_all (void)
{
	for (int i = 0; i < SSW_REF_LEN; i++)
		refnum[i] = nt_table[(unsigned char) ssw_ref[i]];
	for (int q = 0; q < SSW_NQUERY; q++)
		for (int i = 0; i < ssw_query_len[q]; i++)
			qrynum[q][i] = nt_table[(unsigned char) ssw_query[q][i]];
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
#include <x86intrin.h>
static void emit (const char *b, unsigned long n) { (void)!write (1, b, n); }
/* RDTSC, not clock_gettime: the point of the native build is a reference
   figure in the SAME unit as the target's, and nanoseconds are not.
   Caveat worth knowing before quoting it -- the TSC ticks at a fixed
   reference rate, not at the core's actual frequency, so on a machine
   boosting above or below base clock this is cycles-at-base-clock rather
   than true core cycles.  Good enough to say "about one cell per cycle";
   not good enough to compare two x86 parts to three digits. */
static inline unsigned long long cyc (void) { return __rdtsc (); }
#endif

static unsigned slen (const char *s) { unsigned n = 0; while (s[n]) n++; return n; }
static void puts_ (const char *s) { emit (s, slen (s)); }

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

/* v scaled by 1000, printed as d.ddd -- cycles/cell is near 1, so an integer
   would quantise the whole measurement away. */
static void putfix (const char *tag, unsigned long long v1000)
{
	char b[32]; unsigned i = sizeof b;
	b[--i] = '\n';
	for (int d = 0; d < 3; d++) { b[--i] = (char)('0' + v1000 % 10); v1000 /= 10; }
	b[--i] = '.';
	if (!v1000) b[--i] = '0';
	while (v1000) { b[--i] = (char)('0' + v1000 % 10); v1000 /= 10; }
	puts_ (tag);
	emit (&b[i], sizeof b - i);
}

int main (void)
{
	tables_init ();
	encode_all ();

	/* ---- correctness: the three profiles must agree, per query ---- */
	long long checksum = 0;
	for (int q = 0; q < SSW_NQUERY; q++) {
		uint16_t s[3];
		for (int sz = 0; sz < 3; sz++) {
			s_profile *p = ssw_init (qrynum[q], ssw_query_len[q],
						 score_mat, 5, (int8_t) sz);
			s_align *a = ssw_align (p, refnum, SSW_REF_LEN, 3, 1, 0, 0, 0, 15);
			s[sz] = a ? a->score1 : 0xffff;
			if (a) align_destroy (a);
			init_destroy (p);
		}
		/* The byte profile is only APPLICABLE while the optimal score
		   fits in 255 -- a long, similar query scores far above that,
		   and ssw_align then refuses it (returning NULL, which is the
		   0xffff sentinel here) rather than returning a wrong answer.
		   That is the library working, not a mismatch, so the invariant
		   is: word and adaptive always agree, and byte agrees too
		   whenever it was applicable.  Requiring all three
		   unconditionally made a 500-base query look like a failure. */
		int byte_ok = (s[0] != 0xffff);
		if (s[1] != s[2] || (byte_ok && s[0] != s[1])) {
			putnum ("MISMATCH query ", q);
			putnum ("  byte ", s[0]);
			putnum ("  word ", s[1]);
			putnum ("  adaptive ", s[2]);
			puts_ ("FAIL: profiles disagree\n");
			return 1;
		}
		if (!byte_ok && q == 0)
			puts_ ("note: byte profile not applicable (score > 255), word path timed\n");
		checksum = checksum * 131 + s[1];
	}
	putnum ("checksum ", checksum);

	/* ---- timed: ssw_align only, profiles built up front ---- */
	s_profile *prof[SSW_NQUERY];
	for (int q = 0; q < SSW_NQUERY; q++)
		prof[q] = ssw_init (qrynum[q], ssw_query_len[q], score_mat, 5, 2);

	long long acc = 0, cells = 0;
	unsigned long long t0 = cyc ();
	for (int q = 0; q < SSW_NQUERY; q++) {
		s_align *a = ssw_align (prof[q], refnum, SSW_REF_LEN, 3, 1, 0, 0, 0, 15);
		acc += a ? a->score1 : 0;
		if (a) align_destroy (a);
	}
	unsigned long long t1 = cyc ();
	for (int q = 0; q < SSW_NQUERY; q++) {
		cells += (long long) ssw_query_len[q] * SSW_REF_LEN;
		init_destroy (prof[q]);
	}

	unsigned long long cycles = t1 - t0;
	putnum ("queries ", SSW_NQUERY);
	putnum ("ref_len ", SSW_REF_LEN);
	putnum ("acc ", acc);
	putnum ("cells ", cells);
	putnum ("cycles ", (long long) cycles);
	putfix ("cycles_per_cell ", cycles * 1000ull / (unsigned long long) cells);
	putfix ("cells_per_cycle ", (unsigned long long) cells * 1000ull / cycles);
	puts_ ("ok\n");
	return 0;
}
