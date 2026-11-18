#!/bin/bash
# --- csh/tcsh guard: the three lines below do nothing in bash. ---
# "csh guest_config_push.sh ..." re-executes itself with bash; "source guest_config_push.sh" in csh prints a hint and stops.
test "$?BASH_VERSION" = "0" && test -f "$0" && exec /bin/bash "$0" $argv:q
test "$?BASH_VERSION" = "0" && echo "guest_config_push.sh: do not source it. Run:  bash guest_config_push.sh [options]"
if false; then :; fi
# ============================================================
# guest_config_push.sh v1.1  (2026-11-18)
#
# OS configuration of this machine -> VCF Operations, written as properties of its object:
#     Custom Configuration|Guest|THP enabled
#     Custom Configuration|Guest|THP defrag
#     Custom Configuration|Guest|khugepaged scan_sleep_millisecs
#     Custom Configuration|Guest|khugepaged pages_to_scan
#     Custom Configuration|Guest|kernel.numa_balancing
#     Custom Configuration|Guest|hugepages 2MB nr_hugepages
#     Custom Configuration|Guest|hugepages 1GB nr_hugepages
#     Custom Configuration|Guest|default_hugepagesz (cmdline)
#     Custom Configuration|Guest|kernel
#     Custom Configuration|Guest|Collected At
# Which object (--target):
#   vm    (default)  this machine is a VM: its VMWARE VirtualMachine object. Nothing is created.
#   bm    [v1.1]     this machine is a bare-metal host: the object that has its name, of any
#                    adapter kind. When Operations has none, the object is created (adapter kind
#                    BareMetalPush, object type BareMetalServer). ops_metric_push.sh --target bm
#                    uses the same object, so its metrics and this configuration are on one object.
#   auto  [v1.1]     vm on a virtual machine, bm on a bare-metal host (one command line for both)
# Run it once before a test (and again after changing a setting). No background process,
# nothing is left running.
# The script is bash. A csh/tcsh login shell is fine: run it as
# "bash guest_config_push.sh" (or chmod +x and ./guest_config_push.sh). Do not "source" it.
#
# Connection settings [v1.1]: ops_local.conf, the file of ops_metric_push.sh (OPS_HOST, OPS_USER,
# OPS_ENC_KEY, OPS_PASS_ENC). Looked for in the folder of this script, then one folder up.
# Another place: --config PATH or env OPS_PUSH_CONFIG. The file is read as text, never executed.
# Order: option > environment variable (OPS_HOST, OPS_USER, OPS_PASSWORD) > config file >
#        values written in this script (USER SETTINGS below; they are empty in Git).
#
# Usage
#   bash guest_config_push.sh                       # VM: collect + write to Operations
#   bash guest_config_push.sh --target bm           # bare-metal host (the object is created when missing)
#   bash guest_config_push.sh --target auto         # VM or bare-metal host, decided on this machine
#   bash guest_config_push.sh --dry-run             # print the values only
#   bash guest_config_push.sh --check               # token, auth scheme, object lookup (creates nothing)
#   bash guest_config_push.sh --name esx01ev01      # object name differs from hostname (--vm is the same)
#   bash guest_config_push.sh --out /tmp/guest_config.csv   # also save key,value csv
# Options: --config F  --ops-host H  --ops-user U  --pass-file F  --insecure | --verify-tls | --cacert F
#          --adapter-kind K  --resource-kind K   kinds of an object that --target bm creates
#          --version
# Needs: curl, openssl, and python3 or /usr/libexec/platform-python or jq (JSON parsing)
# ============================================================

