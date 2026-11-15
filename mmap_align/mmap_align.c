/* ============================================================================
 * mmap_align.c — LD_PRELOAD interposer that 2 MB-aligns large anonymous mmaps
 *
 * PURPOSE
 *   PrimeSim's in-house "mp alloc" pool allocator obtains its ~3 MB chunks via
 *   direct mmap(), bypassing glibc malloc. Because the kernel (RHEL 8.10 / 4.18)
 *   only guarantees 4 KB alignment for mmap, those 3 MB regions land off the
 *   2 MB grid and ~half become THPeligible=0 (see TrackA_3MB_VMA_Review).
 *
 *   This library intercepts anonymous mmap requests >= a threshold and forces
 *   their start address onto a 2 MB boundary, so a full 2 MB THP window fits.
 *   No application change; the app binary is untouched.
 *
 * HOW IT WORKS
 *   For a qualifying request we over-allocate by (2 MB - 1), let the kernel
 *   place it, then munmap the unaligned head and the trailing slack, returning
 *   only the 2 MB-aligned interior. This is the same idea as posix_memalign for
 *   mmap, and mirrors what kernel 6.1's thp_get_unmapped_area does natively.
 *
 * BUILD
 *   gcc -O2 -fPIC -shared -o mmap_align.so mmap_align.c -ldl
 *
 * USE (guest, in the job-launch shell — inherited by all child jobs)
 *   export MMAP_ALIGN_MIN=2097152        # only align requests >= 2 MB (default)
 *   export MMAP_ALIGN_VERBOSE=0          # 1 = log each aligned call to stderr
 *   export LD_PRELOAD=/path/to/mmap_align.so
 *   python3 .../bench-eda-cae.py run primesim LP5_VL_21 -n 4
 *
 * VERIFY (while a job runs)
 *   PID=$(ps -eo pid,comm,rss --sort=-rss | awk '$2=="primesim"{print $1;exit}')
 *   grep -c '^Size: *3072 kB' /proc/$PID/smaps          # 3 MB VMAs still counted
 *   # then check THPeligible on those VMAs — should now be 1
 *
 * SAFETY / SCOPE
 *   - Only touches anonymous (MAP_ANONYMOUS) mappings without MAP_FIXED, of
 *     length >= MMAP_ALIGN_MIN. File-backed, fixed, and small maps are passed
 *     through untouched.
 *   - If anything fails, it silently falls back to a plain mmap — never worse
 *     than baseline.
 *   - Reversible instantly: unset LD_PRELOAD.
 *   - Trade-off: up to ~2 MB of extra virtual address space is briefly reserved
 *     per call and immediately trimmed; negligible for a 1,540 GB VM.
 * ==========================================================================*/

#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <sys/mman.h>
#include <unistd.h>

#define HUGE_2MB  (2UL * 1024 * 1024)

/* real libc entry points, resolved on first use */
static void *(*real_mmap)(void *, size_t, int, int, int, off_t)   = NULL;
static void *(*real_mmap64)(void *, size_t, int, int, int, off_t) = NULL;

static size_t g_min      = HUGE_2MB;   /* align requests >= this size        */
static int    g_verbose  = 0;
static int    g_init     = 0;

static void init_once(void)
{
    if (g_init) return;
    real_mmap   = dlsym(RTLD_NEXT, "mmap");
    real_mmap64 = dlsym(RTLD_NEXT, "mmap64");
    const char *m = getenv("MMAP_ALIGN_MIN");
    if (m && *m) {
        unsigned long v = strtoul(m, NULL, 10);
        if (v >= HUGE_2MB) g_min = v;
    }
    const char *v = getenv("MMAP_ALIGN_VERBOSE");
    g_verbose = (v && *v && *v != '0');
    g_init = 1;
}

/* decide whether this request is one we should align */
static int should_align(void *addr, size_t len, int flags)
{
    if (addr != NULL)               return 0;   /* caller wants a specific base */
    if (flags & MAP_FIXED)          return 0;
    if (!(flags & MAP_ANONYMOUS))   return 0;   /* file-backed: leave alone     */
    if (len < g_min)                return 0;
    return 1;
}

/* core: allocate len, 2 MB-aligned, by over-map + trim */
static void *aligned_map(void *(*fn)(void *, size_t, int, int, int, off_t),
                         size_t len, int prot, int flags, int fd, off_t off)
{
    size_t over = len + HUGE_2MB;               /* slack for alignment          */
    void  *base = fn(NULL, over, prot, flags, fd, off);
    if (base == MAP_FAILED) {
        /* fall back to an ordinary mapping — never worse than baseline */
        return fn(NULL, len, prot, flags, fd, off);
    }

    uintptr_t raw     = (uintptr_t)base;
    uintptr_t aligned = (raw + HUGE_2MB - 1) & ~(HUGE_2MB - 1);
    size_t    head    = (size_t)(aligned - raw);
    size_t    tail    = over - head - len;

    if (head) munmap(base, head);               /* drop unaligned prefix        */
    if (tail) munmap((void *)(aligned + len), tail); /* drop trailing slack     */

    if (g_verbose)
        fprintf(stderr, "[mmap_align] len=%zu -> base=%p aligned=%p (head=%zu tail=%zu)\n",
                len, base, (void *)aligned, head, tail);

    return (void *)aligned;
}

void *mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off)
{
    init_once();
    if (should_align(addr, len, flags))
        return aligned_map(real_mmap, len, prot, flags, fd, off);
    return real_mmap(addr, len, prot, flags, fd, off);
}

void *mmap64(void *addr, size_t len, int prot, int flags, int fd, off_t off)
{
    init_once();
    if (should_align(addr, len, flags))
        return aligned_map(real_mmap64 ? real_mmap64 : real_mmap,
                           len, prot, flags, fd, off);
    return (real_mmap64 ? real_mmap64 : real_mmap)(addr, len, prot, flags, fd, off);
}
