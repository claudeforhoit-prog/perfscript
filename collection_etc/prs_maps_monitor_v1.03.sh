#!/bin/bash
# ============================================================
# ★ 실행 방법 (이 한 줄 복사해서 실행) ★
#
#   nohup /bin/bash ./prs_maps_monitor_v1.0.sh > /tmp/prs_maps.log 2>&1 &
#
#   진행 확인 : tail -f /tmp/prs_maps.log
#   중지      : pkill -f prs_maps_monitor_v1.0.sh
# ============================================================
# 스크립트명 : prs_maps_monitor_v1.0.sh
# 목적      : 패턴('primesim', 대소문자 무시) 매칭되는 모든 프로세스의
#             /proc/<pid>/maps, smaps, numa_maps 수집 (Rajesh 요청)
#             → large page mapping 효율 + NUMA 할당 위치 분석
# 분류      : 리눅스 성능 테스트 > 메모리 > 프로세스 메모리 맵
# 버전      : 1.0 (확정판: 지정 경로 직접 저장)
# 실행 위치 : PVM (RHEL guest). PRS 잡과 같은 계정 또는 root 로 실행
#
# 핵심 동작
# - 수집 간격마다 PID를 **매번 재탐색** → 잡이 생기고 없어져도 자동 추적
#   (새 잡: 다음 스냅샷부터 포함 / 죽은 잡: 그 전까지 기록 유지)
# - 폴더 생성 없음: 지정한 OUTDIR(기존 경로)에 모든 파일 직접 저장
#   파일명에 호스트+시각 포함이라 여러 run 이 섞여도 구분 가능
# - CSV 3개 (run당 각 1파일):
#   ① smaps_vma_*.csv     : 1행=VMA 1개, smaps 전 필드 38열
#   ② smaps_summary_*.csv : 1행=스냅샷×PID, Cmdline 포함 (Excel 메인)
#   ③ numa_*.csv          : 1행=VMA 1개, 노드별 할당 분포 (numa_maps)
# - raw 3종: maps/smaps/numa_maps 원본 gzip (Rajesh 전달용)
#
# 사용법
#   [루프 모드 - 권장]
#     nohup /bin/bash ./prs_maps_monitor_v1.0.sh > /tmp/prs_maps.log 2>&1 &
#     nohup /bin/bash ./prs_maps_monitor_v1.0.sh --start-at 15:10 > /tmp/prs_maps.log 2>&1 &
#   [원샷 모드] phase 중간 수동 1회
#     ./prs_maps_monitor_v1.0.sh --once --label load
#     ./prs_maps_monitor_v1.0.sh --once --label compute
#   [특정 PID 1개만]
#     ./prs_maps_monitor_v1.0.sh --pid 93390 --once --label compute
# 중지: pkill -f prs_maps_monitor_v1.0.sh  (그때까지 수집분은 저장돼 있음)
#
# 산출물 (OUTDIR 에 직접 저장, 폴더 생성 안 함)
#   <OUTDIR>/smaps_vma_<호스트>_<시작시각>.csv
#   <OUTDIR>/smaps_summary_<호스트>_<시작시각>.csv
#   <OUTDIR>/numa_<호스트>_<시작시각>.csv
#   <OUTDIR>/<호스트>_<PID>_<수집시각>_{maps,smaps,numa_maps}.txt.gz
#
# 주의
# - 타임스탬프 KST(로컬) + epoch 병기. memstats(UTC) 정렬 시 epoch 사용
# - 실측 기준(전체 smaps 9초/15MB): 스냅샷 1회 ~20초, 듀티 3% 미만
# - numa_maps 의 N0/N1 값은 '페이지 수'. CSV에 KB 환산 열 병기
# - INTERVAL_SEC 은 스냅샷 종료 후 대기 시간 (수집 겹침 없음)
# ============================================================

# ==========================================================
# 1. [사용자 설정] ★ 여기만 수정하면 됩니다 ★
# ==========================================================
INTERVAL_SEC=600                       # ① 수집 간격(초). 예: 300=5분, 600=10분
PROC_PATTERN="primesim"                # ② 프로세스 매칭 패턴 (대소문자 무시,
                                       #    간격마다 재탐색 → 잡 교체 자동 추적)
