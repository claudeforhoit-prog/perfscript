#!/bin/bash
# --- csh/tcsh guard: the three lines below do nothing in bash. ---
# "csh guest_config_push.sh ..." re-executes itself with bash; "source guest_config_push.sh" in csh prints a hint and stops.
test "$?BASH_VERSION" = "0" && test -f "$0" && exec /bin/bash "$0" $argv:q
test "$?BASH_VERSION" = "0" && echo "guest_config_push.sh: do not source it. Run:  bash guest_config_push.sh [options]"
if false; then :; fi
# ============================================================
# guest_config_push.sh v1.0  (2026-10-19)
#
# Guest OS configuration snapshot -> VCF Operations, written as properties
# on this VM's VirtualMachine object:
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
# Run it once inside the guest before a test (and again after changing a
# setting). No background process, nothing is left running.
# The script is bash. A csh/tcsh login shell is fine: run it as
# "bash guest_config_push.sh" (or chmod +x and ./guest_config_push.sh). Do not "source" it.
#
# Credentials: same scheme as ops_metric_push_v4_1.sh (OPS_PASS_ENC + OPS_ENC_KEY,
# decrypted with openssl). Both empty -> read from an ops_metric_push_v4*.sh in
# the same directory. Alternatives: --pass-file FILE, env OPS_PASSWORD
#   (bash: export OPS_PASSWORD='...'   csh/tcsh: setenv OPS_PASSWORD '...').
#
# Usage
#   bash guest_config_push.sh                 # collect + write to Operations
#   bash guest_config_push.sh --dry-run       # print the values only
#   bash guest_config_push.sh --check         # token, auth scheme, VM object lookup
#   bash guest_config_push.sh --vm esx01ev01   # VM object name differs from hostname
#   bash guest_config_push.sh --out /tmp/guest_config.csv   # also save key,value csv
# Options: --ops-host H  --ops-user U  --pass-file F  --insecure | --verify-tls | --cacert F
# Needs: curl, openssl, and python3 or /usr/libexec/platform-python or jq (JSON parsing)
# ============================================================

# ==== USER SETTINGS - edit here only ========================
OPS_HOST_DEFAULT=""   # VCF Operations address or IP
OPS_USER_DEFAULT=""                      # Operations LOCAL account
OPS_AUTHSOURCE="LOCAL"
OPS_INSECURE_DEFAULT=1                          # 1 = skip TLS verification (-k)
OPS_PASS_ENC=""                                 # openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt -pass pass:<KEY> -base64 -A
OPS_ENC_KEY=""
VM_NAME_DEFAULT=""                              # VirtualMachine object name in Operations; "" = hostname -s
PROP_ROOT="Custom Configuration|Guest"
# ==== end USER SETTINGS =====================================

set -u
OPS_HOST="$OPS_HOST_DEFAULT"; OPS_USER="$OPS_USER_DEFAULT"; OPS_INSECURE="$OPS_INSECURE_DEFAULT"
OPS_CACERT=""; OPS_VM_NAME="$VM_NAME_DEFAULT"; PASS_FILE=""; DRY_RUN=0; CHECK=0; OUT_CSV=""
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)   DRY_RUN=1 ;;
        --check)     CHECK=1 ;;
        --vm)        shift; OPS_VM_NAME="${1:-}" ;;
        --ops-host)  shift; OPS_HOST="${1:-}" ;;
        --ops-user)  shift; OPS_USER="${1:-}" ;;
        --pass-file) shift; PASS_FILE="${1:-}" ;;
        --out)       shift; OUT_CSV="${1:-}" ;;
        --insecure)  OPS_INSECURE=1 ;;
        --verify-tls) OPS_INSECURE=0 ;;
        --cacert)    shift; OPS_CACERT="${1:-}"; OPS_INSECURE=0 ;;
        -h|--help)   sed -n '2,32p' "$0"; exit 0 ;;
        *) echo "[ERROR] unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done
[ -z "$OPS_VM_NAME" ] && OPS_VM_NAME=$(hostname -s 2>/dev/null || hostname)

# ---------------- collect ----------------
bracket() {   # "[always] madvise never" -> always
    sed -n 's/.*\[\([^]]*\)\].*/\1/p' "$1" 2>/dev/null | head -1
}
readf() { [ -r "$1" ] && tr -d '\n' < "$1" 2>/dev/null || echo "(없음)"; }
THP_DIR=/sys/kernel/mm/transparent_hugepage
val_thp_enabled=$(bracket $THP_DIR/enabled); [ -z "$val_thp_enabled" ] && val_thp_enabled="(없음)"
val_thp_defrag=$(bracket $THP_DIR/defrag);   [ -z "$val_thp_defrag" ] && val_thp_defrag="(없음)"
val_kh_sleep=$(readf $THP_DIR/khugepaged/scan_sleep_millisecs)
val_kh_pages=$(readf $THP_DIR/khugepaged/pages_to_scan)
val_numa_bal=$(sysctl -n kernel.numa_balancing 2>/dev/null); [ -z "$val_numa_bal" ] && val_numa_bal="(없음)"
val_hp_2m=$(readf /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages)
val_hp_1g=$(readf /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages)
val_def_hp=$(grep -o 'default_hugepagesz=[^ ]*' /proc/cmdline 2>/dev/null | head -1 | cut -d= -f2); [ -z "$val_def_hp" ] && val_def_hp="(없음)"
val_kernel=$(uname -r)
val_time=$(date '+%Y-%m-%d %H:%M:%S %Z')

