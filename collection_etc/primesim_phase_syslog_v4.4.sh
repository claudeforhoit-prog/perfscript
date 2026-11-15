#!/bin/bash
# ============================================================
# primesim_phase_syslog.sh   v4.4
#
# PrimeSim output 로그에서 15개 전 단계의 elapsed(self/total) 를 추출해
#   - VCF Ops for Logs 로 원격 Syslog(UDP) 전송  (mode=syslog)
#   - 로컬 CSV 파일로 저장                        (mode=file)
#   - 둘 다                                       (mode=both)
# 파일 1개 = syslog 1줄 = CSV 1행.
#
# 사용법 : ./primesim_phase_syslog.sh <필터문자열> [옵션]
# 예     : ./primesim_phase_syslog.sh primesim_lp5 --dry-run
#          ./primesim_phase_syslog.sh primesim_lp5
#          ./primesim_phase_syslog.sh primesim_lp5 --mode file
#          ./primesim_phase_syslog.sh primesim_lp5 --mode file --out /tmp/tc07.csv
#          ./primesim_phase_syslog.sh primesim_lp5 --mode both
#          ./primesim_phase_syslog.sh primesim_lp5 --dir /data/run2
#
# v4.4 : TotalElapsed_Sec 필드 추가 - 로그 하단 "total elapsed time: N seconds" 의
#        마지막 출현 값(초)을 수집. SrcFile 바로 앞 배치. 미발견 시 -1
# v4.3 : 전송 안정성 - echo 문자열의 괄호 -> 대괄호, 특수문자 -> ASCII 치환
# v4.2 : SYSLOG_TAG 기본값에 실행 유저 계정 포함 [primesim-phase-<user>]
# v4.1 : --dir 옵션 추가 (결과 파일 폴더를 CLI 로 지정, 선택)
# v4.0 : 출력 모드 추가 (syslog / file / both), CSV 저장 + 경로·파일명 지정
# v3.0 : 15개 전 단계 self/total 수집. phase_load/compute 제거(후가공에서 산출).
#        키 규칙 통일: 단계 필드는 ^([a-z]+)_(self|total)$ - 언더스코어 정확히 1개
# ============================================================

# ==========================================================
# * 설정 - 여기만 환경에 맞게 수정 *
# ==========================================================

LOG_DIR="/user/user01/output"      # 결과 파일이 있는 폴더 (--dir 로 덮어쓰기 가능)

# -- 출력 모드 : syslog | file | both --
OUTPUT_MODE="syslog"

# -- syslog 전송 설정 (OUTPUT_MODE=syslog 또는 both 일 때) --
SYSLOG_SERVER="192.0.2.50"        # VCF Ops for Logs IP
SYSLOG_PORT="514"                     # syslog 포트
SYSLOG_TAG="primesim-phase-$(whoami)" # VCF Ops 의 appname 으로 잡힘
                                      #  예) primesim-phase-user01
                                      #  * VCF Ops 필터는 appname = 정확일치 가 아니라
                                      #     'starts with primesim-phase' 로 설정할 것
                                      #  * 계정명에 _ . 등이 있으면 syslog TAG 규격상
                                      #     잘릴 수 있음 -> 그 경우 계정명 직접 기입

# -- 파일 저장 설정 (OUTPUT_MODE=file 또는 both 일 때) --
OUTPUT_DIR="/tmp"                     # 저장 폴더
OUTPUT_FILE=""                        # 파일명. 비우면 자동 생성:
                                      #   primesim_phase_<필터문자열>_<YYYYmmdd-HHMMSS>.csv
                                      # 기존 파일이 있으면 헤더 없이 이어쓰기(append)

FIND_DEPTH=1                          # 1 = LOG_DIR 바로 아래만, 2 이상 = 하위폴더 포함
SYSLOG_SOFT_LIMIT=1024                # syslog 페이로드 권고 한도(bytes). 초과 시 경고

