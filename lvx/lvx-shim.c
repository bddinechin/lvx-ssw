// Part of the LVX project, under the Apache License v2.0 with LLVM Exceptions.
// See LICENSE.TXT in the root of this repository for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

/* Freestanding libc shim for SSW under gem5.
 *
 * Linking newlib's libc here drags in its syscall layer -- fstat, isatty,
 * _exit, kill, getpid -- which the freestanding crt.S in validation/lib does
 * not provide, and providing them would be more scaffolding than the four
 * functions SSW actually wants.  The rest of validation/ is freestanding for
 * the same reason, so this follows it.
 *
 * SSW needs exactly: calloc, malloc, realloc, free, abs, fprintf -- plus strlen
 * for the driver's own output and _impure_ptr for SSW's `stderr'.
 *
 * The allocator is a BUMP allocator and free() is a no-op.  That is sound for
 * this benchmark and would not be in general: SSW allocates per profile and
 * per alignment and frees both, so a run of N alignments leaks N profiles'
 * worth.  Sized for the 80 alignments the driver performs with a wide margin;
 * exhaustion aborts loudly rather than returning NULL, because SSW checks few
 * of its allocations and a silent NULL would surface as a wrong score instead.
 *
 * Deliberately NOT a real allocator: a free-list would put allocator work in
 * the timed region, and this benchmark exists to measure SIMD kernels, not
 * malloc.  The bump pointer costs a load, an add and a store.
 */
#include <stdint.h>
#include <stddef.h>

extern long sys_write (int fd, const void *buf, unsigned long n);

#define HEAP_BYTES (8u << 20)
static unsigned char heap[HEAP_BYTES] __attribute__((aligned (32)));
static size_t brk_;

static void die (const char *m)
{
	unsigned long n = 0;
	while (m[n]) n++;
	sys_write (1, m, n);
	__builtin_trap ();
}

void *malloc (size_t n)
{
	/* 32-byte aligned: SSW stores 128-bit vectors into these buffers with
	   _mm_store_si128, and LVX's STACK_BOUNDARY is 256 bits besides. */
	size_t a = (n + 31u) & ~(size_t) 31u;
	if (brk_ + a > HEAP_BYTES)
		die ("FAIL: bump heap exhausted\n");
	void *p = &heap[brk_];
	brk_ += a;
	return p;
}

void *calloc (size_t c, size_t n)
{
	size_t t = c * n;
	unsigned char *p = malloc (t);
	for (size_t i = 0; i < t; i++)
		p[i] = 0;
	return p;
}

void *realloc (void *old, size_t n)
{
	/* Copies the whole new size rather than the old one, which is safe
	   only because every byte of the bump heap is readable.  SSW grows
	   its CIGAR buffer this way. */
	unsigned char *p = malloc (n);
	if (old) {
		const unsigned char *o = old;
		for (size_t i = 0; i < n; i++)
			p[i] = o[i];
	}
	return p;
}

void free (void *p) { (void) p; }

int abs (int v) { return v < 0 ? -v : v; }

size_t strlen (const char *s)
{
	size_t n = 0;
	while (s[n]) n++;
	return n;
}

/* SSW writes its error paths to `stderr', which newlib expands to
   _impure_ptr->_stderr -- a dereference at the call site, so the pointer has
   to be valid memory even though fprintf below never formats anything.  Points
   at a zeroed blob: the FILE* read out of it is garbage, and fprintf traps
   before using it. */
static char impure_blob[512] __attribute__((aligned (8)));
void *_impure_ptr = impure_blob;

/* SSW only uses fprintf on its error paths; reaching one is a failure, so
   print the fact and stop rather than implement formatting. */
int fprintf (void *stream, const char *fmt, ...)
{
	(void) stream; (void) fmt;
	die ("FAIL: ssw reached an fprintf error path\n");
	return 0;
}
