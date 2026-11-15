#!/bin/sh
# ===========================================================
# set_cat_qos.sh v1.10 - CAT profile all-in-one apply for ESXi
# Usage : sh set_cat_qos.sh catp<P>s<S>[h<H>|e<H>] [PVM1] [PVM2|+|-] [SVM|none] [--no-ops]
#
# v1.10 (2026-10-19): Operations record (default on).
#   (default)      after APPLY SUMMARY, write the applied state to the
#                  HostSystem object in VCF Operations as properties
#                    Custom Configuration|CAT|Profile / Topology / LLC Instances /
#                    Masks / Reserved IDs / Tagging / Verify / Applied At
#                  A failed write prints [WARN] only; the CAT result is unchanged.
#                  plus one metric Custom Metrics|Config|Cat_Profile_Code (default on)
#                  (catp<P>s<S> = P*100+S, h<H> adds 0.1*H, e<E> adds 0.2*E, none = 0)
#   --no-ops       skip the Operations record entirely (--ops / --ops-metrics are accepted and mean the default)
#   --no-ops-metrics  write the properties only, skip the metric
#   --ops-check    preflight only (openssl decrypt, token, auth scheme, HostSystem
#                  lookup, firewall httpClient). No vsish change. Exit 0 = ready.
#   --ops-host H / --ops-user U / --ops-name NAME / --pass-file FILE  override USER SETTINGS
#   Credentials: same scheme as ops_metric_push_v4_1.sh / vmkperf_ops_push.py
#     (OPS_PASS_ENC + OPS_ENC_KEY, decrypted with the ESXi openssl). If both are empty
#     the script looks for ops_metric_push_v4*.sh next to itself. Env OPS_PASSWORD also works.
#   Needs: python3 on the host (ESXi ships it), firewall ruleset httpClient enabled.
#   VM names must not contain spaces (options are separated from positional args by a rebuild).
#   defaults: PVM1=<host>ev01  PVM2=<host>ev02  SVM=<host>ev03
#   e.g.  catp14s1 catp15s1 catp15s3 catp15s6 catp15s9 catp15s1h1
#   With NO VM args the topology is AUTO-DETECTED from POWERED-ON VMs
#   (ps lists vmx-vcpu worlds of running VMs only; powered-off or
#    suspended VMs have no worlds - same spirit as v1.3's
#    LLC-instance / vCPU enumeration):
#     ev01+ev02 on, no ev03 -> Dual VM     (1 PVM + 1 SVM, SVM=ev02)
#     ev01+ev02+ev03 on     -> Two Dual VM (2 PVM + 1 SVM, SVM=ev03)
#     anything else         -> abort, pass VM names explicitly
#   Topology labels (aligned with the vCPU affinity
#   script SetVcpuAffinityProfile_v3_9):
#     Dual VM     = 1 PVM + 1 SVM   (v1.8 label: DualVM+SVM)
#     Two VM      = 2 PVM, no SVM   (new in v1.9 - "none" in the SVM slot)
#     Two Dual VM = 2 PVM + 1 SVM   (v1.8 label: TwoVM+SVM)
#   Apply time is stamped in KST.
#   Explicit VM args override auto-detection:
#     "-" in the PVM1/SVM slot = use the default name;
#     "-" in the PVM2 slot = force single-PVM mode (old 1 PVM + 1 SVM):
#     only PVM1 and SVM are tagged, SVM default becomes <host>ev02.
#     e.g. sh set_cat_qos.sh catp15s1 - -     (PVM=ev01, SVM=ev02)
#   Both topologies use the SAME masks - only tagging differs, so
#   switching per test = just re-run (or let auto-detect decide).
# v1.9 (0915): topology names aligned + SVM-less topologies.
#   - "none" in the SVM slot = no SVM: only PVM(s) are tagged.
#     The CLOS2 mask is still programmed per the profile string;
#     it simply has no VM registered to it.
#   - auto-detect cannot tell Two VM from Dual VM by power state
#     (both look like 2 VMs on), so SVM-less runs must pass VM
#     names explicitly, e.g.
#     PVM2 slot tokens: "+" = default name (<host>ev02) as second PVM,
#     "-"/"none" = no PVM2 (unchanged from v1.8).
#       sh set_cat_qos.sh catp15s1 - + none   (Two VM: ev01+ev02 as PVMs)
#       sh set_cat_qos.sh catp15s1 - - none   (PVM only: ev01)
#   - masks, reserve steps and tagging logic unchanged from v1.8.
# v1.8 (0908): 2 PVM + 1 SVM topology.
#   - PVM1 pinned inside NUMA node 0, PVM2 inside NUMA node 1
#     (vCPU-to-node pinning is configured on the VM side -
#      this script does NOT set or check it).
#   - both PVMs share rmID 1 / closID 1: masks are per LLC instance
#     and identical, so PVM1 owns the top P ways on its node's LLC
#     and PVM2 on the other node's LLC - no way sharing as long as
#     each PVM stays inside its node. per-LLC monitoring still
#     separates them (rmID 1 on llc/0 = PVM1, llc/1 = PVM2, SNC off).
#   - SVM spans both nodes: rmID 2 / closID 2, bottom S ways on
#     BOTH LLC instances, as before.
#   profile grammar and mask layout unchanged from v1.7.
# Profile grammar (0831):
#   p<P>     PVM (CLOS1) gets the TOP P ways of the LLC
#   s<S>     SVM (CLOS2) gets the bottom S ways; without h, system
#            (CLOS0) shares that whole bottom span (SYS == SVM mask)
#   h<H>     system limited to the bottom H ways only, still INSIDE
#            the SVM span (shared with SVM, not separate ways).
#            e.g. catp8s8h1: PVM way 14-7, SVM way 7-0, system way 0
#   (v1.6 fix: v1.5 wrongly placed the SVM span ABOVE separate
#    system ways; system and SVM must share)
#   e<H>     EXCLUSIVE layout (v1.7): all three
#            CLOS disjoint - system = bottom H ways alone, SVM = next
#            S ways above it, PVM = top P ways. Ways left between the
#            SVM span and the PVM span stay unused (isolation gap).
#            e.g. catp12s2e1: system way 0, SVM way 1-2, PVM way 3-14
#                 catp8s6e1 : system way 0, SVM way 1-6, PVM way 7-14
#   Way count defaults to 15 (override: CAT_WAYS=nn env var)
# Environment adaptivity (unchanged since v1.3):
#   - LLC instance count auto-detected from vsish ls
#     (SNC on/off -> 2 or 4 instances; loop covers whatever is listed)
#   - vCPU worlds enumerated from ps at run time
#     (HT on/off changes world count only; tagging is unaffected)
# v1.4 base: reserve steps are check-then-set (re-run safe,
#   avoids "out of resources" on already-reserved IDs)
# - set_qos_id logic inlined (Phani RDT doc):
#     vsish -e set /sched/qos/setID <worldID> <rmID> <closID>
# - Final STATE DUMP enumerates ACTUAL applied state
# - vsish settings are VOLATILE: re-run after every host reboot
# ===========================================================