# ==== USER SETTINGS =========================================
# Keep the connection values in ops_local.conf. The four values below are for copies of this
# script that were filled in by hand before v1.1; in Git they stay empty.
OPS_HOST_DEFAULT=""   # VCF Operations address or IP
OPS_USER_DEFAULT=""                      # Operations LOCAL account
OPS_AUTHSOURCE="LOCAL"
OPS_INSECURE_DEFAULT=1                          # 1 = skip TLS verification (-k)
OPS_PASS_ENC=""                                 # openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt -pass pass:<KEY> -base64 -A
OPS_ENC_KEY=""
VM_NAME_DEFAULT=""                              # object name in Operations; "" = hostname -s
PROP_ROOT="Custom Configuration|Guest"
TARGET_DEFAULT="vm"                             # vm | bm | auto   [--target]
# --target bm: kinds of the object that is created when Operations has none with the host's name.
# The same kinds as ops_metric_push.sh, so that both scripts use one object.
BM_ADAPTER_KIND="BareMetalPush"                 # [--adapter-kind]   letters, digits, _ . - only
BM_RESOURCE_KIND="BareMetalServer"              # [--resource-kind]  letters, digits, _ . - only
# ==== end USER SETTINGS =====================================
SCRIPT_VERSION="1.1"
OPS_CONFIG_NAME="ops_local.conf"

set -u
ENV_OPS_HOST="${OPS_HOST:-}"; ENV_OPS_USER="${OPS_USER:-}"
ARG_OPS_HOST=""; ARG_OPS_USER=""; OPS_CONFIG=""
OPS_INSECURE="$OPS_INSECURE_DEFAULT"
OPS_CACERT=""; OPS_VM_NAME="$VM_NAME_DEFAULT"; PASS_FILE=""; DRY_RUN=0; CHECK=0; OUT_CSV=""
TARGET="$TARGET_DEFAULT"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)   DRY_RUN=1 ;;
        --check)     CHECK=1 ;;
        --target)    shift; TARGET="${1:-}" ;;
        --vm|--name) shift; OPS_VM_NAME="${1:-}" ;;
        --config)    shift; OPS_CONFIG="${1:-}" ;;
        --ops-host)  shift; ARG_OPS_HOST="${1:-}" ;;
        --ops-user)  shift; ARG_OPS_USER="${1:-}" ;;
        --pass-file) shift; PASS_FILE="${1:-}" ;;
        --out)       shift; OUT_CSV="${1:-}" ;;
        --adapter-kind)  shift; BM_ADAPTER_KIND="${1:-}" ;;
        --resource-kind) shift; BM_RESOURCE_KIND="${1:-}" ;;
        --insecure)  OPS_INSECURE=1 ;;
        --verify-tls) OPS_INSECURE=0 ;;
        --cacert)    shift; OPS_CACERT="${1:-}"; OPS_INSECURE=0 ;;
        --version)   echo "$SCRIPT_VERSION"; exit 0 ;;
        -h|--help)   sed -n '8,50p' "$0"; exit 0 ;;
        *) echo "[ERROR] unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done
case "$TARGET" in
    vm|bm|auto) ;;
    *) echo "[ERROR] --target must be one of: vm | bm | auto" >&2; exit 1 ;;
esac
for k in "$BM_ADAPTER_KIND" "$BM_RESOURCE_KIND"; do
    case "$k" in
        ""|*[!A-Za-z0-9_.-]*) echo "[ERROR] --adapter-kind and --resource-kind: letters, digits, _ . - only" >&2; exit 1 ;;
    esac
done
[ -z "$OPS_VM_NAME" ] && OPS_VM_NAME=$(hostname -s 2>/dev/null || hostname)

# /sys and /proc are read below this folder when GCP_ROOT is set (local tests only).
SYS_ROOT="${GCP_ROOT:-}"

