#!/bin/bash
# --- csh/tcsh guard: the three lines below do nothing in bash. ---
# "csh gpu_metric_push.sh ..." re-executes itself with bash; "source gpu_metric_push.sh" in csh prints a hint and stops.
test "$?BASH_VERSION" = "0" && test -f "$0" && exec /bin/bash "$0" $argv:q
test "$?BASH_VERSION" = "0" && echo "gpu_metric_push.sh: do not source it. Run:  bash gpu_metric_push.sh [options]"
if false; then :; fi
# ============================================================
# gpu_metric_push.sh  v1.1 (2026-11-12)  English
#
# v1.1: connection settings moved out of the script
#   The Operations address, the account, the encrypted password and its key
#   are read from ops_local.conf in the folder of this script (--config PATH
#   or env OPS_PUSH_CONFIG for another place). The script holds no address
#   and no credential, so it can be kept in Git; Git holds ops_local.conf with the
#   keys only. The file name no longer carries the version: the banner shows it.
#   Collection is as in v1.0.
#
# NVIDIA GPU metrics from inside a VM that owns its GPU(s) through
# DirectPath I/O (PCI passthrough) -> VCF Operations, a local CSV, or both.
# The ESXi host cannot see a passthrough GPU (host-side nvidia-smi does not
# list it), so the values are read in the guest with nvidia-smi and pushed
# to this VM's VirtualMachine object.
#
#   --mode ops   (default)  push to VCF Operations only
#   --mode file             write a local CSV only, no Ops connection
#   --mode both             push and write the CSV at the same time
#
# Sampling  [--interval 60, default]
#   3 samples per minute, at second 00, 20 and 40 (the 20-second step of the
#   vCenter real-time statistics). One value per metric is pushed per minute,
#   stamped with second 00 of that minute:
#     avg   gauges: utilization, memory, temperature, power, clocks, PCIe rate
#     pct   on/off states: clock event reasons, query success. Share of the
#           3 samples in which the state was on, in percent (0, 33.33, 66.67, 100)
#     last  counters and settings: ECC, retired pages, remapped rows,
#           P-state, PCIe link generation and width, enforced power limit
#   Change the rule per metric in the METRIC TABLE below.
#   No CPU PMU is used, so it runs next to ops_metric_push without counter
#   contention. nvidia-smi runs 2 times per sample plus 2 times per minute.
#
# Ops tree
#   <VM> > Custom Metrics > Guest GPU > gpu0 > Util_Gpu_Pct / Temp_Gpu_C / ...
#                                     > GPU_Count / Query_OK_Pct      (VM level)
#   <VM> > Custom Configuration > Guest GPU > gpu0 > Name / UUID / ...
#          (properties, written once at start)
#   gpuN is the nvidia-smi index. Bus id and UUID are recorded as properties.
#   Units are part of the metric name (_Pct %, _MiB, _C, _W, _MHz, _MBps), as
#   the suite-api stats push has no unit attribute.
#
# Field handling (checked against an H100 80GB HBM3 in pass-through mode)
#   * Fields the installed driver does not know are dropped at start and
#     listed in the banner. Older drivers name clock event reasons
#     clocks_throttle_reasons.*; the script switches to that name by itself.
#   * Values reported as [N/A] or [Not Supported] are skipped, never sent as 0.
#     H100: Retired Pages are N/A (row remapping replaced page retirement),
#     Fan Speed is N/A, utilization is N/A while MIG mode is enabled.
#   * temperature.gpu.tlimit (Temp_TLimit_C) is the margin in C to the maximum
#     operating temperature. It counts down; 0 or lower means the GPU may
#     lower its clocks. On H100 the slowdown and shutdown thresholds use the
#     same T.Limit scale (about -2 C and -5 to -8 C) and are recorded as
#     properties "Slowdown Temp" / "Shutdown Temp".
#   * power.draw is the board power averaged over 1 second.
#
# Requirements
#   bash 3.2+, nvidia-smi (NVIDIA datacenter driver in the guest).
#   Ops modes: curl, python3 or jq, openssl (encrypted password).
#   No root. nvidia-smi must run under the account that starts the collector.
#
# How to run
#   1) Put ops_local.conf beside this script and fill in its four keys:
#      OPS_HOST, OPS_USER, OPS_ENC_KEY, OPS_PASS_ENC
#      (bash gpu_metric_push.sh --encrypt prints the OPS_PASS_ENC line).
#      chmod 600 ops_local.conf. Not needed for --mode file and --check.
#   2) See what this GPU and driver return. No Ops, no waiting:
#        bash gpu_metric_push.sh --check
#   3) Start in the background:
#        nohup bash gpu_metric_push.sh --vm <VM name in Ops> > /tmp/gpu_metric_push.log 2>&1 &
#        nohup bash gpu_metric_push.sh --mode both --out /data/gpu > /tmp/gpu_metric_push.log 2>&1 &
#   4) Stop:
#        bash gpu_metric_push.sh --stop
#
# [Account] Only Ops LOCAL accounts work. SSO/VIDB accounts cannot get
#   tokens through this API.
# ============================================================

set -u
export LC_ALL=C

# ==========================================================
# * Connection settings *  kept in a config file, not in this script
# ----------------------------------------------------------
# File   : ops_local.conf in the folder of this script
#          (another place: --config PATH, or env OPS_PUSH_CONFIG)
# Format : KEY=VALUE, one per line. A line that starts with # is a comment.
#            OPS_HOST=...       Operations (metrics) address or IP
#            OPS_USER=...       Operations account
#            OPS_PASS_ENC=...   encrypted password  (bash gpu_metric_push.sh --encrypt prints it)
#            OPS_ENC_KEY=...    key that decrypts OPS_PASS_ENC
# Order  : command-line option > environment variable > config file
# The file is read as text and never executed. It holds the credential:
# chmod 600. Git holds this file with the keys only; never commit it with values.
# ==========================================================
OPS_CONFIG_NAME="ops_local.conf"
SCRIPT_VERSION="1.1"

OPS_STAT_ROOT="Custom Metrics"
OPS_PROP_ROOT="Custom Configuration"
OPS_GROUP="Guest GPU"
INTERVAL_SEC=60
SAMPLES=3

# ==========================================================
# * [METRIC TABLE] * - edit only here to change what is collected
# ----------------------------------------------------------
# name : Ops metric name (unit suffix)
# agg  : avg = mean of the samples / pct = mean of 1|0 states x 100 /
#        last = value of the last sample that had one
# src  : q:<field>  nvidia-smi --query-gpu field        (every sample)
#        d:<column> nvidia-smi dmon -s et column       (every sample)
#        r:<field>  nvidia-smi --query-remapped-rows    (once a minute)
#        x:gpu_count / x:query_ok                       (computed, VM level)
# Values are converted as: number -> number, P<n> -> n, Active -> 1,
# Not Active -> 0, Yes -> 1, No -> 0. Anything else ([N/A], [Not Supported],
# -) is skipped.
# ==========================================================
METRIC_TABLE="
Util_Gpu_Pct             avg   q:utilization.gpu
Util_MemCtrl_Pct         avg   q:utilization.memory
Mem_Used_MiB             avg   q:memory.used
Mem_Free_MiB             avg   q:memory.free
Mem_Reserved_MiB         last  q:memory.reserved
Temp_Gpu_C               avg   q:temperature.gpu
Temp_Mem_C               avg   q:temperature.memory
Temp_TLimit_C            avg   q:temperature.gpu.tlimit
Power_Draw_W             avg   q:power.draw
Power_Limit_W            last  q:enforced.power.limit
Clock_SM_MHz             avg   q:clocks.sm
Clock_Mem_MHz            avg   q:clocks.mem
PState                   last  q:pstate
ClkEvt_SwPowerCap_Pct    pct   q:clocks_event_reasons.sw_power_cap
ClkEvt_HwSlowdown_Pct    pct   q:clocks_event_reasons.hw_slowdown
ClkEvt_HwThermal_Pct     pct   q:clocks_event_reasons.hw_thermal_slowdown
ClkEvt_HwPowerBrake_Pct  pct   q:clocks_event_reasons.hw_power_brake_slowdown
ClkEvt_SwThermal_Pct     pct   q:clocks_event_reasons.sw_thermal_slowdown
PCIe_Gen                 last  q:pcie.link.gen.current
PCIe_Width               last  q:pcie.link.width.current
PCIe_Rx_MBps             avg   d:rxpci
PCIe_Tx_MBps             avg   d:txpci
PCIe_Replay              last  d:pci
ECC_Corr_Volatile        last  q:ecc.errors.corrected.volatile.total
ECC_Uncorr_Volatile      last  q:ecc.errors.uncorrected.volatile.total
ECC_Corr_Aggregate       last  q:ecc.errors.corrected.aggregate.total
ECC_Uncorr_Aggregate     last  q:ecc.errors.uncorrected.aggregate.total
Retired_SBE              last  q:retired_pages.sbe
Retired_DBE              last  q:retired_pages.dbe
Retired_Pending          last  q:retired_pages.pending
Remap_Corr               last  r:remapped_rows.correctable
Remap_Uncorr             last  r:remapped_rows.uncorrectable
Remap_Pending            last  r:remapped_rows.pending
Remap_Failure            last  r:remapped_rows.failure
GPU_Count                last  x:gpu_count
Query_OK_Pct             pct   x:query_ok
"