QOS_ROOT=/sched/qos/resources/llc

# ==== USER SETTINGS (Operations) - edit here only ===========
OPS_HOST_DEFAULT=""   # VCF Operations address or IP
OPS_USER_DEFAULT=""                      # Operations LOCAL account
OPS_AUTHSOURCE="LOCAL"
OPS_INSECURE=1                                  # 1 = skip TLS verification
OPS_PASS_ENC=""                                 # openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt -pass pass:<KEY> -base64 -A
OPS_ENC_KEY=""
OPS_HOST_NAME_DEFAULT=""                        # HostSystem name in Operations; "" = FQDN from esxcli system hostname
OPS_PROP_ROOT="Custom Configuration|CAT"
OPS_METRIC_ROOT="Custom Metrics|Config"
# ==== end USER SETTINGS ======================================

OPS=1; OPS_METRICS=1; OPS_CHECK=0          # default: properties + metric Cat_Profile_Code (--no-ops skips all, --no-ops-metrics skips the metric)
OPS_HOST="$OPS_HOST_DEFAULT"; OPS_USER="$OPS_USER_DEFAULT"; OPS_HOST_NAME="$OPS_HOST_NAME_DEFAULT"; OPS_PASS_FILE=""
# pull the --ops options out of the positional list (busybox sh: rebuild "$@")
ARGS=""
while [ $# -gt 0 ]; do
    case "$1" in
        --ops)         OPS=1 ;;
        --no-ops)      OPS=0 ;;
        --ops-metrics) OPS=1; OPS_METRICS=1 ;;
        --no-ops-metrics) OPS_METRICS=0 ;;
        --ops-check)   OPS=1; OPS_CHECK=1 ;;
        --ops-host)    shift; OPS_HOST="$1" ;;
        --ops-user)    shift; OPS_USER="$1" ;;
        --ops-name)    shift; OPS_HOST_NAME="$1" ;;
        --pass-file)   shift; OPS_PASS_FILE="$1" ;;
        *) ARGS="$ARGS $1" ;;
    esac
    shift
done
set -- $ARGS

SCRIPT_DIR=`dirname "$0"`
ops_password() {
    # env OPS_PASSWORD > --pass-file > OPS_PASS_ENC/OPS_ENC_KEY > ops_metric_push_v4*.sh beside this script
    if [ -n "$OPS_PASSWORD" ]; then echo "$OPS_PASSWORD"; return 0; fi
    if [ -n "$OPS_PASS_FILE" ]; then head -1 "$OPS_PASS_FILE" 2>/dev/null; return 0; fi
    ENC="$OPS_PASS_ENC"; KEY="$OPS_ENC_KEY"
    if [ -z "$ENC" ] || [ -z "$KEY" ]; then
        for f in "$SCRIPT_DIR"/ops_metric_push_v4*.sh "$SCRIPT_DIR"/ops_metric_push_v4*.txt; do
            [ -f "$f" ] || continue
            ENC=`sed -n 's/^OPS_PASS_ENC="\([^"]*\)".*/\1/p' "$f" | head -1`
            KEY=`sed -n 's/^OPS_ENC_KEY="\([^"]*\)".*/\1/p' "$f" | head -1`
            [ -n "$ENC" ] && [ -n "$KEY" ] && break
        done
    fi
    [ -z "$ENC" ] || [ -z "$KEY" ] && return 1
    printf '%s' "$ENC" | openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 -pass "pass:$KEY" -base64 -A 2>/dev/null
}