# ==========================================================
# vvv 아래는 수정 불필요 vvv
# ==========================================================
#
# [공통 필드]  Hostname, Workload, JobStart_KST, JobIdx, JobTotal, Stage_Count,
#              TotalElapsed_Sec, SrcFile
#
#   TotalElapsed_Sec = 로그 하단 "total elapsed time: N seconds (H hours)" 중
#                      *마지막* 출현의 초 값. 미발견 시 -1
#
# [단계 필드]  규칙: ^([a-z]+)_(self|total)$   (언더스코어 정확히 1개)
#   로그 출현 순서, 15개
#
#   Reading Netlist                     -> netlist_self / netlist_total
#   Parsing                             -> parsing_self / parsing_total
#   License                             -> license_self / license_total
#   Circuit Elaboration                 -> elaboration_self / elaboration_total
#   Begin Voltage Sources Propagation   -> vsrcbegin_self / vsrcbegin_total
#   End Voltage Sources Propagation     -> vsrcend_self / vsrcend_total
#   MOS Model                           -> mosmodel_self / mosmodel_total
#   Circuit Reduction                   -> reduction_self / reduction_total
#   Connectivity Building               -> connectivity_self / connectivity_total
#   DB Building                         -> dbbuild_self / dbbuild_total
#   Initialization                      -> init_self / init_total
#   Output Preparation                  -> outputprep_self / outputprep_total
#   Matrix Building                     -> matrixbuild_self / matrixbuild_total
#   DC Initialization                   -> dcinit_self / dcinit_total
#   Transient Analysis                  -> transient_self / transient_total
#
#   _self  = 그 단계만의 소요 (초)
#   _total = 잡 시작 ~ 그 단계 종료까지의 누적 (초)
#   -1     = 해당 단계가 로그에 없음  /  0 = 실제로 0초
#   단위 = 초, elapsed(벽시계). cpu(16 threads 합산) / MB 는 수집 안 함
#
#   transient_total = 잡 전체 elapsed  ->  TAT = 이 값 4개 평균
#
# [후가공 예] phase 는 수집하지 않음. Power BI / Excel 등에서 산출:
#   phase_load    = matrixbuild_total
#   phase_compute = transient_total - matrixbuild_total
#   경계 변경 시 matrixbuild_total 을 다른 *_total 로 교체 (재수집 불필요)
# ============================================================


# ----------------------------------------------------------
# 1. 인수 파싱
# ----------------------------------------------------------
PATTERN=""
DRY_RUN=0
CLI_MODE=""
CLI_OUT=""
CLI_DIR=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --mode)
            if [ -n "$2" ]; then CLI_MODE="$2"; shift
            else echo "[ERROR] --mode 뒤에 syslog|file|both 필요" >&2; exit 1; fi
            ;;
        --out)
            if [ -n "$2" ]; then CLI_OUT="$2"; shift
            else echo "[ERROR] --out 뒤에 파일 경로 필요" >&2; exit 1; fi
            ;;
        --dir)
            if [ -n "$2" ]; then CLI_DIR="$2"; shift
            else echo "[ERROR] --dir 뒤에 폴더 경로 필요" >&2; exit 1; fi
            ;;
        -h|--help)
            echo "사용법: $0 <필터문자열> [옵션]"
            echo ""
            echo "  <필터문자열>       파일명에 포함된 문자열 [예: primesim_lp5]"
            echo ""
            echo "옵션:"
            echo "  --mode syslog      syslog 전송만 [설정 기본값]"
            echo "  --mode file        CSV 파일 저장만"
            echo "  --mode both        syslog 전송 + CSV 저장"
            echo "  --out PATH         CSV 저장 경로/파일명 [--mode file|both 일 때]"
            echo "                     디렉터리만 주면 자동 파일명 사용"
            echo "  --dir PATH         결과 파일 폴더 [선택. 미지정 시 설정의 LOG_DIR]"
            echo "  --dry-run          전송/저장 없이 화면 출력만"
            echo ""
            echo "예:"
            echo "  $0 primesim_lp5 --dry-run"
            echo "  $0 primesim_lp5"
            echo "  $0 primesim_lp5 --mode file"
            echo "  $0 primesim_lp5 --mode file --out /tmp/tc07.csv"
            echo "  $0 primesim_lp5 --mode both"
            echo "  $0 primesim_lp5 --dir /data/run2 --mode file"
            exit 0
            ;;
        -*)
            echo "[ERROR] 알 수 없는 옵션: $1" >&2; exit 1 ;;
        *)
            if [ -z "$PATTERN" ]; then
                PATTERN="$1"
            else
                echo "[ERROR] 필터 문자열은 1개만 지정하세요 ['$1' 추가 입력됨]" >&2; exit 1
            fi
            ;;
    esac
    shift