# Properties written once at start: <label>  <--query-gpu field>
PROP_TABLE="
Name                     name
UUID                     uuid
PCI Bus Id               pci.bus_id
Serial                   serial
VBIOS Version            vbios_version
Driver Version           driver_version
Memory Total MiB         memory.total
Max SM Clock MHz         clocks.max.sm
Max Memory Clock MHz     clocks.max.mem
Default Power Limit W    power.default_limit
Max Power Limit W        power.max_limit
PCIe Max Gen             pcie.link.gen.max
PCIe Max Width           pcie.link.width.max
ECC Mode                 ecc.mode.current
MIG Mode                 mig.mode.current
Persistence Mode         persistence_mode
Compute Mode             compute_mode
"
# ==========================================================
# vvv no changes needed below vvv
# ==========================================================

OPS_HOST="${OPS_HOST:-}"
OPS_USER="${OPS_USER:-}"
OPS_PASS_ENC=""                # from the config file
OPS_ENC_KEY=""                 # from the config file
CFG_OPS_HOST=""; CFG_OPS_USER=""
SCRIPT_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
OPS_CONFIG="${OPS_PUSH_CONFIG:-${SCRIPT_DIR:-.}/${OPS_CONFIG_NAME}}"
CONFIG_EXPLICIT=0; [ -n "${OPS_PUSH_CONFIG:-}" ] && CONFIG_EXPLICIT=1
CONFIG_STATE="not read"        # read | not found | not readable
DO_ENCRYPT=0
OPS_PASSWORD="${OPS_PASSWORD:-}"
OPS_VM_NAME="${OPS_VM:-}"
OPS_RESOURCE_ID=""
OPS_AUTHSOURCE="LOCAL"
OPS_CACERT=""
OPS_TIMEOUT=8
NV_BIN="${NVIDIA_SMI:-nvidia-smi}"

DRY_RUN=0
DO_CHECK=0
DO_LIST=0
OUT_MODE="ops"                 # ops | file | both
OPS_MODE=1                     # 1 when OUT_MODE is ops or both (and not --dry-run)
CSV_MODE=0                     # 1 when OUT_MODE is file or both
CSV_OUT=""
CSV_DIR=""
CSV_BASE=""
CSV_PATH=""
CSV_PART=1
CSV_ROWS=0
CSV_MAX_BYTES=$(( 10 * 1024 * 1024 ))
CSV_HEADER=""
PCSV_PATH=""
PCSV_PART=1
PCSV_HEADER="Timestamp,EpochSec,VM,GPU,BusId,PID,ProcessName,UsedGpuMemory_MiB"
PID_FILE="/tmp/gpu_metric_push.pid"
PID_OWNED=0
WORK_DIR=""
HOSTNAME_S=$(hostname -s 2>/dev/null || hostname)
OPS_TOKEN=""
TOKEN_EXP=0
TOKEN_FALLBACK_SEC=1500
TOKEN_MARGIN_SEC=300
AUTH_SCHEME="OpsToken"
JSON_TOOL=""
REAUTH_FLAG=""
LOOP=0
PUSH_TRY=0
TIMEOUT_BIN=""
NV_TIMEOUT=8
PROBE_TIMEOUT=10
SAMPLE_GAP=20
Q_LIST=""                      # --query-gpu fields in use (without index,pci.bus_id)
P_LIST=""                      # property fields in use
DROPPED_Q=""
DROPPED_P=""
FIELD_NOTE=""
DMON_OK=0
REMAP_OK=0
PROC_OK=0
PROC_MEM_FIELD="used_gpu_memory"
NV_OUT=""
NV_ERR=""
ACTIVE_TABLE=""
PROBE_RESULT=""
SAMPLE_RC=0
GPU_COUNT_START=0
PROP_FILE=""


# ----------------------------------------------------------
# 1. Help, password, stop
# ----------------------------------------------------------
show_help() {
cat <<HELP
Usage: bash $0 [options]

Collect NVIDIA GPU metrics inside a DirectPath I/O VM with nvidia-smi:
3 samples a minute (second 00, 20, 40), one value per metric pushed per minute.

  --mode ops|file|both  ops = VCF Operations (default) / file = local CSV / both
  --out DIR|FILE.csv    CSV destination for --mode file|both (directory must exist)
  --max-size MB         CSV part size before rolling over [default 10]
  --vm NAME             VirtualMachine name in Ops [default: hostname -s = ${HOSTNAME_S}]
  --resource-id ID      Ops object id, skips the name lookup
  --config FILE         connection settings file [default: ${OPS_CONFIG_NAME} in the
                        folder of this script; env OPS_PUSH_CONFIG]
  --host H              Ops address [default: OPS_HOST of the config file]
  --user U / --pass P   Ops LOCAL account / password (default: config file)
  --cacert FILE         verify the Ops TLS certificate with this CA (default: -k)
  --interval SEC        collection interval, multiple of 3, 15 or more [default 60]
  --nvidia-smi PATH     nvidia-smi binary [default: nvidia-smi on PATH]
  --check               probe nvidia-smi, take one sample now, print the parsed
                        values and properties, then exit (no Ops, no PID file)
  --dry-run             no Ops connection; print the JSON each minute instead
  --list                print the metric table and the property list
  --encrypt             print the OPS_PASS_ENC line for the config file
                        (encrypted password; needs OPS_ENC_KEY in that file)
  --stop                stop the running collector
  -h, --help            this help

Ops tree: <VM> > ${OPS_STAT_ROOT} > ${OPS_GROUP} > gpu<N> > <metric>
          <VM> > ${OPS_PROP_ROOT} > ${OPS_GROUP} > gpu<N> > <property>
Timestamps are local time.
HELP
}

# ----------------------------------------------------------
# Connection settings file (KEY=VALUE lines). Read as text, never executed.
# ----------------------------------------------------------
read_config() {   # $1 = file -> CFG_OPS_HOST CFG_OPS_USER OPS_PASS_ENC OPS_ENC_KEY, CONFIG_STATE
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
            OPS_PASS_ENC) OPS_PASS_ENC="$val" ;;
            OPS_ENC_KEY)  OPS_ENC_KEY="$val" ;;
        esac
    done < "$1"
    CONFIG_STATE="read"
    return 0
}

do_encrypt() {
    local p1 p2 blob
    command -v openssl >/dev/null 2>&1 || { echo "[ERROR] openssl not found" >&2; exit 1; }
    [ -z "$OPS_ENC_KEY" ] && {
        echo "[ERROR] OPS_ENC_KEY is empty in ${OPS_CONFIG} [${CONFIG_STATE}]." >&2
        echo "        Put a key of your choice there first (OPS_ENC_KEY=...), then run --encrypt again." >&2; exit 1; }
    printf 'Password: ' >&2; read -rs p1; echo "" >&2
    printf 'Once more: ' >&2; read -rs p2; echo "" >&2
    [ "$p1" != "$p2" ] && { echo "[ERROR] mismatch" >&2; exit 1; }
    [ -z "$p1" ] && { echo "[ERROR] empty" >&2; exit 1; }
    blob=$(printf '%s' "$p1" | openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt \
           -pass "pass:${OPS_ENC_KEY}" -base64 -A 2>/dev/null)
    [ -z "$blob" ] && { echo "[ERROR] encryption failed" >&2; exit 1; }
    echo ""; echo "Put this line into ${OPS_CONFIG}:"; echo ""
    echo "OPS_PASS_ENC=${blob}"; echo ""; exit 0
}

decrypt_pass() {
    local out
    { [ -z "$OPS_PASS_ENC" ] || [ -z "$OPS_ENC_KEY" ]; } && {
        echo "[ERROR] no password: OPS_PASS_ENC or OPS_ENC_KEY is empty in ${OPS_CONFIG} [${CONFIG_STATE}]." >&2
        echo "        Fill both in (bash $0 --encrypt prints OPS_PASS_ENC), or pass the password with env OPS_PASSWORD." >&2
        return 1; }
    command -v openssl >/dev/null 2>&1 || {
        echo "[ERROR] openssl not found. Inject via export OPS_PASSWORD='...'." >&2; return 1; }
    out=$(printf '%s' "$OPS_PASS_ENC" | openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 \
          -pass "pass:${OPS_ENC_KEY}" -base64 -A 2>/dev/null)
    [ -z "$out" ] && { echo "[ERROR] decryption failed. Check OPS_ENC_KEY, or make OPS_PASS_ENC again with --encrypt." >&2; return 1; }
    printf '%s' "$out"; return 0
}