OUTDIR="/tmp"                          # ③ 저장 경로 (★이미 존재하는 쓰기 가능 경로로 지정★)
MIN_RSS_KB=0                           # ④ 이 값(KB) 미만 RSS 프로세스 스킵 (0=전부)

# ---- 이하 내부 변수 (수정 불필요) ----
PID_ARG=""
LABEL=""
ONCE=0
START_AT=""
HOSTNAME=$(hostname)

# ==========================================================
# 1-1. 인수 파싱
# ==========================================================
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --pid)        PID_ARG="$2"; shift ;;
        --min-rss-kb) MIN_RSS_KB="$2"; shift ;;
        --pattern)    PROC_PATTERN="$2"; shift ;;
        --interval)   INTERVAL_SEC="$2"; shift ;;
        --outdir)     OUTDIR="$2"; shift ;;
        --label)      LABEL="$2"; shift ;;
        --once)       ONCE=1 ;;
        --start-at)
            if [[ -n "$2" && "$2" =~ ^[0-9]{2}:[0-9]{2}$ ]]; then
                START_AT="$2"; shift
            else
                echo "[ERROR] --start-at 형식 오류: HH:MM (예: --start-at 15:10)" >&2
                exit 1
            fi
            ;;
        *) echo "[WARN] 알 수 없는 옵션: $1" >&2 ;;
    esac
    shift
done

# ==========================================================
# 2. 시작 정보 출력
# ==========================================================
echo "============================================================"
echo " PRS maps/smaps/numa_maps 수집 v1.0"
echo " - 모드        : $([ "$ONCE" -eq 1 ] && echo "원샷 (label=${LABEL:-none})" || echo "루프 (${INTERVAL_SEC}초 간격)")"
echo " - PID         : ${PID_ARG:-자동 (pattern='${PROC_PATTERN}' 대소문자 무시, 간격마다 재탐색)}"
echo " - RSS 필터    : ${MIN_RSS_KB} KB 미만 스킵 (0=전부)"
echo " - 결과 상위   : ${OUTDIR}"
[ -n "$START_AT" ] && echo " - 수집 시작   : ${START_AT} (지정)" \
                    || echo " - 수집 시작   : 즉시"
echo " - 실행 시각   : $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================================"

# ==========================================================
# 2-1. --start-at 대기
# ==========================================================
if [ -n "$START_AT" ]; then
    TARGET_EPOCH=$(date -d "today ${START_AT}:00" +%s 2>/dev/null)
    NOW_EPOCH=$(date +%s)
    [ "$TARGET_EPOCH" -le "$NOW_EPOCH" ] && \
        TARGET_EPOCH=$(date -d "tomorrow ${START_AT}:00" +%s 2>/dev/null)
    WAIT_SECS=$(( TARGET_EPOCH - NOW_EPOCH ))
    echo "⏳ $(date '+%H:%M:%S') → ${START_AT} 수집 시작 대기 중 (${WAIT_SECS}초)"
    sleep "$WAIT_SECS"
    echo "▶ $(date '+%Y-%m-%d %H:%M:%S') 수집 시작"
fi

# ==========================================================
# 2-2. 출력 경로 확인 (폴더 생성 안 함)
#      - OUTDIR 은 이미 존재하는, 쓰기 가능한 경로여야 함
#      - 모든 파일(CSV 3개 + raw gz)을 OUTDIR 에 직접 저장
#      - 파일명에 호스트+시각이 포함되어 run 간 충돌 없음
# ==========================================================
START_TS=$(date "+%Y%m%d_%H%M%S")
if [ ! -d "$OUTDIR" ]; then
    echo "[ERROR] 출력 경로가 존재하지 않습니다: ${OUTDIR}" >&2
    echo "        스크립트 상단 OUTDIR 변수를 실제 존재하는 경로로 수정하세요." >&2
    exit 1
fi
if [ ! -w "$OUTDIR" ]; then
    echo "[ERROR] 출력 경로에 쓰기 권한이 없습니다: ${OUTDIR}" >&2
    exit 1
fi
RUNDIR="${OUTDIR}"
RAWDIR="${OUTDIR}"

VMA_CSV="${RUNDIR}/smaps_vma_${HOSTNAME}_${START_TS}.csv"
SUM_CSV="${RUNDIR}/smaps_summary_${HOSTNAME}_${START_TS}.csv"
NUMA_CSV="${RUNDIR}/numa_${HOSTNAME}_${START_TS}.csv"
echo " - 저장 위치   : ${OUTDIR} (폴더 생성 없이 직접 저장)"
echo " - VMA CSV     : $(basename "$VMA_CSV")"
echo " - Summary CSV : $(basename "$SUM_CSV")"
echo " - NUMA CSV    : $(basename "$NUMA_CSV")"