# --target auto: a virtual machine or a bare-metal host. The DMI strings name the platform of a
# VM (VMware and other hypervisors); the CPU flag "hypervisor" is set inside a VM.
is_virtual() {
    local f v
    for f in "$SYS_ROOT/sys/class/dmi/id/sys_vendor" "$SYS_ROOT/sys/class/dmi/id/product_name"; do
        [ -r "$f" ] || continue
        v=$(tr -d '\n' < "$f" 2>/dev/null)
        case "$v" in
            *VMware*|*QEMU*|*KVM*|*Xen*|*VirtualBox*|*"Virtual Machine"*) return 0 ;;
        esac
    done
    grep -q '^flags.* hypervisor' "$SYS_ROOT/proc/cpuinfo" 2>/dev/null && return 0
    return 1
}
TARGET_NOTE=""
if [ "$TARGET" = "auto" ]; then
    if is_virtual; then TARGET="vm"; TARGET_NOTE=" (auto: this machine is a virtual machine)"
    else TARGET="bm"; TARGET_NOTE=" (auto: this machine is not a virtual machine)"; fi
fi

# ---------------- collect ----------------
bracket() {   # "[always] madvise never" -> always
    sed -n 's/.*\[\([^]]*\)\].*/\1/p' "$1" 2>/dev/null | head -1
}
readf() { [ -r "$1" ] && tr -d '\n' < "$1" 2>/dev/null || echo "(없음)"; }
THP_DIR=$SYS_ROOT/sys/kernel/mm/transparent_hugepage
val_thp_enabled=$(bracket $THP_DIR/enabled); [ -z "$val_thp_enabled" ] && val_thp_enabled="(없음)"
val_thp_defrag=$(bracket $THP_DIR/defrag);   [ -z "$val_thp_defrag" ] && val_thp_defrag="(없음)"
val_kh_sleep=$(readf $THP_DIR/khugepaged/scan_sleep_millisecs)
val_kh_pages=$(readf $THP_DIR/khugepaged/pages_to_scan)
if [ -n "$SYS_ROOT" ]; then val_numa_bal=$(readf "$SYS_ROOT/proc/sys/kernel/numa_balancing")
else val_numa_bal=$(sysctl -n kernel.numa_balancing 2>/dev/null); fi
[ -z "$val_numa_bal" ] && val_numa_bal="(없음)"
val_hp_2m=$(readf $SYS_ROOT/sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages)
val_hp_1g=$(readf $SYS_ROOT/sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages)
val_def_hp=$(grep -o 'default_hugepagesz=[^ ]*' $SYS_ROOT/proc/cmdline 2>/dev/null | head -1 | cut -d= -f2); [ -z "$val_def_hp" ] && val_def_hp="(없음)"
val_kernel=$(uname -r)
val_time=$(date '+%Y-%m-%d %H:%M:%S %Z')

KEYS=("THP enabled" "THP defrag" "khugepaged scan_sleep_millisecs" "khugepaged pages_to_scan" "kernel.numa_balancing" "hugepages 2MB nr_hugepages" "hugepages 1GB nr_hugepages" "default_hugepagesz (cmdline)" "kernel" "Collected At")
VALS=("$val_thp_enabled" "$val_thp_defrag" "$val_kh_sleep" "$val_kh_pages" "$val_numa_bal" "$val_hp_2m" "$val_hp_1g" "$val_def_hp" "$val_kernel" "$val_time")