done

# CLI 가 설정값보다 우선
[ -n "$CLI_MODE" ] && OUTPUT_MODE="$CLI_MODE"
[ -n "$CLI_DIR" ]  && LOG_DIR="$CLI_DIR"

# ----------------------------------------------------------
# 2. 사전 검증
# ----------------------------------------------------------
if [ -z "$PATTERN" ]; then
    echo "[ERROR] 필터 문자열이 필요합니다." >&2
    echo "사용법: $0 <필터문자열> [--mode syslog|file|both] [--out PATH] [--dir PATH] [--dry-run]" >&2
    exit 1
fi

case "$OUTPUT_MODE" in
    syslog|file|both) ;;
    *)
        echo "[ERROR] OUTPUT_MODE 값 오류: '${OUTPUT_MODE}' [syslog | file | both 중 하나]" >&2
        exit 1
        ;;
esac

if [ ! -d "$LOG_DIR" ]; then
    echo "[ERROR] 결과 파일 폴더 없음: ${LOG_DIR}" >&2
    if [ -n "$CLI_DIR" ]; then
        echo "        --dir 인수 확인" >&2
    else
        echo "        스크립트 상단 LOG_DIR 확인 [또는 --dir 로 지정]" >&2
    fi
    exit 1
fi

if [ ! -r "$LOG_DIR" ]; then
    echo "[ERROR] 결과 파일 폴더 읽기 권한 없음: ${LOG_DIR}" >&2
    exit 1
fi

# -- syslog 준비 확인 --
NEED_SYSLOG=0
[ "$OUTPUT_MODE" = "syslog" ] && NEED_SYSLOG=1
[ "$OUTPUT_MODE" = "both" ]   && NEED_SYSLOG=1

if [ "$DRY_RUN" -eq 0 ] && [ "$NEED_SYSLOG" -eq 1 ]; then
    if ! command -v logger >/dev/null 2>&1; then
        echo "[ERROR] logger 명령 없음. --mode file 또는 --dry-run 사용" >&2
        exit 1
    fi
fi

# -- 파일 저장 경로 결정 --
NEED_FILE=0
[ "$OUTPUT_MODE" = "file" ] && NEED_FILE=1
[ "$OUTPUT_MODE" = "both" ] && NEED_FILE=1

CSV_PATH=""
if [ "$NEED_FILE" -eq 1 ]; then
    if [ -n "$CLI_OUT" ]; then
        if [ -d "$CLI_OUT" ]; then
            # 디렉터리만 준 경우 -> 자동 파일명
            CSV_PATH="${CLI_OUT%/}/primesim_phase_${PATTERN}_$(date '+%Y%m%d-%H%M%S').csv"
        else
            CSV_PATH="$CLI_OUT"
        fi
    elif [ -n "$OUTPUT_FILE" ]; then
        CSV_PATH="${OUTPUT_DIR%/}/${OUTPUT_FILE}"
    else
        CSV_PATH="${OUTPUT_DIR%/}/primesim_phase_${PATTERN}_$(date '+%Y%m%d-%H%M%S').csv"
    fi

    CSV_DIR="${CSV_PATH%/*}"
    [ "$CSV_DIR" = "$CSV_PATH" ] && CSV_DIR="."

    if [ ! -d "$CSV_DIR" ]; then
        echo "[ERROR] 저장 폴더 없음: ${CSV_DIR}" >&2
        exit 1
    fi
    if [ ! -w "$CSV_DIR" ]; then
        echo "[ERROR] 저장 폴더 쓰기 권한 없음: ${CSV_DIR}" >&2
        exit 1
    fi
    if [ -e "$CSV_PATH" ] && [ ! -w "$CSV_PATH" ]; then
        echo "[ERROR] 기존 파일 쓰기 권한 없음: ${CSV_PATH}" >&2
        exit 1
    fi