# ops_push <check|record> : talks to Operations with the python3 that ships with ESXi
ops_push() {
    OPS_MODE=$1
    PY=`command -v python3 2>/dev/null`; [ -z "$PY" ] && [ -x /bin/python ] && PY=/bin/python
    [ -z "$PY" ] && { echo "[WARN] ops: python3 not found on this host - nothing recorded"; return 1; }
    OPS_PASSWORD_V=`ops_password`
    [ -z "$OPS_PASSWORD_V" ] && { echo "[WARN] ops: no password (set OPS_PASS_ENC/OPS_ENC_KEY, --pass-file or env OPS_PASSWORD) - nothing recorded"; return 1; }
    [ -z "$OPS_HOST_NAME" ] && OPS_HOST_NAME=`esxcli system hostname get 2>/dev/null | sed -n 's/.*Fully Qualified Domain Name: *//p' | head -1`
    [ -z "$OPS_HOST_NAME" ] && OPS_HOST_NAME=`hostname 2>/dev/null`
    FW=`esxcli network firewall ruleset list -r httpClient 2>/dev/null | awk 'NR>2{print $2}'`
    export OPS_MODE OPS_HOST OPS_USER OPS_AUTHSOURCE OPS_INSECURE OPS_HOST_NAME OPS_PROP_ROOT OPS_METRIC_ROOT OPS_METRICS FW
    export CAT_PROFILE="$PROFILE" CAT_TOPO="$TOPO" CAT_LLC="$NUM ($LLC_FLAT)" CAT_MASKS="clos0=$SYS_MASK clos1=$PVM_MASK clos2=$SVM_MASK"
    export CAT_RESERVED="$RSVD_TXT" CAT_TAGGING="$TAG_TXT" CAT_VERIFY="$VERIFY_TXT" CAT_APPLIED="$RUN_KST KST"
    OPS_PASSWORD="$OPS_PASSWORD_V" "$PY" - <<'PYEOF_OPS'
import os, sys, json, ssl, time, re, urllib.request, urllib.parse
host=os.environ["OPS_HOST"]; user=os.environ["OPS_USER"]; pw=os.environ["OPS_PASSWORD"]; src=os.environ.get("OPS_AUTHSOURCE","LOCAL")
insecure=os.environ.get("OPS_INSECURE","1")=="1"; name=os.environ["OPS_HOST_NAME"]; mode=os.environ["OPS_MODE"]
proot=os.environ["OPS_PROP_ROOT"]; mroot=os.environ["OPS_METRIC_ROOT"]; want_metric=os.environ.get("OPS_METRICS","0")=="1"
ctx=ssl._create_unverified_context() if insecure else ssl.create_default_context()
opener=urllib.request.build_opener(urllib.request.HTTPSHandler(context=ctx))
base="https://"+host; token=None; scheme="OpsToken"
def req(method,path,body=None,auth=True,query=None):
    url=base+path+(("?"+urllib.parse.urlencode(query)) if query else "")
    data=json.dumps(body).encode("utf-8") if body is not None else None
    r=urllib.request.Request(url,data=data,method=method); r.add_header("Accept","application/json")
    if data is not None: r.add_header("Content-Type","application/json")
    if auth and token: r.add_header("Authorization","%s %s"%(scheme,token))
    try:
        resp=opener.open(r,timeout=20); return resp.getcode(), resp.read().decode("utf-8","replace")
    except Exception as e:
        code=getattr(e,"code",0)
        try: text=e.read().decode("utf-8","replace")
        except Exception: text=str(e)
        return code,text
def fail(msg):
    print("[WARN] ops: "+msg); sys.exit(1)
if os.environ.get("FW","") and os.environ["FW"].lower()!="true":
    print("[WARN] ops: firewall ruleset httpClient is not enabled (esxcli network firewall ruleset set -e true -r httpClient)")
code,text=req("POST","/suite-api/api/auth/token/acquire",{"username":user,"password":pw,"authSource":src},auth=False)
try: token=json.loads(text).get("token")
except ValueError: token=None
if not token: fail("token acquisition failed HTTP %s %s"%(code,text[:160]))
ok=False
for s in ("OpsToken","vRealizeOpsToken"):
    scheme=s; c,t=req("GET","/suite-api/api/resources",query={"pageSize":1,"_no_links":"true"})
    if c==200: ok=True; break
if not ok: fail("auth header rejected (OpsToken/vRealizeOpsToken)")
c,t=req("GET","/suite-api/api/resources",query={"adapterKindKey":"VMWARE","resourceKind":"HostSystem","name":name,"_no_links":"true"})
try: rl=json.loads(t).get("resourceList") or []
except ValueError: rl=[]
hit=[r for r in rl if ((r.get("resourceKey") or {}).get("name") or "").lower()==name.lower()]
if not hit:
    # fallback: Operations may hold the host as short name or with another domain suffix
    short=name.split(".")[0]; rx="^"+re.escape(short)+"(\\..*)?$"
    c,t=req("GET","/suite-api/api/resources",query={"adapterKindKey":"VMWARE","resourceKind":"HostSystem","regex":rx,"_no_links":"true"})
    try: rl=json.loads(t).get("resourceList") or []
    except ValueError: rl=[]
    hit=[r for r in rl if re.match(rx,((r.get("resourceKey") or {}).get("name") or ""),re.I)]
    if hit: name=(hit[0].get("resourceKey") or {}).get("name") or name
if not hit: fail("HostSystem '%s' not found in Operations (HTTP %s, %d candidates) - use --ops-name <name as shown in Operations>"%(name,c,len(rl)))
rid=hit[0].get("identifier")
if mode=="check":
    print("[OPS-CHECK] token ok (%s), HostSystem %s -> %s, firewall httpClient=%s"%(scheme,name,rid,os.environ.get("FW","?"))); sys.exit(0)
ts=int(time.time()*1000)
items=[("Profile",os.environ["CAT_PROFILE"]),("Topology",os.environ["CAT_TOPO"]),("LLC Instances",os.environ["CAT_LLC"]),("Masks",os.environ["CAT_MASKS"]),
       ("Reserved IDs",os.environ["CAT_RESERVED"]),("Tagging",os.environ["CAT_TAGGING"]),("Verify",os.environ["CAT_VERIFY"]),("Applied At",os.environ["CAT_APPLIED"])]
body={"property-content":[{"statKey":"%s|%s"%(proot,k),"timestamps":[ts],"values":[v]} for k,v in items]}
c,t=req("POST","/suite-api/api/resources/%s/properties"%rid,body)
if c not in (200,201,204): fail("property write failed HTTP %s %s"%(c,t[:160]))
msg="[OPS] %s CAT Profile=%s recorded %s (%d properties)"%(name,os.environ["CAT_PROFILE"],os.environ["CAT_APPLIED"],len(items))
if want_metric:
    m=re.match(r"catp(\d+)s(\d+)(?:h(\d+)|e(\d+))?$",os.environ["CAT_PROFILE"])
    codev=0.0
    if m: codev=int(m.group(1))*100+int(m.group(2))+0.1*int(m.group(3) or 0)+0.2*int(m.group(4) or 0)
    sb={"stat-content":[{"statKey":"%s|Cat_Profile_Code"%mroot,"timestamps":[ts],"data":[codev]}]}
    c,t=req("POST","/suite-api/api/resources/%s/stats"%rid,sb)
    msg+=", metric Cat_Profile_Code=%s %s"%(codev,"ok" if c in (200,201,204) else "FAILED HTTP %s"%c)
print(msg)
PYEOF_OPS
}