echo "[guest_config_push] v${SCRIPT_VERSION}  target: ${TARGET}${TARGET_NOTE}   object: ${OPS_VM_NAME}   host: $(hostname -f 2>/dev/null || hostname)"
i=0
while [ $i -lt ${#KEYS[@]} ]; do
    printf '  %-34s = %s\n' "${KEYS[$i]}" "${VALS[$i]}"
    i=$((i+1))
done
if [ -n "$OUT_CSV" ]; then
    { printf '\xEF\xBB\xBF'; echo "key,value"; i=0; while [ $i -lt ${#KEYS[@]} ]; do echo "\"${KEYS[$i]}\",\"${VALS[$i]}\""; i=$((i+1)); done; } > "$OUT_CSV"
    echo "[guest_config_push] csv saved: $OUT_CSV"
fi
[ "$DRY_RUN" -eq 1 ] && { echo "[guest_config_push] dry-run: nothing written to Operations"; exit 0; }

# ---------------- connection settings ----------------
# Config file (KEY=VALUE lines). Read as text, never executed. The same file and the same
# reading as ops_metric_push.sh.
CFG_OPS_HOST=""; CFG_OPS_USER=""; CFG_PASS_ENC=""; CFG_ENC_KEY=""; CONFIG_STATE="not found"
read_config() {   # $1 = file -> CFG_OPS_HOST CFG_OPS_USER CFG_PASS_ENC CFG_ENC_KEY, CONFIG_STATE
    local line key val first=1
    CONFIG_STATE="not found"
    [ -f "$1" ] || return 0
    CONFIG_STATE="not readable"
    [ -r "$1" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$first" -eq 1 ]; then line="${line#$'\xef\xbb\xbf'}"; first=0; fi   # UTF-8 mark some Windows editors write
        line="${line%$'\r'}"                                                     # CR+LF line ends
        case "$line" in *=*) ;; *) continue ;; esac
        key="${line%%=*}"; val="${line#*=}"
        key="${key#"${key%%[![:space:]]*}"}"; key="${key%"${key##*[![:space:]]}"}"
        case "$key" in \#*) continue ;; esac
        key="${key#export }"
        val="${val#"${val%%[![:space:]]*}"}"
        case "$val" in
            \"*) val="${val#\"}"; val="${val%\"*}" ;;
            \'*) val="${val#\'}"; val="${val%\'*}" ;;
            *)   val="${val%%[[:space:]]#*}"; val="${val%"${val##*[![:space:]]}"}" ;;
        esac
        case "$key" in
            OPS_HOST)     CFG_OPS_HOST="$val" ;;
            OPS_USER)     CFG_OPS_USER="$val" ;;
            OPS_PASS_ENC) CFG_PASS_ENC="$val" ;;
            OPS_ENC_KEY)  CFG_ENC_KEY="$val" ;;
        esac
    done < "$1"
    CONFIG_STATE="read"
    return 0
}
if [ -z "$OPS_CONFIG" ]; then
    if [ -n "${OPS_PUSH_CONFIG:-}" ]; then OPS_CONFIG="$OPS_PUSH_CONFIG"
    elif [ -f "$SCRIPT_DIR/$OPS_CONFIG_NAME" ]; then OPS_CONFIG="$SCRIPT_DIR/$OPS_CONFIG_NAME"
    elif [ -f "$SCRIPT_DIR/../$OPS_CONFIG_NAME" ]; then OPS_CONFIG="$SCRIPT_DIR/../$OPS_CONFIG_NAME"
    else OPS_CONFIG="$SCRIPT_DIR/$OPS_CONFIG_NAME"; fi
fi
read_config "$OPS_CONFIG"
OPS_HOST="${ARG_OPS_HOST:-${ENV_OPS_HOST:-${CFG_OPS_HOST:-$OPS_HOST_DEFAULT}}}"
OPS_USER="${ARG_OPS_USER:-${ENV_OPS_USER:-${CFG_OPS_USER:-$OPS_USER_DEFAULT}}}"
[ -z "$OPS_HOST" ] && { echo "[ERROR] no Operations address: OPS_HOST is empty in ${OPS_CONFIG} [${CONFIG_STATE}]. Fill in ops_local.conf (or --ops-host, env OPS_HOST)" >&2; exit 1; }
[ -z "$OPS_USER" ] && { echo "[ERROR] no Operations account: OPS_USER is empty in ${OPS_CONFIG} [${CONFIG_STATE}]. Fill in ops_local.conf (or --ops-user, env OPS_USER)" >&2; exit 1; }

# ---------------- Operations ----------------
command -v curl >/dev/null 2>&1 || { echo "[ERROR] curl not found" >&2; exit 1; }
JSON_PY=""
for c in python3 /usr/libexec/platform-python python; do command -v "$c" >/dev/null 2>&1 && { JSON_PY="$c"; break; }; done
JSON_JQ=""; command -v jq >/dev/null 2>&1 && JSON_JQ="jq"
[ -z "$JSON_PY" ] && [ -z "$JSON_JQ" ] && { echo "[ERROR] need python3, /usr/libexec/platform-python or jq for JSON parsing" >&2; exit 1; }

json_token() {   # stdin json -> token
    if [ -n "$JSON_PY" ]; then "$JSON_PY" -c 'import sys,json
try: print(json.load(sys.stdin).get("token",""))
except Exception: print("")'
    else jq -r '.token // ""'; fi
}
json_identifier() {   # stdin json object -> its identifier
    if [ -n "$JSON_PY" ]; then "$JSON_PY" -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: d={}
print((d.get("identifier") or "") if isinstance(d,dict) else "")'
    else jq -r 'if type=="object" then (.identifier // "") else "" end'; fi
}
json_resource_id() {   # stdin resources json, $1 name -> identifier of exact name match
    if [ -n "$JSON_PY" ]; then "$JSON_PY" -c 'import sys,json
name=sys.argv[1].lower()
try: rl=json.load(sys.stdin).get("resourceList") or []
except Exception: rl=[]
hit=[r for r in rl if ((r.get("resourceKey") or {}).get("name") or "").lower()==name]
print(hit[0].get("identifier","") if hit else "")' "$1"
    else jq -r --arg n "$1" '[.resourceList[]? | select((.resourceKey.name|ascii_downcase)==($n|ascii_downcase))][0].identifier // ""'; fi
}
# stdin resources json, $1 name, $2 push adapter kind -> "id|object type|adapter kind|count" of the object
# with that name. An object that another adapter collects is preferred over one of the push adapter kind.
# "ERR" = the answer is not a resource list.
json_pick_object() {
    if [ -n "$JSON_PY" ]; then "$JSON_PY" -c 'import sys,json
name,push=sys.argv[1],sys.argv[2]
try: d=json.load(sys.stdin)
except Exception: print("ERR"); sys.exit(0)
if not isinstance(d,dict): print("ERR"); sys.exit(0)
rl=d.get("resourceList") or []
def rk(r): return r.get("resourceKey") or {}
def nm(r): return rk(r).get("name") or ""
ex=[r for r in rl if nm(r)==name]
if not ex: ex=[r for r in rl if nm(r).lower()==name.lower()]
real=[r for r in ex if (rk(r).get("adapterKindKey") or "")!=push]
pick=(real or ex)[:1]
if pick:
    r=pick[0]
    print("%s|%s|%s|%d"%(r.get("identifier",""), rk(r).get("resourceKindKey") or "", rk(r).get("adapterKindKey") or "", len(ex)))
else: print("|||0")' "$1" "$2"
    else jq -r --arg n "$1" --arg p "$2" '
        if type!="object" then "ERR" else
        (.resourceList//[]) as $rl
        |([$rl[]|select(.resourceKey.name==$n)]) as $e
        |(if ($e|length)>0 then $e
          else [$rl[]|select((.resourceKey.name|ascii_downcase)==($n|ascii_downcase))] end) as $ex
        |([$ex[]|select((.resourceKey.adapterKindKey//"")!=$p)]) as $real
        |(if ($real|length)>0 then $real[0] else ($ex[0]//null) end) as $r
        |"\(($r.identifier)//"")|\(($r.resourceKey.resourceKindKey)//"")|\(($r.resourceKey.adapterKindKey)//"")|\($ex|length)"
        end'; fi
}
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

ops_password() {
    if [ -n "${OPS_PASSWORD:-}" ]; then printf '%s' "$OPS_PASSWORD"; return 0; fi
    if [ -n "$PASS_FILE" ]; then head -1 "$PASS_FILE"; return 0; fi
    local enc="${CFG_PASS_ENC:-$OPS_PASS_ENC}" key="${CFG_ENC_KEY:-$OPS_ENC_KEY}" f
    if [ -z "$enc" ] || [ -z "$key" ]; then
        # copies made before v1.1: an ops_metric_push_v4*.sh in the same folder that holds the two values
        for f in "$SCRIPT_DIR"/ops_metric_push_v4*.sh "$SCRIPT_DIR"/ops_metric_push_v4*.txt; do
            [ -f "$f" ] || continue
            enc=$(sed -n 's/^OPS_PASS_ENC="\([^"]*\)".*/\1/p' "$f" | head -1)
            key=$(sed -n 's/^OPS_ENC_KEY="\([^"]*\)".*/\1/p' "$f" | head -1)
            [ -n "$enc" ] && [ -n "$key" ] && break
        done
    fi
    { [ -z "$enc" ] || [ -z "$key" ]; } && return 1
    printf '%s' "$enc" | openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 -pass "pass:${key}" -base64 -A 2>/dev/null
}

OPS_PW=$(ops_password) || true
[ -z "$OPS_PW" ] && { echo "[ERROR] no Operations password: OPS_PASS_ENC or OPS_ENC_KEY is empty in ${OPS_CONFIG} [${CONFIG_STATE}] (or --pass-file, env OPS_PASSWORD)" >&2; exit 1; }
if [ "$OPS_INSECURE" -eq 1 ]; then CURL_TLS="-k"; elif [ -n "$OPS_CACERT" ]; then CURL_TLS="--cacert $OPS_CACERT"; else CURL_TLS=""; fi
case "$OPS_HOST" in
    http://*|https://*) OPS_BASE="${OPS_HOST%/}" ;;
    *)                  OPS_BASE="https://${OPS_HOST}" ;;
esac
RESP_FILE=$(mktemp 2>/dev/null || echo "/tmp/guest_config_push_$$.resp")
trap 'rm -f "$RESP_FILE"' EXIT

resp=$(curl -s $CURL_TLS --max-time 15 -X POST "${OPS_BASE}/suite-api/api/auth/token/acquire" \
      -H 'Content-Type: application/json' -H 'Accept: application/json' \
      -d "{\"username\":\"$(json_escape "$OPS_USER")\",\"password\":\"$(json_escape "$OPS_PW")\",\"authSource\":\"${OPS_AUTHSOURCE}\"}" 2>&1)
OPS_TOKEN=$(printf '%s' "$resp" | json_token)
[ -z "$OPS_TOKEN" ] && { echo "[ERROR] token acquisition failed: $(printf '%s' "$resp" | head -c 200)" >&2; exit 1; }
AUTH_SCHEME=""
for s in OpsToken vRealizeOpsToken; do
    code=$(curl -s $CURL_TLS -o /dev/null -w '%{http_code}' --max-time 15 -G "${OPS_BASE}/suite-api/api/resources" \
           --data-urlencode "pageSize=1" --data-urlencode "_no_links=true" -H "Authorization: ${s} ${OPS_TOKEN}" -H 'Accept: application/json' 2>/dev/null)
    [ "$code" = "200" ] && { AUTH_SCHEME="$s"; break; }
done
[ -z "$AUTH_SCHEME" ] && { echo "[ERROR] auth header rejected (OpsToken/vRealizeOpsToken)" >&2; exit 1; }

# ---------------- the object ----------------
RID=""; FOUND_KIND=""; FOUND_ADAPTER=""; PUSH_KIND=""; OBJ_CREATED=0; TARGET_DESC=""

lookup_vm() {     # 0 = RID set
    resp=$(curl -s $CURL_TLS --max-time 20 -G "${OPS_BASE}/suite-api/api/resources" \
          --data-urlencode "adapterKindKey=VMWARE" --data-urlencode "resourceKind=VirtualMachine" \
          --data-urlencode "name=${OPS_VM_NAME}" --data-urlencode "_no_links=true" \
          -H "Authorization: ${AUTH_SCHEME} ${OPS_TOKEN}" -H 'Accept: application/json' 2>&1)
    RID=$(printf '%s' "$resp" | json_resource_id "$OPS_VM_NAME")
    [ -n "$RID" ]
}
# --target bm: find the object of this host among every adapter kind.
#   0 = found (RID, FOUND_KIND, FOUND_ADAPTER set)   1 = Operations answered and has no object with that name
#   2 = the lookup itself failed (nothing may be created on that basis)
lookup_bm() {
    local parsed rest cnt
    code=$(curl -s $CURL_TLS -o "$RESP_FILE" -w '%{http_code}' --max-time 20 -G "${OPS_BASE}/suite-api/api/resources" \
          --data-urlencode "name=${OPS_VM_NAME}" --data-urlencode "_no_links=true" \
          -H "Authorization: ${AUTH_SCHEME} ${OPS_TOKEN}" -H 'Accept: application/json' 2>/dev/null)
    if [ "$code" != "200" ]; then
        echo "[ERROR] object lookup failed [HTTP ${code}]: $(head -c 200 "$RESP_FILE" 2>/dev/null)" >&2
        return 2
    fi
    parsed=$(json_pick_object "$OPS_VM_NAME" "$BM_ADAPTER_KIND" < "$RESP_FILE" 2>/dev/null)
    case "$parsed" in
        ''|ERR) echo "[ERROR] object lookup: the answer of Operations could not be read: $(head -c 200 "$RESP_FILE" 2>/dev/null)" >&2; return 2 ;;
    esac
    RID="${parsed%%|*}"
    rest="${parsed#*|}"; FOUND_KIND="${rest%%|*}"
    rest="${rest#*|}";   FOUND_ADAPTER="${rest%%|*}"
    cnt="${rest##*|}"
    [ -z "$RID" ] && return 1
    [ -n "$cnt" ] && [ "$cnt" -gt 1 ] 2>/dev/null && \
        echo "[WARN] ${cnt} objects share the name '${OPS_VM_NAME}' -> using ${FOUND_KIND} of ${FOUND_ADAPTER}" >&2
    return 0
}
# --target bm: create the object of this host. Operations creates the push adapter kind and the object
# type when they do not exist yet (suite-api: POST /api/resources/adapterkinds/{adapterKindKey}).
create_bm_object() {
    local body id n a k
    n=$(json_escape "$OPS_VM_NAME"); a=$(json_escape "$BM_ADAPTER_KIND"); k=$(json_escape "$BM_RESOURCE_KIND")
    body=$(printf '{"description":"bare-metal host, object created by a metric push script","resourceKey":{"name":"%s","adapterKindKey":"%s","resourceKindKey":"%s"},"resourceStatusStates":[]}' "$n" "$a" "$k")
    code=$(curl -s $CURL_TLS -o "$RESP_FILE" -w '%{http_code}' --max-time 30 \
          -X POST "${OPS_BASE}/suite-api/api/resources/adapterkinds/${BM_ADAPTER_KIND}" \
          -H "Authorization: ${AUTH_SCHEME} ${OPS_TOKEN}" \
          -H 'Content-Type: application/json' -H 'Accept: application/json' -d "$body" 2>/dev/null)
    id=""
    case "$code" in 200|201) id=$(json_identifier < "$RESP_FILE" 2>/dev/null) ;; esac
    if [ -z "$id" ]; then
        echo "[ERROR] the Operations object '${OPS_VM_NAME}' could not be created [HTTP ${code}, ${BM_ADAPTER_KIND} / ${BM_RESOURCE_KIND}]" >&2
        echo "        Answer of Operations: $(head -c 300 "$RESP_FILE" 2>/dev/null)" >&2
        return 1
    fi
    RID="$id"; FOUND_KIND="$BM_RESOURCE_KIND"; FOUND_ADAPTER="$BM_ADAPTER_KIND"; OBJ_CREATED=1
    return 0
}
# --target bm: an existing object of any adapter kind, else create one. PUSH_KIND is set when the object
# belongs to the push adapter kind: its properties are then written through that kind.
resolve_bm() {
    local rc
    lookup_bm; rc=$?
    [ "$rc" -eq 2 ] && return 1
    if [ "$rc" -ne 0 ]; then
        if [ "$CHECK" -eq 1 ]; then
            TARGET_DESC="no object named '${OPS_VM_NAME}' yet. The first run creates it: ${BM_RESOURCE_KIND} of ${BM_ADAPTER_KIND}"
            return 0
        fi
        if ! create_bm_object; then
            # the object may exist already although the search did not show it: look once more
            lookup_bm; rc=$?
            if [ "$rc" -ne 0 ]; then
                echo "        Check that the account may create objects in Operations." >&2
                return 1
            fi
        fi
    fi
    if [ "$FOUND_ADAPTER" = "$BM_ADAPTER_KIND" ]; then
        PUSH_KIND="$BM_ADAPTER_KIND"
        if [ "$OBJ_CREATED" -eq 1 ]; then TARGET_DESC="${FOUND_KIND} of ${FOUND_ADAPTER}, created now"
        else TARGET_DESC="${FOUND_KIND} of ${FOUND_ADAPTER}, created by an earlier run"; fi
    else
        PUSH_KIND=""
        TARGET_DESC="${FOUND_KIND:-kind unknown} of ${FOUND_ADAPTER:-adapter unknown}, existing object"
    fi
    return 0
}

if [ "$TARGET" = "bm" ]; then
    resolve_bm || exit 1
else
    if ! lookup_vm; then
        echo "[ERROR] VirtualMachine '${OPS_VM_NAME}' not found in Operations (use --name <name as shown in Operations>)" >&2
        echo "        A bare-metal host: --target bm (the object is created when Operations has none)." >&2
        exit 1
    fi
    TARGET_DESC="VirtualMachine"
fi
if [ "$CHECK" -eq 1 ]; then
    if [ -n "$RID" ]; then echo "[CHECK] token ok (${AUTH_SCHEME}), target ${TARGET}, ${OPS_VM_NAME} -> ${RID} [${TARGET_DESC}], RESULT: ready"
    else echo "[CHECK] token ok (${AUTH_SCHEME}), target ${TARGET}, ${TARGET_DESC}, RESULT: ready"; fi
    exit 0
fi

# ---------------- write the properties ----------------
TS=$(( $(date +%s) * 1000 ))
BODY='{"property-content":['
i=0
while [ $i -lt ${#KEYS[@]} ]; do
    [ $i -gt 0 ] && BODY="${BODY},"
    BODY="${BODY}{\"statKey\":\"$(json_escape "${PROP_ROOT}|${KEYS[$i]}")\",\"timestamps\":[${TS}],\"values\":[\"$(json_escape "${VALS[$i]}")\"]}"
    i=$((i+1))
done
BODY="${BODY}]}"
code=$(curl -s $CURL_TLS -o "$RESP_FILE" -w '%{http_code}' --max-time 30 \
       -X POST "${OPS_BASE}/suite-api/api/resources/${RID}/properties${PUSH_KIND:+/adapterkinds/${PUSH_KIND}}" \
       -H "Authorization: ${AUTH_SCHEME} ${OPS_TOKEN}" -H 'Content-Type: application/json' -H 'Accept: application/json' \
       -d "$BODY" 2>/dev/null)
case "$code" in
    200|201|204) echo "[OPS] ${OPS_VM_NAME} Guest properties ${#KEYS[@]} recorded ${val_time} [${TARGET_DESC}]"; exit 0 ;;
    *) echo "[ERROR] property write failed HTTP ${code}: $(head -c 200 "$RESP_FILE" 2>/dev/null)" >&2; exit 1 ;;
esac