fi

# ----------------------------------------------------------
# 3. 배너
# ----------------------------------------------------------
echo "============================================================"
echo " PrimeSim Stage 수집  v4.4  [15 stages]"
if [ -n "$CLI_DIR" ]; then
    echo " - 결과 폴더   : ${LOG_DIR} [depth=${FIND_DEPTH}]  [--dir 지정]"
else
    echo " - 결과 폴더   : ${LOG_DIR} [depth=${FIND_DEPTH}]"
fi
echo " - 필터        : *${PATTERN}*"
if [ "$DRY_RUN" -eq 1 ]; then
    echo " - 모드        : DRY-RUN [전송/저장 안 함, 화면 출력만]"
else
    echo " - 모드        : ${OUTPUT_MODE}"
    if [ "$NEED_SYSLOG" -eq 1 ]; then
        echo " - syslog      : ${SYSLOG_SERVER}:${SYSLOG_PORT}  appname=${SYSLOG_TAG}"
    fi
    if [ "$NEED_FILE" -eq 1 ]; then
        if [ -e "$CSV_PATH" ]; then
            echo " - CSV         : ${CSV_PATH}  [기존 파일 -> 이어쓰기]"
        else
            echo " - CSV         : ${CSV_PATH}  [신규 생성]"
        fi
    fi
fi
echo "============================================================"

# ----------------------------------------------------------
# 4. 대상 파일
# ----------------------------------------------------------
FILES=()
while IFS= read -r f; do
    [ -n "$f" ] && FILES+=("$f")
done < <(find "$LOG_DIR" -maxdepth "$FIND_DEPTH" -type f -name "*${PATTERN}*" 2>/dev/null | sort)

