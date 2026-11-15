#!/bin/bash
# jemalloc 적용 전수 검사 — primesim 계열 전 프로세스 (게스트에서, 런 중 실행)
# 판정 3축: ① maps 에 libjemalloc 로드 여부 ② LD_PRELOAD 환경 전파 여부 ③ 3MB 익명 매핑 수(=glibc 경로 지문)
# 사용: bash jemalloc_check.sh
printf '%-8s %-7s %-16s %-9s %-9s %-30s %s\n' PID PPID COMM jemalloc LD_env 'LD_PRELOAD 값' '3MB익명매핑'
total=0; ok=0
for p in $(pgrep -f 'primesim|prs_lp5vl|bench-eda-cae' 2>/dev/null); do
  [ -r /proc/$p/maps ] || continue
  comm=$(cat /proc/$p/comm 2>/dev/null)
  ppid=$(awk '{print $4}' /proc/$p/stat 2>/dev/null)
  if grep -q 'libjemalloc' /proc/$p/maps 2>/dev/null; then jm='O'; else jm='X'; fi
  lp=$(tr '\0' '\n' </proc/$p/environ 2>/dev/null | sed -n 's/^LD_PRELOAD=//p')
  if [ -n "$lp" ]; then le='O'; else le='X'; lp='(없음)'; fi
  # 3MB(3072KB) 익명 매핑 수 — jemalloc 정상 동작 시 0 근접해야 함
  m3=$(gawk 'NF==5 {split($1,a,"-"); sz=(strtonum("0x"a[2])-strtonum("0x"a[1]))/1024; if (sz==3072) c++} END{print c+0}' /proc/$p/maps 2>/dev/null)
  printf '%-8s %-7s %-16s %-9s %-9s %-30.30s %s\n' "$p" "$ppid" "$comm" "$jm" "$le" "$lp" "$m3"
  if [ "$comm" = "primesim" ]; then
    total=$((total+1)); [ "$jm" = "O" ] && [ "${m3:-99}" -lt 50 ] && ok=$((ok+1))
  fi
done
echo
echo "primesim 잡 $total 개 중 정상 적용 $ok 개"
echo "판정 기준:"
echo "  jemalloc=O + 3MB매핑≈0     → 정상 적용 (glibc 개별 mmap 경로 소멸)"
echo "  jemalloc=O + 3MB매핑 수천  → 로드만 되고 미사용 (정적 링크/자체 allocator) — smaps 정밀 확인"
echo "  jemalloc=X                 → 전파 끊김: 그 프로세스의 부모 실행 지점에 export 필요"
echo "  LD_env=O 인데 jemalloc=X   → 경로 오류/권한/아키텍처 불일치 — ldd 로 라이브러리 확인"
