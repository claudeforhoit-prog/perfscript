#!/bin/sh
# ===========================================================
# start_vms_lpage_gate.sh v1.0 (2026-09-23) - ESXi shell
#   Power on VMs one at a time; go to the next VM only after the
#   previous VM's 1GB large-page backing is complete, judged by
#     vsish -e get /memory/lpage/vmLpage/<worldID>
#       "Current number of 1GB page backings"  -> current
#       "1GB page backing attempts failed"      -> failed
#   Target = configured memory MB / 1024 (whole 1GB pages).
#   Host memory usage is NOT used for the decision (it counts overhead
#   and says nothing about page size).
#
# Usage : sh start_vms_lpage_gate.sh [options] [VM ...]
#   VM ...        VM display names in the order to power on.
#                 none = all VMs on this host, name order.
#   -n            check only: print 1GB backing table of powered-on VMs, no power on
#   -i SEC        poll interval (default 15)
#   -t MIN        per-VM timeout (default 90)
#   -s N          stall samples: N polls with no increase -> stop (default 6)
#   -p PCT        completion percent of target (default 100)
#   -c            continue to next VM even if a gate failed
#   -v            dump the raw vsish block for each VM once
#   -x PATTERN    exclude VMs whose name matches PATTERN (sh glob, repeatable)
# Result per VM : Completed | LpageFailed | Stalled | Timeout | NoNode |
#                 StartFailed | AlreadyOn(+gate result)
# Everything runs on the host; nothing outside ESXi is needed.
# ===========================================================

POLL=15; TMO=90; STALL=6; PCT=100; CONT=0; VERB=0; CHECK=0; EXCL=""
while getopts "ni:t:s:p:cvx:" o; do
    case "$o" in
        n) CHECK=1 ;; i) POLL=$OPTARG ;; t) TMO=$OPTARG ;; s) STALL=$OPTARG ;;
        p) PCT=$OPTARG ;; c) CONT=1 ;; v) VERB=1 ;; x) EXCL="$EXCL $OPTARG" ;;
        *) echo "usage: sh $0 [-n] [-i sec] [-t min] [-s n] [-p pct] [-c] [-v] [-x pat] [VM ...]"; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

LP=/memory/lpage/vmLpage
now() { date '+%H:%M:%S'; }
excluded() {  # excluded <name> -> 0 if matches any -x pattern
    for p in $EXCL; do case "$1" in $p) return 0 ;; esac; done
    return 1
}

# ---- VM inventory: name -> vmid (vim-cmd), memory MB ------
vmid_of()  { vim-cmd vmsvc/getallvms 2>/dev/null | awk -v n="$1" 'NR>1 && $2==n {print $1; exit}'; }
mem_mb_of(){ vim-cmd vmsvc/get.config "$1" 2>/dev/null | grep -m1 'memoryMB' | sed 's/[^0-9]//g'; }
state_of() { vim-cmd vmsvc/power.getstate "$1" 2>/dev/null | tail -1; }   # "Powered on" / "Powered off"

# ---- name -> world/cartel id (esxcli), pick the id present under vmLpage ----
lpage_id_of() {
    ids=`esxcli vm process list 2>/dev/null | awk -v n="$1" '
        /World ID:/      {w=$3}
        /VMX Cartel ID:/ {c=$4}
        /Display Name:/  {sub(/^[ \t]*Display Name:[ \t]*/,""); if ($0==n) {print w, c; exit}}'`
    [ -z "$ids" ] && return 1
    have=`vsish -e ls $LP/ 2>/dev/null | tr -d '/'`
    for i in $ids; do
        echo "$have" | grep -q -x "$i" && { echo "$i"; return 0; }
    done
    # ls empty or no match: fall back to world id (first token)
    set -- $ids; echo "$1"; return 0
}
lpage_read() {  # lpage_read <id> -> "cur fail" (empty if unreadable)
    out=`vsish -e get $LP/$1 2>/dev/null` || return 1
    [ -z "$out" ] && return 1
    cur=`echo "$out" | grep -i 'Current number of 1GB page backings' | head -1 | sed 's/.*://; s/[^0-9]//g'`
    fail=`echo "$out" | grep -i '1GB page backing attempts failed' | head -1 | sed 's/.*://; s/[^0-9]//g'`
    [ -z "$cur" ] && return 1
    [ -z "$fail" ] && fail=0
    echo "$cur $fail"
}

# ---- table of powered-on VMs (check mode / final summary) ----
lpage_table() {
    printf '%-24s %-9s %6s %8s %8s %7s %7s\n' VM worldID MemGB 1GB_cur 1GB_tgt pct failed
    esxcli vm process list 2>/dev/null | awk '/Display Name:/ {sub(/^[ \t]*Display Name:[ \t]*/,""); print}' | sort | while read -r n; do
        [ -z "$n" ] && continue
        vmid=`vmid_of "$n"`; mb=`mem_mb_of "$vmid"`; [ -z "$mb" ] && mb=0
        tgt=$((mb / 1024))
        id=`lpage_id_of "$n"` || { printf '%-24s %-9s %6s %8s %8s %7s %7s\n' "$n" "-" "$((mb/1024))" "-" "$tgt" "-" "no-world"; continue; }
        r=`lpage_read "$id"` || { printf '%-24s %-9s %6s %8s %8s %7s %7s\n' "$n" "$id" "$((mb/1024))" "-" "$tgt" "-" "no-node"; continue; }
        set -- $r; cur=$1; fail=$2
        pct=0; [ "$tgt" -gt 0 ] && pct=$((cur * 100 / tgt))
        printf '%-24s %-9s %6s %8s %8s %6s%% %7s\n' "$n" "$id" "$((mb/1024))" "$cur" "$tgt" "$pct" "$fail"
    done
}