TOTAL_FOUND=${#FILES[@]}

if [ "$TOTAL_FOUND" -eq 0 ]; then
    echo "[WARN] 매칭 파일 없음: ${LOG_DIR}/*${PATTERN}*"
    exit 0
fi

echo "[INFO] 매칭 파일 ${TOTAL_FOUND}개"
echo ""

# ----------------------------------------------------------
# 5. 필드 순서 정의 (로그 출현 순서)
# ----------------------------------------------------------
KEY_ORDER="netlist parsing license elaboration vsrcbegin vsrcend mosmodel reduction connectivity dbbuild init outputprep matrixbuild dcinit transient"

read -r -a KEYS <<< "$KEY_ORDER"
NKEY=${#KEYS[@]}

# ----------------------------------------------------------
# 6. CSV 헤더 (신규 파일일 때만)
# ----------------------------------------------------------
if [ "$NEED_FILE" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
    if [ ! -e "$CSV_PATH" ]; then
        H="Hostname,Workload,JobStart_KST,JobIdx,JobTotal,Stage_Count"
        for (( i=0; i<NKEY; i++ )); do
            H="${H},${KEYS[$i]}_self,${KEYS[$i]}_total"
        done
        H="${H},TotalElapsed_Sec,SrcFile"
        echo "$H" > "$CSV_PATH" || { echo "[ERROR] CSV 헤더 쓰기 실패: ${CSV_PATH}" >&2; exit 1; }
    fi
fi

# ----------------------------------------------------------
# 7. 로그 본문 파서 (awk 1-pass)
#    출력: hostname|stage_count|<k1_self>|<k1_total>|...|<k15_self>|<k15_total>|dupwarn|unmapped|totelap
# ----------------------------------------------------------
parse_body() {
    awk -v korder="$KEY_ORDER" '
    function norm(s) {
        gsub(/[ \t]+/, " ", s); sub(/^ /, "", s); sub(/ $/, "", s); return s
    }
    BEGIN {
        want["Reading Netlist"]                   = "netlist"
        want["Parsing"]                           = "parsing"
        want["License"]                           = "license"
        want["Circuit Elaboration"]               = "elaboration"
        want["Begin Voltage Sources Propagation"] = "vsrcbegin"
        want["End Voltage Sources Propagation"]   = "vsrcend"
        want["MOS Model"]                         = "mosmodel"
        want["Circuit Reduction"]                 = "reduction"
        want["Connectivity Building"]             = "connectivity"
        want["DB Building"]                       = "dbbuild"
        want["Initialization"]                    = "init"
        want["Output Preparation"]                = "outputprep"
        want["Matrix Building"]                   = "matrixbuild"
        want["DC Initialization"]                 = "dcinit"
        want["Transient Analysis"]                = "transient"
        hn = ""; n = 0; unlist = ""; totelap = "-1"
    }

    # -- Hostname: 첫 매칭만 --
    hn == "" && match($0, /Hostname[ \t]*:/) {
        v = substr($0, RSTART + RLENGTH)
        sub(/^[ \t]+/, "", v)
        sub(/[,;].*$/, "", v)
        sub(/[ \t].*$/, "", v)
        if (v != "") hn = v
    }

    # -- total elapsed time: N seconds (...) : 마지막 출현 값 유지 --
    tolower($0) ~ /total elapsed time/ {
        tl = tolower($0)
        p = index(tl, "total elapsed time")
        rest = substr($0, p + 18)
        sub(/^[ \t]*:[ \t]*/, "", rest)
        if (match(rest, /^[0-9]+(\.[0-9]+)?/)) {
            totelap = substr(rest, RSTART, RLENGTH)
        }
    }

    # -- Resource Usage for <Stage>(self/total): a/b sec (cpu), c/d sec (elapsed), e/f MB --
    /Resource Usage for .*\(self\/total\)/ {
        line = $0
        p1 = index(line, "Resource Usage for ")
        if (p1 == 0) next
        rest = substr(line, p1 + 19)
        p2 = index(rest, "(self/total)")
        if (p2 == 0) next
        stage = norm(substr(rest, 1, p2 - 1))

        p3 = index(line, "sec (elapsed)")
        if (p3 == 0) next
        pre = substr(line, 1, p3 - 1)
        m = split(pre, a, ",")
        tok = a[m]
        gsub(/[ \t]/, "", tok)
        if (split(tok, b, "/") != 2) next
        if (b[1] !~ /^[0-9]+(\.[0-9]+)?$/) next
        if (b[2] !~ /^[0-9]+(\.[0-9]+)?$/) next

        n++
        s = b[1] + 0; t = b[2] + 0

        if (stage in want) {
            k = want[stage]
            if (found[k]) { selfv[k] += s; dup[k]++ }
            else          { selfv[k]  = s; found[k] = 1 }
            totalv[k] = t
        } else {
            if (!(stage in unmap)) {
                unmap[stage] = 1
                unlist = unlist (unlist == "" ? "" : "; ") stage
            }
        }
    }

    END {
        if (hn == "") hn = "unknown"
        out = hn "|" n
        cnt = split(korder, K, " ")
        for (i = 1; i <= cnt; i++) {
            k = K[i]
            if (found[k]) out = out "|" sprintf("%.2f", selfv[k]) "|" sprintf("%.2f", totalv[k])
            else          out = out "|-1|-1"
        }
        dw = ""
        for (i = 1; i <= cnt; i++) {
            k = K[i]
            if (dup[k] > 0) dw = dw " " k "x" (dup[k] + 1)
        }
        print out "|" dw "|" unlist "|" totelap
    }
    ' "$1" 2>/dev/null
}

# ----------------------------------------------------------
# 8. 메인 루프
# ----------------------------------------------------------
SENT=0
WROTE=0
SKIP_NAME=0
SKIP_NOSTAGE=0
WARN_MISS=0
WARN_OVER=0

for FILE in "${FILES[@]}"; do
    BASE="${FILE##*/}"

    # -- 8-1. 파일명 파싱 --
    NAME="${BASE%.log}"
    NAME="${NAME#stdout_}"

    if [[ ! "$NAME" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})_([0-9]{2}:[0-9]{2}:[0-9]{2})_.*_([0-9]+)_of_([0-9]+)$ ]]; then
        echo "[SKIP] ${BASE}"
        echo "       파일명 형식 불일치 [기대: stdout_<날짜>_<시각>_..._N_of_M.log]"
        SKIP_NAME=$(( SKIP_NAME + 1 ))
        continue
    fi

    F_DATE="${BASH_REMATCH[1]}"
    F_TIME="${BASH_REMATCH[2]}"
    JOB_IDX="${BASH_REMATCH[3]}"
    JOB_TOTAL="${BASH_REMATCH[4]}"

    # 콜론 -> 하이픈 (key:value 파싱 보호)
    JOBSTART="${F_DATE}T${F_TIME//:/-}"
    SRCFILE="${NAME//:/-}"

    # -- 8-2. 본문 파싱 --
    R=$(parse_body "$FILE")

    if [ -z "$R" ]; then
        echo "[SKIP] ${BASE} - 파일 읽기 실패"
        SKIP_NOSTAGE=$(( SKIP_NOSTAGE + 1 ))
        continue
    fi

    IFS='|' read -r -a A <<< "$R"

    HOSTN="${A[0]}"
    STAGE_CNT="${A[1]}"

    if [ "${STAGE_CNT:-0}" -eq 0 ] 2>/dev/null; then
        echo "[SKIP] ${BASE} - 'Resource Usage for' 라인 없음 [미완료 잡?]"
        SKIP_NOSTAGE=$(( SKIP_NOSTAGE + 1 ))
        continue
    fi

    # -- 8-3. 필드 조립 (A[2] 부터 self/total 쌍) --
    STAGE_FIELDS=""      # syslog 용  ", k_self:v, k_total:v"
    STAGE_CSV=""         # CSV 용     ",v,v"
    MISS=""
    idx=2
    TR_T="-1"
    for (( i=0; i<NKEY; i++ )); do
        k="${KEYS[$i]}"
        sv="${A[$idx]}"; idx=$(( idx + 1 ))
        tv="${A[$idx]}"; idx=$(( idx + 1 ))
        STAGE_FIELDS="${STAGE_FIELDS}, ${k}_self:${sv}, ${k}_total:${tv}"
        STAGE_CSV="${STAGE_CSV},${sv},${tv}"
        [ "$sv" = "-1" ] && MISS="${MISS} ${k}"
        [ "$k" = "transient" ] && TR_T="$tv"
    done

    DUPW="${A[$idx]}"; idx=$(( idx + 1 ))
    UNMAP="${A[$idx]}"; idx=$(( idx + 1 ))
    TOTELAP="${A[$idx]}"
    [ -z "$TOTELAP" ] && TOTELAP="-1"

    # -- 8-4. 경고 --
    if [ -n "$MISS" ]; then
        echo "[WARN] ${BASE} - 단계 미발견:${MISS} [해당 필드 -1]"
        WARN_MISS=$(( WARN_MISS + 1 ))
    fi
    if [ -n "${DUPW// /}" ]; then
        echo "[WARN] ${BASE} - 단계 중복 출현:${DUPW} [self 합산, total 마지막값]"
    fi
    if [ -n "${UNMAP// /}" ]; then
        echo "[WARN] ${BASE} - 매핑에 없는 단계[수집 안 됨]: ${UNMAP}"
    fi
    if [ "$HOSTN" = "unknown" ]; then
        echo "[WARN] ${BASE} - 본문에서 Hostname 못 찾음 -> unknown"
    fi
    if [ "$TOTELAP" = "-1" ]; then
        echo "[WARN] ${BASE} - 'total elapsed time' 라인 못 찾음 -> TotalElapsed_Sec=-1"
    fi

    # -- 8-5. syslog 페이로드 조립 --
    P="Hostname:${HOSTN}"
    P="${P}, Workload:${PATTERN}"
    P="${P}, JobStart_KST:${JOBSTART}"
    P="${P}, JobIdx:${JOB_IDX}"
    P="${P}, JobTotal:${JOB_TOTAL}"
    P="${P}, Stage_Count:${STAGE_CNT}"
    P="${P}${STAGE_FIELDS}"
    P="${P}, TotalElapsed_Sec:${TOTELAP}"
    P="${P}, SrcFile:${SRCFILE}"

    PLEN=${#P}

    # -- 8-6. CSV 행 조립 (문자 필드는 따옴표, 숫자는 그대로) --
    ROW="\"${HOSTN}\",\"${PATTERN}\",\"${JOBSTART}\",${JOB_IDX},${JOB_TOTAL},${STAGE_CNT}"
    ROW="${ROW}${STAGE_CSV}"
    ROW="${ROW},${TOTELAP}"
    ROW="${ROW},\"${SRCFILE}\""

    # -- 8-7. 출력 --
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "----- ${BASE}  [syslog ${PLEN} bytes] -----"
        echo "[syslog] ${P}"
        echo "[csv   ] ${ROW}"
        echo ""
        SENT=$(( SENT + 1 ))
        continue
    fi

    OK=0

    # syslog 전송
    if [ "$NEED_SYSLOG" -eq 1 ]; then
        if [ "$PLEN" -gt "$SYSLOG_SOFT_LIMIT" ]; then
            echo "[WARN] ${BASE} - syslog 페이로드 ${PLEN}B > ${SYSLOG_SOFT_LIMIT}B. 수신측 절단 여부 확인 필요"
            WARN_OVER=$(( WARN_OVER + 1 ))
        fi
        if logger -n "$SYSLOG_SERVER" -P "$SYSLOG_PORT" -d -t "$SYSLOG_TAG" "$P" 2>/dev/null; then
            SENT=$(( SENT + 1 ))
            OK=1
        else
            echo "[FAIL] ${BASE} - logger 전송 실패"
        fi
    fi

    # CSV 저장
    if [ "$NEED_FILE" -eq 1 ]; then
        if echo "$ROW" >> "$CSV_PATH"; then
            WROTE=$(( WROTE + 1 ))
            OK=1
        else
            echo "[FAIL] ${BASE} - CSV 쓰기 실패: ${CSV_PATH}"
        fi
    fi

    if [ "$OK" -eq 1 ]; then
        echo "[OK  ] ${BASE} | host=${HOSTN} | job=${JOB_IDX}/${JOB_TOTAL} | stages=${STAGE_CNT} | elapsed=${TR_T}s | total=${TOTELAP}s"
    fi
done

# ----------------------------------------------------------
# 9. 요약
# ----------------------------------------------------------
echo ""
echo "============================================================"
echo " 매칭 파일             : ${TOTAL_FOUND}"
if [ "$DRY_RUN" -eq 1 ]; then
    echo " 파싱 성공             : ${SENT}"
else
    [ "$NEED_SYSLOG" -eq 1 ] && echo " syslog 전송           : ${SENT}"
    [ "$NEED_FILE" -eq 1 ]   && echo " CSV 저장              : ${WROTE}  -> ${CSV_PATH}"
fi
echo " 건너뜀[파일명]        : ${SKIP_NAME}"
echo " 건너뜀[단계 없음]     : ${SKIP_NOSTAGE}"
echo " 경고[단계 누락]       : ${WARN_MISS}"
[ "$NEED_SYSLOG" -eq 1 ] && echo " 경고[페이로드 길이]   : ${WARN_OVER}"

PROC=$SENT
[ "$OUTPUT_MODE" = "file" ] && PROC=$WROTE
if [ "$PROC" -ne "$TOTAL_FOUND" ]; then
    echo ""
    echo " * 매칭 ${TOTAL_FOUND}개 중 ${PROC}개만 처리됨 - 위 SKIP 사유 확인"
fi
echo "============================================================"
