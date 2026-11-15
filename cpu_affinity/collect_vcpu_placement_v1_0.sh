#!/bin/sh
# ===========================================================
# collect_vcpu_placement.sh v1.0 (2026-09-28) - ESXi shell
#   Record which host pCPU each VM vCPU runs on, and whether that
#   VM's memory access goes remote (other NUMA node).
#
#   [1] topology     pcpu -> package / core / NUMA node
#                    esxcli hardware cpu list (+ sched-stats -t ncpus)
#   [2] placement    per vCPU world, the pcpu it sits on right now
#                    primary : sched-stats -t cpu  ('cpu' column per world,
#                              plus status RUN/WAIT/READY and pcpu affinity)
#                    fallback: vsish world node, auto-discovered (see -p)
#                              or given with -N
#   [3] locality     sched-stats -t numa-clients
#                    home node, local/remote memory, %local per client
#   [4] migration    sched-stats -t numa-migration
#   [5] pcpu busy    sched-stats -t pcpu-stats
#                    which pcpu numbers are actually consumed - this
#                    answers the question even if [2] finds no node
#
#   Nothing is hardcoded. Socket count, cores per socket, HT, SNC,
#   NUMA node count, VM list and vCPU count are read from the host
#   at run time.
#
# Usage : sh collect_vcpu_placement.sh [options] [VM ...]
#   VM ...      VM display names to watch. none = all powered-on VMs.
#   -p          probe only: topology + interface discovery, no sampling
#   -i SEC      sample interval (default 10)
#   -t SEC      total duration, 0 = run until Ctrl-C (default 600)
#   -o DIR      output root (default /tmp/vcpuplace)
#   -L LABEL    run label written into every row (e.g. vm3, vm4)
#   -e N        also capture esxtop batch for N samples (large file)
#   -v          keep raw command output of every sample under raw/
#   -N PATH     use this vsish node for the per-vCPU pcpu id instead of
#               auto-discovery. @W@ stands for the world id, and a
#               struct key may follow after a colon, e.g.
#                 -N /world/@W@/cpuState:curPcpu
#
# Output : <DIR>/<host>_<label>_<UTCstamp>/
#   topology.csv  vm_context.csv  placement.csv  numa_clients.csv
#   numa_migration.csv  pcpu_stats.csv  probe.txt  summary.txt  raw/
#
# Read-only. No vsish -e set, no VM reconfigure, no power operation.
# ESXi clock is UTC; every row carries ts_utc and ts_kst (KST = UTC+9).
# ===========================================================

INT=10; DUR=600; ROOT=/tmp/vcpuplace; LABEL=default; PROBE_ONLY=0; ETOP=0; VERB=0; NODE_ARG=""
while getopts "pi:t:o:L:e:vN:" o; do
    case "$o" in
        p) PROBE_ONLY=1 ;; i) INT=$OPTARG ;; t) DUR=$OPTARG ;; o) ROOT=$OPTARG ;;
        L) LABEL=$OPTARG ;; e) ETOP=$OPTARG ;; v) VERB=1 ;; N) NODE_ARG=$OPTARG ;;
        *) echo "usage: sh $0 [-p] [-i sec] [-t sec] [-o dir] [-L label] [-e n] [-N node] [-v] [VM ...]"; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

HOST=`hostname 2>/dev/null`
HOST=${HOST%%.*}
STAMP=`TZ=UTC date '+%Y%m%d_%H%M%S'`
OUT=$ROOT/${HOST}_${LABEL}_${STAMP}
RAW=$OUT/raw
mkdir -p "$RAW" || { echo "[ERR] cannot create $RAW"; exit 1; }

TOPO=$OUT/topology.csv
VMCTX=$OUT/vm_context.csv
PLACE=$OUT/placement.csv
NCLI=$OUT/numa_clients.csv
NMIG=$OUT/numa_migration.csv
PSTAT=$OUT/pcpu_stats.csv
PROBE=$OUT/probe.txt
SUMM=$OUT/summary.txt

u_now() { TZ=UTC   date '+%Y-%m-%dT%H:%M:%S'; }
k_now() { TZ=KST-9 date '+%Y-%m-%dT%H:%M:%S'; }
say()   { echo "$*"; echo "$*" >> "$PROBE"; }

first_int() { awk '{ for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/) { print $i; exit } }'; }