KEYS=("THP enabled" "THP defrag" "khugepaged scan_sleep_millisecs" "khugepaged pages_to_scan" "kernel.numa_balancing" "hugepages 2MB nr_hugepages" "hugepages 1GB nr_hugepages" "default_hugepagesz (cmdline)" "kernel" "Collected At")
VALS=("$val_thp_enabled" "$val_thp_defrag" "$val_kh_sleep" "$val_kh_pages" "$val_numa_bal" "$val_hp_2m" "$val_hp_1g" "$val_def_hp" "$val_kernel" "$val_time")

echo "[guest_config_push] VM object: ${OPS_VM_NAME}   host: $(hostname -f 2>/dev/null || hostname)"
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
json_resource_id() {   # stdin resources json, $1 name -> identifier of exact name match
    if [ -n "$JSON_PY" ]; then "$JSON_PY" -c 'import sys,json
name=sys.argv[1].lower()
try: rl=json.load(sys.stdin).get("resourceList") or []
except Exception: rl=[]
hit=[r for r in rl if ((r.get("resourceKey") or {}).get("name") or "").lower()==name]
print(hit[0].get("identifier","") if hit else "")' "$1"
    else jq -r --arg n "$1" '[.resourceList[]? | select((.resourceKey.name|ascii_downcase)==($n|ascii_downcase))][0].identifier // ""'; fi
}
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

ops_password() {
    if [ -n "${OPS_PASSWORD:-}" ]; then printf '%s' "$OPS_PASSWORD"; return 0; fi
    if [ -n "$PASS_FILE" ]; then head -1 "$PASS_FILE"; return 0; fi
    local enc="$OPS_PASS_ENC" key="$OPS_ENC_KEY" f
    if [ -z "$enc" ] || [ -z "$key" ]; then
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
[ -z "$OPS_PW" ] && { echo "[ERROR] no Operations password (OPS_PASS_ENC/OPS_ENC_KEY, --pass-file or env OPS_PASSWORD)" >&2; exit 1; }
if [ "$OPS_INSECURE" -eq 1 ]; then CURL_TLS="-k"; elif [ -n "$OPS_CACERT" ]; then CURL_TLS="--cacert $OPS_CACERT"; else CURL_TLS=""; fi
OPS_BASE="https://${OPS_HOST}"

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
resp=$(curl -s $CURL_TLS --max-time 20 -G "${OPS_BASE}/suite-api/api/resources" \
      --data-urlencode "adapterKindKey=VMWARE" --data-urlencode "resourceKind=VirtualMachine" \
      --data-urlencode "name=${OPS_VM_NAME}" --data-urlencode "_no_links=true" \
      -H "Authorization: ${AUTH_SCHEME} ${OPS_TOKEN}" -H 'Accept: application/json' 2>&1)
RID=$(printf '%s' "$resp" | json_resource_id "$OPS_VM_NAME")
[ -z "$RID" ] && { echo "[ERROR] VirtualMachine '${OPS_VM_NAME}' not found in Operations (use --vm <name as shown in Operations>)" >&2; exit 1; }
if [ "$CHECK" -eq 1 ]; then
    echo "[CHECK] token ok (${AUTH_SCHEME}), VirtualMachine ${OPS_VM_NAME} -> ${RID}, RESULT: ready"
    exit 0
fi

TS=$(( $(date +%s) * 1000 ))
BODY='{"property-content":['
i=0
while [ $i -lt ${#KEYS[@]} ]; do
    [ $i -gt 0 ] && BODY="${BODY},"
    BODY="${BODY}{\"statKey\":\"$(json_escape "${PROP_ROOT}|${KEYS[$i]}")\",\"timestamps\":[${TS}],\"values\":[\"$(json_escape "${VALS[$i]}")\"]}"
    i=$((i+1))
done
BODY="${BODY}]}"
code=$(curl -s $CURL_TLS -o /tmp/guest_config_push.resp -w '%{http_code}' --max-time 30 \
       -X POST "${OPS_BASE}/suite-api/api/resources/${RID}/properties" \
       -H "Authorization: ${AUTH_SCHEME} ${OPS_TOKEN}" -H 'Content-Type: application/json' -H 'Accept: application/json' \
       -d "$BODY" 2>/dev/null)
case "$code" in
    200|201|204) echo "[OPS] ${OPS_VM_NAME} Guest properties ${#KEYS[@]} recorded ${val_time}"; rm -f /tmp/guest_config_push.resp; exit 0 ;;
    *) echo "[ERROR] property write failed HTTP ${code}: $(head -c 200 /tmp/guest_config_push.resp 2>/dev/null)" >&2; exit 1 ;;
esac