if [ $OPS_CHECK -eq 1 ]; then
    ops_push check
    exit $?
fi

PROFILE=$1
WAYS=${CAT_WAYS:-15}

# ---- run timestamp (UTC + KST) ----------------------------
# ESXi host clock is UTC; KST = UTC+9 (POSIX TZ sign is inverted: KST-9)
RUN_UTC=`TZ=UTC date '+%Y-%m-%d %H:%M:%S'`
RUN_KST=`TZ=KST-9 date '+%Y-%m-%d %H:%M:%S'`
FULL_MASK_N=$(( (1 << WAYS) - 1 ))
FULL_MASK=`printf '0x%x' $FULL_MASK_N`

usage() {
    echo "[ERR] usage: sh $0 catp<P>s<S>[h<H>|e<H>] [PVM1_NAME] [PVM2_NAME|+|-] [SVM_NAME|none]"
    echo "      e.g. catp14s1 | catp15s1 | catp15s3 | catp15s3h1 | catp12s2e1 | catp8s6e1"
    echo "      PVM2 '-' = single-PVM mode (PVM=ev01, SVM=ev02 defaults)"
    exit 1
}

# ---- parse profile name -----------------------------------
case "$PROFILE" in
    catp[0-9]*s[0-9]*) ;;
    *) usage ;;
esac
P=`expr "$PROFILE" : 'catp\([0-9][0-9]*\)s'`
S=`expr "$PROFILE" : 'catp[0-9][0-9]*s\([0-9][0-9]*\)'`
H=`expr "$PROFILE" : '.*h\([0-9][0-9]*\)$'`
[ -z "$H" ] && H=0
E=`expr "$PROFILE" : '.*e\([0-9][0-9]*\)$'`
[ -z "$E" ] && E=0
# reject trailing junk (e.g. catp15s1x2) and h+e together
EXPECT="catp${P}s${S}"
if [ "$E" -gt 0 ]; then
    EXPECT="${EXPECT}e${E}"
elif [ "$H" -gt 0 ]; then
    EXPECT="${EXPECT}h${H}"
fi
[ "$EXPECT" = "$PROFILE" ] || usage

# ---- validate counts --------------------------------------
[ "$P" -ge 1 ] && [ "$P" -le "$WAYS" ] || { echo "[ERR] p$P out of range 1..$WAYS"; exit 1; }
[ "$S" -ge 1 ] && [ "$S" -le "$WAYS" ] || { echo "[ERR] s$S out of range 1..$WAYS"; exit 1; }
if [ "$E" -gt 0 ]; then
    [ $(( S + E )) -le "$WAYS" ] || { echo "[ERR] s$S + e$E exceeds $WAYS ways"; exit 1; }
    GAP=$(( WAYS - P - S - E ))
    if [ "$GAP" -gt 0 ]; then
        echo "[INFO] exclusive layout leaves $GAP way(s) unused between SVM and PVM"
    elif [ "$GAP" -lt 0 ]; then
        echo "[WARN] PVM top $P ways overlaps the SVM span (p+s+e > $WAYS) - allowed but check intent"
    fi
