#!/bin/sh
# =============================================================================
# set_credentials.sh - VCF Operations 접속 정보 일괄 설정
#
#   패키지 안 모든 스크립트(.sh / .py / .ps1)의 Operations 주소, 계정, 암호문, 암호화 키를
#   한 번에 넣거나 바꾼다. POSIX sh (ESXi busybox sh, Linux bash/dash 공용).
#
#   사용: sh set_credentials.sh [-d 패키지폴더] [--ops-host H] [--ops-user U]
#                               [--enc-key K] [--pass-enc ENC] [--check] [--no-backup] [-h]
#
#   대상 변수 (줄 맨 앞의 대입 줄만 교체, 나머지 줄은 그대로)
#     .sh / .py : OPS_HOST_DEFAULT  OPS_USER_DEFAULT  OPS_PASS_ENC  OPS_ENC_KEY
#     .ps1      : $Global:CfgSnap_OpsHost  $Global:CfgSnap_OpsUser
#                 $Global:CfgSnap_OpsPassEnc  $Global:CfgSnap_OpsEncKey
#   암호문 형식 (스크립트들의 복호화 방식과 동일)
#     openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt -base64 -A
#     (키는 환경 변수로 openssl 에 넘긴다 = -pass pass:<KEY> 와 같은 결과, 프로세스 목록 노출 방지)
# =============================================================================

PROG=set_credentials.sh
NL='
'
TAB='	'

usage() {
    cat <<'EOF'
사용: sh set_credentials.sh [옵션]

  VCF Operations 주소, 계정, 암호(암호문), 암호화 키를 패키지 안 모든 스크립트에 일괄 적용.
  지정하지 않은 값은 대화형 입력. 암호와 키는 화면 표시 없이 두 번 입력.

옵션
  -d DIR           패키지 폴더 (기본: 이 스크립트가 있는 폴더)
  --ops-host H     Operations 주소 (FQDN 또는 IP)
  --ops-user U     Operations 계정 (LOCAL 계정)
  --enc-key K      암호화 키 (암호문 생성, 복호화에 사용)
  --pass-enc ENC   이미 만든 암호문 사용 (암호 입력 생략). --enc-key 와 같은 키로 만든 것
  --check          변경 없이 파일별 현재 값 상태만 출력
  --no-backup      교체 전 .bak 백업 생략
  -h, --help       도움말

입력 제한
  주소, 계정, 키에는 큰따옴표("), $, 역따옴표(`), 역슬래시(\), 탭과 줄바꿈 사용 불가
  (sh, py, ps1 의 큰따옴표 문자열 안에 그대로 들어가는 값이기 때문). 암호 자체는 제한 없음
  (단, 앞뒤 공백 불가).

예
  sh set_credentials.sh                                    # 전부 대화형 입력
  sh set_credentials.sh --ops-host ops.example.local --ops-user svc_ops
  sh set_credentials.sh --check
EOF
}

die()  { printf '[오류] %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

# ---------------------------------------------------------------- 인자
PKG_DIR=""; O_HOST=""; O_USER=""; O_KEY=""; O_ENC=""
H_HOST=0; H_USER=0; H_KEY=0; H_ENC=0
CHECK=0; BACKUP=1

need_arg() { [ "$2" -ge 2 ] || die "옵션 값 없음: $1"; }
while [ $# -gt 0 ]; do
    case "$1" in
        -d)            need_arg "$1" $#; PKG_DIR=$2; shift 2 ;;
        --ops-host)    need_arg "$1" $#; O_HOST=$2; H_HOST=1; shift 2 ;;
        --ops-host=*)  O_HOST=${1#*=}; H_HOST=1; shift ;;
        --ops-user)    need_arg "$1" $#; O_USER=$2; H_USER=1; shift 2 ;;
        --ops-user=*)  O_USER=${1#*=}; H_USER=1; shift ;;
        --enc-key)     need_arg "$1" $#; O_KEY=$2; H_KEY=1; shift 2 ;;
        --enc-key=*)   O_KEY=${1#*=}; H_KEY=1; shift ;;
        --pass-enc)    need_arg "$1" $#; O_ENC=$2; H_ENC=1; shift 2 ;;
        --pass-enc=*)  O_ENC=${1#*=}; H_ENC=1; shift ;;
        --check)       CHECK=1; shift ;;
        --no-backup)   BACKUP=0; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             die "알 수 없는 옵션: $1 (도움말: sh $PROG -h)" ;;
    esac
done

if [ -z "$PKG_DIR" ]; then
    PKG_DIR=$(dirname "$0")