echo "[INFO] `hostname` `now` - 1GB lpage gate via vsish $LP/<worldID>"
if [ "$CHECK" -eq 1 ]; then
    echo "[CHECK] powered-on VMs:"; lpage_table; exit 0
fi

# ---- target list ----
if [ $# -gt 0 ]; then
    LIST="$*"
else
    LIST=`vim-cmd vmsvc/getallvms 2>/dev/null | awk 'NR>1 {print $2}' | sort`
fi
PLAN=""
for n in $LIST; do excluded "$n" && { echo "[SKIP] $n (excluded)"; continue; }; PLAN="$PLAN $n"; done
[ -z "$PLAN" ] && { echo "[ERR] no VMs to start"; exit 1; }
echo "[PLAN] order:$PLAN"
echo "[GATE] 1GB backings >= target*$PCT% | poll ${POLL}s | timeout ${TMO}m | stall $STALL polls"

SUMMARY=""
ERR=0
for n in $PLAN; do
    vmid=`vmid_of "$n"`
    if [ -z "$vmid" ]; then echo "[ERR] $n: not found on this host"; SUMMARY="$SUMMARY\n$n NotFound"; ERR=1; [ $CONT -eq 1 ] && continue || break; fi
    mb=`mem_mb_of "$vmid"`; [ -z "$mb" ] && mb=0; tgt=$((mb / 1024)); goal=$(( (tgt * PCT + 99) / 100 ))
    st=`state_of "$vmid"`
    echo "------------------------------------------------------------"
    echo "[$n] vmid=$vmid mem=${mb}MB target=${tgt} x1GB goal=${goal} state='$st'"
    pre=""
    case "$st" in
        *"Powered on"*) echo "  already on - checking backing only"; pre="AlreadyOn+" ;;
        *) echo "  `now` power on"; vim-cmd vmsvc/power.on "$vmid" >/dev/null 2>&1 || { echo "[ERR] $n: power.on failed"; SUMMARY="$SUMMARY\n$n StartFailed"; ERR=1; [ $CONT -eq 1 ] && continue || break; } ;;
    esac

    t0=`date +%s`; deadline=$((t0 + TMO * 60)); prev=-1; stall=0; res="Timeout"; id=""; cur=0; fail=0; dumped=0
    while [ `date +%s` -lt $deadline ]; do
        if [ -z "$id" ]; then
            id=`lpage_id_of "$n"` || id=""
            if [ -z "$id" ]; then
                [ $(( `date +%s` - t0 )) -gt 60 ] && { res="NoNode"; break; }
                sleep 5; continue
            fi
        fi
        r=`lpage_read "$id"`
        if [ -z "$r" ]; then
            [ $(( `date +%s` - t0 )) -gt 120 ] && { res="NoNode"; break; }
            sleep $POLL; continue
        fi
        [ $VERB -eq 1 ] && [ $dumped -eq 0 ] && { echo "  --- vsish $LP/$id ---"; vsish -e get $LP/$id 2>&1 | sed 's/^/    /'; dumped=1; }
        set -- $r; cur=$1; fail=$2
        pct=0; [ "$tgt" -gt 0 ] && pct=$((cur * 100 / tgt))
        echo "  `now` 1GB $cur / $tgt (${pct}%) failed=$fail"
        [ "$cur" -ge "$goal" ] && { res="Completed"; break; }
        if [ $prev -ge 0 ] && [ "$cur" -le "$prev" ]; then stall=$((stall + 1)); else stall=0; fi
        if [ $stall -ge $STALL ]; then [ "$fail" -gt 0 ] && res="LpageFailed" || res="Stalled"; break; fi
        prev=$cur
        sleep $POLL
    done
    el=$(( `date +%s` - t0 ))
    case "$res" in
        Completed)   echo "  [OK] $n: 1GB backing complete $cur/$tgt failed=$fail (${el}s)" ;;
        LpageFailed) echo "  [FAIL] $n: stuck at $cur/$tgt with failed=$fail - host lacks contiguous 1GB regions; free memory (power off other VMs) or reboot host to defragment, then retry"; ERR=1 ;;
        Stalled)     echo "  [WARN] $n: no increase at $cur/$tgt, failed=0 - check prealloc / power state"; ERR=1 ;;
        Timeout)     echo "  [WARN] $n: timeout ${TMO}m at $cur/$tgt failed=$fail"; ERR=1 ;;
        NoNode)      echo "  [WARN] $n: world id / $LP node not found or unreadable (run with -v and check raw)"; ERR=1 ;;
    esac
    SUMMARY="$SUMMARY\n$n ${pre}${res} ${cur}/${tgt} failed=${fail} ${el}s"
    if [ "$res" != "Completed" ] && [ $CONT -eq 0 ]; then echo "[STOP] not starting further VMs (use -c to continue)"; break; fi
done

echo "============================================================"
echo "[SUMMARY]"; printf "$SUMMARY\n" | sed '/^$/d; s/^/  /'
echo "[TABLE] powered-on VMs now:"; lpage_table
[ $ERR -eq 0 ] && { echo "[OK] all gates passed"; exit 0; } || { echo "[FAIL] see above"; exit 1; }