do_stop() {
    local pid w
    if [ ! -f "$PID_FILE" ]; then
        echo "[INFO] No collector running (${PID_FILE} not found)."
        echo "       Manual stop: pkill -f gpu_metric_push"
        exit 0
    fi
    pid=$(cat "$PID_FILE" 2>/dev/null)
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
        echo "[INFO] PID ${pid:-?} is already gone. Cleaning up the PID file."
        rm -f "$PID_FILE"; exit 0
    fi
    echo "[INFO] Stopping collector [PID ${pid}]..."
    pkill -TERM -P "$pid" 2>/dev/null
    kill -TERM "$pid" 2>/dev/null
    w=0
    while kill -0 "$pid" 2>/dev/null && [ "$w" -lt 5 ]; do sleep 1; w=$((w+1)); done
    if kill -0 "$pid" 2>/dev/null; then
        pkill -KILL -P "$pid" 2>/dev/null
        kill -KILL "$pid" 2>/dev/null
        echo "[INFO] Force kill (-9) performed."
    fi
    rm -f "$PID_FILE"
    echo "[INFO] Stopped."
    exit 0
}


# ----------------------------------------------------------
# 2. Arguments
# ----------------------------------------------------------
while [ "$#" -gt 0 ]; do
    case "$1" in
        --mode)
            case "${2:-}" in
                ops|file|both) OUT_MODE="$2" ;;
                *) echo "[ERROR] --mode must be ops, file or both" >&2; exit 1 ;;
            esac
            shift ;;
        --out)         CSV_OUT="${2:-}"; shift ;;
        --max-size)
            case "${2:-}" in ''|*[!0-9]*|0) echo "[ERROR] --max-size needs a number of MB (1 or more)" >&2; exit 1 ;; esac
            CSV_MAX_BYTES=$(( $2 * 1024 * 1024 )); shift ;;
        --vm|--name)   OPS_VM_NAME="${2:-}"; shift ;;
        --resource-id) OPS_RESOURCE_ID="${2:-}"; shift ;;
        --config)      OPS_CONFIG="${2:-}"; CONFIG_EXPLICIT=1; shift ;;
        --host)        OPS_HOST="${2:-}"; shift ;;
        --user)        OPS_USER="${2:-}"; shift ;;
        --pass)        OPS_PASSWORD="${2:-}"; shift ;;
        --cacert)      OPS_CACERT="${2:-}"; shift ;;
        --interval)
            case "${2:-}" in ''|*[!0-9]*) echo "[ERROR] --interval needs seconds" >&2; exit 1 ;; esac
            INTERVAL_SEC="$2"; shift ;;
        --nvidia-smi)  NV_BIN="${2:-}"; shift ;;
        --check)       DO_CHECK=1 ;;
        --dry-run)     DRY_RUN=1 ;;
        --list)        DO_LIST=1 ;;
        --encrypt)     DO_ENCRYPT=1 ;;
        --stop)        do_stop ;;
        -h|--help)     show_help; exit 0 ;;
        *) echo "[ERROR] unknown option: $1  (see --help)" >&2; exit 1 ;;
    esac
    shift
done

# connection settings: command-line option > environment variable > config file
if [ "$CONFIG_EXPLICIT" -eq 1 ] && [ ! -f "$OPS_CONFIG" ]; then
    echo "[ERROR] config file not found: ${OPS_CONFIG}" >&2; exit 1
fi
read_config "$OPS_CONFIG"
[ -z "$OPS_HOST" ] && OPS_HOST="$CFG_OPS_HOST"
[ -z "$OPS_USER" ] && OPS_USER="$CFG_OPS_USER"
[ "$DO_ENCRYPT" -eq 1 ] && do_encrypt

if [ "$DO_LIST" -eq 1 ]; then
    echo "Metric table (name / aggregation / source):"
    printf '%s\n' "$METRIC_TABLE" | awk 'NF>=3 && $1 !~ /^#/ { printf "  %-26s %-5s %s\n", $1, $2, $3 }'
    echo ""
    echo "Properties written at start (label / --query-gpu field), plus Shutdown/Slowdown/Max Operating Temp:"
    printf '%s\n' "$PROP_TABLE" | awk 'NF>=2 && $1 !~ /^#/ { f=$NF; $NF=""; sub(/[ \t]+$/, ""); printf "  %-26s %s\n", $0, f }'
    echo ""
    echo "Ops tree: <VM> > ${OPS_STAT_ROOT} > ${OPS_GROUP} > gpu<N> > <metric>"
    exit 0
fi

[ "$INTERVAL_SEC" -lt 15 ] && { echo "[ERROR] --interval minimum is 15" >&2; exit 1; }
[ $(( INTERVAL_SEC % SAMPLES )) -ne 0 ] && { echo "[ERROR] --interval must be a multiple of ${SAMPLES}" >&2; exit 1; }
SAMPLE_GAP=$(( INTERVAL_SEC / SAMPLES ))
# Two nvidia-smi calls per sample must finish inside one sample step.
NV_TIMEOUT=$(( (SAMPLE_GAP - 2) / 2 ))
[ "$NV_TIMEOUT" -gt 8 ] && NV_TIMEOUT=8
[ "$NV_TIMEOUT" -lt 2 ] && NV_TIMEOUT=2

case "$OUT_MODE" in
    ops)  OPS_MODE=1; CSV_MODE=0 ;;
    file) OPS_MODE=0; CSV_MODE=1 ;;
    both) OPS_MODE=1; CSV_MODE=1 ;;
esac
[ "$DRY_RUN" -eq 1 ] && OPS_MODE=0
if [ "$DO_CHECK" -eq 1 ]; then OPS_MODE=0; CSV_MODE=0; fi
if [ "$CSV_MODE" -eq 1 ] && [ -z "$CSV_OUT" ]; then
    echo "[ERROR] --mode ${OUT_MODE} needs --out <directory or file.csv>" >&2; exit 1
fi
[ -z "$OPS_VM_NAME" ] && OPS_VM_NAME="$HOSTNAME_S"

command -v timeout >/dev/null 2>&1 && TIMEOUT_BIN="timeout"


# ----------------------------------------------------------
# 3. nvidia-smi helpers
# ----------------------------------------------------------
WORK_DIR=$(mktemp -d /tmp/gpu_metric_push.XXXXXX 2>/dev/null) || {
    echo "[ERROR] cannot create a work directory under /tmp" >&2; exit 1; }
NV_OUT="${WORK_DIR}/nv.out"
NV_ERR="${WORK_DIR}/nv.err"
REAUTH_FLAG="${WORK_DIR}/reauth"
TABLE_FILE="${WORK_DIR}/table"
MIN_FILE="${WORK_DIR}/minute.dat"
AGG_FILE="${WORK_DIR}/agg.dat"
BUSMAP_FILE="${WORK_DIR}/busmap"

# Run nvidia-smi with a time limit. stdout -> NV_OUT, stderr -> NV_ERR.
# Returns the nvidia-smi exit code, or 124 when the time limit was hit.
run_nv() {
    local t="$1" pid start rc
    shift
    : > "$NV_OUT"; : > "$NV_ERR"
    if [ -n "$TIMEOUT_BIN" ]; then
        "$TIMEOUT_BIN" -k 2 "$t" "$NV_BIN" "$@" > "$NV_OUT" 2> "$NV_ERR"
        rc=$?
        [ "$rc" -eq 137 ] && rc=124
        return "$rc"
    fi
    # No coreutils timeout: watch the wall clock ($SECONDS), not a loop count.
    "$NV_BIN" "$@" > "$NV_OUT" 2> "$NV_ERR" &
    pid=$!
    start=$SECONDS
    while kill -0 "$pid" 2>/dev/null; do
        if [ $(( SECONDS - start )) -ge "$t" ]; then
            { kill -TERM "$pid"; sleep 1; kill -KILL "$pid"; wait "$pid"; } 2>/dev/null
            return 124
        fi
        sleep 0.2
    done
    wait "$pid"
    return $?
}