# ---- 1) host topology -------------------------------------
esxcli hardware cpu list > "$RAW/esxcli_cpu_list.txt" 2>/dev/null
sched-stats -t ncpus      > "$RAW/sched-stats_ncpus.txt" 2>/dev/null
vsish -e cat /hardware/cpuTopology 2>/dev/null > "$RAW/vsish_cpuTopology.txt"

echo "pcpu,package,core,node,apic" > "$TOPO"
awk -F: '
  function flush() { if (cur != "") printf "%s,%s,%s,%s,%s\n", cur, pkg, core, node, apic }
  /^CPU:/ { flush(); cur=$2; gsub(/[ \t]/,"",cur); pkg=""; core=""; node=""; apic=""; next }
  NF >= 2 {
    key=$1; val=$2
    gsub(/^[ \t]+/,"",key); gsub(/[ \t]+$/,"",key)
    gsub(/^[ \t]+/,"",val); gsub(/[ \t]+$/,"",val)
    lk=tolower(key)
    if      (lk ~ /package/)                       pkg=val
    else if (lk ~ /core id|core number|^core$/)    core=val
    else if (lk ~ /node/)                          node=val
    else if (lk ~ /apic/)                          apic=val
  }
  END { flush() }
' "$RAW/esxcli_cpu_list.txt" >> "$TOPO"

NPCPU=`awk 'NR>1' "$TOPO" | wc -l | first_int`
NPKG=`awk -F, 'NR>1 && $2!="" {print $2}' "$TOPO" | sort -u | wc -l | first_int`
NCORE=`awk -F, 'NR>1 && $3!="" {print $2"/"$3}' "$TOPO" | sort -u | wc -l | first_int`
NNODE=`awk -F, 'NR>1 && $4!="" {print $4}' "$TOPO" | sort -u | wc -l | first_int`
[ -z "$NPCPU" ] && NPCPU=0
[ "$NPCPU" -eq 0 ] && { echo "[ERR] no pcpu parsed from esxcli hardware cpu list - see $RAW"; exit 1; }
HT=1
[ -n "$NCORE" ] && [ "$NCORE" -gt 0 ] && HT=$((NPCPU / NCORE))

: > "$PROBE"
say "[topology] host=$HOST  pcpu=$NPCPU  package=$NPKG  core=$NCORE  threads/core=$HT  numa_node=$NNODE"
[ "$NNODE" = "0" ] && say "[WARN] esxcli reported no NUMA node per pcpu - node column stays empty; see $RAW/sched-stats_numa-pnode.txt"

# ---- 2) VM context (from esxcli + vmx) --------------------
esxcli vm process list > "$RAW/esxcli_vm_process_list.txt" 2>/dev/null

