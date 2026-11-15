#!/usr/bin/env bash
# TrackA S-01 — PrimeSim taskset pinning (게스트 RHEL에서 실행)
#
# 구조 (TC-108 sched_thread 실측):
#   primesim 프로세스 1개 = 잡 1개, 내부 스레드 5개
#     - TID==PID  메인 연산 스레드 (exec 14,530s)
#     - TID 3개   워커 (exec ~900s, 런 시작 후 뒤늦게 생성됨)
#     - TID 1개   헬퍼 (exec 77ms, 사실상 유휴)
#   4잡 x 활성 4스레드 = 16 vCPU
#
# 사용:
#   ./taskset_pin_primesim.sh apply            # 잡 단위 4-vCPU 마스크, 30초 주기 감시
#   MODE=thread ./taskset_pin_primesim.sh apply# 스레드 1:1 (Distinct_CPUs=1 목표)
#   ONCE=1 ./taskset_pin_primesim.sh apply     # 1회만
#   DRYRUN=1 ./taskset_pin_primesim.sh apply   # 명령만 출력
#   ./taskset_pin_primesim.sh verify           # 현재 affinity 표로 확인
#   ./taskset_pin_primesim.sh reset            # 전체 vCPU로 원복
#
# 환경변수: MODE=job|thread  INTERVAL=30  CPUS_PER_JOB=4  NCPU=(자동)  LOG=/var/tmp/...

set -u

MODE=${MODE:-job}
INTERVAL=${INTERVAL:-30}
CPUS_PER_JOB=${CPUS_PER_JOB:-4}
ONCE=${ONCE:-0}
DRYRUN=${DRYRUN:-0}
NCPU=${NCPU:-$(nproc)}
LOG=${LOG:-/var/tmp/taskset_pin_primesim.log}

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG" >&2; }

# 스케줄러가 실제로 붙어 있는 vCPU 목록을 정규화해 비교 (0-3 == 0,1,2,3)
expand() {  # "0-3,8" -> "0 1 2 3 8"
  local out=() part a b
  IFS=',' read -ra part <<< "$1"
  for p in "${part[@]}"; do
    if [[ "$p" == *-* ]]; then a=${p%-*}; b=${p#*-}; for ((i=a;i<=b;i++)); do out+=("$i"); done
    else out+=("$p"); fi
  done
  echo "${out[*]}"
}

cur_aff() { taskset -cp "$1" 2>/dev/null | awk -F': ' '{print $2}'; }

pin() {  # pin <tid> <cpulist>
  local tid=$1 want=$2 have
  have=$(cur_aff "$tid") || return 0
  [[ -z "$have" ]] && return 0
  [[ "$(expand "$have")" == "$(expand "$want")" ]] && return 0
  if [[ "$DRYRUN" == "1" ]]; then log "DRYRUN taskset -pc $want $tid  (현재 $have)"; return 0; fi
  taskset -pc "$want" "$tid" >/dev/null 2>&1 && log "PINNED tid=$tid $have -> $want"
}

# 스레드를 CPU 사용시간 내림차순으로 나열 (utime+stime, /proc/<tid>/stat 14·15번 필드)
threads_by_cpu() {  # <pid>
  local pid=$1 tid rest ticks
  for tid in $(ls /proc/"$pid"/task 2>/dev/null); do
    rest=$(sed 's/.*) //' /proc/"$pid"/task/"$tid"/stat 2>/dev/null) || continue
    # rest 의 1번째=state, utime=12번째, stime=13번째
    ticks=$(awk '{print $12+$13}' <<< "$rest")
    printf '%s %s\n' "${ticks:-0}" "$tid"
  done | sort -rn | awk '{print $2}'
}

jobs_pids() { pgrep -x primesim 2>/dev/null | sort -n; }

apply_once() {
  local -a pids; mapfile -t pids < <(jobs_pids)
  (( ${#pids[@]} == 0 )) && return 0
  local njob=${#pids[@]} idx=0 pid base mask
  # 잡 수가 예상(NCPU/CPUS_PER_JOB)보다 많으면 마스크가 겹치므로 경고만 남기고 라운드로빈
  (( njob * CPUS_PER_JOB > NCPU )) && log "WARN 잡 ${njob}개 x ${CPUS_PER_JOB}vCPU > ${NCPU}vCPU — 마스크 중복"
  for pid in "${pids[@]}"; do
    base=$(( (idx * CPUS_PER_JOB) % NCPU ))
    mask="${base}-$(( base + CPUS_PER_JOB - 1 ))"
    if [[ "$MODE" == "thread" ]]; then
      local -a tids; mapfile -t tids < <(threads_by_cpu "$pid")
      local t i=0
      for t in "${tids[@]}"; do
        if (( i < CPUS_PER_JOB )); then pin "$t" "$(( base + i ))"   # 활성 상위 N개 = 1 vCPU 전용
        else pin "$t" "$mask"; fi                                     # 유휴 헬퍼 = 잡 마스크 공유
        i=$((i+1))
      done
    else
      # -a: 현재 존재하는 모든 스레드에 적용 (이후 생성 스레드는 상속)
      if [[ "$DRYRUN" == "1" ]]; then log "DRYRUN taskset -acp $mask $pid"
      else taskset -acp "$mask" "$pid" >/dev/null 2>&1 && log "PINNED pid=$pid -> $mask"; fi
    fi
    idx=$((idx+1))
  done
}

verify() {
  printf '%-8s %-8s %-10s %-9s %-12s %s\n' PID TID CURCPU AFFINITY MIGRATIONS EXEC_ms
  local pid tid cpu aff mig exec
  for pid in $(jobs_pids); do
    for tid in $(threads_by_cpu "$pid"); do
      # stat 39번 필드(processor) — comm 제거 후이므로 awk 기준 $37
      cpu=$(awk '{print $37}' <<< "$(sed 's/.*) //' /proc/"$pid"/task/"$tid"/stat)")
      aff=$(cur_aff "$tid")
      mig=$(awk '/nr_migrations/{print $3}' /proc/"$pid"/task/"$tid"/sched 2>/dev/null)
      exec=$(awk '/se.sum_exec_runtime/{print $3}' /proc/"$pid"/task/"$tid"/sched 2>/dev/null)
      printf '%-8s %-8s %-10s %-9s %-12s %s\n' "$pid" "$tid" "$cpu" "$aff" "$mig" "$exec"
    done
  done
}

reset_all() {
  local pid
  for pid in $(jobs_pids); do
    taskset -acp "0-$((NCPU-1))" "$pid" >/dev/null 2>&1 && log "RESET pid=$pid -> 0-$((NCPU-1))"
  done
}

case "${1:-apply}" in
  apply)
    log "START mode=$MODE cpus_per_job=$CPUS_PER_JOB ncpu=$NCPU interval=${INTERVAL}s once=$ONCE dryrun=$DRYRUN"
    if [[ "$ONCE" == "1" ]]; then apply_once
    else while true; do apply_once; sleep "$INTERVAL"; done; fi ;;
  verify) verify ;;
  reset)  reset_all ;;
  *) echo "usage: $0 {apply|verify|reset}" >&2; exit 2 ;;
esac