nv_rc_text() {   # nvidia-smi exit codes (nvidia-smi manual, RETURN VALUE)
    case "$1" in
        0)   echo "success" ;;
        2)   echo "invalid argument or field" ;;
        3)   echo "operation not available on this device" ;;
        4)   echo "this user has no permission for the device or operation" ;;
        6)   echo "a query to find an object was unsuccessful" ;;
        8)   echo "external power cables are not attached" ;;
        9)   echo "NVIDIA driver is not loaded" ;;
        10)  echo "interrupt issue with a GPU" ;;
        12)  echo "NVML shared library not found" ;;
        13)  echo "NVML does not implement this function" ;;
        14)  echo "infoROM is corrupted" ;;
        15)  echo "GPU has fallen off the bus or is inaccessible" ;;
        124) echo "no answer within the time limit" ;;
        126|127) echo "nvidia-smi not found or not executable" ;;
        *)   echo "other error" ;;
    esac
}

table_sources() {   # $1 = q|d|r|x -> comma list of sources with that prefix, table order
    printf '%s\n' "$METRIC_TABLE" | awk -v p="$1" '
        NF>=3 && $1 !~ /^#/ { n=index($3, ":"); if (substr($3, 1, n-1)==p) { f=substr($3, n+1); if (!(f in s)) { s[f]=1; o=o (o==""?"":",") f } } }
        END { printf "%s", o }'
}

list_remove() {   # $1 = comma list, $2 = item -> list without item
    printf '%s' "$1" | awk -v r="$2" 'BEGIN { RS="," } { gsub(/[\r\n]/, ""); if ($0!="" && $0!=r) o=o (o==""?"":",") $0 } END { printf "%s", o }'
}

list_has() {   # $1 = comma list, $2 = item
    case ",$1," in *",$2,"*) return 0 ;; esac
    return 1
}

# Keep the fields this driver accepts. nvidia-smi rejects a whole query when a
# single field is unknown (exit 2, 'Field "x" is not a valid field to query.'),
# so unknown fields are removed one at a time. Result in PROBE_RESULT,
# removed fields appended to the variable named in $2.
probe_query_fields() {
    local list="$1" dropvar="$2" rc bad tries=0 f ok=""
    while [ "$tries" -lt 80 ]; do
        run_nv "$PROBE_TIMEOUT" --query-gpu="index,pci.bus_id${list:+,$list}" --format=csv,noheader,nounits
        rc=$?
        if [ "$rc" -eq 0 ]; then PROBE_RESULT="$list"; return 0; fi
        [ "$rc" -ne 2 ] && return "$rc"
        bad=$(cat "$NV_OUT" "$NV_ERR" 2>/dev/null | sed -n 's/.*Field "\([^"]*\)".*/\1/p' | head -1)
        { [ -z "$bad" ] || ! list_has "$list" "$bad"; } && break
        list=$(list_remove "$list" "$bad")
        eval "$dropvar=\"\${$dropvar}\${$dropvar:+,}\$bad\""
        tries=$(( tries + 1 ))
    done
    # error text not recognised: test each remaining field alone
    for f in $(printf '%s' "$list" | tr ',' ' '); do
        run_nv "$PROBE_TIMEOUT" --query-gpu="index,${f}" --format=csv,noheader,nounits
        if [ $? -eq 0 ]; then ok="${ok}${ok:+,}${f}"
        else eval "$dropvar=\"\${$dropvar}\${$dropvar:+,}\$f\""; fi
    done
    PROBE_RESULT="$ok"
    return 0
}

# Build the active metric table (name agg src) from the probe results.
build_active_table() {
    printf '%s\n' "$METRIC_TABLE" | awk -v ql=",${Q_LIST}," -v dm="$DMON_OK" -v rm="$REMAP_OK" '
        NF>=3 && $1 !~ /^#/ {
            n=index($3, ":"); p=substr($3, 1, n-1); f=substr($3, n+1)
            if (p=="q" && index(ql, "," f ",")==0) next
            if (p=="d" && dm!=1) next
            if (p=="r" && rm!=1) next
            print $1, $2, $3
        }' > "$TABLE_FILE"
    ACTIVE_TABLE=$(cat "$TABLE_FILE")
}

# Shared awk value conversion.
AWK_CONV='
function trim(v) { gsub(/^[ \t\r]+|[ \t\r]+$/, "", v); return v }
function conv(v) {
    v = trim(v)
    if (v ~ /^-?[0-9]+(\.[0-9]+)?$/) return v
    if (v ~ /^P[0-9]+$/) return substr(v, 2)
    if (v == "Active") return "1"
    if (v == "Not Active") return "0"
    if (v == "Yes") return "1"
    if (v == "No") return "0"
    return ""
}
function fmt(x,   v) {
    v = sprintf("%.2f", x)
    if (v ~ /\./) { sub(/0+$/, "", v); sub(/\.$/, "", v) }
    if (v == "-0") v = "0"
    return v
}'

# One sample: --query-gpu and dmon. Appends "sample<TAB>gpu<TAB>metric<TAB>value"
# lines to MIN_FILE and refreshes BUSMAP_FILE ("bus<TAB>index").
take_sample() {
    local s="$1" rc ok=0 cnt=0
    run_nv "$NV_TIMEOUT" --query-gpu="index,pci.bus_id${Q_LIST:+,$Q_LIST}" --format=csv,noheader,nounits
    rc=$?
    SAMPLE_RC="$rc"
    if [ "$rc" -eq 0 ] && [ -s "$NV_OUT" ]; then
        ok=1
        awk -F', ' '{ b=$2; gsub(/^[ \t]+|[ \t\r]+$/, "", b); i=$1; gsub(/[ \t\r]/, "", i); if (b!="") print b "\t" i }' "$NV_OUT" > "$BUSMAP_FILE"
        cnt=$(wc -l < "$BUSMAP_FILE" | tr -d ' ')
        awk -v s="$s" -v flist="index,pci.bus_id${Q_LIST:+,$Q_LIST}" "$AWK_CONV"'
            BEGIN { nf=split(flist, fl, ",") }
            FNR==NR { n=index($3, ":"); if (substr($3, 1, n-1)=="q") m[substr($3, n+1)]=$1; next }
            {
                c=split($0, v, ", ")
                idx=trim(v[1]); if (idx=="") next
                for (i=3; i<=c && i<=nf; i++) {
                    if (!(fl[i] in m)) continue
                    x=conv(v[i]); if (x!="") print s "\t" idx "\t" m[fl[i]] "\t" x
                }
            }' "$TABLE_FILE" "$NV_OUT" >> "$MIN_FILE"
    fi
    if [ "$DMON_OK" -eq 1 ]; then
        run_nv "$NV_TIMEOUT" dmon -s et -c 1
        if [ $? -eq 0 ]; then
            awk -v s="$s" "$AWK_CONV"'
                FNR==NR { n=index($3, ":"); if (substr($3, 1, n-1)=="d") m[substr($3, n+1)]=$1; next }
                /^#/ { if (!hdr) { line=$0; sub(/^#[ \t]*/, "", line); nh=split(line, h, /[ \t]+/); hdr=1 }; next }
                hdr && NF>1 {
                    idx=$1
                    for (i=2; i<=NF && i<=nh; i++) if (h[i] in m) { x=conv($i); if (x!="") print s "\t" idx "\t" m[h[i]] "\t" x }
                }' "$TABLE_FILE" "$NV_OUT" >> "$MIN_FILE"
        fi
    fi
    printf '%s\t-\tQuery_OK_Pct\t%s\n' "$s" "$ok" >> "$MIN_FILE"
    printf '%s\t-\tGPU_Count\t%s\n' "$s" "$cnt" >> "$MIN_FILE"
}

# Once a minute: remapped rows (needs the bus map of a successful sample).
take_remap() {
    local s="$1" f
    [ "$REMAP_OK" -eq 1 ] && [ -s "$BUSMAP_FILE" ] || return 0
    f=$(table_sources r)
    run_nv "$NV_TIMEOUT" --query-remapped-rows="gpu_bus_id,${f}" --format=csv,noheader,nounits || return 0
    awk -v s="$s" -v flist="gpu_bus_id,${f}" "$AWK_CONV"'
        FILENAME==ARGV[1] { n=index($3, ":"); if (substr($3, 1, n-1)=="r") m[substr($3, n+1)]=$1; next }
        FILENAME==ARGV[2] { split($0, b, "\t"); bus[b[1]]=b[2]; next }
        {
            c=split($0, v, ", "); nf=split(flist, fl, ",")
            k=trim(v[1]); if (!(k in bus)) next
            for (i=2; i<=c && i<=nf; i++) if (fl[i] in m) { x=conv(v[i]); if (x!="") print s "\t" bus[k] "\t" m[fl[i]] "\t" x }
        }' "$TABLE_FILE" "$BUSMAP_FILE" "$NV_OUT" >> "$MIN_FILE"
}