ALLVM=`awk '/^[^ \t]/ && NF>0 { print }' "$RAW/esxcli_vm_process_list.txt"`
if [ $# -gt 0 ]; then VMS="$*"; else VMS="$ALLVM"; fi

vm_field() {  # vm_field <vmname> <key>
    awk -v vm="$1" -v key="$2" '
      $0 ~ /^[^ \t]/ { inblk = ($0 == vm) ; next }
      inblk && index($0, key ":") { sub(/^[^:]*:[ \t]*/,""); print; exit }
    ' "$RAW/esxcli_vm_process_list.txt"
}

echo "ts_utc,host,label,vm,world_id,numvcpus,cores_per_socket,mem_mb,vcpu_affinity_keys,node_affinity_keys,numa_keys,vmx" > "$VMCTX"
U=`u_now`
for VM in $VMS; do
    WID=`vm_field "$VM" "World ID"`
    CFG=`vm_field "$VM" "Config File"`
    NV=""; CPS=""; MEM=""; AFF=0; NAFF=0; NUMAK=""
    if [ -n "$CFG" ] && [ -f "$CFG" ]; then
        grep -iE 'numvcpus|coresPerSocket|^memSize|affinity|^numa\.|sched\.node|sched\.mem' "$CFG" \
            > "$RAW/vmx_${VM}.txt" 2>/dev/null
        NV=`awk -F'"' '/numvcpus/ {print $2; exit}'          "$RAW/vmx_${VM}.txt"`
        CPS=`awk -F'"' '/coresPerSocket/ {print $2; exit}'   "$RAW/vmx_${VM}.txt"`
        MEM=`awk -F'"' '/^memSize/ {print $2; exit}'         "$RAW/vmx_${VM}.txt"`
        AFF=`grep -c 'sched\.vcpu[0-9]*\.affinity'           "$RAW/vmx_${VM}.txt"`
        NAFF=`grep -c 'sched\.node[0-9]*\.affinity'          "$RAW/vmx_${VM}.txt"`
        NUMAK=`awk '/^numa\./ {printf "%s;", $1}'            "$RAW/vmx_${VM}.txt"`
    fi
    echo "$U,$HOST,$LABEL,$VM,$WID,$NV,$CPS,$MEM,$AFF,$NAFF,$NUMAK,$CFG" >> "$VMCTX"
    say "[vm] $VM  world=$WID  vcpu=$NV  coresPerSocket=$CPS  memMB=$MEM  vcpuAffinityKeys=$AFF  nodeAffinityKeys=$NAFF"
done

# ---- 3) vCPU worlds ---------------------------------------
# ps lists vmx-vcpu worlds of running VMs only (same source as set_cat_qos).
vcpu_worlds() {  # vcpu_worlds <vmname> -> "<worldid> <vcpuidx>" per line
    ps 2>/dev/null | grep "$1" | grep vcpu | grep -v grep | awk '
      { idx=""
        for (i=1;i<=NF;i++) if ($i ~ /vcpu-[0-9]+/) { idx=$i; break }
        if (idx == "") next
        n=idx; sub(/^.*vcpu-/,"",n); sub(/[^0-9].*$/,"",n)
        print $1, n }'
}

VCPU_MAP=$RAW/vcpu_worlds.txt
: > "$VCPU_MAP"
for VM in $VMS; do
    vcpu_worlds "$VM" | while read -r W I; do echo "$VM $W $I" >> "$VCPU_MAP"; done
done
NVW=`wc -l < "$VCPU_MAP" | first_int`
say "[vcpu] vcpu worlds found: $NVW  (file $VCPU_MAP)"
[ "$NVW" = "0" ] && say "[WARN] no vcpu world matched - check VM names against 'ps | grep vcpu'"

# ---- 4) placement source ----------------------------------
# Primary: sched-stats -t cpu. One table for every world; the 'cpu' column
# is the pcpu the world is on (or was last on when status != RUN).
# Fallback: a vsish node under /world/<id>/ - candidate list first, then a
# filtered recursive walk so the node can be identified on this build.
PLACE_SRC=""; PCPU_PATH=""; PCPU_KEY=""
FIRSTW=`awk 'NR==1 {print $2}' "$VCPU_MAP"`

sched-stats -t cpu > "$RAW/sched-stats_cpu_probe.txt" 2>/dev/null
SS_OK=`awk 'NR==1 { for (i=1;i<=NF;i++) { if ($i=="cpu") c=1; if ($i=="name") n=1 } }
             $0 ~ /vmx-vcpu-[0-9]+:/ { r++ }
             END { print (c && n && r>0) ? "1" : "0" }' "$RAW/sched-stats_cpu_probe.txt"`
if [ "$SS_OK" = "1" ] && [ -z "$NODE_ARG" ]; then
    PLACE_SRC=sched-stats
    say "[probe] placement source = sched-stats -t cpu  (columns: `head -1 "$RAW/sched-stats_cpu_probe.txt" | tr -s ' ' | cut -c1-160`)"
else
    [ "$SS_OK" != "1" ] && say "[probe] sched-stats -t cpu has no usable 'cpu'/'name' column here - trying vsish"
fi

in_range() { [ -n "$1" ] && [ "$1" -ge 0 ] 2>/dev/null && [ "$1" -lt "$NPCPU" ] 2>/dev/null; }

if [ -z "$PLACE_SRC" ] && [ -n "$FIRSTW" ]; then
    for T in /world/@W@/sched/pcpu /world/@W@/sched/currentPcpu /world/@W@/sched/lastPcpu \
             /world/@W@/sched/state /world/@W@/cpuState /world/@W@/runState \
             /sched/worlds/@W@/pcpu /sched/worlds/@W@/state ; do
        P=`echo "$T" | sed "s#@W@#$FIRSTW#"`
        O=`vsish -e get "$P" 2>/dev/null`
        [ -z "$O" ] && continue
        echo "--- candidate $P" >> "$RAW/pcpu_node_candidates.txt"
        echo "$O" >> "$RAW/pcpu_node_candidates.txt"
        NL=`echo "$O" | wc -l | first_int`
        if [ "$NL" = "1" ]; then
            V=`echo "$O" | first_int`
            if in_range "$V"; then PCPU_PATH=$T; PCPU_KEY=""; break; fi
        else
            K=`echo "$O" | grep -i 'pcpu' | awk -F: '{ v=$2; gsub(/[^0-9]/,"",v); if (v != "") { k=$1; gsub(/^[ \t]+/,"",k); gsub(/[ \t]+$/,"",k); print k"|"v; exit } }'`
            KN=`echo "$K" | awk -F'|' '{print $1}'`
            KV=`echo "$K" | awk -F'|' '{print $2}'`
            if in_range "$KV"; then PCPU_PATH=$T; PCPU_KEY=$KN; break; fi
        fi
    done
fi

walk() {  # walk <path> <depth> : dump leaves whose name mentions cpu/node/numa/migrat/affin
    [ "$2" -le 0 ] && return
    for e in `vsish -e ls "$1" 2>/dev/null`; do
        case "$e" in
            */) walk "$1$e" $(($2 - 1)) ;;
            *)  case "$e" in
                    *cpu*|*CPU*|*Cpu*|*node*|*Node*|*numa*|*Numa*|*NUMA*|*migrat*|*Migrat*|*affin*|*Affin*)
                        V=`vsish -e get "$1$e" 2>/dev/null | tr '\n' ' ' | cut -c1-240`
                        echo "  $1$e = $V" >> "$PROBE" ;;
                esac ;;
        esac
    done
}