fi
[ -d "$PKG_DIR" ] || die "패키지 폴더 없음: $PKG_DIR"
PKG_DIR=$(cd "$PKG_DIR" && pwd) || die "패키지 폴더 접근 불가: $PKG_DIR"

# ---------------------------------------------------------------- 파일 처리 (awk)
# SC_MODE=get : SC_IDX 번째 변수의 값 출력 (대입 줄이 없으면 종료 코드 1)
# SC_MODE=set : 4개 변수의 대입 줄에서 따옴표 안 값만 교체해 전체 출력
# 값은 ENVIRON 으로 받고 문자열 연결로만 넣는다 -> /, &, |, \ 등이 치환을 깨지 않는다.
AWK_PROG='
BEGIN {
    lang = ENVIRON["SC_LANG"]; mode = ENVIRON["SC_MODE"]; want = ENVIRON["SC_IDX"] + 0
    if (lang == "ps1") {
        nm[1] = "$Global:CfgSnap_OpsHost"; nm[2] = "$Global:CfgSnap_OpsUser"
        nm[3] = "$Global:CfgSnap_OpsPassEnc"; nm[4] = "$Global:CfgSnap_OpsEncKey"
    } else {
        nm[1] = "OPS_HOST_DEFAULT"; nm[2] = "OPS_USER_DEFAULT"
        nm[3] = "OPS_PASS_ENC";     nm[4] = "OPS_ENC_KEY"
    }
    val[1] = ENVIRON["SC_HOST"]; val[2] = ENVIRON["SC_USER"]
    val[3] = ENVIRON["SC_ENC"];  val[4] = ENVIRON["SC_KEY"]
    found = 0; got = ""
}
{
    line = $0
    for (i = 1; i <= 4; i++) {
        L = length(nm[i])
        if (substr(line, 1, L) != nm[i]) continue
        rest = substr(line, L + 1); j = 1
        if (lang != "sh") while (substr(rest, j, 1) == " " || substr(rest, j, 1) == "\t") j++
        if (substr(rest, j, 1) != "=") continue
        j++
        if (lang != "sh") while (substr(rest, j, 1) == " " || substr(rest, j, 1) == "\t") j++
        if (substr(rest, j, 1) != "\"") continue
        k = index(substr(rest, j + 1), "\"")
        if (k == 0) continue
        if (mode == "get") {
            if (i == want && !found) { got = substr(rest, j + 1, k - 1); found = 1 }
        } else {
            line = substr(line, 1, L) substr(rest, 1, j) val[i] substr(rest, j + k)
        }
        break
    }
    if (mode == "set") print line
}
END {
    if (mode == "get") { if (!found) exit 1; print got }
}'

lang_of() {
    case "$1" in
        *.ps1) echo ps1 ;;
        *.py)  echo py ;;
        *)     echo sh ;;
    esac
}

# get_val FILE IDX -> 값 출력, 대입 줄 없으면 종료 코드 1
get_val() {
    SC_LANG=$(lang_of "$1") SC_MODE=get SC_IDX=$2 LC_ALL=C awk "$AWK_PROG" "$1"
}