# Aggregate MIN_FILE -> AGG_FILE ("gpu<TAB>metric<TAB>value"; gpu "-" = VM level).
aggregate_minute() {
    awk "$AWK_CONV"'
        FNR==NR { agg[$1]=$2; next }
        {
            key=$2 SUBSEP $3; s=$1+0
            if (agg[$3]=="last") { if (!(key in ls) || s>=ls[key]) { ls[key]=s; lv[key]=$4 } }
            else { sum[key]+=$4; cnt[key]++ }
            seen[key]=1
        }
        END {
            for (key in seen) {
                split(key, k, SUBSEP)
                if (agg[k[2]]=="last") v=lv[key]
                else { x=sum[key]/cnt[key]; if (agg[k[2]]=="pct") x=x*100; v=fmt(x) }
                print k[1] "\t" k[2] "\t" v
            }
        }' "$TABLE_FILE" "$MIN_FILE" | sort > "$AGG_FILE"
}

build_json() {   # $1 = timestamp ms
    awk -F'\t' -v ts="$1" -v root="$OPS_STAT_ROOT" -v grp="$OPS_GROUP" '
        BEGIN { printf "{\"stat-content\":["; first=1 }
        NF>=3 && $3!="" {
            key=root "|" grp; if ($1!="-") key=key "|gpu" $1; key=key "|" $2
            printf "%s{\"statKey\":\"%s\",\"timestamps\":[%s],\"data\":[%s]}", (first?"":","), key, ts, $3
            first=0
        }
        END { printf "]}" }' "$AGG_FILE"
}

minute_summary() {   # one log line per minute
    awk -F'\t' '
        $1=="-" { vm[$2]=$3; next }
        { g[$1]=1; val[$1 SUBSEP $2]=$3 }
        END {
            o=""
            for (i in g) {
                o=o sprintf(" | gpu%s util=%s%% mem=%sMiB temp=%sC pwr=%sW", i,
                    ((i SUBSEP "Util_Gpu_Pct") in val ? val[i SUBSEP "Util_Gpu_Pct"] : "-"),
                    ((i SUBSEP "Mem_Used_MiB") in val ? val[i SUBSEP "Mem_Used_MiB"] : "-"),
                    ((i SUBSEP "Temp_Gpu_C") in val ? val[i SUBSEP "Temp_Gpu_C"] : "-"),
                    ((i SUBSEP "Power_Draw_W") in val ? val[i SUBSEP "Power_Draw_W"] : "-"))
            }
            printf "gpus=%s query_ok=%s%%%s", ("GPU_Count" in vm ? vm["GPU_Count"] : "0"), ("Query_OK_Pct" in vm ? vm["Query_OK_Pct"] : "0"), o
        }' "$AGG_FILE"
}


# ----------------------------------------------------------
# 4. CSV  [--mode file|both]
# ----------------------------------------------------------
csv_setup() {
    local run=1 try
    case "$CSV_OUT" in
        *.csv) CSV_DIR=$(dirname "$CSV_OUT"); CSV_BASE="${CSV_OUT%.csv}" ;;
        *)     CSV_DIR="${CSV_OUT%/}"; [ -z "$CSV_DIR" ] && CSV_DIR="/"
               CSV_BASE="${CSV_DIR}/gpu_metric_${HOSTNAME_S}_$(date '+%Y%m%d-%H%M%S')" ;;
    esac
    [ -d "$CSV_DIR" ] || { echo "[ERROR] --out directory does not exist: ${CSV_DIR}" >&2; exit 1; }
    [ -w "$CSV_DIR" ] || { echo "[ERROR] --out directory is not writable: ${CSV_DIR}" >&2; exit 1; }
    try="$CSV_BASE"
    while [ -e "${try}_001.csv" ]; do run=$(( run + 1 )); try="${CSV_BASE}-r${run}"; done
    CSV_BASE="$try"
    # Every metric of the full table is a column, collected or not, so files
    # from different VMs and drivers merge as one table.
    CSV_HEADER="Timestamp,EpochSec,VM,GPU,BusId,$(printf '%s\n' "$METRIC_TABLE" | awk 'NF>=3 && $1 !~ /^#/ { o=o (o==""?"":",") $1 } END { printf "%s", o }')"
    csv_open_part
    if [ "$PROC_OK" -eq 1 ]; then pcsv_open_part; fi
}

csv_open_part() {
    CSV_PATH=$(printf '%s_%03d.csv' "$CSV_BASE" "$CSV_PART")
    while [ -e "$CSV_PATH" ]; do CSV_PART=$(( CSV_PART + 1 )); CSV_PATH=$(printf '%s_%03d.csv' "$CSV_BASE" "$CSV_PART"); done
    printf '%s\n' "$CSV_HEADER" >> "$CSV_PATH" || { echo "[ERROR] cannot write CSV file: ${CSV_PATH}" >&2; exit 1; }
    echo "[INFO] CSV file: ${CSV_PATH}"
}

pcsv_open_part() {
    PCSV_PATH=$(printf '%s_procs_%03d.csv' "$CSV_BASE" "$PCSV_PART")
    while [ -e "$PCSV_PATH" ]; do PCSV_PART=$(( PCSV_PART + 1 )); PCSV_PATH=$(printf '%s_procs_%03d.csv' "$CSV_BASE" "$PCSV_PART"); done
    printf '%s\n' "$PCSV_HEADER" >> "$PCSV_PATH" || { echo "[ERROR] cannot write CSV file: ${PCSV_PATH}" >&2; exit 1; }
    echo "[INFO] Process CSV file: ${PCSV_PATH}"
}

csv_roll() {   # $1 = path variable name, $2 = open function
    local p sz
    eval "p=\${$1}"
    sz=$(wc -c < "$p" 2>/dev/null | tr -d ' ')
    case "$sz" in ''|*[!0-9]*) sz=0 ;; esac
    if [ "$sz" -ge "$CSV_MAX_BYTES" ]; then
        if [ "$1" = "CSV_PATH" ]; then CSV_PART=$(( CSV_PART + 1 )); else PCSV_PART=$(( PCSV_PART + 1 )); fi
        "$2"
    fi
}

# One row per GPU per minute; VM-level metrics repeat on every row.
csv_write_minute() {   # $1 = timestamp text, $2 = epoch sec
    local n
    n=$(printf '%s\n' "$METRIC_TABLE" | awk 'NF>=3 && $1 !~ /^#/ { o=o (o==""?"":",") $1 } END { printf "%s", o }')
    awk -F'\t' -v ts="$1" -v ep="$2" -v vmname="$OPS_VM_NAME" -v names="$n" '
        FILENAME==ARGV[1] { bus[$2]=$1; next }
        { if ($1=="-") vmv[$2]=$3; else { g[$1]=1; val[$1 SUBSEP $2]=$3 } }
        END {
            nn=split(names, nm, ",")
            for (b in bus) g[b]=1
            any=0
            for (i in g) {
                any=1
                row=ts "," ep "," vmname "," i "," ((i in bus) ? bus[i] : "")
                for (j=1; j<=nn; j++) {
                    k=i SUBSEP nm[j]
                    row=row "," ((k in val) ? val[k] : ((nm[j] in vmv) ? vmv[nm[j]] : ""))
                }
                print row
            }
            if (!any) {
                row=ts "," ep "," vmname ",,"
                for (j=1; j<=nn; j++) row=row "," ((nm[j] in vmv) ? vmv[nm[j]] : "")
                print row
            }
        }' "$BUSMAP_FILE" "$AGG_FILE" | sort >> "$CSV_PATH" || { echo "[WARN] $1 CSV write failed (${CSV_PATH})" >&2; return 0; }
    CSV_ROWS=$(( CSV_ROWS + 1 ))
    csv_roll CSV_PATH csv_open_part
}

# Process list once a minute, CSV only (one row per process, not pushed to Ops).
csv_write_procs() {   # $1 = timestamp text, $2 = epoch sec
    [ "$PROC_OK" -eq 1 ] && [ -n "$PCSV_PATH" ] || return 0
    run_nv "$NV_TIMEOUT" --query-compute-apps="gpu_bus_id,pid,process_name,${PROC_MEM_FIELD}" --format=csv,noheader,nounits || return 0
    [ -s "$NV_OUT" ] || return 0
    awk -v ts="$1" -v ep="$2" -v vmname="$OPS_VM_NAME" '
        FILENAME==ARGV[1] { split($0, b, "\t"); bus[b[1]]=b[2]; next }
        {
            c=split($0, v, ", "); if (c<4) next
            for (i=1; i<=c; i++) gsub(/^[ \t\r]+|[ \t\r]+$/, "", v[i])
            name=v[3]; for (i=4; i<c; i++) name=name ", " v[i]
            gsub(/"/, "\"\"", name)
            printf "%s,%s,%s,%s,%s,%s,\"%s\",%s\n", ts, ep, vmname, ((v[1] in bus) ? bus[v[1]] : ""), v[1], v[2], name, v[c]
        }' "$BUSMAP_FILE" "$NV_OUT" >> "$PCSV_PATH" || return 0
    csv_roll PCSV_PATH pcsv_open_part
}