else
    if [ "$H" -gt "$S" ]; then
        echo "[WARN] h$H exceeds s$S - system mask reaches beyond the SVM span, check intent"
    fi
    if [ "$P" -lt "$WAYS" ] && [ $(( P + S )) -gt "$WAYS" ]; then
        echo "[WARN] PVM top $P ways overlaps bottom $S ways (p+s > $WAYS) - allowed but check intent"
    fi
fi

# ---- compute masks ----------------------------------------
# PVM: top P ways (same mask on every LLC instance; NUMA pinning
#   decides which PVM actually uses which instance).
# shared family (no e): SVM = bottom S ways; system shares that span
#   (whole span, or only its bottom H ways when h<H> is given).
# exclusive family (e<E>): system = bottom E ways alone, SVM = next
#   S ways above it - all three CLOS disjoint.
PVM_MASK=`printf '0x%x' $(( ((1 << P) - 1) << (WAYS - P) ))`
if [ "$E" -gt 0 ]; then
    SYS_MASK=`printf '0x%x' $(( (1 << E) - 1 ))`
    SVM_MASK=`printf '0x%x' $(( ((1 << S) - 1) << E ))`
elif [ "$H" -gt 0 ]; then
    SVM_MASK=`printf '0x%x' $(( (1 << S) - 1 ))`
    SYS_MASK=`printf '0x%x' $(( (1 << H) - 1 ))`
else
    SVM_MASK=`printf '0x%x' $(( (1 << S) - 1 ))`
    SYS_MASK=$SVM_MASK
fi

# ---- VM names (arg override > hostname-derived default) ---
HN=`hostname 2>/dev/null`
HN=${HN%%.*}
# vm_up <name>: true if the VM has vcpu worlds in ps right now
vm_up() {
    VU_N=`ps | grep "$1" | grep vcpu | grep -v grep | wc -l`
    [ "$VU_N" -gt 0 ]
}