if [ -z "$PLACE_SRC" ] && [ -z "$PCPU_PATH" ] && [ -n "$FIRSTW" ]; then
    say "[probe] no candidate node returned a pcpu id - walking vsish for world $FIRSTW (depth 3)"
    walk "/world/$FIRSTW/" 3
    say "[probe] walk done. pick the leaf that reads back a pcpu id and rerun with -N :"
    say "[probe]   sh $0 -N /world/@W@/<leaf> ...        (scalar node)"
    say "[probe]   sh $0 -N /world/@W@/<leaf>:<key> ...  (key inside a struct)"
fi
if [ -n "$NODE_ARG" ]; then
    case "$NODE_ARG" in
        *:*) PCPU_PATH=${NODE_ARG%%:*}; PCPU_KEY=${NODE_ARG#*:} ;;
        *)   PCPU_PATH=$NODE_ARG; PCPU_KEY="" ;;
    esac
    say "[probe] per-vcpu pcpu node forced by -N : $PCPU_PATH key='${PCPU_KEY:-<scalar>}'"
fi
PCPU_PRE=${PCPU_PATH%%@W@*}
PCPU_SUF=${PCPU_PATH#*@W@}
if [ -z "$PLACE_SRC" ] && [ -n "$PCPU_PATH" ]; then
    PLACE_SRC=vsish
    say "[probe] placement source = vsish $PCPU_PATH  key='${PCPU_KEY:-<scalar>}'"
elif [ -z "$PLACE_SRC" ]; then
    say "[probe] placement source NOT resolved - placement.csv stays empty; use pcpu_stats.csv (set-level) and probe.txt"
fi

# One sample = one vsish call per vCPU world (no other process), then a
# single awk pass that parses the dump and joins the topology table.
# Per-vCPU shell pipelines were 4 processes per vCPU - at 96 vCPU that made
# one sample take several seconds and overrun the interval.
DUMP=$RAW/.pcpu_dump
VMLIST=`echo $VMS`
sample_placement() {
    case "$PLACE_SRC" in
        sched-stats) sample_placement_ss ;;
        vsish)       sample_placement_vsish ;;
    esac
}