# ==========================================================
# 3. 종료 처리
# ==========================================================
cleanup() {
    echo "수집 종료: $(date '+%Y-%m-%d %H:%M:%S') / 결과: ${RUNDIR}"
    exit 0
}
trap cleanup SIGTERM SIGINT

# ==========================================================
# 4. CSV 헤더 기록
# ==========================================================
# smaps 수치부 필드 순서 (파서와 공유)
KNOWN_FIELDS="Size KernelPageSize MMUPageSize Rss Pss Pss_Dirty Shared_Clean Shared_Dirty Private_Clean Private_Dirty Referenced Anonymous LazyFree AnonHugePages ShmemPmdMapped FilePmdMapped Shared_Hugetlb Private_Hugetlb Swap SwapPss Locked"

{
    printf "Timestamp_KST,Epoch,Hostname,PID,Comm,Label,SnapshotID"
    printf ",VMA_Start,VMA_End,Perms,Offset,Dev,Inode,Path"
    for f in $KNOWN_FIELDS; do printf ",%s_KB" "$f"; done
    printf ",THPeligible,ProtectionKey,VmFlags\n"
} > "$VMA_CSV"

echo "Timestamp_KST,Epoch,Hostname,PID,Comm,Cmdline,Label,SnapshotID,VMA_Count,Total_Size_KB,Total_Rss_KB,Total_Anonymous_KB,Total_AnonHugePages_KB,Total_Hugetlb_KB,Total_Swap_KB,THP_Coverage_Pct_x100,AnonHuge_VMA_Count,Largest_Anon_VMA_KB,Collect_ms" > "$SUM_CSV"

echo "Timestamp_KST,Epoch,Hostname,PID,Comm,Label,SnapshotID,VMA_Start,Policy,Attr,KernelPageSize_KB,Anon_Pages,Dirty_Pages,Mapped_Pages,MapMax,Active_Pages,Writeback_Pages,Swapcache_Pages,N0_Pages,N1_Pages,N2_Pages,N3_Pages,N0_KB,N1_KB,N2_KB,N3_KB" > "$NUMA_CSV"

# ==========================================================
# 5. PID 탐색: 패턴 매칭 프로세스 전부, 대소문자 무시
#    pgrep -fi 미지원 환경은 ps+grep 으로 자동 폴백
#    자기 자신 제외 / MIN_RSS_KB 미만 제외 / --pid 시 1개만
# ==========================================================
find_pids() {
    local raw rc
    if [ -n "$PID_ARG" ]; then
        [ -d "/proc/${PID_ARG}" ] && echo "$PID_ARG"
        return
    fi
    raw=$(pgrep -fi "$PROC_PATTERN" 2>/dev/null); rc=$?
    if [ "$rc" -ge 2 ]; then   # -i 미지원 등 문법 오류 → 폴백
        raw=$(ps -eo pid=,args= | grep -iE "$PROC_PATTERN" | grep -v grep | awk '{print $1}')
    fi
    echo "$raw" | while read -r p; do
        [ -z "$p" ] && continue
        [ "$p" = "$$" ] && continue
        rss=$(awk '/^VmRSS:/{print $2}' "/proc/${p}/status" 2>/dev/null)
        [ -z "$rss" ] && continue
        [ "$rss" -lt "$MIN_RSS_KB" ] && continue
        echo "${rss} ${p}"
    done | sort -rn | awk '{print $2}'
}