if [ $# -lt 2 ]; then
    # no VM args: decide topology from which ev0x VMs are running
    U1=0; U2=0; U3=0
    vm_up "${HN}ev01" && U1=1
    vm_up "${HN}ev02" && U2=1
    vm_up "${HN}ev03" && U3=1
    if [ $U1 -eq 1 ] && [ $U2 -eq 1 ] && [ $U3 -eq 1 ]; then
        PVM1_NAME=${HN}ev01; PVM2_NAME=${HN}ev02; SVM_NAME=${HN}ev03
        echo "[INFO] auto-detect: ev01+ev02+ev03 powered on -> Two Dual VM (2 PVM + 1 SVM)"
    elif [ $U1 -eq 1 ] && [ $U2 -eq 1 ]; then
        PVM1_NAME=${HN}ev01; PVM2_NAME=""; SVM_NAME=${HN}ev02
        echo "[INFO] auto-detect: ev01+ev02 powered on (no ev03) -> Dual VM (1 PVM + 1 SVM)"
    else
        echo "[ERR] auto-detect failed - powered on: ev01=$U1 ev02=$U2 ev03=$U3"
        echo "      need ev01+ev02 (Dual VM) or ev01+ev02+ev03 (Two Dual VM),"
        echo "      or pass VM names explicitly: sh $0 $PROFILE <PVM1> <PVM2|-> <SVM|none>"
        exit 1
    fi
else
    # "-" in the PVM1/SVM slot = use the default name;
    # "-" in the PVM2 slot = single-PVM mode (no PVM2)
    PVM1_NAME=${2:-${HN}ev01}
    [ "$PVM1_NAME" = "-" ] && PVM1_NAME=${HN}ev01
    PVM2_NAME=${3:-${HN}ev02}
    [ "$PVM2_NAME" = "+" ] && PVM2_NAME=${HN}ev02
    if [ "$PVM2_NAME" = "-" ] || [ "$PVM2_NAME" = "none" ]; then
        # single-PVM mode forced: old 1 PVM + 1 SVM topology (SVM = ev02 default)
        PVM2_NAME=""
        SVM_NAME=${4:-${HN}ev02}
        [ "$SVM_NAME" = "-" ] && SVM_NAME=${HN}ev02
        [ "$SVM_NAME" = "none" ] && SVM_NAME=""
    else
        SVM_NAME=${4:-${HN}ev03}
        [ "$SVM_NAME" = "-" ] && SVM_NAME=${HN}ev03
        [ "$SVM_NAME" = "none" ] && SVM_NAME=""
    fi
fi

# ---- detect LLC instances ---------------------------------
LLC_NODES=`vsish -e ls ${QOS_ROOT}/ 2>/dev/null | sed 's#/##'`
if [ -z "$LLC_NODES" ]; then
    echo "[ERR] no LLC nodes under ${QOS_ROOT}/ - CAT unsupported or vsish path changed"
    exit 1
fi
NUM=`echo "$LLC_NODES" | wc -l`
LLC_FLAT=`echo "$LLC_NODES" | tr '\n' ' '`
echo "[INFO] run at $RUN_UTC UTC / $RUN_KST KST"
echo "[INFO] profile=$PROFILE  ways=$WAYS  CLOS0(sys)=$SYS_MASK  CLOS1(PVM)=$PVM_MASK  CLOS2(SVM)=$SVM_MASK"
echo "[INFO] LLC instances=$NUM ( $LLC_FLAT) - SNC on/off covered by enumeration"
# topology label: Dual VM / Two VM / Two Dual VM / PVM only
if [ -n "$PVM2_NAME" ] && [ -n "$SVM_NAME" ]; then TOPO="Two Dual VM"
elif [ -n "$PVM2_NAME" ]; then TOPO="Two VM"
elif [ -n "$SVM_NAME" ]; then TOPO="Dual VM"
else TOPO="PVM only"; fi
if [ -n "$SVM_NAME" ]; then
    SVM_DESC="SVM=$SVM_NAME (rmID 2 / closID 2, spans nodes)"
else
    SVM_DESC="no SVM (CLOS2 mask programmed, no VM tagged)"
fi
if [ -n "$PVM2_NAME" ]; then
    echo "[INFO] topology: $TOPO - PVM1=$PVM1_NAME PVM2=$PVM2_NAME (both rmID 1 / closID 1, NUMA-split)  $SVM_DESC  [$RUN_KST KST]"
    echo "[INFO] PVM-to-node pinning (PVM1=node0, PVM2=node1) is a VM-side setting - not applied here"
else
    echo "[INFO] topology: $TOPO - PVM=$PVM1_NAME (rmID 1 / closID 1)  $SVM_DESC  [$RUN_KST KST]"
fi

# ---- sanity: warn if CBM width unexpected -----------------
CUR0=`vsish -e get ${QOS_ROOT}/0/closID/0/mask 2>/dev/null`
if [ "$CUR0" != "$FULL_MASK" ] && [ "$CUR0" != "$SYS_MASK" ]; then
    echo "[WARN] llc/0 CLOS0 mask=$CUR0 (expected $FULL_MASK default or $SYS_MASK already-applied) - verify way count (CAT_WAYS=$WAYS)"
fi

ERR=0

# ---- 1) rmID reserved (skip if already reserved) ----------
# ESXi rejects re-reserving an already-reserved ID ("out of resources"),
# so check current state first and only set when needed.
for i in $LLC_NODES; do
    for r in 1 2; do
        CUR=`vsish -e get ${QOS_ROOT}/$i/rmID/$r/reserved 2>/dev/null`
        if [ "$CUR" = "1" ]; then
            echo "  [SKIP] llc/$i rmID $r already reserved"
        else
            vsish -e set ${QOS_ROOT}/$i/rmID/$r/reserved 1 || { echo "[ERR] rmID $r reserve failed on llc/$i"; ERR=1; }
        fi
    done
done

# ---- 2) closID reserved (skip if already reserved) --------
for i in $LLC_NODES; do
    for c in 1 2; do
        CUR=`vsish -e get ${QOS_ROOT}/$i/closID/$c/reserved 2>/dev/null`
        if [ "$CUR" = "1" ]; then
            echo "  [SKIP] llc/$i closID $c already reserved"
        else
            vsish -e set ${QOS_ROOT}/$i/closID/$c/reserved 1 || { echo "[ERR] closID $c reserve failed on llc/$i"; ERR=1; }
        fi
    done
done

# ---- 3) masks ---------------------------------------------
for i in $LLC_NODES; do
    vsish -e set ${QOS_ROOT}/$i/closID/0/mask $SYS_MASK || { echo "[ERR] CLOS0 mask failed on llc/$i"; ERR=1; }
    vsish -e set ${QOS_ROOT}/$i/closID/1/mask $PVM_MASK || { echo "[ERR] CLOS1 mask failed on llc/$i"; ERR=1; }
    vsish -e set ${QOS_ROOT}/$i/closID/2/mask $SVM_MASK || { echo "[ERR] CLOS2 mask failed on llc/$i"; ERR=1; }
done

# ---- 4) VM tagging (inlined set_qos_id logic) -------------
# tag_vm <name-pattern> <rmID> <closID> <key>
# key distinguishes temp files per VM (two PVMs share rmID 1)
tag_vm() {
    TV_PAT=$1
    TV_RMID=$2
    TV_CLOS=$3
    TV_KEY=$4
    WLIST_FILE=/tmp/catqos_worlds_$$_${TV_KEY}
    : > $WLIST_FILE
    ps | grep "$TV_PAT" | grep vcpu | grep -v grep | awk '{print $1, $3;}' | while read -r worldid name; do
        if vsish -e set /sched/qos/setID "$worldid" "$TV_RMID" "$TV_CLOS"; then
            echo "$worldid $name" >> $WLIST_FILE
            echo "  [TAG] world $worldid ($name) -> rmID $TV_RMID / closID $TV_CLOS"
        else
            echo "  [ERR] setID failed for world $worldid ($name)"
        fi
    done
    TV_CNT=`wc -l < $WLIST_FILE`
    if [ "$TV_CNT" -eq 0 ]; then
        echo "[ERR] no vcpu worlds matched pattern '$TV_PAT' - VM not running or name wrong"
        return 1
    fi
    return 0
}

echo "[TAG] PVM1 $PVM1_NAME"
tag_vm "$PVM1_NAME" 1 1 p1
RC_P1=$?
P1_WLIST=/tmp/catqos_worlds_$$_p1
[ $RC_P1 -ne 0 ] && ERR=1

RC_P2=1
P2_WLIST=/tmp/catqos_worlds_$$_p2
if [ -n "$PVM2_NAME" ]; then
    echo "[TAG] PVM2 $PVM2_NAME"
    tag_vm "$PVM2_NAME" 1 1 p2
    RC_P2=$?
    [ $RC_P2 -ne 0 ] && ERR=1
fi

RC_SVM=1
SVM_WLIST=/tmp/catqos_worlds_$$_sv
if [ -n "$SVM_NAME" ]; then
    echo "[TAG] SVM $SVM_NAME"
    tag_vm "$SVM_NAME" 2 2 sv
    RC_SVM=$?
    [ $RC_SVM -ne 0 ] && ERR=1
fi

# ---- 5) per-vCPU readback ---------------------------------
# dump_vm <label> <worldlist-file> <expect-rmID> <expect-closID> <key>
# prints per-vCPU actual rmID/closID; returns 0 if all match
dump_vm() {
    DV_LBL=$1
    DV_FILE=$2
    DV_RMID=$3
    DV_CLOS=$4
    DV_KEY=$5
    DV_TOT=0
    DV_OK=0
    DV_OUT=/tmp/catqos_dump_$$_${DV_KEY}
    : > $DV_OUT
    while read -r wid name; do
        DV_TOT=`expr $DV_TOT + 1`
        SS=`vsish -e get /sched/Vcpus/$wid/stats/summaryStats 2>/dev/null`
        R=`echo "$SS" | grep rmID   | sed 's/[^0-9]*//g'`
        C=`echo "$SS" | grep closID | sed 's/[^0-9]*//g'`
        if [ "$R" = "$DV_RMID" ] && [ "$C" = "$DV_CLOS" ]; then
            MARK=OK
            DV_OK=`expr $DV_OK + 1`
        else
            MARK=MISMATCH
        fi
        echo "     world $wid ($name) : rmID=$R closID=$C [$MARK]" >> $DV_OUT
        echo "$DV_TOT $DV_OK" > /tmp/catqos_cnt_$$_${DV_KEY}
    done < $DV_FILE
    read DV_TOT DV_OK < /tmp/catqos_cnt_$$_${DV_KEY} 2>/dev/null
    rm -f /tmp/catqos_cnt_$$_${DV_KEY}
    [ -z "$DV_TOT" ] && DV_TOT=0
    [ -z "$DV_OK" ] && DV_OK=0
    echo "$DV_OK $DV_TOT"
    [ "$DV_OK" = "$DV_TOT" ] && [ "$DV_TOT" != "0" ]
}

P1_CNT="0 0"; P2_CNT="0 0"; SVM_CNT="0 0"
P1_VOK=0; P2_VOK=0; SVM_VOK=0
if [ $RC_P1 -eq 0 ]; then
    P1_CNT=`dump_vm PVM1 $P1_WLIST 1 1 p1` && P1_VOK=1 || ERR=1
fi
if [ $RC_P2 -eq 0 ]; then
    P2_CNT=`dump_vm PVM2 $P2_WLIST 1 1 p2` && P2_VOK=1 || ERR=1
fi
if [ $RC_SVM -eq 0 ]; then
    SVM_CNT=`dump_vm SVM $SVM_WLIST 2 2 sv` && SVM_VOK=1 || ERR=1
fi
P1_DUMP=/tmp/catqos_dump_$$_p1
P2_DUMP=/tmp/catqos_dump_$$_p2
SVM_DUMP=/tmp/catqos_dump_$$_sv

# ---- 6) enumerate ACTUAL reserved IDs + masks per LLC -----
STATE_DUMP=/tmp/catqos_state_$$
: > $STATE_DUMP
MASK_OK=1
for i in $LLC_NODES; do
    echo "  llc/$i" >> $STATE_DUMP
    # -- closIDs: list all, report reserved ones + CLOS0, with masks
    CLOS_LIST=`vsish -e ls ${QOS_ROOT}/$i/closID/ 2>/dev/null | sed 's#/##'`
    for c in $CLOS_LIST; do
        RSV=`vsish -e get ${QOS_ROOT}/$i/closID/$c/reserved 2>/dev/null`
        MSK=`vsish -e get ${QOS_ROOT}/$i/closID/$c/mask 2>/dev/null`
        if [ "$c" = "0" ] || [ "$RSV" = "1" ]; then
            case "$c" in
                0) ROLE="hypervisor" ;;
                1) ROLE="PVM" ;;
                2) ROLE="SVM" ;;
                *) ROLE="other" ;;
            esac
            echo "     closID $c ($ROLE) : reserved=$RSV mask=$MSK" >> $STATE_DUMP
        fi
    done
    # -- rmIDs: report reserved ones
    RM_LIST=`vsish -e ls ${QOS_ROOT}/$i/rmID/ 2>/dev/null | sed 's#/##'`
    RM_RSVD=""
    for r in $RM_LIST; do
        RSV=`vsish -e get ${QOS_ROOT}/$i/rmID/$r/reserved 2>/dev/null`
        [ "$RSV" = "1" ] && RM_RSVD="$RM_RSVD $r"
    done
    echo "     rmID reserved :$RM_RSVD" >> $STATE_DUMP
    # -- expected-value check
    M0=`vsish -e get ${QOS_ROOT}/$i/closID/0/mask 2>/dev/null`
    M1=`vsish -e get ${QOS_ROOT}/$i/closID/1/mask 2>/dev/null`
    M2=`vsish -e get ${QOS_ROOT}/$i/closID/2/mask 2>/dev/null`
    [ "$M0" = "$SYS_MASK" ] || { echo "[ERR] llc/$i CLOS0 mismatch ($M0 != $SYS_MASK)"; MASK_OK=0; ERR=1; }
    [ "$M1" = "$PVM_MASK" ] || { echo "[ERR] llc/$i CLOS1 mismatch ($M1 != $PVM_MASK)"; MASK_OK=0; ERR=1; }
    [ "$M2" = "$SVM_MASK" ] || { echo "[ERR] llc/$i CLOS2 mismatch ($M2 != $SVM_MASK)"; MASK_OK=0; ERR=1; }