# ----------------------------------------------------------
# 5. Ops
# ----------------------------------------------------------
json_get() {
    case "$JSON_TOOL" in
        python3) printf '%s' "$1" | python3 -c '
import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
if isinstance(d,dict):
    v=d.get(sys.argv[1],""); print(v if v is not None else "")
' "$2" 2>/dev/null ;;
        jq) printf '%s' "$1" | jq -r --arg k "$2" 'if type=="object" then (.[$k]//"") else "" end' 2>/dev/null ;;
    esac
}
json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

acquire_token() {
    local body resp u p a validity now
    u=$(json_escape "$OPS_USER"); p=$(json_escape "$OPS_PASSWORD"); a=$(json_escape "$OPS_AUTHSOURCE")
    body=$(printf '{"username":"%s","password":"%s","authSource":"%s"}' "$u" "$p" "$a")
    resp=$(curl -s $CURL_TLS --max-time 15 \
        -X POST "${OPS_BASE}/suite-api/api/auth/token/acquire" \
        -H 'Content-Type: application/json' -H 'Accept: application/json' -d "$body" 2>&1)
    OPS_TOKEN=$(json_get "$resp" token)
    [ -z "$OPS_TOKEN" ] && { echo "[WARN] token acquisition failed. Response: $(printf '%s' "$resp" | head -c 250)" >&2; return 1; }
    now=$(date '+%s'); validity=$(json_get "$resp" validity)
    case "$validity" in ''|*[!0-9]*) TOKEN_EXP=$(( now + TOKEN_FALLBACK_SEC )) ;;
                        *) TOKEN_EXP=$(( validity / 1000 )) ;; esac
    rm -f "$REAUTH_FLAG"; return 0
}

detect_auth_scheme() {
    local s code=""
    for s in OpsToken vRealizeOpsToken; do
        code=$(curl -s $CURL_TLS -o /dev/null -w '%{http_code}' --max-time 15 -G \
            "${OPS_BASE}/suite-api/api/resources" \
            --data-urlencode "pageSize=1" --data-urlencode "_no_links=true" \
            -H "Authorization: ${s} ${OPS_TOKEN}" -H 'Accept: application/json' 2>/dev/null)
        [ "$code" = "200" ] && { AUTH_SCHEME="$s"; return 0; }
    done
    echo "[ERROR] auth header rejected [OpsToken/vRealizeOpsToken, HTTP ${code}]" >&2; return 1
}

lookup_vm() {
    local resp out
    resp=$(curl -s $CURL_TLS --max-time 20 -G "${OPS_BASE}/suite-api/api/resources" \
        --data-urlencode "adapterKindKey=VMWARE" --data-urlencode "resourceKind=VirtualMachine" \
        --data-urlencode "name=${OPS_VM_NAME}" --data-urlencode "_no_links=true" \
        -H "Authorization: ${AUTH_SCHEME} ${OPS_TOKEN}" -H 'Accept: application/json' 2>&1)
    if [ "$JSON_TOOL" = "python3" ]; then
        out=$(printf '%s' "$resp" | python3 -c '
import sys,json
name=sys.argv[1]
try: d=json.load(sys.stdin)
except Exception: print("|0"); sys.exit(0)
rl=d.get("resourceList") or []
nm=lambda r: (r.get("resourceKey") or {}).get("name") or ""
ex=[r for r in rl if nm(r)==name] or [r for r in rl if nm(r).lower()==name.lower()]
print("%s|%d" % (ex[0].get("identifier","") if ex else "", len(ex)))
' "$OPS_VM_NAME" 2>/dev/null)
    else
        out=$(printf '%s' "$resp" | jq -r --arg n "$OPS_VM_NAME" '
            (.resourceList//[]) as $rl
            |([$rl[]|select(.resourceKey.name==$n)]) as $e
            |(if ($e|length)>0 then $e else [$rl[]|select((.resourceKey.name|ascii_downcase)==($n|ascii_downcase))] end) as $ex
            |"\(($ex[0].identifier)//"")|\($ex|length)"' 2>/dev/null)
    fi
    OPS_RESOURCE_ID="${out%%|*}"
    [ -z "$OPS_RESOURCE_ID" ] && return 1
    [ "${out##*|}" -gt 1 ] 2>/dev/null && \
        echo "[WARN] ${out##*|} VMs share the name '${OPS_VM_NAME}' -> using the first. Otherwise use --resource-id." >&2
    return 0
}

push_stats() {   # $1 = json, $2 = timestamp text
    local json="$1" ts="$2" attempt=1 out code=""
    while [ "$attempt" -le 2 ]; do
        out="${WORK_DIR}/push.$$.${attempt}"
        code=$(curl -s $CURL_TLS -o "$out" -w '%{http_code}' --max-time "$OPS_TIMEOUT" \
            -X POST "${OPS_BASE}/suite-api/api/resources/${OPS_RESOURCE_ID}/stats" \
            -H "Authorization: ${AUTH_SCHEME} ${OPS_TOKEN}" \
            -H 'Content-Type: application/json' -H 'Accept: application/json' -d "$json" 2>/dev/null)
        case "$code" in
            200|201|204) rm -f "$out"; return 0 ;;
            401|403) : > "$REAUTH_FLAG"; echo "[WARN] ${ts} auth rejected [HTTP ${code}] -> re-auth scheduled" >&2; rm -f "$out"; return 1 ;;
        esac
        rm -f "$out"; attempt=$(( attempt + 1 )); [ "$attempt" -le 2 ] && sleep 1
    done
    echo "[WARN] ${ts} push failed [HTTP ${code}] (2 attempts)" >&2; return 1
}

# Properties at start: per GPU from --query-gpu, thresholds from -q -d TEMPERATURE.
# Writes "gpu<TAB>label<TAB>value" lines to PROP_FILE.
collect_props() {
    PROP_FILE="${WORK_DIR}/props"
    : > "$PROP_FILE"
    [ -z "$P_LIST" ] && return 0
    run_nv "$PROBE_TIMEOUT" --query-gpu="index,pci.bus_id,${P_LIST}" --format=csv,noheader,nounits || return 0
    awk -v flist="index,pci.bus_id,${P_LIST}" -v ptab="$(printf '%s\n' "$PROP_TABLE" | awk 'NF>=2 && $1 !~ /^#/ { f=$NF; $NF=""; sub(/[ \t]+$/, ""); printf "%s=%s;", f, $0 }')" '
        BEGIN { n=split(ptab, pt, ";"); for (i=1; i<=n; i++) if (pt[i]!="") { k=substr(pt[i], 1, index(pt[i], "=")-1); lab[k]=substr(pt[i], index(pt[i], "=")+1) } }
        {
            c=split($0, v, ", "); nf=split(flist, fl, ",")
            for (i=1; i<=c; i++) gsub(/^[ \t\r]+|[ \t\r]+$/, "", v[i])
            for (i=3; i<=c && i<=nf; i++) if (fl[i] in lab) print v[1] "\t" lab[fl[i]] "\t" v[i]
        }' "$NV_OUT" >> "$PROP_FILE"
    awk -F', ' '{ b=$2; gsub(/^[ \t]+|[ \t\r]+$/, "", b); i=$1; gsub(/[ \t\r]/, "", i); if (b!="") print b "\t" i }' "$NV_OUT" > "${WORK_DIR}/propbus"
    run_nv "$PROBE_TIMEOUT" -q -d TEMPERATURE || return 0
    awk '
        FILENAME==ARGV[1] { split($0, b, "\t"); bus[b[1]]=b[2]; next }
        /^GPU [0-9A-Fa-f]+:/ { cur=$2; next }
        cur!="" && /:/ {
            label=$0; sub(/:.*/, "", label); gsub(/^[ \t]+|[ \t]+$/, "", label)
            val=$0; sub(/^[^:]*:[ \t]*/, "", val); gsub(/[ \t\r]+$/, "", val)
            name=""
            if (label ~ /^GPU Shutdown/) name="Shutdown Temp"
            else if (label ~ /^GPU Slowdown/) name="Slowdown Temp"
            else if (label ~ /^GPU Max Operating/) name="Max Operating Temp"
            else if (label ~ /^Memory Max Operating/) name="Memory Max Operating Temp"
            if (name=="" || val=="" || val=="N/A") next
            if (label ~ /T\.Limit/) val=val " (T.Limit margin)"
            if (cur in bus) print bus[cur] "\t" name "\t" val
        }' "${WORK_DIR}/propbus" "$NV_OUT" >> "$PROP_FILE"
}

push_props() {
    local body ts code
    [ -s "$PROP_FILE" ] || return 0
    ts=$(( $(date '+%s') * 1000 ))
    body=$(awk -F'\t' -v ts="$ts" -v root="$OPS_PROP_ROOT" -v grp="$OPS_GROUP" -v when="$(date '+%Y-%m-%d %H:%M:%S %Z')" -v cnt="$GPU_COUNT_START" '
        function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
        BEGIN { printf "{\"property-content\":["
                printf "{\"statKey\":\"%s\",\"timestamps\":[%s],\"values\":[\"%s\"]}", esc(root "|" grp "|Collected At"), ts, esc(when)
                printf ",{\"statKey\":\"%s\",\"timestamps\":[%s],\"values\":[\"%s\"]}", esc(root "|" grp "|GPU Count"), ts, esc(cnt) }
        NF>=3 { printf ",{\"statKey\":\"%s\",\"timestamps\":[%s],\"values\":[\"%s\"]}", esc(root "|" grp "|gpu" $1 "|" $2), ts, esc($3) }
        END { printf "]}" }' "$PROP_FILE")
    code=$(curl -s $CURL_TLS -o "${WORK_DIR}/prop.resp" -w '%{http_code}' --max-time 30 \
        -X POST "${OPS_BASE}/suite-api/api/resources/${OPS_RESOURCE_ID}/properties" \
        -H "Authorization: ${AUTH_SCHEME} ${OPS_TOKEN}" -H 'Content-Type: application/json' -H 'Accept: application/json' \
        -d "$body" 2>/dev/null)
    case "$code" in
        200|201|204) echo "[INFO] properties recorded: $(wc -l < "$PROP_FILE" | tr -d ' ') GPU items + Collected At, GPU Count" ;;
        *) echo "[WARN] property write failed HTTP ${code}: $(head -c 200 "${WORK_DIR}/prop.resp" 2>/dev/null)" >&2 ;;
    esac
}


