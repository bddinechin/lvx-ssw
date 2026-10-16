// Part of the LVX project, under the Apache License v2.0 with LLVM Exceptions.
// See LICENSE.TXT in the root of this repository for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

/* Freestanding output and cycle reading, shared by the benchmark drivers.
 *
 * Extracted from lvx-bench.c when lvx-inter.c arrived and wanted the same six
 * functions.  Nothing here is benchmark-specific; the cycle counter and the
 * write path are, which is the whole reason they are in one place.
 *
 * There is no printf: the drivers run bare metal under gem5 over the crt.S in
 * lvx-csw's validation/lib, which provides write(2) and exit(2) and nothing
 * else, so every number is formatted by hand.
 */
#if !defined(LVX_SSW_IO_H)
#define LVX_SSW_IO_H

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

#endif /* LVX_SSW_IO_H */