done

# ---- 7) final summary -------------------------------------
echo ""
echo "==================== APPLY SUMMARY ===================="
echo " Profile        : $PROFILE (p=$P s=$S h=$H ways=$WAYS)"
echo " Applied at     : $RUN_KST KST ($RUN_UTC UTC)"
echo " LLC instances  : $NUM ( $LLC_FLAT)"
echo " Intended       : CLOS0(hyp)=$SYS_MASK  CLOS1(PVM)=$PVM_MASK  CLOS2(SVM)=$SVM_MASK"
if [ -n "$PVM2_NAME" ]; then
    echo " Topology       : $TOPO - PVM1=$PVM1_NAME(node0) PVM2=$PVM2_NAME(node1) share CLOS1; $SVM_DESC"
else
    echo " Topology       : $TOPO - PVM=$PVM1_NAME  $SVM_DESC"
fi
echo ""
echo " [ACTUAL STATE - read back from vsish]"
cat $STATE_DUMP
if [ $MASK_OK -eq 1 ]; then
    echo " Mask verify    : PASS (all LLC instances match intended masks)"
else
    echo " Mask verify    : FAIL (see [ERR] above)"
fi
echo ""
echo " [VM TAGGING - per-vCPU readback]"
set -- $P1_CNT
if [ "$P1_VOK" = "1" ]; then
    echo "  PVM1 $PVM1_NAME : $1/$2 vCPUs rmID=1 closID=1 [ALL OK]"