# ==========================================================
# 6. 스냅샷 수집 (PID 1개): raw 3종 저장 + CSV 3개 append
# ==========================================================
collect_snapshot() {
    local pid="$1"
    local ts epoch tsfile comm cmdline snap
    local raw_maps raw_smaps raw_numa t0 t1 dur

    ts=$(date "+%Y-%m-%d %H:%M:%S")
    epoch=$(date +%s)
    tsfile=$(date "+%Y%m%d_%H%M%S")
    comm=$(cat "/proc/${pid}/comm" 2>/dev/null | tr -d ',\n')
    [ -z "$comm" ] && comm="unknown"
    cmdline=$( { tr '\0' ' ' < "/proc/${pid}/cmdline"; } 2>/dev/null | tr '\n\r' '  ' | tr -d '"' | tr ',' ';' | cut -c1-500)
    snap="${HOSTNAME}_${pid}_${tsfile}"
    raw_maps="${RAWDIR}/${snap}_maps.txt"
    raw_smaps="${RAWDIR}/${snap}_smaps.txt"
    raw_numa="${RAWDIR}/${snap}_numa_maps.txt"

    t0=$(date +%s%3N)
    cat "/proc/${pid}/maps"      > "$raw_maps"  2>/dev/null
    cat "/proc/${pid}/smaps"     > "$raw_smaps" 2>/dev/null
    cat "/proc/${pid}/numa_maps" > "$raw_numa"  2>/dev/null
    t1=$(date +%s%3N)
    dur=$(( t1 - t0 ))

    if [ ! -s "$raw_smaps" ]; then
        echo "[${ts}] [WARN] PID ${pid} smaps 읽기 실패 (프로세스 종료/권한) - 스킵"
        rm -f "$raw_maps" "$raw_smaps" "$raw_numa"
        return 1
    fi

    # ── (1) smaps 단일 패스: VMA CSV 38열 + Summary 1행 ─────
    awk -v ts="$ts" -v ep="$epoch" -v host="$HOSTNAME" -v pid="$pid" \
        -v comm="$comm" -v cmdline="$cmdline" -v label="$LABEL" -v snap="$snap" \
        -v vmacsv="$VMA_CSV" -v sumcsv="$SUM_CSV" -v dur="$dur" \
        -v known="$KNOWN_FIELDS" '
    BEGIN {
        nf = split(known, FLD, " ")
        for (i = 1; i <= nf; i++) ISKNOWN[FLD[i]] = 1
    }
    function flush(  line, i, ahuge, htlb) {
        if (vstart == "") return
        line = ts "," ep "," host "," pid "," comm "," label "," snap
        line = line "," vstart "," vend "," perms "," offset "," dev "," inode ",\"" path "\""
        for (i = 1; i <= nf; i++)
            line = line "," (FLD[i] in V ? V[FLD[i]] : -1)
        line = line "," thpel "," pkey "," vmflags
        print line >> vmacsv
        n_vma++
        t_size  += (V["Size"]      + 0)
        t_rss   += (V["Rss"]       + 0)
        t_anon  += (V["Anonymous"] + 0)
        ahuge    = (V["AnonHugePages"]   + 0)
        htlb     = (V["Shared_Hugetlb"]  + 0) + (V["Private_Hugetlb"] + 0)
        t_ahuge += ahuge; t_htlb += htlb
        t_swap  += (V["Swap"] + 0)
        if (ahuge > 0) n_ahvma++
        if ((V["Anonymous"] + 0) > max_anon) max_anon = V["Anonymous"] + 0
        vstart = ""
    }
    /^[0-9a-f]+-[0-9a-f]+ / {
        flush()
        split($1, a, "-"); vstart = a[1]; vend = a[2]
        perms = $2; offset = $3; dev = $4; inode = $5
        path = ""
        for (i = 6; i <= NF; i++) path = (path == "" ? $i : path " " $i)
        gsub(/"/, "", path); gsub(/,/, ";", path)
        delete V; thpel = -1; pkey = -1; vmflags = ""
        next
    }
    /^VmFlags:/ {
        vmflags = ""
        for (i = 2; i <= NF; i++) vmflags = (vmflags == "" ? $i : vmflags "|" $i)
        next
    }
    /^THPeligible:/   { thpel = $2; next }
    /^ProtectionKey:/ { pkey  = $2; next }
    /^[A-Za-z_]+:/ {
        k = $1; sub(/:$/, "", k)
        V[k] = $2
        if (!(k in ISKNOWN) && !(k in WARNED)) {
            WARNED[k] = 1
            printf "[WARN] CSV 미정의 smaps 필드: %s (raw에는 보존됨)\n", k
        }
        next
    }
    END {
        flush()
        cov = (t_anon > 0) ? int(t_ahuge / t_anon * 10000) : 0
        printf "%s,%s,%s,%s,%s,\"%s\",%s,%s,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d\n", \
            ts, ep, host, pid, comm, cmdline, label, snap, \
            n_vma, t_size, t_rss, t_anon, t_ahuge, t_htlb, t_swap, \
            cov, n_ahvma, max_anon, dur >> sumcsv
    }' "$raw_smaps"

    # ── (2) numa_maps 파싱: NUMA CSV ───────────────────────
    #  형식 예: 7f10.. default anon=100 dirty=100 N0=60 N1=40 kernelpagesize_kB=4
    #  N0~N3 페이지 수 + KB 환산 병기. file=/heap/stack/huge 는 Attr 로 통합
    if [ -s "$raw_numa" ]; then
        awk -v ts="$ts" -v ep="$epoch" -v host="$HOSTNAME" -v pid="$pid" \
            -v comm="$comm" -v label="$LABEL" -v snap="$snap" \
            -v numacsv="$NUMA_CSV" '
        {
            addr = $1; policy = $2
            attr = ""; kpg = 4
            anon=0; dirty=0; mapped=0; mapmax=0; active=-1; wb=0; swpc=0
            n[0]=0; n[1]=0; n[2]=0; n[3]=0; extra=0
            for (i = 3; i <= NF; i++) {
                tok = $i
                eq = index(tok, "=")
                if (eq == 0) {                        # bare flag: heap/stack/huge 등
                    attr = (attr == "" ? tok : attr ";" tok)
                    continue
                }
                k = substr(tok, 1, eq - 1); v = substr(tok, eq + 1)
                if      (k == "anon")              anon   = v
                else if (k == "dirty")             dirty  = v
                else if (k == "mapped")            mapped = v
                else if (k == "mapmax")            mapmax = v
                else if (k == "active")            active = v
                else if (k == "writeback")         wb     = v
                else if (k == "swapcache")         swpc   = v
                else if (k == "kernelpagesize_kB") kpg    = v
                else if (k == "file") {
                    gsub(/"/, "", v); gsub(/,/, ";", v)
                    attr = (attr == "" ? "file=" v : attr ";file=" v)
                }
                else if (k ~ /^N[0-9]+$/) {
                    idx = substr(k, 2) + 0
                    if (idx <= 3) n[idx] = v
                    else if (!extra) { extra = 1
                        printf "[WARN] 노드 %s 발견 (CSV는 N0-N3까지, raw 참조)\n", k }
                }
            }
            printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,\"%s\",%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d\n", \
                ts, ep, host, pid, comm, label, snap, \
                addr, policy, attr, kpg, anon, dirty, mapped, mapmax, active, wb, swpc, \
                n[0], n[1], n[2], n[3], \
                n[0]*kpg, n[1]*kpg, n[2]*kpg, n[3]*kpg >> numacsv
        }' "$raw_numa"
    else
        echo "[${ts}] [WARN] PID ${pid} numa_maps 읽기 실패 (CSV 스킵, maps/smaps 는 정상)"
    fi

    # ── (3) raw 압축 보관 ──────────────────────────────────
    gzip -f "$raw_maps" "$raw_smaps" "$raw_numa" 2>/dev/null
    echo "[${ts}] PID=${pid}(${comm}) snap=${snap} collect=${dur}ms label=${LABEL:-none}"
    return 0
}

# ==========================================================
# 7. 스냅샷 1회 = 그 순간 매칭되는 PID 전부 순차 수집
# ==========================================================
collect_all() {
    local pids n_ok t0 t1
    pids=$(find_pids)
    [ -z "$pids" ] && return 1
    n_ok=0
    t0=$(date +%s)
    for p in $pids; do
        collect_snapshot "$p" && n_ok=$(( n_ok + 1 ))
    done
    t1=$(date +%s)
    echo "[$(date '+%H:%M:%S')] 스냅샷 완료: PID ${n_ok}개 수집, 총 $(( t1 - t0 ))초 소요"
    return 0
}

# ==========================================================
# 8. 메인
# ==========================================================
if [ "$ONCE" -eq 1 ]; then
    if ! collect_all; then
        echo "[ERROR] 대상 프로세스 없음 (pattern='${PROC_PATTERN}', pid='${PID_ARG}')" >&2
        exit 1
    fi
    exit 0
fi

while true; do
    if ! collect_all; then
        echo "[$(date '+%H:%M:%S')] 대상 프로세스 대기 중 (pattern='${PROC_PATTERN}')"
        sleep 60
        continue
    fi
    sleep "$INTERVAL_SEC"
done