# sched-stats -t cpu: header names give the column index (layout differs
# between builds, so nothing is indexed by position). Rows whose name is
# vmx-vcpu-<i>:<vm> and whose <vm> is in the watch list are kept.
sample_placement_ss() {
    O=`sched-stats -t cpu 2>/dev/null`
    [ -z "$O" ] && return
    [ "$VERB" = "1" ] && { echo "=== $U cpu" >> "$RAW/sched-stats_cpu.txt"; echo "$O" >> "$RAW/sched-stats_cpu.txt"; }
    echo "$O" | awk -v u="$U" -v k="$K" -v h="$HOST" -v lab="$LABEL" -v vms="$VMLIST" '
      BEGIN { FS=","; n=split(vms, a, " "); for (j=1;j<=n;j++) want[a[j]]=1 }
      NR == FNR { if (FNR > 1) { pkg[$1]=$2; cor[$1]=$3; nod[$1]=$4 } ; next }
      FNR == 1 { FS=" "; $0=$0
                 for (i=1;i<=NF;i++) { if ($i=="cpu") ci=i; if ($i=="name") ni=i; if ($i=="status") si=i; if ($i=="affinity") ai=i }
                 next }
      ci && ni && $ni ~ /^vmx-vcpu-[0-9]+:/ {
          nm=$ni; vm=nm; sub(/^[^:]*:/,"",vm)
          if (!(vm in want)) next
          idx=nm; sub(/^vmx-vcpu-/,"",idx); sub(/:.*$/,"",idx)
          pc=$ci; st=(si ? $si : ""); af=(ai ? $ai : "")
          printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n", u, k, h, lab, vm, $1, idx, pc, pkg[pc], cor[pc], nod[pc], st, af
      }
    ' "$TOPO" - >> "$PLACE"
}

sample_placement_vsish() {
    [ -z "$PCPU_PATH" ] && return
    while read -r VM W I; do
        echo "@@ $VM $W $I"
        vsish -e get "$PCPU_PRE$W$PCPU_SUF" 2>/dev/null
    done < "$VCPU_MAP" > "$DUMP"
    awk -v u="$U" -v k="$K" -v h="$HOST" -v lab="$LABEL" -v key="$PCPU_KEY" -F, '
      FNR == NR { if (FNR > 1) { pkg[$1]=$2; cor[$1]=$3; nod[$1]=$4 } ; next }
      { line = $0 }
      line ~ /^@@ / {
          if (vm != "") emit()
          split(line, a, " "); vm=a[2]; w=a[3]; i=a[4]; pc=""; done_=0
          next
      }
      vm != "" && done_ == 0 {
          if (key == "") {
              n = split(line, t, /[ \t]+/)
              for (j = 1; j <= n; j++) if (t[j] ~ /^[0-9]+$/) { pc=t[j]; done_=1; break }
          } else if (index(line, key) > 0) {
              v = line; sub(/^[^:]*:/, "", v); gsub(/[^0-9]/, "", v)
              if (v != "") { pc=v; done_=1 }
          }
      }
      END { if (vm != "") emit() }
      function emit() {
          printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,,\n", u, k, h, lab, vm, w, i, pc, pkg[pc], cor[pc], nod[pc]
      }
    ' "$TOPO" "$DUMP" >> "$PLACE"
}

# ---- 5) generic table -> csv (column names taken from the header) ---
tidy() {  # tidy <outfile> ; table on stdin
    OF=$1; NEED=0
    [ -f "$OF" ] || NEED=1
    awk -v u="$U" -v k="$K" -v lab="$LABEL" -v h="$HOST" -v need="$NEED" -v of="$OF" '
      function csv(l) { gsub(/^[ \t]+/,"",l); gsub(/[ \t]+$/,"",l); gsub(/[ \t]+/,",",l); gsub(/,+/,",",l); return l }
      NF == 0 { next }
      $0 ~ /^[-=]+$/ { next }
      hdr == "" { hdr = csv($0); if (need == 1) print "ts_utc,ts_kst,host,label," hdr >> of; next }
      { print u "," k "," h "," lab "," csv($0) >> of }
    '
}

snap() {  # snap <sched-stats type> <outfile> <tag>
    O=`sched-stats -t "$1" 2>/dev/null`
    [ -z "$O" ] && return 1
    echo "$O" | tidy "$2"
    [ "$VERB" = "1" ] && { echo "=== $U $1" >> "$RAW/${3}.txt"; echo "$O" >> "$RAW/${3}.txt"; }
    return 0
}

U=`u_now`; K=`k_now`
snap numa-clients   "$RAW/check_numa_clients.csv"   numa-clients   || say "[WARN] sched-stats -t numa-clients gave nothing"
snap numa-migration "$RAW/check_numa_migration.csv" numa-migration || say "[WARN] sched-stats -t numa-migration gave nothing"
snap pcpu-stats     "$RAW/check_pcpu_stats.csv"     pcpu-stats     || say "[WARN] sched-stats -t pcpu-stats gave nothing"
sched-stats -t numa-pnode > "$RAW/sched-stats_numa-pnode.txt" 2>/dev/null
sched-stats -t numa-global > "$RAW/sched-stats_numa-global.txt" 2>/dev/null