else
    echo "  PVM1 $PVM1_NAME : $1/$2 vCPUs OK - FAILED or mismatch present"
fi
[ -f $P1_DUMP ] && cat $P1_DUMP
if [ -n "$PVM2_NAME" ]; then
    set -- $P2_CNT
    if [ "$P2_VOK" = "1" ]; then
        echo "  PVM2 $PVM2_NAME : $1/$2 vCPUs rmID=1 closID=1 [ALL OK]"
    else
        echo "  PVM2 $PVM2_NAME : $1/$2 vCPUs OK - FAILED or mismatch present"
    fi
    [ -f $P2_DUMP ] && cat $P2_DUMP
fi
if [ -n "$SVM_NAME" ]; then
    set -- $SVM_CNT
    if [ "$SVM_VOK" = "1" ]; then
        echo "  SVM $SVM_NAME : $1/$2 vCPUs rmID=2 closID=2 [ALL OK]"
    else
        echo "  SVM $SVM_NAME : $1/$2 vCPUs OK - FAILED or mismatch present"
    fi
    [ -f $SVM_DUMP ] && cat $SVM_DUMP
else
    echo "  SVM            : none (topology $TOPO) - no CLOS2 tagging"
fi
echo ""
echo " Volatile       : all settings lost on host reboot - re-run this script"
echo "======================================================="
# ---- Operations record (v1.10, default on; --no-ops skips) ----
if [ $OPS -eq 1 ]; then
    RSVD_TXT="rmID`grep -m1 'rmID reserved' $STATE_DUMP 2>/dev/null | sed 's/.*reserved ://'`; closID 0 1 2"
    set -- $P1_CNT; TAG_TXT="PVM1 $PVM1_NAME $1/$2"
    if [ -n "$PVM2_NAME" ]; then set -- $P2_CNT; TAG_TXT="$TAG_TXT; PVM2 $PVM2_NAME $1/$2"; fi
    if [ -n "$SVM_NAME" ]; then set -- $SVM_CNT; TAG_TXT="$TAG_TXT; SVM $SVM_NAME $1/$2"; else TAG_TXT="$TAG_TXT; SVM none"; fi
    if [ $MASK_OK -eq 1 ] && [ $ERR -eq 0 ]; then VERIFY_TXT="PASS"; else VERIFY_TXT="FAIL"; fi
    ops_push record || true
else
    echo "[OPS] skipped (--no-ops)"
fi
rm -f $P1_WLIST $P2_WLIST $SVM_WLIST $P1_DUMP $P2_DUMP $SVM_DUMP $STATE_DUMP

if [ $ERR -eq 0 ]; then
    echo "[OK] $PROFILE fully applied and verified"
    exit 0
else
    echo "[FAIL] one or more steps failed - review [ERR] lines above"
    exit 1
fi