# ----------------------------------------------------------
# 6. Termination
# ----------------------------------------------------------
cleanup() {
    pkill -TERM -P $$ 2>/dev/null
    [ "$PID_OWNED" -eq 1 ] && rm -f "$PID_FILE"
    [ -n "$WORK_DIR" ] && rm -rf "$WORK_DIR"
    if [ "$DO_CHECK" -eq 0 ]; then
        echo ""
        echo "Stopped: $(date '+%Y-%m-%d %H:%M:%S')  [${LOOP} completed intervals / ${PUSH_TRY} pushes / ${CSV_ROWS} CSV intervals]"
        [ "$CSV_MODE" -eq 1 ] && echo "Last CSV: ${CSV_PATH}"
    fi
    exit 0
}
trap cleanup TERM INT


# ----------------------------------------------------------
# 7. Start: nvidia-smi checks and field probe
# ----------------------------------------------------------
run_nv "$PROBE_TIMEOUT" -L
rc=$?
if [ "$rc" -ne 0 ] || ! grep -q '^GPU ' "$NV_OUT"; then
    echo "[ERROR] nvidia-smi -L failed [exit ${rc}: $(nv_rc_text "$rc")]" >&2
    cat "$NV_OUT" "$NV_ERR" 2>/dev/null | grep -v '^[[:space:]]*$' | head -3 | sed 's/^/        /' >&2
    echo "        DirectPath I/O GPUs are visible only inside their VM, with the NVIDIA driver loaded." >&2
    rm -rf "$WORK_DIR"; exit 1
fi
GPU_COUNT_START=$(grep -c '^GPU ' "$NV_OUT")
cp "$NV_OUT" "${WORK_DIR}/gpulist"

Q_ALL=$(table_sources q)
probe_query_fields "$Q_ALL" DROPPED_Q
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "[ERROR] nvidia-smi --query-gpu failed [exit ${rc}: $(nv_rc_text "$rc")]" >&2
    rm -rf "$WORK_DIR"; exit 1
fi
Q_LIST="$PROBE_RESULT"
# Older drivers: clocks_throttle_reasons.* instead of clocks_event_reasons.*
case ",${DROPPED_Q}," in
    *,clocks_event_reasons.*)
        METRIC_TABLE=$(printf '%s\n' "$METRIC_TABLE" | sed 's/q:clocks_event_reasons\./q:clocks_throttle_reasons./')
        DROPPED_Q=""
        probe_query_fields "$(table_sources q)" DROPPED_Q
        Q_LIST="$PROBE_RESULT"
        FIELD_NOTE="clock event reasons read as clocks_throttle_reasons.* (older driver)"
        ;;
esac
P_ALL=$(printf '%s\n' "$PROP_TABLE" | awk 'NF>=2 && $1 !~ /^#/ { o=o (o==""?"":",") $NF } END { printf "%s", o }')
probe_query_fields "$P_ALL" DROPPED_P
P_LIST="$PROBE_RESULT"

if [ -n "$(table_sources d)" ]; then
    run_nv "$PROBE_TIMEOUT" dmon -s et -c 1
    [ $? -eq 0 ] && grep -q 'rxpci' "$NV_OUT" && DMON_OK=1
fi
if [ -n "$(table_sources r)" ]; then
    run_nv "$PROBE_TIMEOUT" --query-remapped-rows="gpu_bus_id,$(table_sources r)" --format=csv,noheader,nounits
    [ $? -eq 0 ] && REMAP_OK=1
fi
if [ "$CSV_MODE" -eq 1 ] || [ "$DO_CHECK" -eq 1 ]; then
    run_nv "$PROBE_TIMEOUT" --query-compute-apps="gpu_bus_id,pid,process_name,used_gpu_memory" --format=csv,noheader,nounits
    if [ $? -eq 0 ]; then PROC_OK=1
    else
        run_nv "$PROBE_TIMEOUT" --query-compute-apps="gpu_bus_id,pid,process_name,used_memory" --format=csv,noheader,nounits
        [ $? -eq 0 ] && { PROC_OK=1; PROC_MEM_FIELD="used_memory"; }
    fi
fi
build_active_table
METRIC_ON=$(wc -l < "$TABLE_FILE" | tr -d ' ')
METRIC_ALL=$(printf '%s\n' "$METRIC_TABLE" | awk 'NF>=3 && $1 !~ /^#/ { n++ } END { print n+0 }')


# ----------------------------------------------------------
# 7-1. --check: one sample now, print, exit
# ----------------------------------------------------------
if [ "$DO_CHECK" -eq 1 ]; then
    echo "================ gpu_metric_push --check ================"
    echo "nvidia-smi     : $(command -v "$NV_BIN" 2>/dev/null || echo "$NV_BIN")"
    echo "GPUs           : ${GPU_COUNT_START}"
    sed 's/^/                 /' "${WORK_DIR}/gpulist"
    echo "metrics        : ${METRIC_ON} of ${METRIC_ALL} in use"
    [ -n "$DROPPED_Q" ] && echo "dropped fields : ${DROPPED_Q} (unknown to this driver)"
    [ -n "$DROPPED_P" ] && echo "dropped props  : ${DROPPED_P} (unknown to this driver)"
    [ -n "$FIELD_NOTE" ] && echo "note           : ${FIELD_NOTE}"
    echo "dmon -s et     : $([ "$DMON_OK" -eq 1 ] && echo ok || echo 'not available -> PCIe_Rx/Tx/Replay skipped')"
    echo "remapped rows  : $([ "$REMAP_OK" -eq 1 ] && echo ok || echo 'not available -> Remap_* skipped')"
    echo "compute apps   : $([ "$PROC_OK" -eq 1 ] && echo "ok (${PROC_MEM_FIELD})" || echo 'not available')"
    : > "$MIN_FILE"
    take_sample 1
    echo "sample         : exit ${SAMPLE_RC} ($(nv_rc_text "$SAMPLE_RC"))"
    take_remap 1
    aggregate_minute
    echo ""
    echo "--- raw --query-gpu line(s) for: index,pci.bus_id,${Q_LIST}"
    run_nv "$NV_TIMEOUT" --query-gpu="index,pci.bus_id${Q_LIST:+,$Q_LIST}" --format=csv,noheader,nounits
    sed 's/^/    /' "$NV_OUT"
    echo ""
    echo "--- values that would be pushed (one sample; avg/pct of 1 sample)"
    awk -F'\t' '{ printf "    %-4s %-26s %s\n", ($1=="-" ? "VM" : "gpu" $1), $2, $3 }' "$AGG_FILE"
    echo ""
    echo "--- metrics with no value on this GPU (N/A, Not Supported or not collected)"
    awk 'FNR==NR { have[$2]=1; next } NF>=3 && $1 !~ /^#/ && !($1 in have) { printf "    %-26s %s\n", $1, $3 }' "$AGG_FILE" "$TABLE_FILE"
    printf '%s\n' "$METRIC_TABLE" | awk -v ql=",${Q_LIST}," -v dm="$DMON_OK" -v rm="$REMAP_OK" '
        NF>=3 && $1 !~ /^#/ { n=index($3, ":"); p=substr($3, 1, n-1); f=substr($3, n+1)
            if ((p=="q" && index(ql, "," f ",")==0) || (p=="d" && dm!=1) || (p=="r" && rm!=1)) printf "    %-26s %s (not collected)\n", $1, $3 }'
    collect_props
    echo ""
    echo "--- properties (written once at start in ops mode)"
    awk -F'\t' '{ printf "    gpu%-3s %-26s %s\n", $1, $2, $3 }' "$PROP_FILE"
    if [ "$PROC_OK" -eq 1 ]; then
        echo ""
        echo "--- compute processes now"
        run_nv "$NV_TIMEOUT" --query-compute-apps="gpu_bus_id,pid,process_name,${PROC_MEM_FIELD}" --format=csv,noheader,nounits
        if [ -s "$NV_OUT" ]; then sed 's/^/    /' "$NV_OUT"; else echo "    (none)"; fi
    fi
    echo "========================================================="
    rm -rf "$WORK_DIR"
    exit 0
