#!/bin/bash
# mmap_align — build + self-test. Run on the GUEST (RHEL 8.10).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"

echo "== 1) build =="
gcc -O2 -fPIC -shared -o mmap_align.so mmap_align.c -ldl
echo "   built: $HERE/mmap_align.so"

echo
echo "== 2) self-test (a tiny program that mmaps 3 MB anonymously) =="
cat > /tmp/mmtest.c <<'EOF'
#define _GNU_SOURCE
#include <stdio.h>
#include <stdint.h>
#include <sys/mman.h>
int main(void){
    size_t L = 3UL*1024*1024;            /* 3 MB, like the mp alloc chunk */
    void *p = mmap(NULL, L, PROT_READ|PROT_WRITE,
                   MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
    if (p==MAP_FAILED){ perror("mmap"); return 1; }
    uintptr_t off = (uintptr_t)p % (2UL*1024*1024);
    printf("addr=%p  offset_within_2MB=%lu KB  %s\n",
           p, off/1024, off==0 ? "ALIGNED":"unaligned");
    return 0;
}
EOF
gcc -O2 -o /tmp/mmtest /tmp/mmtest.c

echo "   -- without interposer (baseline): expect 'unaligned' --"
/tmp/mmtest

echo "   -- with interposer: expect 'ALIGNED' (offset 0) --"
MMAP_ALIGN_VERBOSE=1 LD_PRELOAD="$HERE/mmap_align.so" /tmp/mmtest

echo
echo "== done. if the second line says ALIGNED (offset 0 KB), the interposer works. =="