# 대상 파일 목록: 4개 변수 중 하나라도 대입 줄이 있는 .sh/.py/.ps1 (이 스크립트, 백업 제외)
list_targets() {
    find "$PKG_DIR" -type f \( -name '*.sh' -o -name '*.py' -o -name '*.ps1' \) 2>/dev/null | sort |
    while IFS= read -r f; do
        case "$f" in
            "$PKG_DIR/$PROG"|*.bak|*/_build_pkg/*) continue ;;
        esac
        for i in 1 2 3 4; do
            if get_val "$f" $i >/dev/null 2>&1; then printf '%s\n' "$f"; break; fi
        done
    done
}

rel() { printf '%s' "${1#$PKG_DIR/}"; }

# 표시용: 앞 4자 + '..'  (빈 값은 '값 없음')
mask4() {
    if [ -z "$1" ]; then printf '%s' "값 없음"; else printf '%s..' "$(printf '%s' "$1" | cut -c1-4)"; fi
}

TARGETS=$(list_targets)
[ -n "$TARGETS" ] || die "대상 파일 없음 (접속 정보 변수가 있는 스크립트를 찾지 못함): $PKG_DIR"
NT=$(printf '%s\n' "$TARGETS" | wc -l | tr -d ' ')

# ---------------------------------------------------------------- --check
if [ "$CHECK" -eq 1 ]; then
    info "접속 정보 상태 점검: $PKG_DIR (대상 파일 ${NT}개)"
    # printf 폭은 바이트 기준 -> 한글 머리글과 상태 문구는 화면 칸 수(9칸)로 맞춘 고정 문자열 사용
    printf '%-54s  %s  %s  %s  %s\n' "파일" "주소     " "계정     " "암호문   " "키"
    printf '%s\n' "$TARGETS" | while IFS= read -r f; do
        line=$(printf '%-52s' "$(rel "$f")")
        for i in 1 2 3 4; do
            if v=$(get_val "$f" $i); then
                if [ -n "$v" ]; then s="설정됨   "; else s="비어 있음"; fi
            else
                s="항목 없음"
            fi
            line="$line  $s"
        done
        printf '%s\n' "$line"
    done
    exit 0
fi

# ---------------------------------------------------------------- 입력
command -v openssl >/dev/null 2>&1 || die "openssl 없음 (암호문 생성, 확인에 필요)"

IS_TTY=0; [ -t 0 ] && IS_TTY=1
ask() {   # ask 변수명 프롬프트  (표시 입력)
    [ "$IS_TTY" -eq 1 ] || die "대화형 입력 불가 (터미널 아님): $2 값을 옵션으로 지정"
    printf '%s: ' "$2" >&2
    IFS= read -r _a || die "입력 중단"
    eval "$1=\$_a"
}
STTY_OLD=""
restore_tty() { [ -n "$STTY_OLD" ] && stty "$STTY_OLD" 2>/dev/null; STTY_OLD=""; }
read_hidden() {   # read_hidden 변수명 프롬프트
    if [ "$IS_TTY" -eq 1 ]; then
        if command -v stty >/dev/null 2>&1; then      # 표시 끄기를 프롬프트보다 먼저
            STTY_OLD=$(stty -g 2>/dev/null)
            trap 'restore_tty; printf "\n" >&2; exit 130' INT TERM HUP
            stty -echo 2>/dev/null
        fi
        printf '%s: ' "$2" >&2
        IFS= read -r _h; _rc=$?
        restore_tty; trap - INT TERM HUP
        printf '\n' >&2
        [ $_rc -eq 0 ] || die "입력 중단"
    else
        IFS= read -r _h || die "입력 없음: $2 (표준 입력)"
    fi
    eval "$1=\$_h"
}
read_twice() {   # read_twice 변수명 이름
    read_hidden _p1 "$2 입력 (화면 표시 안 됨)"
    read_hidden _p2 "$2 재입력"
    [ "$_p1" = "$_p2" ] || die "$2 불일치"
    [ -n "$_p1" ] || die "$2 값 없음"
    eval "$1=\$_p1"
    _p1=""; _p2=""
}
check_safe() {   # check_safe 이름 값 : 큰따옴표 문자열에 그대로 넣을 수 있는지
    case "$2" in
        *'"'*|*'$'*|*'`'*|*'\'*|*"$NL"*|*"$TAB"*|*“*|*”*)
            die "$1 에 허용되지 않는 문자 포함 (\" \$ \` \\ 탭과 줄바꿈 불가)" ;;
    esac
    [ -n "$2" ] || die "$1 값 없음"
}

[ "$H_HOST" -eq 1 ] || ask O_HOST "Operations 주소 (FQDN 또는 IP)"
check_safe "Operations 주소" "$O_HOST"
[ "$H_USER" -eq 1 ] || ask O_USER "Operations 계정"
check_safe "Operations 계정" "$O_USER"
[ "$H_KEY" -eq 1 ] || read_twice O_KEY "암호화 키"
check_safe "암호화 키" "$O_KEY"

oenc() { SC_OKEY=$O_KEY openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt -pass env:SC_OKEY -base64 -A 2>/dev/null; }
odec() { SC_OKEY=$O_KEY openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 -pass env:SC_OKEY -base64 -A 2>/dev/null; }

if [ "$H_ENC" -eq 1 ]; then
    case "$O_ENC" in
        ''|*[!A-Za-z0-9+/=]*) die "암호문 형식 오류 (base64 문자만 허용)" ;;
    esac
    DEC=$(printf '%s' "$O_ENC" | odec) || DEC=""
    [ -n "$DEC" ] || die "복호화 확인 실패 (--pass-enc 암호문과 암호화 키 불일치 또는 형식 오류)"
    DEC=""
    info "암호문: 지정값 사용, 복호화 확인 완료"
else
    read_twice O_PW "Operations 암호"
    case "$O_PW" in
        ' '*|*' '|"$TAB"*|*"$TAB") die "암호 앞뒤 공백 불가 (일부 스크립트가 복호화 후 공백 제거)" ;;
    esac
    O_ENC=$(printf '%s' "$O_PW" | oenc) || O_ENC=""
    [ -n "$O_ENC" ] || die "암호문 생성 실패 (openssl 의 -pbkdf2 지원 여부 확인)"
    DEC=$(printf '%s' "$O_ENC" | odec) || DEC=""
    [ "$DEC" = "$O_PW" ] || die "복호화 확인 실패 (생성한 암호문이 원래 암호로 복원되지 않음)"
    O_PW=""; DEC=""
    info "암호문 생성 완료, 복호화 확인 완료"
fi

# ---------------------------------------------------------------- 적용
STAMP=$(date +%Y%m%d-%H%M%S)
info "적용 대상: $PKG_DIR (파일 ${NT}개)"
FAILN=0
RESULT=""
OLDIFS=$IFS
set -f          # 경로의 * ? 가 glob 으로 펼쳐지지 않도록
IFS=$NL
for f in $TARGETS; do
    IFS=$OLDIFS
    r=$(rel "$f")
    tmp="$f.sc_tmp.$$"
    if ! SC_LANG=$(lang_of "$f") SC_MODE=set SC_HOST=$O_HOST SC_USER=$O_USER SC_ENC=$O_ENC SC_KEY=$O_KEY \
            LC_ALL=C awk "$AWK_PROG" "$f" > "$tmp"; then
        rm -f "$tmp"; info "  [실패] $r : 변환 오류"; FAILN=$(expr $FAILN + 1); IFS=$NL; continue
    fi
    # awk 는 마지막 줄 끝에 줄바꿈을 붙인다. 원본이 줄바꿈 없이 끝나면 맞춰 준다.
    if [ -n "$(tail -c 1 "$f")" ]; then
        printf '%s' "$(cat "$tmp")" > "$tmp.2" && mv "$tmp.2" "$tmp"
    fi
    a=$(wc -l < "$f" | tr -d ' '); b=$(wc -l < "$tmp" | tr -d ' ')
    if [ "$a" != "$b" ]; then
        rm -f "$tmp"; info "  [실패] $r : 줄 수 불일치 ($a -> $b), 원본 유지"; FAILN=$(expr $FAILN + 1); IFS=$NL; continue
    fi
    if cmp -s "$f" "$tmp"; then
        rm -f "$tmp"; st="변경 없음"
    else
        if [ "$BACKUP" -eq 1 ]; then
            bk="$f.$STAMP.bak"; [ -e "$bk" ] && bk="$f.$STAMP.$$.bak"
            cp -p "$f" "$bk" || { rm -f "$tmp"; die "백업 실패: $r"; }
        fi
        cat "$tmp" > "$f" && rm -f "$tmp" || { rm -f "$tmp"; die "쓰기 실패: $r"; }
        st="적용 완료"
    fi
    # 재확인
    ok=1
    v1=$(get_val "$f" 1); [ "$v1" = "$O_HOST" ] || ok=0
    v2=$(get_val "$f" 2); [ "$v2" = "$O_USER" ] || ok=0
    v3=$(get_val "$f" 3); [ "$v3" = "$O_ENC" ]  || ok=0
    v4=$(get_val "$f" 4); [ "$v4" = "$O_KEY" ]  || ok=0
    if [ $ok -eq 0 ]; then st="확인 실패"; FAILN=$(expr $FAILN + 1); fi
    RESULT="$RESULT$r$TAB${v1:-값 없음}$TAB${v2:-값 없음}$TAB$(mask4 "$v3")$TAB$(mask4 "$v4")$TAB$st$NL"
    IFS=$NL
done
IFS=$OLDIFS
set +f

info ""
printf '%-54s %-26s %-16s %-11s %-9s %s\n' "파일" "주소" "계정" "암호문" "키" "결과"
printf '%s' "$RESULT" | while IFS="$TAB" read -r c1 c2 c3 c4 c5 c6; do
    printf '%-52s %-24s %-14s %-8s %-8s %s\n' "$c1" "$c2" "$c3" "$c4" "$c5" "$c6"
done
[ "$BACKUP" -eq 1 ] && info "백업: 변경 파일마다 <파일>.$STAMP.bak"
if [ "$FAILN" -gt 0 ]; then
    info "결과: 실패 ${FAILN}건"; exit 2
fi
info "결과: 전체 ${NT}개 파일 적용 확인 완료"
exit 0