if [ "$PROBE_ONLY" = "1" ]; then
    # Probe runs also dump the hardware side, so the core/node map can be
    # rebuilt from vsish if esxcli did not report Core Id or Node.
    say "[probe] walking /hardware/cpu/ and /hardware/numa/ (probe mode only)"
    walk "/hardware/cpu/" 3
    walk "/hardware/numa/" 3
    say "[done] probe only. output: $OUT"
    exit 0
fi

# ---- 6) sample loop ---------------------------------------
echo "ts_utc,ts_kst,host,label,vm,world_id,vcpu,pcpu,package,core,node,status,affinity" > "$PLACE"
if [ "$ETOP" != "0" ]; then
    esxtop -b -a -d "$INT" -n "$ETOP" > "$OUT/esxtop_batch.csv" 2>/dev/null &
    say "[esxtop] batch started: -d $INT -n $ETOP -> $OUT/esxtop_batch.csv"
fi

START=`date '+%s'`
N=0
while : ; do
    U=`u_now`; K=`k_now`
    N=$((N + 1))

    sample_placement

    snap numa-clients   "$NCLI"  numa-clients
    snap numa-migration "$NMIG"  numa-migration
    snap pcpu-stats     "$PSTAT" pcpu-stats

    echo "[$N] $U (KST $K) sampled"
    [ "$DUR" != "0" ] && [ $((`date '+%s'` - START + INT)) -gt "$DUR" ] && break
    sleep "$INT"
done

# ---- 7) summary -------------------------------------------
{
  echo "run      : $HOST label=$LABEL start_utc=$STAMP samples=$N interval=${INT}s"
  echo "topology : pcpu=$NPCPU package=$NPKG core=$NCORE threads/core=$HT numa_node=$NNODE"
  echo "placement: source=${PLACE_SRC:-<unresolved>} ${PCPU_PATH} ${PCPU_KEY}"
  echo ""
  if [ -n "$PLACE_SRC" ]; then
      echo "per VM observed placement (from placement.csv, all rows; status column tells RUN vs WAIT/READY)"
      echo "vm  samples  vcpus  distinct_pcpu  packages  nodes  cores_shared_by_2+_vcpu"
      awk -F, 'NR>1 && $8!="" {
          vm=$5; s[vm]++; vc[vm","$7]=1; pc[vm","$8]=1
          if ($9!="") pk[vm","$9]=1
          if ($11!="") nd[vm","$11]=1
          if ($9!="" && $10!="") cc[vm","$9"/"$10","$7]=1
      }
      END {
          for (key in pc) { split(key,a,","); npc[a[1]]++ }
          for (key in vc) { split(key,a,","); nvc[a[1]]++ }
          for (key in pk) { split(key,a,","); npk[a[1]]++ }
          for (key in nd) { split(key,a,","); nnd[a[1]]++ }
          for (key in cc) { split(key,a,","); ncc[a[1]","a[2]]++ }
          for (key in ncc) { split(key,a,","); if (ncc[key] > 1) shared[a[1]]++ }
          for (v in s) printf "%s  %d  %d  %d  %d  %d  %d\n", v, s[v], nvc[v], npc[v], npk[v], nnd[v], shared[v]+0
      }' "$PLACE" | sort
      echo ""
      echo "pcpu set per VM (sorted)"
      awk -F, 'NR>1 && $8!="" { k=$5; if (!seen[k","$8]++) list[k]=list[k]" "$8 }
               END { for (v in list) print v":"list[v] }' "$PLACE" | sort
  else
      echo "placement.csv empty - no placement source resolved."
      echo "Use pcpu_stats.csv (per-pcpu used time -> which pcpu numbers are consumed)"
      echo "and probe.txt (vsish walk) to fix the node, then rerun."
  fi
  echo ""
  echo "last numa-clients sample (home node / local / remote per client)"
  tail -30 "$NCLI"
} > "$SUMM" 2>&1

cat "$SUMM"
echo ""
echo "[done] output dir : $OUT"