fi


# ----------------------------------------------------------
# 8. Start: Ops connection, PID file, banner
# ----------------------------------------------------------
if [ "$OPS_MODE" -eq 1 ]; then
    { [ "$OPS_HOST" = "ops.example.com" ] || [ -z "$OPS_HOST" ]; } && {
        echo "[ERROR] Ops address not set. Put OPS_HOST=<address> into ${OPS_CONFIG} [${CONFIG_STATE}], or use --host / env OPS_HOST." >&2
        [ "$CONFIG_STATE" = "not found" ] && echo "        Put ops_local.conf (the file with the four keys) there and fill it in." >&2
        rm -rf "$WORK_DIR"; exit 1; }
    [ -z "$OPS_USER" ] && {
        echo "[ERROR] account not set. Put OPS_USER=<account> into ${OPS_CONFIG} [${CONFIG_STATE}], or use --user / env OPS_USER." >&2
        rm -rf "$WORK_DIR"; exit 1; }
    [ -z "$OPS_PASSWORD" ] && { OPS_PASSWORD=$(decrypt_pass) || { rm -rf "$WORK_DIR"; exit 1; }; }
    command -v curl >/dev/null 2>&1 || { echo "[ERROR] curl not found" >&2; rm -rf "$WORK_DIR"; exit 1; }
    if command -v python3 >/dev/null 2>&1; then JSON_TOOL="python3"
    elif command -v jq >/dev/null 2>&1; then JSON_TOOL="jq"
    else echo "[ERROR] python3 or jq required" >&2; rm -rf "$WORK_DIR"; exit 1; fi
    case "$OPS_HOST" in
        http://*|https://*) OPS_BASE="${OPS_HOST%/}" ;;
        *)                  OPS_BASE="https://${OPS_HOST}" ;;
    esac
    if [ -n "$OPS_CACERT" ]; then
        [ -r "$OPS_CACERT" ] || { echo "[ERROR] --cacert not readable" >&2; rm -rf "$WORK_DIR"; exit 1; }
        CURL_TLS="--cacert ${OPS_CACERT}"
    else
        CURL_TLS="-k"
    fi
    acquire_token || { echo "[ERROR] token acquisition failed -> abort [check LOCAL account/password/address/443]" >&2; rm -rf "$WORK_DIR"; exit 1; }
    detect_auth_scheme || { rm -rf "$WORK_DIR"; exit 1; }
    if [ -z "$OPS_RESOURCE_ID" ]; then
        lookup_vm || { echo "[ERROR] VirtualMachine '${OPS_VM_NAME}' not found in Ops. Use --vm <name as shown in Ops> or --resource-id." >&2; rm -rf "$WORK_DIR"; exit 1; }
    fi
fi

if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        echo "[ERROR] Already running [PID ${OLD_PID}]. Stop with: bash $0 --stop" >&2
        rm -rf "$WORK_DIR"; exit 1
    fi
fi
if echo "$$" > "$PID_FILE" 2>/dev/null; then PID_OWNED=1; else echo "[WARN] failed to write PID file (${PID_FILE})" >&2; fi

[ "$CSV_MODE" -eq 1 ] && csv_setup

if [ "$OPS_MODE" -eq 1 ]; then
    collect_props
    push_props
fi

echo "================ gpu_metric_push v${SCRIPT_VERSION} ================"
echo " - mode           : ${OUT_MODE}$([ "$DRY_RUN" -eq 1 ] && echo ' (dry-run: JSON printed, not pushed)')"
echo " - GPUs           : ${GPU_COUNT_START}"
echo " - samples        : ${SAMPLES} per ${INTERVAL_SEC}s, every ${SAMPLE_GAP}s from second 00; nvidia-smi time limit ${NV_TIMEOUT}s"
echo " - metrics        : ${METRIC_ON} of ${METRIC_ALL} in use"
[ -n "$DROPPED_Q" ] && echo " - dropped fields : ${DROPPED_Q} (unknown to this driver)"
[ -n "$FIELD_NOTE" ] && echo " - note           : ${FIELD_NOTE}"
echo " - dmon / remap   : $([ "$DMON_OK" -eq 1 ] && echo ok || echo off) / $([ "$REMAP_OK" -eq 1 ] && echo ok || echo off)"
if [ "$OPS_MODE" -eq 1 ]; then
    echo " - Ops            : ${OPS_BASE} (${AUTH_SCHEME})"
    echo " - config file    : ${OPS_CONFIG} [${CONFIG_STATE}]"
    echo " - target         : VirtualMachine ${OPS_VM_NAME} -> ${OPS_RESOURCE_ID}"
    echo " - Ops tree       : ${OPS_STAT_ROOT} > ${OPS_GROUP} > gpu<N> > <metric>"
fi
[ "$CSV_MODE" -eq 1 ] && echo " - CSV            : ${CSV_PATH}"
echo " - stop           : bash $0 --stop"
echo "======================================================"
echo "[INFO] Waiting for the next ${INTERVAL_SEC}s boundary..."


# ----------------------------------------------------------
# 9. Main loop
# ----------------------------------------------------------
while true; do
    NOW_EPOCH=$(date '+%s')
    NEXT_EPOCH=$(( (NOW_EPOCH / INTERVAL_SEC + 1) * INTERVAL_SEC ))
    { sleep $(( NEXT_EPOCH - NOW_EPOCH )); } 2>/dev/null   # no "Terminated" line on --stop
    T0="$NEXT_EPOCH"
    TIMESTAMP=$(date '+%Y-%m-%dT%H:%M:%S')

    if [ "$OPS_MODE" -eq 1 ]; then
        if [ -f "$REAUTH_FLAG" ] || [ "$T0" -ge $(( TOKEN_EXP - TOKEN_MARGIN_SEC )) ]; then
            acquire_token && echo "[INFO] ${TIMESTAMP} token re-acquired" || echo "[WARN] ${TIMESTAMP} token re-acquisition failed" >&2
        fi
    fi

    : > "$MIN_FILE"
    s=1
    while [ "$s" -le "$SAMPLES" ]; do
        if [ "$s" -gt 1 ]; then
            TGT=$(( T0 + (s - 1) * SAMPLE_GAP )); NOW_EPOCH=$(date '+%s')
            [ "$TGT" -gt "$NOW_EPOCH" ] && { sleep $(( TGT - NOW_EPOCH )); } 2>/dev/null
        fi
        take_sample "$s"
        [ "$SAMPLE_RC" -ne 0 ] && echo "[WARN] ${TIMESTAMP} sample ${s}: nvidia-smi exit ${SAMPLE_RC} ($(nv_rc_text "$SAMPLE_RC"))" >&2
        s=$(( s + 1 ))
    done
    take_remap "$SAMPLES"
    aggregate_minute

    JSON=$(build_json $(( T0 * 1000 )))
    if [ "$DRY_RUN" -eq 1 ] && [ "$CSV_MODE" -eq 0 ]; then
        echo "$JSON"
    elif [ "$OPS_MODE" -eq 1 ]; then
        push_stats "$JSON" "$TIMESTAMP" &
        PUSH_TRY=$(( PUSH_TRY + 1 ))
    fi
    if [ "$CSV_MODE" -eq 1 ]; then
        csv_write_minute "$TIMESTAMP" "$T0"
        csv_write_procs "$TIMESTAMP" "$T0"
    fi
    LOOP=$(( LOOP + 1 ))
    echo "[${TIMESTAMP}] #${LOOP} | $(minute_summary)"
done
