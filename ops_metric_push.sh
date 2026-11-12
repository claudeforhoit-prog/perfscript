#!/bin/bash
# --- csh/tcsh guard: the three lines below do nothing in bash. ---
# "csh ops_metric_push.sh ..." re-executes itself with bash; "source ops_metric_push.sh" in csh prints a hint and stops.
test "$?BASH_VERSION" = "0" && test -f "$0" && exec /bin/bash "$0" $argv:q
test "$?BASH_VERSION" = "0" && echo "ops_metric_push.sh: do not source it. Run:  bash ops_metric_push.sh [options]"
if false; then :; fi
# ============================================================
# ops_metric_push.sh  v4.4 (2026-11-12)  English
#
# v4.4: connection settings moved out of the script
#   The Operations address, the account, the encrypted password and its key
#   are read from ops_local.conf in the folder of this script (--config PATH
#   or env OPS_PUSH_CONFIG for another place). The script holds no address
#   and no credential, so it can be kept in Git; Git holds ops_local.conf with the
#   keys only. The file name no longer carries the version: the banner shows it.
#   Collection is as in v4.3.
#
# v4.3: AMD events for every Zen generation that ESXi 8.0 and later support
#   CPU classes amd_zen1 .. amd_zen5 (amd_zen = any of them). The class comes
#   from the CPUID family and model, with the ranges the Linux kernel uses to
#   choose its per-generation event list
#   (tools/perf/pmu-events/arch/x86/mapfile.csv):
#     amd_zen1  Family 17h, models 00h-2Fh                  EPYC 7001, Ryzen Embedded V1000
#     amd_zen2  Family 17h, other models                    EPYC 7002
#     amd_zen3  Family 19h, models 00h-0Fh 20h-2Fh 40h-5Fh  EPYC 7003
#     amd_zen4  Family 19h, other models                    EPYC 9004, EPYC 8004
#     amd_zen5  Family 1Ah, models 00h-2Fh 40h-4Fh 60h-7Fh  EPYC 9005
#   The alias table has a CPU class column, because one short name can have
#   a different event code per generation (l2_itlb_miss). The L1D fill events
#   (PMCx044, any fill) are in the kernel event lists from Zen 3 on, so the
#   L1D_Fill_* lines are n/a on Zen 1 and Zen 2. The Zen 2 list has the
#   demand fill event PMCx043 instead: Zen 2 gets the L1D_Demand_Fill_* lines,
#   which count demand fills only (prefetch fills are separate events there).
#   The Zen 1 list has no fill-by-source event. The generic cache/TLB lines
#   are not used on any amd_zen class. Collection itself is as in v4.2.
#
# v4.2: perf started once instead of every minute, multiplexing check,
#       AMD Zen 5 (Turin) events
#   1) perf is started ONCE and stays up ("resident"). `perf stat -I <ms>`
#      prints the count deltas of every interval and the collector only reads
#      them. v4.1 started a new `perf stat ... sleep 55` every minute, which
#      creates, enables and tears down every event on every CPU each minute.
#      The measured window is now the whole interval (60 of 60 s, was 55).
#      A perf without -I is detected at start-up and the collector then uses
#      the v4.1 method by itself. --perf-mode resident|window forces one.
#   2) Multiplexing is measured and shown. With more events than hardware
#      counters the kernel time-shares the counters; perf then scales the
#      counts and reports the share of time each event really counted. The
#      start-up check, the support log and every per-interval log line show
#      that share. --perf-fit keeps only as many events as the counters hold
#      (in metric-table order), so no event is time-shared.
#   3) CPU-specific table lines (cpu=<class> / cpu!=<class>) and an event
#      alias table with raw event codes. AMD Zen 5 (Family 1Ah: Turin, Turin
#      Dense) gets the group "Guest Perf AMD". Codes and names come from the
#      Linux kernel event list for Zen 5,
#      tools/perf/pmu-events/arch/x86/amdzen5/*.json (maintained by AMD).
#      The generic cache/TLB lines are not used on Zen 5: there the kernel
#      maps cache-references/cache-misses to L2 events and has no LLC event,
#      so the same metric name would not mean the same thing as on Intel.
#   4) No associative arrays: runs on bash 3.2 and later (v4.1 needed bash 4).
#   5) Rows keep the v4.1 stamp, the START of the interval they cover, but are
#      written when that interval ends (v4.1: 55 s into it). The first row
#      appears one interval after the start.
#
# Collect Guest OS metrics (perf + /proc) once a minute and output them
# as either an Ops push, a local CSV file, or both. Once started, it
# keeps collecting until it receives a termination signal (Ctrl+C / kill).
#
#   --mode ops   (default)  push to VCF Operations only  [v2 behaviour]
#   --mode file             write a local CSV only, no Ops connection
#   --mode both             push and write the CSV at the same time
#
# What is collected  [v4]
#   --collect both  (default)  perf metrics + THP metrics      [v3 behaviour]
#   --collect thp              THP / proc metrics only -- perf is never
#                              started, so the run adds no PMU load and needs
#                              no perf_event_paranoid change
#   --collect perf             perf metrics only, THP metrics skipped
#   --collect A,B,C            an explicit metric-name list (see --list)
#   Metrics that are not selected keep their CSV column, empty, so files from
#   different hosts and different --collect settings still merge as one table.
#
# Where it is pushed  [v4]
#   --target vm   (default)  look the name up as a VMWARE VirtualMachine and
#                            fail if it is absent          [v3 behaviour]
#   --target any             match the name against objects of every adapter
#                            kind, VirtualMachine first. Use this when the
#                            target is not a VM -- a physical host object, or
#                            any object an adapter already collects -- as long
#                            as that object exists in Ops.
#   The script never creates Ops objects: an object only exists behind a real
#   adapter, so a pushed-in placeholder would have nothing collecting it. For a
#   physical host with no object at all, collect to CSV with --mode file.
#
# Ops tree structure:
#   <object> > Custom Metrics > Guest Perf Generic  > IPC_Ratio / ...
#                             > Guest Perf Extended > ITLB_MissRate_Pct / ...
#                             > Guest THP           > Thp_Coverage_Pct / ...
#
# ------------------------------------------------------------
# [How to run]
#
#   1) Put the script and its config file in one folder
#        ops_metric_push.sh
#        ops_local.conf           # the four values filled in
#        chmod 755 ops_metric_push.sh ; chmod 600 ops_local.conf
#      A copy that arrived as .txt: mv ops_metric_push.txt ops_metric_push.sh
#
#   2) Fill in ops_local.conf: OPS_HOST, OPS_USER, OPS_PASS_ENC, OPS_ENC_KEY
#      (not needed for --mode file, which never contacts Ops)
#
#   2-1) Pre-configure perf permissions (required for perf metric
#        collection. Without it, only THP metrics are collected)
#        sudo sysctl -w kernel.perf_event_paranoid=-1
#        Persistent: echo "kernel.perf_event_paranoid=-1" | sudo tee -a /etc/sysctl.conf
#        Not needed at all with --collect thp, which never calls perf.
#
#      No time-shared counters (fewer perf metrics when the VM has fewer
#      counters than events; the support log lists what was left out):
#        nohup bash ops_metric_push.sh --perf-fit > /tmp/ops_push.log 2>&1 &
#
#   3) Run — background with nohup for always-on collection (recommended)
#        nohup bash ops_metric_push.sh > /tmp/ops_push.log 2>&1 &
#
#      THP only, no perf (lowest overhead -- safe during a timed run):
#        nohup bash ops_metric_push.sh --collect thp > /tmp/ops_push.log 2>&1 &
#
#      Push to a non-VM object that already exists in Ops:
#        nohup bash ops_metric_push.sh --target any --vm bm-node01 > /tmp/ops_push.log 2>&1 &
#
#      CSV only (no Ops connection) / push + CSV together:
#        nohup bash ops_metric_push.sh --mode file --out /data/perf > /tmp/ops_push.log 2>&1 &
#        nohup bash ops_metric_push.sh --mode both --out /data/perf > /tmp/ops_push.log 2>&1 &
#
#      csh/tcsh (the default shell of the guests) has no "2>&1". Write ">&" there:
#        nohup bash ops_metric_push.sh >& /tmp/ops_push.log &
#        nohup bash ops_metric_push.sh --perf-fit >& /tmp/ops_push.log &
#
#      · nohup  : keeps the process alive even if the terminal (SSH)
#                 is closed. Without it, collection stops on logout.
#      · &      : runs in the background so the terminal stays usable.
#      · > ... 2>&1 : collects stdout and stderr into /tmp/ops_push.log.
#      Collection continues after the shell is closed.
#
#   4) Check progress
#        tail -f /tmp/ops_push.log             # per-minute collection summary
#        cat  /tmp/ops_metric_push_support.log # event support probe results
#
#   5) Stop (recommended: --stop — reliably cleans up child processes such as perf)
#        bash ops_metric_push.sh --stop
#      * kill/pkill also works. The resident perf watches the collector and
#        ends by itself within 10 s after the collector is gone, even after
#        kill -9. --stop terminates the children immediately as well.
#      * If the VM name (--vm) is omitted, the guest hostname (without
#        domain) is used for automatic lookup in Ops. Case differences
#        are corrected automatically.
#
#   * On server reboot, the nohup process is gone. If auto-start after
#     boot is needed, register crontab @reboot or a systemd unit separately.
#
#   * To generate a new encrypted password after a password change:
#        bash ops_metric_push.sh --encrypt       # prints the OPS_PASS_ENC line for ops_local.conf
#   * To list only the defined metrics:
#        bash ops_metric_push.sh --list
#
# ------------------------------------------------------------
# [CSV output]  --mode file|both  requires --out
#
#   --out accepts a directory (recommended) or a full *.csv path.
#   File name:  ops_metric_<host>_<YYYYmmdd-HHMMSS>_001.csv
#     - the start timestamp keeps each run separate, so starting and
#       stopping collection several times a day never collides
#     - if a name is somehow already taken, "-r2", "-r3" ... is appended
#     - past --max-size (default 10MB) it rolls over to _002.csv, _003.csv ...
#       and each part repeats the header so it opens on its own
#   The script NEVER truncates: every write uses >> and an existing part
#   file is skipped rather than overwritten.
#
#   Layout: 1 row = 1 collection. Columns are fixed at Timestamp, EpochSec
#   plus all metrics in [METRIC TABLE] order, regardless of which ones the
#   support probe excluded on this CPU -- so CSVs from different hosts share
#   one schema and can be merged directly.
#   An empty cell means "not collected" (unsupported event, missing input,
#   zero denominator, or the first minute of a delta metric). This mirrors
#   the push path, which omits those values so Ops draws a gap instead of a
#   misleading 0. Timestamps are local time (KST on the Track A guests).
#
# ------------------------------------------------------------
# [To change what is collected]  Edit only the [METRIC TABLE] below.
#   One line = <group>|<metric name>  <calc>  <source1>  <source2>  <description>
#   perf events are aggregated automatically so perf runs only once.
#
# [Unsupported event handling]  * Addresses the customer concern that
#   perf events differ per CPU model.
#   At startup, each perf event is actually tested briefly.
#   - Unsupported events are removed from the collection list entirely
#     (no -1 generated every minute).
#   - Metrics that use an unsupported event as input are also excluded
#     in cascade.
#   - Support/unsupport verdicts are logged to /tmp/ops_metric_push_support.log.
#     (Overwritten on every run. Customers can use this file to answer
#     "why is this metric missing?")
#   - Even if some events are unsupported, the script proceeds without
#     prompting and collects only what is supported.
#   /proc (THP) items are CPU-independent and are not subject to this probe.
#
# [Value rules]
#   - Percent (_Pct) values are plain % values. Ex: Thp_Coverage_Pct = 88.80
#   - IPC is a ratio, so it is named IPC_Ratio. Ex: 1.52
#   - Ratios/percents use two decimal places. Counters are integers.
#   - Not computable (zero denominator / missing numerator or denominator)
#     = -1. -1 values are NOT pushed
#     -> the Ops chart shows an empty gap (no point) at that time.
#   * The Ops suite-api stats push does not support a units attribute,
#     so units are encoded as metric-name suffixes
#     (_Pct=%, _kB=kilobytes, _Ratio=unitless ratio).
#
# [THP caveat] vmstat thp_* are cumulative counters since boot. Success
#   rates are also cumulative and become nearly flat later on. For
#   interval changes, apply a Rate-of-change super metric on the raw
#   fields in Ops.
#
# [Measurement window] Aligned to second 00 of every minute.
#   resident perf (default): one perf process counts continuously and prints
#     the deltas of each 60 s interval. Its interval timer is not tied to the
#     wall clock, so the output slowly falls behind the minute boundary. When
#     it is more than 5 s behind, perf is restarted on the next boundary and
#     that one interval has no perf values.
#   window perf (--perf-mode window, or a perf without -I): a new perf run of
#     55 s in every interval, as in v4.1.
#   Parsing and push happen right after the boundary. Push runs in the
#   background. perf adds overhead while it counts — see [perf load] below.
#
# [perf load]
#   - Events beyond the number of hardware counters are time-shared by the
#     kernel (multiplexing): it keeps moving the events on and off the
#     counters of every CPU, and perf scales the counts up to an estimate.
#     The log shows "perf run <N>%": 100 = no event is time-shared.
#   - --perf-fit removes the time-sharing by using fewer events.
#   - --collect thp uses no counter at all.
#   The NMI watchdog (kernel.nmi_watchdog=1) holds one counter by itself.
#
# [Account] Only Ops LOCAL accounts work. SSO/VIDB accounts cannot get
#   tokens through this API.
#
# [No concurrent runs] Running alongside other perf collectors causes
#   PMU contention and inaccurate measurements.
# ============================================================

set -u

# ==========================================================
# * [METRIC TABLE] *  — edit only here to change what is collected
# ----------------------------------------------------------
# calc : raw=value as-is / ratio=s1/s2 / pct=s1/s2*100(%) / spct=s1/(s1+s2)*100(%)
#        delta=current - previous-minute value (1-min change, for vmstat cumulative counters)
#        dspct=delta-based success rate: Δs1/(Δs1+Δs2)*100(%) (success rate for this 1 minute)
#        * delta/dspct need a previous value, so the first collection minute is skipped
#        * delta activity 0 -> delta pushes 0 (no-activity info); dspct denominator 0 -> -1, excluded
#        pti=s1/s2*1000, three decimals (per thousand instructions, the unit AMD uses
#        for its recommended metrics; suffix _PTI)
# src  : perf:<event> | meminfo:<key> | vmstat:<key>
#        (perf: events are probed for support at startup. If unsupported,
#         that line and any other line referencing the event are all
#         excluded automatically)
#        perf:<event> is a perf event name, or a short name from the
#        [PERF EVENT ALIASES] table below (raw event codes).
# order: with --perf-fit the events are kept in the order they first appear in this
#        table, so put the lines you need most first. The AMD lines start with the
#        page-walk and memory-fill events for that reason.
# cpu  : optional last word of a line, cpu=<class> or cpu!=<class>.
#        The line is used only on (cpu=) or only off (cpu!=) that CPU class.
#        Classes: intel | amd_zen1 .. amd_zen5 | amd | other   (shown by --list)
#        amd_zen stands for any of amd_zen1 .. amd_zen5. Several classes are joined
#        with commas: cpu=amd_zen3,amd_zen4,amd_zen5
#        A line that does not apply keeps its CSV column, empty.
# ==========================================================
METRIC_TABLE="
Guest Perf Generic|IPC_Ratio            ratio  perf:instructions           perf:cycles                 instructions/cycle
Guest Perf Generic|Cache_MissRate_Pct   pct    perf:cache-misses           perf:cache-references       LLC miss rate  cpu!=amd_zen
Guest Perf Generic|L1D_MissRate_Pct     pct    perf:L1-dcache-load-misses  perf:L1-dcache-loads        L1D miss rate  cpu!=amd_zen
Guest Perf Generic|DTLB_MissRate_Pct    pct    perf:dTLB-load-misses       perf:dTLB-loads             dTLB miss rate  cpu!=amd_zen
Guest Perf Generic|Instructions         raw    perf:instructions           -                           instruction count
Guest Perf Generic|Cycles               raw    perf:cycles                 -                           cycle count
Guest Perf Generic|Cache_Ref            raw    perf:cache-references        -                           LLC references  cpu!=amd_zen
Guest Perf Generic|Cache_Miss           raw    perf:cache-misses           -                           LLC misses  cpu!=amd_zen
Guest Perf Generic|L1D_Loads            raw    perf:L1-dcache-loads        -                           L1D loads  cpu!=amd_zen
Guest Perf Generic|L1D_Load_Miss        raw    perf:L1-dcache-load-misses  -                           L1D load misses  cpu!=amd_zen
Guest Perf Generic|DTLB_Loads           raw    perf:dTLB-loads             -                           dTLB loads  cpu!=amd_zen
Guest Perf Generic|DTLB_Load_Miss       raw    perf:dTLB-load-misses       -                           dTLB load misses  cpu!=amd_zen
Guest Perf Extended|ITLB_MissRate_Pct   pct    perf:iTLB-load-misses       perf:iTLB-loads             iTLB miss rate  cpu!=amd_zen
Guest Perf Extended|ITLB_Loads          raw    perf:iTLB-loads             -                           iTLB loads  cpu!=amd_zen
Guest Perf Extended|ITLB_Load_Miss      raw    perf:iTLB-load-misses       -                           iTLB load misses  cpu!=amd_zen
Guest Perf Extended|LLC_Load_Miss       raw    perf:LLC-load-misses        -                           LLC load misses  cpu!=amd_zen
Guest Perf Extended|LLC_Store_Miss      raw    perf:LLC-store-misses       -                           LLC store misses  cpu!=amd_zen
Guest THP|Thp_Coverage_Pct              pct    meminfo:AnonHugePages       meminfo:AnonPages           THP coverage (instant)
Guest THP|Thp_AllocSuccess_Pct          dspct  vmstat:thp_fault_alloc      vmstat:thp_fault_fallback   1-min delta-based fault success rate
Guest THP|Thp_CollapseSuccess_Pct       dspct  vmstat:thp_collapse_alloc   vmstat:thp_collapse_alloc_failed  1-min delta-based collapse success rate
Guest THP|AnonPages_kB                   raw    meminfo:AnonPages          -                           anonymous pages (instant)
Guest THP|AnonHugePages_kB               raw    meminfo:AnonHugePages      -                           THP pages (instant)
Guest THP|Thp_Fault_Alloc_Delta          delta  vmstat:thp_fault_alloc     -                           THP fault allocs in 1 min
Guest THP|Thp_Fault_Fallback_Delta       delta  vmstat:thp_fault_fallback  -                           fallbacks in 1 min
Guest THP|Thp_Collapse_Alloc_Delta       delta  vmstat:thp_collapse_alloc  -                           collapse successes in 1 min
Guest THP|Thp_Collapse_Failed_Delta      delta  vmstat:thp_collapse_alloc_failed  -                    collapse failures in 1 min
Guest Perf AMD|L2_DTLB_Miss_PTI         pti    perf:l2_dtlb_miss           perf:instructions           L2 DTLB misses (page walks) per 1000 instr  cpu=amd_zen
Guest Perf AMD|L1D_Fill_Mem_PTI         pti    perf:dc_fill_mem            perf:instructions           L1D fills from DRAM or MMIO per 1000 instr  cpu=amd_zen3,amd_zen4,amd_zen5
Guest Perf AMD|L1D_Demand_Fill_Mem_PTI  pti    perf:dmnd_fill_mem          perf:instructions           L1D demand fills from DRAM or IO per 1000 instr (Zen 2)  cpu=amd_zen2
Guest Perf AMD|L2_Miss_PTI              pti    perf:l2_miss                perf:instructions           L2 misses (IC+DC requests, no prefetch) per 1000 instr  cpu=amd_zen
Guest Perf AMD|L1D_Fill_Mem_Pct         pct    perf:dc_fill_mem            perf:dc_fill_all            share of L1D fills that came from DRAM or MMIO  cpu=amd_zen3,amd_zen4,amd_zen5
Guest Perf AMD|L1D_Demand_Fill_Mem_Pct  pct    perf:dmnd_fill_mem          perf:dmnd_fill_all          share of L1D demand fills that came from DRAM or IO (Zen 2)  cpu=amd_zen2
Guest Perf AMD|L1_DTLB_Miss_PTI         pti    perf:l1_dtlb_miss           perf:instructions           L1 DTLB misses per 1000 instr  cpu=amd_zen
Guest Perf AMD|L2_ITLB_Miss_PTI         pti    perf:l2_itlb_miss           perf:instructions           L2 ITLB misses (page walks) per 1000 instr  cpu=amd_zen
Guest Perf AMD|L2_DTLB_Miss             raw    perf:l2_dtlb_miss           -                           L2 DTLB misses (page walks)  cpu=amd_zen
Guest Perf AMD|L1D_Fill_Mem             raw    perf:dc_fill_mem            -                           L1D fills from DRAM or MMIO  cpu=amd_zen3,amd_zen4,amd_zen5
Guest Perf AMD|L1D_Demand_Fill_Mem      raw    perf:dmnd_fill_mem          -                           L1D demand fills from DRAM or IO (Zen 2)  cpu=amd_zen2
Guest Perf AMD|L2_Miss                  raw    perf:l2_miss                -                           L2 misses (IC+DC requests, no prefetch)  cpu=amd_zen
Guest Perf AMD|L1D_Fill_All             raw    perf:dc_fill_all            -                           L1D fills from every source  cpu=amd_zen3,amd_zen4,amd_zen5
Guest Perf AMD|L1D_Demand_Fill_All      raw    perf:dmnd_fill_all          -                           L1D demand fills from every listed source (Zen 2)  cpu=amd_zen2
Guest Perf AMD|L1_DTLB_Miss             raw    perf:l1_dtlb_miss           -                           L1 DTLB misses  cpu=amd_zen
Guest Perf AMD|L2_ITLB_Miss             raw    perf:l2_itlb_miss           -                           L2 ITLB misses (page walks)  cpu=amd_zen
"

# ==========================================================
# * [PERF EVENT ALIASES] *  raw event codes behind the short names used above
# ----------------------------------------------------------
# One line = <short name>  <CPU classes>  <perf event string>  <event code, vendor event name>
# The short name is what perf prints (name=...), so keep both the same.
# CPU classes: written as after cpu= in the metric table (amd_zen = every Zen
#   class, a comma list, or "any"). A short name may have several lines; the
#   first line whose classes include this CPU is used.
# AMD: config = (umask << 8) | event code  (core events with a code up to 0xFF).
# Source of the AMD lines: Linux kernel, tools/perf/pmu-events/arch/x86/amdzen1
#   .. amdzen5 (one event list per Zen generation, maintained by AMD). Which
#   CPUID family/model uses which list: tools/perf/pmu-events/arch/x86/mapfile.csv.
#   PMCx044 (L1D fills by data source, any fill) is listed from Zen 3 on.
#   PMCx043 (L1D demand fills by data source) is what the Zen 2 list has. Its
#   sub-events are one unit-mask bit per source; dmnd_fill_mem sets the two
#   DRAM/IO bits (0x08 this die, 0x40 another die), dmnd_fill_all the five
#   listed bits (0x01 0x02 0x08 0x10 0x40).
#   PMCx085 (L2 ITLB miss): the unit mask for all page sizes differs per list;
#   the Zen 1 list has no unit mask on the event itself and AMD's recommended
#   event l2_itlb_misses (0x07) is used there.
# ==========================================================
PERF_ALIAS_TABLE="
l2_dtlb_miss   amd_zen                      cpu/config=0xf045,name=l2_dtlb_miss/   PMCx045 umask 0xf0  ls_l1_d_tlb_miss.all_l2_miss (Zen 4-5), l2_dtlb_misses (Zen 1-3)
dc_fill_mem    amd_zen3,amd_zen4,amd_zen5   cpu/config=0x4844,name=dc_fill_mem/    PMCx044 umask 0x48  ls_any_fills_from_sys.dram_io_all (Zen 4-5), l1_data_cache_fills_from_memory (Zen 3)
l2_miss        amd_zen                      cpu/config=0x0964,name=l2_miss/        PMCx064 umask 0x09  l2_cache_req_stat.ic_dc_miss_in_l2
dc_fill_all    amd_zen3,amd_zen4,amd_zen5   cpu/config=0xff44,name=dc_fill_all/    PMCx044 umask 0xff  ls_any_fills_from_sys.all (Zen 4-5), l1_data_cache_fills_all (Zen 3)
dmnd_fill_mem  amd_zen2                     cpu/config=0x4843,name=dmnd_fill_mem/  PMCx043 umask 0x48  ls_refills_from_sys.ls_mabresp_lcl_dram + ls_mabresp_rmt_dram
dmnd_fill_all  amd_zen2                     cpu/config=0x5b43,name=dmnd_fill_all/  PMCx043 umask 0x5b  ls_refills_from_sys, the five listed sources
l1_dtlb_miss   amd_zen                      cpu/config=0xff45,name=l1_dtlb_miss/   PMCx045 umask 0xff  ls_l1_d_tlb_miss.all
l2_itlb_miss   amd_zen4,amd_zen5            cpu/config=0x0f85,name=l2_itlb_miss/   PMCx085 umask 0x0f  bp_l1_tlb_miss_l2_tlb_miss.all
l2_itlb_miss   amd_zen2,amd_zen3            cpu/config=0xff85,name=l2_itlb_miss/   PMCx085 umask 0xff  bp_l1_tlb_miss_l2_tlb_miss
l2_itlb_miss   amd_zen1                     cpu/config=0x0785,name=l2_itlb_miss/   PMCx085 umask 0x07  l2_itlb_misses
"


# ==========================================================
# * Connection settings *  kept in a config file, not in this script
# ----------------------------------------------------------
# File   : ops_local.conf in the folder of this script
#          (another place: --config PATH, or env OPS_PUSH_CONFIG)
# Format : KEY=VALUE, one per line. A line that starts with # is a comment.
#            OPS_HOST=...       Operations (metrics) address or IP
#            OPS_USER=...       Operations account
#            OPS_PASS_ENC=...   encrypted password  (bash ops_metric_push.sh --encrypt prints it)
#            OPS_ENC_KEY=...    key that decrypts OPS_PASS_ENC
# Order  : command-line option > environment variable > config file
# The file is read as text and never executed. It holds the credential:
# chmod 600. Git holds this file with the keys only; never commit it with values.
# ==========================================================
OPS_CONFIG_NAME="ops_local.conf"
SCRIPT_VERSION="4.4"

OPS_STAT_ROOT="Custom Metrics"
INTERVAL_SEC=60
PERF_WIN_SEC=55                # length of one perf run with --perf-mode window (v4.1 method)
PERF_MODE="resident"           # resident = one perf process for the whole run | window = a new run per interval  [--perf-mode]
PERF_FIT=0                     # 1 = keep only as many events as the hardware counters hold  [--perf-fit]
PERF_LAG_MAX=5                 # resident perf is restarted on a boundary when its output is this many seconds late
PERF_WAIT_MAX=8                # seconds to wait after a boundary for the interval output of the resident perf
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
DRY_RUN=0
DRY_RUN_OPT=0                  # 1 only when --dry-run was passed explicitly

COLLECT_MODE="group"           # group (thp|perf|both) | names (explicit list)
COLLECT_SCOPE="both"           # thp | perf | both        [--collect]
COLLECT_NAMES=""               # comma-separated metric names, COLLECT_MODE=names
COLLECT_LABEL=""               # banner text

TARGET_KIND="vm"               # vm | any                 [--target]
OPS_FOUND_KIND=""              # resourceKindKey of the object actually matched
OPS_TARGET_DESC=""             # banner text

OUT_MODE="ops"                 # ops | file | both
CSV_MODE=0                     # 1 when OUT_MODE is file or both
CSV_OUT=""                     # --out value (directory or full *.csv path)
CSV_DIR=""                     # resolved output directory
CSV_BASE=""                    # path prefix, without the _NNN.csv suffix
CSV_PATH=""                    # part file currently being written
CSV_PART=1
CSV_ROWS=0
CSV_MAX_BYTES=$(( 10 * 1024 * 1024 ))   # --max-size, default 10MB
CSV_HEADER=""
PID_OWNED=0                    # 1 only when this process wrote the PID file

HOSTNAME_S=$(hostname -s 2>/dev/null || hostname)
PROC_ROOT="${OPS_PUSH_PROC_ROOT:-/proc}"   # for tests only: a directory that stands in for /proc
PERF_SEP=';'                   # perf stat -x separator (the perf manual recommends ';' because commas are not quoted)
PERF_TMPFILE="/tmp/ops_push_perf_$$"
REAUTH_FLAG="/tmp/ops_push_reauth_$$"
SUPPORT_LOG="/tmp/ops_metric_push_support.log"   # fixed path, overwritten each run
PID_FILE_PERF="/tmp/ops_metric_push.pid"         # collector that drives the PMU
PID_FILE_NOPERF="/tmp/ops_metric_push_noperf.pid" # THP-only collector, no PMU use
PID_FILE="$PID_FILE_PERF"                        # for --stop, written at startup
OPS_TOKEN=""
TOKEN_EXP=0
TOKEN_FALLBACK_SEC=1500
TOKEN_MARGIN_SEC=300
AUTH_SCHEME="OpsToken"
GAP_MIN=5
LOOP=0
PUSH_TRY=0
PROBE_KEPT=0
PROBE_DROPPED=0
PROBE_SKIPPED=0
PROBE_DISABLED=""
PERF_OK_N=0
PERF_BAD_N=0

declare -a M_GROUP M_NAME M_CALC M_SRC1 M_SRC2 M_ACTIVE M_INSCOPE
declare -a M_CPU               # cpu=/cpu!= condition of the line ("" = every CPU)
declare -a M_NA                # 1 = the line does not apply to this CPU class
declare -a M_PREV1 M_PREV2     # previous cumulative values of source 1 / 2 for delta and dspct ("" = none yet)
declare -a CSV_ROW             # this minute's values, indexed like the table
METRIC_N=0
PERF_EVENTS=""                 # perf event strings of the events in use, comma separated (for perf -e)
PERF_LABELS=""                 # their names as perf prints them, space separated
# perf events the selected metrics ask for, in metric-table order (= priority for --perf-fit)
declare -a EV_KEY              # name in the metric table = name perf prints
declare -a EV_SPEC             # perf event string (same as the name unless an alias defines a raw code)
declare -a EV_STATE            # new | ok | bad (unsupported) | fit (dropped by --perf-fit) | unused | undef (no code for this CPU class)
declare -a EV_VAL EV_PCT       # count and share of time counted, for the interval that just ended
EV_N=0
EV_OK_N=0
declare -a ALIAS_KEY ALIAS_SPEC ALIAS_NOTE
declare -a ALIAS_CLS ALIAS_ON     # CPU classes of the alias line, 1 = the line applies to this CPU
ALIAS_N=0
declare -a PROC_SRC PROC_VAL   # meminfo:/vmstat: sources in use and their current values
PROC_N=0
PROC_WANT=""
CPU_VENDOR=""; CPU_FAMILY=-1; CPU_MODEL_NO=-1; CPU_CLASS="other"
CPU_GROUP=""                   # amd_zen for the classes amd_zen1 .. amd_zen5, "" otherwise
NA_N=0                         # selected metrics that do not apply to this CPU class
PERF_PID=""                    # the perf process of the current interval
PERF_HOLD=0                    # 1 = do not start perf on this boundary (it starts on the next one)
PERF_HAVE=0                    # 1 = the interval that just ended has perf values
PERF_LAST_TS=""                # time stamp of the last perf interval block that was used
PERF_STARTS=0                  # how many times perf was started for collection
PERF_INTERVAL_OK=""            # "" not checked | 1 | 0   (perf stat -I works)
PERF_MODE_WHY=""               # why the mode differs from what was asked for
PARSE_TS=""
MUX_KNOWN=0                    # 1 = perf prints the share of time each event counted
MUX_MIN_X100=-1                # smallest share among the events, in 1/100 percent (10000 = no multiplexing)
MUX_TXT="-"
FIT_DROPPED=""                 # events removed by --perf-fit
CAL_NOTE=""                    # result of the start-up multiplexing check
RV="-1"; PX=-1


# ----------------------------------------------------------
# 1. Arguments
# ----------------------------------------------------------
show_help() {
    cat <<HELP
Usage: bash $0 --vm <VM name>

  Push Guest OS perf/proc metrics to the matching object in VCF Operations,
  or write them to a local CSV. Collected items are managed in the
  [METRIC TABLE] at the top of the script; --collect narrows that table and
  --target decides which existing Ops object they are pushed to.

Options:
  --collect WHAT     What to collect: both | thp | perf | <name,name,...>
                     [default: both]
                       both = perf metrics + THP metrics (v3 behaviour)
                       thp  = THP / proc metrics only. perf is never started,
                              so no PMU load and no perf_event_paranoid needed
                       perf = perf metrics only, THP metrics skipped
                       a,b  = explicit metric names, exactly as --list prints them
                     Unselected metrics keep an empty CSV column, so files from
                     different hosts/settings still merge as one table.
  --target WHERE     Ops push target: vm | any [default: vm]
                       vm  = VMWARE VirtualMachine of this name; error if absent
                       any = match the name against every adapter kind,
                             VirtualMachine first. For a target that is not a
                             VM but does already exist in Ops.
                     Objects are never created: one only exists behind a real
                     adapter. A physical host with no object -> --mode file.
  --mode MODE        Output mode: ops | file | both [default: ops]
                       ops  = push to Ops only (v2 behaviour)
                       file = write a local CSV only, never contacts Ops
                       both = push and write the CSV at the same time
  --out PATH         CSV output directory, or a full *.csv path
                     [required for --mode file|both]
  --max-size MB      Roll over to the next CSV part above this size [default: 10]
  --vm NAME          Ops object name [default: ${HOSTNAME_S}]
                     vCenter display name with --target vm; object name otherwise
  --name NAME        Same as --vm (clearer wording with --target any)
  --config PATH      Connection settings file [default: ${OPS_CONFIG_NAME} in the
                     folder of this script]  [env: OPS_PUSH_CONFIG]
  --host HOST        Override Ops address [config file: OPS_HOST]  [env: OPS_HOST]
  --user NAME        Override account     [config file: OPS_USER]  [env: OPS_USER]
  --pass PASS        Override password [env OPS_PASSWORD recommended]
  --resource-id ID   Specify the Ops resource id directly (skips lookup)
  --interval SEC     Collection interval in seconds [default: ${INTERVAL_SEC}]
  --perf-mode MODE   How perf is run: resident | window [default: resident]
                       resident = one perf process for the whole run; it prints
                                  the deltas of every interval (perf stat -I),
                                  so perf is not started again every interval.
                                  Falls back to window by itself when this
                                  perf has no -I.
                       window   = a new perf run of ${PERF_WIN_SEC}s in every interval (v4.1)
  --perf-fit         Keep only as many perf events as the hardware counters
                     hold, in metric-table order, so that no event is
                     time-shared (multiplexed). Metrics that lose an event are
                     excluded and listed in the support probe log.
  --cacert PATH      Verify certificates + CA path (uses -k if omitted)
  --list             Print the metrics defined in the table and exit
  --stop             Stop a running collector including its child processes
  --dry-run          Print JSON without pushing (support probe still runs)
  --encrypt          Print the OPS_PASS_ENC line for the config file (encrypted
                     password; needs OPS_ENC_KEY in that file) and exit
  -h, --help         Help

Examples:
  bash $0 --list
  bash $0 --dry-run --vm vm-node01
  nohup bash $0 --perf-fit --vm vm-node01 > /tmp/ops_push.log 2>&1 &
  nohup bash $0 --collect thp --vm vm-node01 > /tmp/ops_push.log 2>&1 &
  nohup bash $0 --target any --name bm-node01 > /tmp/ops_push.log 2>&1 &
  nohup bash $0 --vm vm-node01 > /tmp/ops_push.log 2>&1 &
  nohup bash $0 --mode file --out /data/perf > /tmp/ops_push.log 2>&1 &
  nohup bash $0 --mode both --out /data/perf --vm vm-node01 > /tmp/ops_push.log 2>&1 &

CSV output [--mode file|both]:
  File   : <out>/ops_metric_<host>_<YYYYmmdd-HHMMSS>_001.csv
           Each run gets its own file (start timestamp), so repeated
           start/stop cycles in one day never overwrite each other.
           Above --max-size it rolls over to _002.csv, _003.csv ...
           Existing files are never truncated or overwritten.
  Layout : 1 row = 1 collection. Columns are fixed at Timestamp, EpochSec
           plus every metric in table order, even the ones the probe
           excluded, so CSVs from different hosts merge directly.
           An empty cell = not collected (same meaning as a value the push
           path omits, which Ops draws as a gap rather than a 0).
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

# --stop : reliably terminate a running collector including children (perf/sleep/curl)
# A THP-only run keeps its own PID file, so a perf collector and a THP-only
# collector can coexist. --stop takes down whichever of the two is alive.
stop_one() {   # $1 = pid file. 0 = a live collector was stopped
    local pf="$1" pid w kid
    [ -f "$pf" ] || return 1
    pid=$(cat "$pf" 2>/dev/null)
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
        echo "[INFO] ${pf}: PID ${pid:-?} is already gone. Cleaning up the PID file."
        rm -f "$pf"
        return 1
    fi
    echo "[INFO] Stopping collector [PID ${pid}]  (${pf})..."
    # clean up children (perf, sleep, curl) first, then the main process.
    # perf has a child of its own (the command it waits for); stop that one as well.
    for kid in $(pgrep -P "$pid" 2>/dev/null); do
        pkill -TERM -P "$kid" 2>/dev/null
    done
    pkill -TERM -P "$pid" 2>/dev/null
    kill -TERM "$pid" 2>/dev/null
    # wait up to 5 seconds, then force kill
    w=0
    while kill -0 "$pid" 2>/dev/null && [ "$w" -lt 5 ]; do sleep 1; w=$((w+1)); done
    if kill -0 "$pid" 2>/dev/null; then
        pkill -KILL -P "$pid" 2>/dev/null
        kill -KILL "$pid" 2>/dev/null
        echo "[INFO] Force kill (-9) performed."
    fi
    rm -f "$pf"
    echo "[INFO] Stopped."
    return 0
}

do_stop() {
    local pf stopped=0
    for pf in "$PID_FILE_PERF" "$PID_FILE_NOPERF"; do
        stop_one "$pf" && stopped=$((stopped+1))
    done
    if [ "$stopped" -eq 0 ]; then
        echo "[INFO] No collector running (checked ${PID_FILE_PERF}, ${PID_FILE_NOPERF}),"
        echo "       or it was started the old way."
        echo "       Manual stop: pkill -f ops_metric_push; pkill -f 'perf stat -a -x'"
    fi
    exit 0
}

DO_LIST=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --vm|--name)   OPS_VM_NAME="${2:-}"; shift ;;
        --collect)
            case "${2:-}" in
                both|all)  COLLECT_MODE="group"; COLLECT_SCOPE="both" ;;
                thp|THP)   COLLECT_MODE="group"; COLLECT_SCOPE="thp"  ;;
                perf|PERF) COLLECT_MODE="group"; COLLECT_SCOPE="perf" ;;
                '') echo "[ERROR] --collect needs a value: both | thp | perf | <name,name,...>" >&2; exit 1 ;;
                -*) echo "[ERROR] --collect needs a value: both | thp | perf | <name,name,...>" >&2; exit 1 ;;
                *)  COLLECT_MODE="names"; COLLECT_NAMES="$2" ;;
            esac
            shift ;;
        --target)
            case "${2:-}" in
                vm|any) TARGET_KIND="$2" ;;
                *) echo "[ERROR] --target must be one of: vm | any" >&2; exit 1 ;;
            esac
            shift ;;
        --config)      OPS_CONFIG="${2:-}"; CONFIG_EXPLICIT=1; shift ;;
        --host)        OPS_HOST="${2:-}"; shift ;;
        --user)        OPS_USER="${2:-}"; shift ;;
        --pass)        OPS_PASSWORD="${2:-}"; shift ;;
        --resource-id) OPS_RESOURCE_ID="${2:-}"; shift ;;
        --cacert)      OPS_CACERT="${2:-}"; shift ;;
        --interval)
            case "${2:-}" in ''|*[!0-9]*) echo "[ERROR] --interval must be an integer" >&2; exit 1 ;; esac
            INTERVAL_SEC="$2"; shift ;;
        --perf-mode)
            case "${2:-}" in
                resident|window) PERF_MODE="$2" ;;
                *) echo "[ERROR] --perf-mode must be one of: resident | window" >&2; exit 1 ;;
            esac
            shift ;;
        --perf-fit) PERF_FIT=1 ;;
        --mode)
            case "${2:-}" in
                ops|file|both) OUT_MODE="$2" ;;
                *) echo "[ERROR] --mode must be one of: ops | file | both" >&2; exit 1 ;;
            esac
            shift ;;
        --out)     CSV_OUT="${2:-}"; shift ;;
        --max-size)
            case "${2:-}" in ''|*[!0-9]*) echo "[ERROR] --max-size must be an integer (MB)" >&2; exit 1 ;; esac
            [ "$2" -lt 1 ] && { echo "[ERROR] --max-size minimum is 1 (MB)" >&2; exit 1; }
            CSV_MAX_BYTES=$(( $2 * 1024 * 1024 )); shift ;;
        --list)    DO_LIST=1 ;;
        --stop)    do_stop ;;
        --dry-run) DRY_RUN=1; DRY_RUN_OPT=1 ;;
        --encrypt) DO_ENCRYPT=1 ;;
        -h|--help) show_help; exit 0 ;;
        *) echo "[ERROR] Unknown option: $1" >&2; echo "        bash $0 --help" >&2; exit 1 ;;
    esac
    shift
done
[ -z "$OPS_VM_NAME" ] && OPS_VM_NAME="$HOSTNAME_S"

# connection settings: command-line option > environment variable > config file
if [ "$CONFIG_EXPLICIT" -eq 1 ] && [ ! -f "$OPS_CONFIG" ]; then
    echo "[ERROR] config file not found: ${OPS_CONFIG}" >&2; exit 1
fi
read_config "$OPS_CONFIG"
[ -z "$OPS_HOST" ] && OPS_HOST="$CFG_OPS_HOST"
[ -z "$OPS_USER" ] && OPS_USER="$CFG_OPS_USER"
[ "$DO_ENCRYPT" -eq 1 ] && do_encrypt

# --- Collect scope resolution -------------------------------
# Names are matched exactly as --list prints them; whitespace inside the
# list is only there for readability.
if [ "$COLLECT_MODE" = "names" ]; then
    COLLECT_NAMES=$(printf '%s' "$COLLECT_NAMES" | tr -d '[:space:]')
    [ -z "$COLLECT_NAMES" ] && { echo "[ERROR] --collect list is empty" >&2; exit 1; }
fi


# --- Output mode resolution ---------------------------------
# "file" contacts Ops for nothing, so it reuses the whole dry-run guard set
# (no password decrypt, no token, no curl/json requirement, no pre-start checks).
case "$OUT_MODE" in
    file) CSV_MODE=1; DRY_RUN=1 ;;
    both) CSV_MODE=1 ;;
    ops)  CSV_MODE=0 ;;
esac
if [ "$CSV_MODE" -eq 1 ] && [ -z "$CSV_OUT" ]; then
    echo "[ERROR] --mode ${OUT_MODE} requires --out <directory|file.csv>" >&2; exit 1
fi
if [ "$CSV_MODE" -eq 0 ] && [ -n "$CSV_OUT" ]; then
    echo "[ERROR] --out has no effect without --mode file|both" >&2; exit 1
fi
if [ "$DRY_RUN_OPT" -eq 1 ] && [ "$OUT_MODE" = "both" ]; then
    echo "[ERROR] --dry-run conflicts with --mode both (both requires a real push)." >&2
    echo "        Use --mode file for collection without pushing." >&2; exit 1
fi


# ----------------------------------------------------------
# 2. CPU class, table parsing (perf event aggregation + collect scope)
# ----------------------------------------------------------
# CPU class from /proc/cpuinfo. It decides which cpu=/cpu!= lines of the metric table and which
# lines of the alias table apply.
detect_cpu_class() {
    local ci="${PROC_ROOT}/cpuinfo" m
    CPU_VENDOR=$(awk -F: '/^vendor_id/{gsub(/[ \t]/,"",$2); print $2; exit}' "$ci" 2>/dev/null)
    CPU_FAMILY=$(awk -F: '/^cpu family/{gsub(/[ \t]/,"",$2); print $2; exit}' "$ci" 2>/dev/null)
    CPU_MODEL_NO=$(awk -F: '/^model[ \t]*:/{gsub(/[ \t]/,"",$2); print $2; exit}' "$ci" 2>/dev/null)
    case "$CPU_FAMILY" in ''|*[!0-9]*) CPU_FAMILY=-1 ;; esac
    case "$CPU_MODEL_NO" in ''|*[!0-9]*) CPU_MODEL_NO=-1 ;; esac
    CPU_GROUP=""
    case "$CPU_VENDOR" in
        GenuineIntel) CPU_CLASS="intel" ;;
        AuthenticAMD)
            CPU_CLASS="amd"
            # Zen generation from family and model (decimal here): the ranges the Linux kernel uses to
            # choose its per-generation event list (tools/perf/pmu-events/arch/x86/mapfile.csv).
            #   Family 17h (23): models 00h-2Fh = Zen 1, the others = Zen 2
            #   Family 19h (25): models 00h-0Fh, 20h-2Fh, 40h-5Fh = Zen 3, the others = Zen 4
            #   Family 1Ah (26): models 00h-2Fh, 40h-4Fh, 60h-7Fh = Zen 5 (the others: no class yet)
            m="$CPU_MODEL_NO"
            if [ "$m" -ge 0 ]; then
                case "$CPU_FAMILY" in
                    23) if [ "$m" -le 47 ]; then CPU_CLASS="amd_zen1"; else CPU_CLASS="amd_zen2"; fi ;;
                    25) if [ "$m" -le 15 ] || { [ "$m" -ge 32 ] && [ "$m" -le 47 ]; } \
                           || { [ "$m" -ge 64 ] && [ "$m" -le 95 ]; }; then
                            CPU_CLASS="amd_zen3"
                        else
                            CPU_CLASS="amd_zen4"
                        fi ;;
                    26) if [ "$m" -le 47 ] || { [ "$m" -ge 64 ] && [ "$m" -le 79 ]; } \
                           || { [ "$m" -ge 96 ] && [ "$m" -le 127 ]; }; then
                            CPU_CLASS="amd_zen5"
                        fi ;;
                esac
            fi
            case "$CPU_CLASS" in amd_zen[1-5]) CPU_GROUP="amd_zen" ;; esac ;;
        *) CPU_CLASS="other" ;;
    esac
}
detect_cpu_class

cpu_match() {   # $1 = class list: a class, the group name amd_zen, "any", or several joined with commas. 0 = this CPU is in it
    local rest="$1" p
    while [ -n "$rest" ]; do
        p="${rest%%,*}"
        case "$rest" in *,*) rest="${rest#*,}" ;; *) rest="" ;; esac
        [ -z "$p" ] && continue
        [ "$p" = "any" ] && return 0
        [ "$p" = "$CPU_CLASS" ] && return 0
        { [ -n "$CPU_GROUP" ] && [ "$p" = "$CPU_GROUP" ]; } && return 0
    done
    return 1
}

cpu_applies() {   # $1 = "" | cpu=<class list> | cpu!=<class list>. 0 = the line applies to this CPU
    case "$1" in
        '')     return 0 ;;
        cpu!=*) cpu_match "${1#cpu!=}" && return 1; return 0 ;;
        cpu=*)  cpu_match "${1#cpu=}" && return 0; return 1 ;;
    esac
    return 0
}

parse_aliases() {
    local line k cls sp note
    while IFS= read -r line; do
        case "$line" in ''|\#*) continue ;; esac
        # shellcheck disable=SC2086
        set -- $line
        k="${1:-}"; cls="${2:-}"; sp="${3:-}"
        { [ -z "$k" ] || [ -z "$cls" ] || [ -z "$sp" ]; } && { echo "[ERROR] alias table parse failed: '${line}'" >&2; exit 1; }
        # the second word is the CPU class list; a perf event string there means the column is missing
        case "$cls" in */*|*=*) echo "[ERROR] alias table line has no CPU class column: '${line}'" >&2; exit 1 ;; esac
        shift 3
        note=""
        [ "$#" -gt 0 ] && note="$*"
        ALIAS_KEY[$ALIAS_N]="$k"; ALIAS_CLS[$ALIAS_N]="$cls"; ALIAS_SPEC[$ALIAS_N]="$sp"; ALIAS_NOTE[$ALIAS_N]="$note"
        if cpu_match "$cls"; then ALIAS_ON[$ALIAS_N]="1"; else ALIAS_ON[$ALIAS_N]="0"; fi
        ALIAS_N=$((ALIAS_N+1))
    done <<EOF
$PERF_ALIAS_TABLE
EOF
}
parse_aliases

want_event() {   # $1 = event name from the table. Adds it once, in table order.
    local k="$1" i sp st
    i=0
    while [ "$i" -lt "$EV_N" ]; do
        [ "${EV_KEY[$i]}" = "$k" ] && return 0
        i=$((i+1))
    done
    # The alias line for this CPU class gives the raw code. A short name that only has lines for
    # other classes has no code on this CPU: state undef, it is never passed to perf.
    sp="$k"; st="new"
    i=0
    while [ "$i" -lt "$ALIAS_N" ]; do
        if [ "${ALIAS_KEY[$i]}" = "$k" ]; then
            if [ "${ALIAS_ON[$i]}" = "1" ]; then sp="${ALIAS_SPEC[$i]}"; st="new"; break; fi
            st="undef"
        fi
        i=$((i+1))
    done
    EV_KEY[$EV_N]="$k"; EV_SPEC[$EV_N]="$sp"; EV_STATE[$EV_N]="$st"; EV_VAL[$EV_N]="-1"; EV_PCT[$EV_N]="-"
    EV_N=$((EV_N+1))
}

ev_state() {   # $1 = event name -> RV = its state, "" when the event is not in use
    local i=0
    RV=""
    while [ "$i" -lt "$EV_N" ]; do
        [ "${EV_KEY[$i]}" = "$1" ] && { RV="${EV_STATE[$i]}"; return 0; }
        i=$((i+1))
    done
    return 0
}

want_proc() {   # $1 = meminfo:<key> | vmstat:<key>. Adds it once.
    local i=0
    while [ "$i" -lt "$PROC_N" ]; do
        [ "${PROC_SRC[$i]}" = "$1" ] && return 0
        i=$((i+1))
    done
    PROC_SRC[$PROC_N]="$1"; PROC_VAL[$PROC_N]="-1"; PROC_N=$((PROC_N+1))
    PROC_WANT="${PROC_WANT:+$PROC_WANT }$1"
}

# A metric belongs to the perf scope when any of its sources is a perf event,
# and to the THP scope otherwise (meminfo/vmstat). Deriving this from the
# sources rather than the group name means a new line added to the metric
# table is classified correctly without touching this code.
metric_scope() {   # $1=src1 $2=src2 -> perf | thp
    case "$1 $2" in
        *perf:*) echo "perf" ;;
        *)       echo "thp"  ;;
    esac
}

in_scope() {   # $1=metric scope  $2=metric name. 0 = selected by --collect
    case "$COLLECT_MODE" in
        group)
            [ "$COLLECT_SCOPE" = "both" ] && return 0
            [ "$COLLECT_SCOPE" = "$1" ] && return 0
            return 1 ;;
        names)
            case ",${COLLECT_NAMES}," in
                *",$2,"*) return 0 ;;
                *)        return 1 ;;
            esac ;;
    esac
    return 1
}

parse_table() {
    local line grp rest name calc s1 s2 f sc w cond n
    while IFS= read -r line; do
        case "$line" in ''|\#*) continue ;; esac
        grp="${line%%|*}"
        rest="${line#*|}"
        name="${rest%%[[:space:]]*}"
        rest="${rest#"$name"}"
        # shellcheck disable=SC2086
        set -- $rest
        calc="${1:-}"; s1="${2:-}"; s2="${3:-}"
        { [ -z "$calc" ] || [ -z "$s1" ]; } && { echo "[ERROR] table parse failed: '${line}'" >&2; exit 1; }
        cond=""
        for w in "$@"; do
            case "$w" in cpu=*|cpu!=*) cond="$w" ;; esac
        done
        n="$METRIC_N"
        M_GROUP[$n]="$grp"; M_NAME[$n]="$name"; M_CALC[$n]="$calc"
        M_SRC1[$n]="$s1";   M_SRC2[$n]="$s2";   M_CPU[$n]="$cond"
        M_PREV1[$n]="";     M_PREV2[$n]=""
        sc=$(metric_scope "$s1" "$s2")
        if in_scope "$sc" "$name"; then
            M_INSCOPE[$n]="1"
            if cpu_applies "$cond"; then
                M_NA[$n]="0"; M_ACTIVE[$n]="1"
                # only a selected metric that applies to this CPU asks for its perf events,
                # so --collect thp leaves the event list empty and perf is never probed or started
                for f in "$s1" "$s2"; do
                    case "$f" in
                        perf:*)             want_event "${f#perf:}" ;;
                        meminfo:*|vmstat:*) want_proc "$f" ;;
                    esac
                done
            else
                M_NA[$n]="1"; M_ACTIVE[$n]="0"; NA_N=$((NA_N+1))
            fi
        else
            M_INSCOPE[$n]="0"; M_ACTIVE[$n]="0"; M_NA[$n]="0"
            cpu_applies "$cond" || M_NA[$n]="1"
        fi
        METRIC_N=$((METRIC_N+1))
    done <<EOF
$METRIC_TABLE
EOF
}
parse_table
[ "$METRIC_N" -eq 0 ] && { echo "[ERROR] metric table is empty" >&2; exit 1; }

# --- --collect verification -------------------------------------
# An unknown name is an error, not a silently empty run: a typo would
# otherwise produce a CSV of empty columns that looks like missing data.
SCOPE_N=0
i=0
while [ "$i" -lt "$METRIC_N" ]; do
    [ "${M_INSCOPE[$i]}" = "1" ] && SCOPE_N=$((SCOPE_N+1))
    i=$((i+1))
done
if [ "$COLLECT_MODE" = "names" ]; then
    MISSING=""
    OLD_IFS="$IFS"; IFS=','
    for nm in $COLLECT_NAMES; do
        [ -z "$nm" ] && continue
        found=0; i=0
        while [ "$i" -lt "$METRIC_N" ]; do
            [ "${M_NAME[$i]}" = "$nm" ] && { found=1; break; }
            i=$((i+1))
        done
        [ "$found" -eq 0 ] && MISSING="${MISSING:+$MISSING, }${nm}"
    done
    IFS="$OLD_IFS"
    if [ -n "$MISSING" ]; then
        echo "[ERROR] --collect: no such metric: ${MISSING}" >&2
        echo "        Valid names: bash $0 --list" >&2
        exit 1
    fi
fi
[ "$SCOPE_N" -eq 0 ] && { echo "[ERROR] --collect selected no metric" >&2; exit 1; }
CPU_LABEL="${CPU_CLASS} [${CPU_VENDOR:-unknown vendor}, family ${CPU_FAMILY}, model ${CPU_MODEL_NO}]"

case "$COLLECT_MODE" in
    group)
        case "$COLLECT_SCOPE" in
            both) COLLECT_LABEL="both [perf + THP], ${SCOPE_N}/${METRIC_N} metrics" ;;
            thp)  COLLECT_LABEL="THP only [perf not started], ${SCOPE_N}/${METRIC_N} metrics" ;;
            perf) COLLECT_LABEL="perf only [THP skipped], ${SCOPE_N}/${METRIC_N} metrics" ;;
        esac ;;
    names) COLLECT_LABEL="named [${COLLECT_NAMES}], ${SCOPE_N}/${METRIC_N} metrics" ;;
esac

# A run that asks for no perf event touches no PMU, so it may legitimately
# run beside a perf collector. It takes its own PID file; --stop covers both.
if [ "$EV_N" -eq 0 ]; then
    PID_FILE="$PID_FILE_NOPERF"
fi

ev_names() {   # -> names of the wanted perf events on one line
    local i=0 out=""
    while [ "$i" -lt "$EV_N" ]; do out="${out}${EV_KEY[$i]} "; i=$((i+1)); done
    printf '%s' "$out"
}

if [ "$DO_LIST" -eq 1 ]; then
    echo "Defined metrics [${METRIC_N}]  root='${OPS_STAT_ROOT}'"
    echo "collect  : ${COLLECT_LABEL}"
    echo "CPU class: ${CPU_LABEL}"
    if [ "$EV_N" -gt 0 ]; then
        echo "perf events [requested by the selected metrics]: $(ev_names)"
    else
        echo "perf events [requested by the selected metrics]: none -- perf is not started"
    fi
    echo "───────────────────────────────────────────"
    echo "  sel = selected by --collect   -   = not selected (empty CSV column)"
    echo "  n/a = selected, but the line is for another CPU class (empty CSV column)"
    echo "  cpu=amd_zen means amd_zen1 .. amd_zen5"
    i=0
    while [ "$i" -lt "$METRIC_N" ]; do
        if [ "${M_INSCOPE[$i]}" != "1" ]; then mark=" - "
        elif [ "${M_NA[$i]}" = "1" ]; then mark="n/a"
        else mark="sel"; fi
        printf '  %s  %-20s | %-24s %-6s %s %s %s\n' \
            "$mark" "${M_GROUP[$i]}" "${M_NAME[$i]}" "${M_CALC[$i]}" "${M_SRC1[$i]}" "${M_SRC2[$i]}" "${M_CPU[$i]}"
        i=$((i+1))
    done
    echo "───────────────────────────────────────────"
    if [ "$ALIAS_N" -gt 0 ]; then
        echo "perf event aliases (raw event codes).  * = the line used on this CPU class"
        i=0
        while [ "$i" -lt "$ALIAS_N" ]; do
            if [ "${ALIAS_ON[$i]}" = "1" ]; then mark="*"; else mark=" "; fi
            printf ' %s %-14s %-27s %-40s %s\n' "$mark" "${ALIAS_KEY[$i]}" "${ALIAS_CLS[$i]}" "${ALIAS_SPEC[$i]}" "${ALIAS_NOTE[$i]}"
            i=$((i+1))
        done
        echo "───────────────────────────────────────────"
    fi
    echo "Ops tree: <object> > ${OPS_STAT_ROOT} > <group> > <metric>"
    exit 0
fi


# ----------------------------------------------------------
# 3. Validation / password / URL
# ----------------------------------------------------------
[ "$INTERVAL_SEC" -lt 10 ] && { echo "[ERROR] --interval minimum is 10" >&2; exit 1; }
[ "$INTERVAL_SEC" -ne 60 ] && PERF_WIN_SEC=$(( INTERVAL_SEC - GAP_MIN ))
GAP=$(( INTERVAL_SEC - PERF_WIN_SEC ))
{ [ "$PERF_WIN_SEC" -le 0 ] || [ "$GAP" -lt "$GAP_MIN" ]; } && { echo "[ERROR] perf window calculation error" >&2; exit 1; }
# with a short --interval the waiting limits of the resident perf shrink with it
[ "$PERF_WAIT_MAX" -gt $(( INTERVAL_SEC / 3 )) ] && PERF_WAIT_MAX=$(( INTERVAL_SEC / 3 ))
[ "$PERF_LAG_MAX" -gt $(( INTERVAL_SEC / 5 )) ] && PERF_LAG_MAX=$(( INTERVAL_SEC / 5 ))
[ "$PERF_LAG_MAX" -lt 1 ] && PERF_LAG_MAX=1

if [ "$DRY_RUN" -eq 0 ]; then
    { [ "$OPS_HOST" = "ops.example.com" ] || [ -z "$OPS_HOST" ]; } && {
        echo "[ERROR] Ops address not set. Put OPS_HOST=<address> into ${OPS_CONFIG} [${CONFIG_STATE}], or use --host / env OPS_HOST." >&2
        [ "$CONFIG_STATE" = "not found" ] && echo "        Put ops_local.conf (the file with the four keys) there and fill it in." >&2
        exit 1; }
    [ -z "$OPS_USER" ] && {
        echo "[ERROR] account not set. Put OPS_USER=<account> into ${OPS_CONFIG} [${CONFIG_STATE}], or use --user / env OPS_USER." >&2; exit 1; }
fi
PASS_SRC="config file, encrypted"
if [ -n "$OPS_PASSWORD" ]; then PASS_SRC="env var/argument"
elif [ "$DRY_RUN" -eq 0 ]; then OPS_PASSWORD=$(decrypt_pass) || exit 1; fi

if [ "$DRY_RUN" -eq 0 ]; then
    [ -z "$OPS_PASSWORD" ] && { echo "[ERROR] password is empty" >&2; exit 1; }
    command -v curl >/dev/null 2>&1 || { echo "[ERROR] curl not found" >&2; exit 1; }
fi

JSON_TOOL=""
if command -v python3 >/dev/null 2>&1; then JSON_TOOL="python3"
elif command -v jq >/dev/null 2>&1; then JSON_TOOL="jq"
elif [ "$DRY_RUN" -eq 0 ]; then echo "[ERROR] python3 or jq required" >&2; exit 1; fi

case "$OPS_HOST" in
    http://*|https://*) OPS_BASE="${OPS_HOST%/}" ;;
    *)                  OPS_BASE="https://${OPS_HOST}" ;;
esac
if [ -n "$OPS_CACERT" ]; then
    [ -r "$OPS_CACERT" ] || { echo "[ERROR] --cacert not readable" >&2; exit 1; }
    CURL_TLS="--cacert ${OPS_CACERT}"; TLS_LABEL="CA verify"
else
    CURL_TLS="-k"; TLS_LABEL="verification skipped [-k]"
fi

# ----------------------------------------------------------
# 3-1. CSV destination  [--mode file|both]
#      Resolves the base name only. Nothing is created until the
#      header is written, after the support probe.
# ----------------------------------------------------------
if [ "$CSV_MODE" -eq 1 ]; then
    case "$CSV_OUT" in
        *.csv)
            CSV_DIR=$(dirname "$CSV_OUT")
            CSV_BASE="${CSV_OUT%.csv}"
            ;;
        *)
            CSV_DIR="${CSV_OUT%/}"
            [ -z "$CSV_DIR" ] && CSV_DIR="/"
            CSV_BASE="${CSV_DIR}/ops_metric_${HOSTNAME_S}_$(date '+%Y%m%d-%H%M%S')"
            ;;
    esac
    # The directory must already exist -- same policy as prs_maps_monitor.
    # Creating it silently would hide a typo and scatter data.
    [ -d "$CSV_DIR" ] || { echo "[ERROR] --out directory does not exist: ${CSV_DIR}" >&2; exit 1; }
    [ -w "$CSV_DIR" ] || { echo "[ERROR] --out directory is not writable: ${CSV_DIR}" >&2; exit 1; }
    # Collision guard: if this base is already taken (same-second restart, or
    # an explicit --out file.csv reused), step aside instead of overwriting.
    CSV_RUN=1
    CSV_BASE_TRY="$CSV_BASE"
    while [ -e "${CSV_BASE_TRY}_001.csv" ]; do
        CSV_RUN=$(( CSV_RUN + 1 ))
        CSV_BASE_TRY="${CSV_BASE}-r${CSV_RUN}"
    done
    CSV_BASE="$CSV_BASE_TRY"
fi

# Header: every metric in table order, including probe-excluded ones, so the
# schema is identical on every host and the files can be merged as-is.
build_csv_header() {
    local i
    CSV_HEADER="Timestamp,EpochSec"
    i=0
    while [ "$i" -lt "$METRIC_N" ]; do
        CSV_HEADER="${CSV_HEADER},${M_NAME[$i]}"
        i=$(( i + 1 ))
    done
}

# Open the next part file. Only ever appends: an existing part is skipped,
# never truncated.
csv_open_part() {
    CSV_PATH=$(printf '%s_%03d.csv' "$CSV_BASE" "$CSV_PART")
    while [ -e "$CSV_PATH" ]; do
        CSV_PART=$(( CSV_PART + 1 ))
        CSV_PATH=$(printf '%s_%03d.csv' "$CSV_BASE" "$CSV_PART")
    done
    printf '%s\n' "$CSV_HEADER" >> "$CSV_PATH" || {
        echo "[ERROR] cannot write CSV file: ${CSV_PATH}" >&2; exit 1; }
    echo "[INFO] CSV file: ${CSV_PATH}"
}

# One collection = one row. Rolls over once the part exceeds --max-size.
csv_write_row() {
    local i row sz
    row="${TIMESTAMP},${TS_EPOCH}"
    i=0
    while [ "$i" -lt "$METRIC_N" ]; do
        row="${row},${CSV_ROW[$i]-}"
        i=$(( i + 1 ))
    done
    printf '%s\n' "$row" >> "$CSV_PATH" || {
        echo "[WARN] ${TIMESTAMP} CSV write failed (${CSV_PATH})" >&2; return 0; }
    CSV_ROWS=$(( CSV_ROWS + 1 ))
    sz=$(wc -c < "$CSV_PATH" 2>/dev/null | tr -d ' ')
    case "$sz" in ''|*[!0-9]*) sz=0 ;; esac
    if [ "$sz" -ge "$CSV_MAX_BYTES" ]; then
        echo "[INFO] ${TIMESTAMP} part ${CSV_PART} reached $(( sz / 1048576 ))MB -> rolling over"
        CSV_PART=$(( CSV_PART + 1 ))
        csv_open_part
    fi
}


# ----------------------------------------------------------
# 4. perf base availability
# ----------------------------------------------------------
PERF_BASE_OK=0
PERF_REASON=""
if [ "$EV_N" -eq 0 ]; then
    if [ "$COLLECT_MODE" = "group" ] && [ "$COLLECT_SCOPE" = "thp" ]; then
        PERF_REASON="not requested [--collect thp]"
    elif [ "$COLLECT_MODE" = "names" ]; then
        PERF_REASON="not requested [--collect ${COLLECT_NAMES} needs no perf event]"
    else
        PERF_REASON="no perf events in table"
    fi
elif ! command -v perf >/dev/null 2>&1; then
    PERF_REASON="perf command not found [yum install perf]"
else
    PN=$(cat "${PROC_ROOT}/sys/kernel/perf_event_paranoid" 2>/dev/null || echo "?")
    if perf stat -e cycles -a sleep 0 >/dev/null 2>&1; then
        PERF_BASE_OK=1
    else
        PERF_REASON="permission/vPMU issue [perf_event_paranoid=${PN}]. sudo sysctl -w kernel.perf_event_paranoid=-1"
        # already -1 and still failing: the VM has no virtual PMU, or this kernel has no PMU driver for the CPU
        [ "$PN" = "-1" ] && PERF_REASON="no usable PMU [perf_event_paranoid=-1 already]. Check that the VM has virtual CPU performance counters enabled and that the kernel supports this CPU: dmesg | grep -i 'performance events'"
    fi
fi
NMI_WD=$(cat "${PROC_ROOT}/sys/kernel/nmi_watchdog" 2>/dev/null || echo "?")
CPU_MODEL=$(awk -F: '/model name/{print $2; exit}' "${PROC_ROOT}/cpuinfo" 2>/dev/null | sed 's/^ *//')
KREL=$(uname -r 2>/dev/null || echo "?")


# ----------------------------------------------------------
# 5. perf helpers: read a result, multiplexing share, start/stop
# ----------------------------------------------------------
# Field order of perf stat -x (perf-stat manual, "CSV FORMAT"):
#   [time stamp, only with -I] ; count ; unit ; event name ; run time ; share of time counted (%) ; ...
# Older perf prints only  [time stamp] ; count ; event name.  The event name is found by value,
# so both layouts are read.
#
# perf_parse reads one perf result into EV_VAL / EV_PCT.
#   $1 = file with the perf stat -x output
#   $2 = 1 when the file holds interval blocks (perf stat -I), 0 for a single run
#   $3 = number of event lines a complete result has
# With interval blocks it takes the newest complete block that is newer than PERF_LAST_TS.
# Returns 0 and sets PARSE_TS when a result was found.
perf_parse() {
    local f="$1" iv="$2" need="$3" out tag a b c i
    PARSE_TS=""
    [ -s "$f" ] || return 1
    out=$(awk -F"$PERF_SEP" -v want="$PERF_LABELS" -v iv="$iv" -v last="$PERF_LAST_TS" -v need="$need" '
        function trim(x) { gsub(/^[ \t]+|[ \t]+$/, "", x); return x }
        BEGIN { n = split(want, W, " "); for (i = 1; i <= n; i++) isev[W[i]] = 1; nb = 0 }
        {
            sub(/\r$/, "")
            off = 0; ts = "-"
            if (iv == 1) {
                ts = trim($1)
                if (ts !~ /^[0-9]+(\.[0-9]+)?$/) next
                off = 1
            }
            ev = ""; j = 0
            for (i = 2 + off; i <= NF; i++) { t = trim($i); if (t in isev) { ev = t; j = i; break } }
            if (ev == "") next
            v = trim($(1 + off)); if (v !~ /^[0-9]+$/) v = "-1"
            p = "-"
            if (j + 2 <= NF) { q = trim($(j + 2)); if (q ~ /^[0-9]+(\.[0-9]+)?$/) p = q }
            if (!(ts in cnt)) { order[++nb] = ts; cnt[ts] = 0 }
            if (!((ts SUBSEP ev) in val)) cnt[ts]++
            val[ts SUBSEP ev] = v; pc[ts SUBSEP ev] = p
        }
        END {
            pick = ""
            for (b = nb; b >= 1; b--) {                     # newest block first
                ts = order[b]
                if (cnt[ts] < need) continue                # still being written
                if (iv == 1 && last != "" && (ts + 0) <= (last + 0)) break   # nothing newer than the block already used
                pick = ts; break
            }
            if (pick == "") exit 1
            print "T " pick
            for (i = 1; i <= n; i++)
                if ((pick SUBSEP W[i]) in val) print "E " W[i] " " val[pick SUBSEP W[i]] " " pc[pick SUBSEP W[i]]
        }' "$f" 2>/dev/null) || return 1
    [ -z "$out" ] && return 1
    while IFS=' ' read -r tag a b c; do
        case "$tag" in
            T) PARSE_TS="$a" ;;
            E) i=0
               while [ "$i" -lt "$EV_N" ]; do
                   if [ "${EV_KEY[$i]}" = "$a" ]; then EV_VAL[$i]="$b"; EV_PCT[$i]="$c"; break; fi
                   i=$((i+1))
               done ;;
        esac
    done <<EOF
$out
EOF
    [ -n "$PARSE_TS" ]
}

perf_reset_values() {
    local i=0
    while [ "$i" -lt "$EV_N" ]; do EV_VAL[$i]="-1"; EV_PCT[$i]="-"; i=$((i+1)); done
}

perf_lists() {   # rebuilds PERF_EVENTS / PERF_LABELS / EV_OK_N from the events whose state is ok
    local i=0
    PERF_EVENTS=""; PERF_LABELS=""; EV_OK_N=0
    while [ "$i" -lt "$EV_N" ]; do
        if [ "${EV_STATE[$i]}" = "ok" ]; then
            PERF_EVENTS="${PERF_EVENTS:+$PERF_EVENTS,}${EV_SPEC[$i]}"
            PERF_LABELS="${PERF_LABELS:+$PERF_LABELS }${EV_KEY[$i]}"
            EV_OK_N=$((EV_OK_N+1))
        fi
        i=$((i+1))
    done
}

pct_x100() {   # $1 = percentage text such as 41.67 -> PX in 1/100 percent; -1 when it is not a number
    local t="$1" ip fp
    PX=-1
    case "$t" in ''|-|*[!0-9.]*|*.*.*) return 0 ;; esac
    ip="${t%%.*}"; fp=""
    case "$t" in *.*) fp="${t#*.}" ;; esac
    fp="${fp}00"; fp="${fp:0:2}"
    [ -z "$ip" ] && ip=0
    PX=$(( 10#$ip * 100 + 10#$fp ))
    return 0
}

x100_txt() {   # $1 = value in 1/100 percent -> RV like 41.67
    local frac
    printf -v frac '%02d' $(( $1 % 100 ))
    RV="$(( $1 / 100 )).${frac}"
}

# Share of the interval in which the least-counted event was really counting.
# 100% = no event had to share a hardware counter (no multiplexing).
mux_summary() {
    local i=0 min=-1
    MUX_KNOWN=0
    while [ "$i" -lt "$EV_N" ]; do
        if [ "${EV_STATE[$i]}" = "ok" ]; then
            pct_x100 "${EV_PCT[$i]}"
            if [ "$PX" -ge 0 ]; then
                MUX_KNOWN=1
                { [ "$min" -lt 0 ] || [ "$PX" -lt "$min" ]; } && min="$PX"
            fi
        fi
        i=$((i+1))
    done
    MUX_MIN_X100="$min"
    if [ "$MUX_KNOWN" -eq 1 ]; then
        x100_txt "$min"
        MUX_TXT="run ${RV}%"
        [ "$min" -lt 10000 ] && MUX_TXT="${MUX_TXT} (multiplexed)"
    else
        MUX_TXT="run n/a"
    fi
    return 0
}

# Supported = perf prints a data line for the event with a number in the count field.
# "<not supported>", "<not counted>" and event parser errors have no such line.
probe_event() {   # $1 = perf event string  $2 = name perf prints. supported 0 / unsupported 1; prints the count
    perf stat -a -x "$PERF_SEP" -e "$1" sleep 0.2 2>&1 | awk -F"$PERF_SEP" -v e="$2" '
        { for (i = 2; i <= NF; i++) { t = $i; gsub(/^[ \t]+|[ \t]+$/, "", t)
              if (t == e) { v = $1; gsub(/[ \t]/, "", v); if (v ~ /^[0-9]+$/) { ok = 1; cnt = v } } } }
        END { if (ok) print cnt; exit ok ? 0 : 1 }'
}

perf_calibrate() {   # one 1 s run with all events in use together -> MUX_KNOWN, MUX_MIN_X100
    local f="${PERF_TMPFILE}.cal"
    perf_reset_values
    MUX_KNOWN=0; MUX_MIN_X100=-1
    [ "$EV_OK_N" -gt 0 ] || return 0
    perf stat -a -x "$PERF_SEP" -e "$PERF_EVENTS" sleep 1 >/dev/null 2>"$f"
    PERF_LAST_TS=""
    perf_parse "$f" 0 "$EV_OK_N" && mux_summary
    rm -f "$f"
    return 0
}

perf_interval_check() {   # does this perf print interval blocks (perf stat -I)? -> PERF_INTERVAL_OK
    local f="${PERF_TMPFILE}.ivt" n i=0 first=""
    while [ "$i" -lt "$EV_N" ]; do
        [ "${EV_STATE[$i]}" = "ok" ] && { first="${EV_SPEC[$i]}"; break; }
        i=$((i+1))
    done
    PERF_INTERVAL_OK=0
    [ -n "$first" ] || return 0
    perf stat -a -x "$PERF_SEP" -I 300 -e "$first" sleep 1 >/dev/null 2>"$f"
    n=$(awk -F"$PERF_SEP" '{ t = $1; gsub(/[ \t]/, "", t); if (t ~ /^[0-9]+\.[0-9]+$/ && NF >= 3) c++ } END { print c + 0 }' "$f" 2>/dev/null)
    rm -f "$f"
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    [ "$n" -ge 2 ] && PERF_INTERVAL_OK=1
    return 0
}

perf_stop() {
    [ -z "$PERF_PID" ] && return 0
    pkill -TERM -P "$PERF_PID" 2>/dev/null      # what perf waits for: the keeper shell, or sleep
    kill -TERM "$PERF_PID" 2>/dev/null
    PERF_PID=""
    return 0
}

perf_start() {   # starts perf for the interval that begins now
    local keeper
    if [ "$PERF_MODE" = "resident" ]; then
        # perf counts until the command it was given ends. That command is a small shell that ends
        # when this collector is gone, so perf cannot be left running behind, not even after kill -9.
        keeper='while kill -0 "$1" 2>/dev/null; do sleep 10; done'
        : > "$PERF_TMPFILE"
        PERF_LAST_TS=""
        perf stat -a -x "$PERF_SEP" -I $(( INTERVAL_SEC * 1000 )) -e "$PERF_EVENTS" \
            sh -c "$keeper" keeper "$$" >/dev/null 2>>"$PERF_TMPFILE" &
    else
        : > "${PERF_TMPFILE}.win"
        perf stat -a -x "$PERF_SEP" -e "$PERF_EVENTS" sleep "$PERF_WIN_SEC" >/dev/null 2>"${PERF_TMPFILE}.win" &
    fi
    PERF_PID=$!
    disown 2>/dev/null          # no "Terminated" job notice in the log when perf is stopped
    PERF_STARTS=$((PERF_STARTS+1))
    return 0
}

# Takes the perf result of the interval that just ended -> PERF_HAVE, EV_VAL, EV_PCT, MUX_TXT
perf_collect() {
    local waited lag sz
    PERF_HAVE=0
    perf_reset_values
    [ "$PERF_RUN" -eq 1 ] || { MUX_TXT="-"; return 0; }
    MUX_TXT="no data"
    [ -z "$PERF_PID" ] && return 0              # nothing was counting in the interval that just ended
    if [ "$PERF_MODE" = "resident" ]; then
        waited=0
        while :; do
            if perf_parse "$PERF_TMPFILE" 1 "$EV_OK_N"; then PERF_HAVE=1; break; fi
            kill -0 "$PERF_PID" 2>/dev/null || break
            [ "$waited" -ge $(( PERF_WAIT_MAX * 5 )) ] && break
            sleep 0.2; waited=$((waited+1))
        done
        if [ "$PERF_HAVE" -eq 1 ]; then
            PERF_LAST_TS="$PARSE_TS"
            mux_summary
            lag=$(( $(date '+%s') - BOUNDARY ))
            if [ "$lag" -gt "$PERF_LAG_MAX" ]; then
                echo "[INFO] ${WAKE_TXT} perf interval output came ${lag}s after the boundary -> perf restarts on the next boundary (that one interval has no perf values)"
                perf_stop; PERF_HOLD=1
            else
                sz=$(wc -c < "$PERF_TMPFILE" 2>/dev/null | tr -d ' ')
                case "$sz" in ''|*[!0-9]*) sz=0 ;; esac
                [ "$sz" -gt 262144 ] && : > "$PERF_TMPFILE"     # perf appends to the file, so emptying it is safe
            fi
        elif ! kill -0 "$PERF_PID" 2>/dev/null; then
            echo "[WARN] ${WAKE_TXT} perf is not running any more -> starting it again now" >&2
            PERF_PID=""
        else
            echo "[WARN] ${WAKE_TXT} no perf interval output within ${PERF_WAIT_MAX}s -> perf restarts on the next boundary" >&2
            perf_stop; PERF_HOLD=1
        fi
    else
        waited=0
        while kill -0 "$PERF_PID" 2>/dev/null && [ "$waited" -lt 15 ]; do sleep 0.2; waited=$((waited+1)); done
        if kill -0 "$PERF_PID" 2>/dev/null; then
            echo "[WARN] ${WAKE_TXT} the perf run did not end in time -> stopped" >&2
            perf_stop
        fi
        PERF_PID=""
        PERF_LAST_TS=""
        if perf_parse "${PERF_TMPFILE}.win" 0 "$EV_OK_N"; then
            PERF_HAVE=1; mux_summary
        else
            echo "[WARN] ${WAKE_TXT} perf failed" >&2
        fi
    fi
    return 0
}

# Starts perf for the next interval when none is counting (first boundary, every boundary in
# window mode, or after perf was stopped).
perf_begin() {
    [ "$PERF_RUN" -eq 1 ] || return 0
    if [ "$PERF_HOLD" -eq 1 ]; then PERF_HOLD=0; return 0; fi
    [ -n "$PERF_PID" ] && return 0
    perf_start
}


# ----------------------------------------------------------
# 5-1. * Event support probe (A: measured) + multiplexing check + cascade exclusion + log
# ----------------------------------------------------------
PROBE_NA=0
PROBE_FIT=0
UNUSED_EVENTS=""

# A selected metric of this CPU class stays active only while none of its perf events is
# unsupported (bad) or removed by --perf-fit (fit).
resolve_metrics() {
    local i=0 f act
    while [ "$i" -lt "$METRIC_N" ]; do
        if [ "${M_INSCOPE[$i]}" = "1" ] && [ "${M_NA[$i]}" != "1" ]; then
            act=1
            for f in "${M_SRC1[$i]}" "${M_SRC2[$i]}"; do
                case "$f" in
                    perf:*) ev_state "${f#perf:}"
                            case "$RV" in bad|fit) act=0 ;; esac ;;
                esac
            done
            M_ACTIVE[$i]="$act"
        fi
        i=$((i+1))
    done
}

# A supported event that no active metric uses any more does not need a counter.
prune_events() {
    local j=0 i used
    while [ "$j" -lt "$EV_N" ]; do
        if [ "${EV_STATE[$j]}" = "ok" ]; then
            used=0; i=0
            while [ "$i" -lt "$METRIC_N" ]; do
                if [ "${M_ACTIVE[$i]}" = "1" ]; then
                    if [ "${M_SRC1[$i]}" = "perf:${EV_KEY[$j]}" ] || [ "${M_SRC2[$i]}" = "perf:${EV_KEY[$j]}" ]; then used=1; break; fi
                fi
                i=$((i+1))
            done
            if [ "$used" -eq 0 ]; then
                EV_STATE[$j]="unused"
                UNUSED_EVENTS="${UNUSED_EVENTS:+$UNUSED_EVENTS, }${EV_KEY[$j]}"
            fi
        fi
        j=$((j+1))
    done
}

run_support_probe() {
    local kept dropped skipped na fitn disabled_names fit_names i j bad_ev fit_ev f pc
    : > "$SUPPORT_LOG" 2>/dev/null || true

    {
        echo "========================================================"
        echo " ops_metric_push v${SCRIPT_VERSION}  event support probe log"
        echo " Host      : ${HOSTNAME_S}"
        echo " CPU       : ${CPU_MODEL:-unknown}"
        echo " CPU class : ${CPU_LABEL}"
        echo " Kernel    : ${KREL}"
        echo " Probed at : $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo " Collect   : ${COLLECT_LABEL}"
        echo " Method    : perf stat measurement (0.2s test per event)"
        echo "========================================================"
        echo ""
        echo "[perf event support probe]"
    } >> "$SUPPORT_LOG"

    if [ "$EV_N" -eq 0 ]; then
        {
            echo " (no perf event requested -> probe skipped, perf is never started)"
            echo " Reason: ${PERF_REASON}"
        } >> "$SUPPORT_LOG"
    elif [ "$PERF_BASE_OK" -ne 1 ]; then
        {
            echo " (perf itself disabled -> all perf events treated as unsupported)"
            echo " Reason: ${PERF_REASON}"
        } >> "$SUPPORT_LOG"
        i=0
        while [ "$i" -lt "$EV_N" ]; do EV_STATE[$i]="bad"; PERF_BAD_N=$((PERF_BAD_N+1)); i=$((i+1)); done
    else
        echo " (the number is the count of the 0.2 s test on all CPUs. 0 on a busy system = the event does not count here)" >> "$SUPPORT_LOG"
        i=0
        while [ "$i" -lt "$EV_N" ]; do
            if [ "${EV_STATE[$i]}" = "undef" ]; then
                EV_STATE[$i]="bad"; PERF_BAD_N=$((PERF_BAD_N+1))
                printf ' no code     %-14s the alias table has no line for CPU class %s\n' "${EV_KEY[$i]}" "$CPU_CLASS" >> "$SUPPORT_LOG"
            elif pc=$(probe_event "${EV_SPEC[$i]}" "${EV_KEY[$i]}"); then
                EV_STATE[$i]="ok"; PERF_OK_N=$((PERF_OK_N+1))
                if [ "${EV_SPEC[$i]}" = "${EV_KEY[$i]}" ]; then printf ' supported   %-24s count %s\n' "${EV_KEY[$i]}" "$pc" >> "$SUPPORT_LOG"
                else printf ' supported   %-14s = %-38s count %s\n' "${EV_KEY[$i]}" "${EV_SPEC[$i]}" "$pc" >> "$SUPPORT_LOG"; fi
            else
                EV_STATE[$i]="bad"; PERF_BAD_N=$((PERF_BAD_N+1))
                if [ "${EV_SPEC[$i]}" = "${EV_KEY[$i]}" ]; then printf ' unsupported %s\n' "${EV_KEY[$i]}" >> "$SUPPORT_LOG"
                else printf ' unsupported %-14s = %s\n' "${EV_KEY[$i]}" "${EV_SPEC[$i]}" >> "$SUPPORT_LOG"; fi
            fi
            i=$((i+1))
        done
    fi
    resolve_metrics
    prune_events
    perf_lists

    # --- multiplexing check, --perf-fit ---
    if [ "$EV_OK_N" -gt 0 ]; then
        perf_calibrate
        {
            echo ""
            echo "[Multiplexing check]  one 1 s run with the ${EV_OK_N} supported events together"
            echo " 100% = the event counted the whole time. Less = it shared a hardware counter with others,"
            echo " perf scaled its count up, and the kernel kept switching the counters."
        } >> "$SUPPORT_LOG"
        if [ "$MUX_KNOWN" -eq 1 ]; then
            i=0
            while [ "$i" -lt "$EV_N" ]; do
                [ "${EV_STATE[$i]}" = "ok" ] && printf ' %-24s %s%%\n' "${EV_KEY[$i]}" "${EV_PCT[$i]}" >> "$SUPPORT_LOG"
                i=$((i+1))
            done
            if [ "$MUX_MIN_X100" -ge 10000 ]; then
                CAL_NOTE="none [${EV_OK_N} events, each counted 100% of the time]"
            else
                x100_txt "$MUX_MIN_X100"
                CAL_NOTE="yes [${EV_OK_N} events, the least-counted one ran ${RV}% of the time]"
                if [ "$PERF_FIT" -eq 1 ]; then
                    while [ "$MUX_MIN_X100" -ge 0 ] && [ "$MUX_MIN_X100" -lt 10000 ] && [ "$EV_OK_N" -gt 1 ]; do
                        j=$(( EV_N - 1 ))
                        while [ "$j" -ge 0 ] && [ "${EV_STATE[$j]}" != "ok" ]; do j=$((j-1)); done
                        [ "$j" -lt 0 ] && break
                        EV_STATE[$j]="fit"
                        FIT_DROPPED="${EV_KEY[$j]}${FIT_DROPPED:+, $FIT_DROPPED}"
                        resolve_metrics
                        prune_events
                        perf_lists
                        perf_calibrate
                    done
                    if [ "$MUX_KNOWN" -eq 1 ] && [ "$MUX_MIN_X100" -ge 10000 ]; then
                        CAL_NOTE="none after --perf-fit [${EV_OK_N} events kept; removed: ${FIT_DROPPED}]"
                    else
                        CAL_NOTE="still present after --perf-fit [${EV_OK_N} events kept; removed: ${FIT_DROPPED}]"
                    fi
                    echo " --perf-fit removed (last in table order first): ${FIT_DROPPED}" >> "$SUPPORT_LOG"
                else
                    echo " To count without time-sharing, start with --perf-fit (fewer events)." >> "$SUPPORT_LOG"
                fi
            fi
        else
            CAL_NOTE="unknown [this perf prints no running-time column]"
            [ "$PERF_FIT" -eq 1 ] && echo " --perf-fit cannot check the counters with this perf: every supported event is kept." >> "$SUPPORT_LOG"
        fi
        [ -n "$UNUSED_EVENTS" ] && echo " not counted, no remaining metric needs it: ${UNUSED_EVENTS}" >> "$SUPPORT_LOG"
        echo " Result: multiplexing ${CAL_NOTE}" >> "$SUPPORT_LOG"
    fi

    # --- resident perf needs perf stat -I ---
    if [ "$EV_OK_N" -gt 0 ] && [ "$PERF_MODE" = "resident" ]; then
        perf_interval_check
        if [ "$PERF_INTERVAL_OK" -ne 1 ]; then
            PERF_MODE="window"
            PERF_MODE_WHY="this perf prints no interval output (perf stat -I)"
        fi
    fi
    if [ "$EV_OK_N" -gt 0 ]; then
        {
            echo ""
            echo "[perf mode]"
            if [ "$PERF_MODE" = "resident" ]; then
                echo " resident: one perf process for the whole run, deltas every ${INTERVAL_SEC}s (perf stat -I)"
            else
                echo " window: a new perf run of ${PERF_WIN_SEC}s in every interval${PERF_MODE_WHY:+  [${PERF_MODE_WHY}]}"
            fi
        } >> "$SUPPORT_LOG"
    fi

    { echo ""; echo "[Metric resolution result]"; } >> "$SUPPORT_LOG"
    kept=0; dropped=0; skipped=0; na=0; fitn=0; disabled_names=""; fit_names=""
    i=0
    while [ "$i" -lt "$METRIC_N" ]; do
        # not selected by --collect: neither collected nor "excluded", so it is
        # reported separately -- an operator reading this log must be able to
        # tell "you did not ask for it" apart from "this CPU cannot do it"
        if [ "${M_INSCOPE[$i]}" != "1" ]; then
            skipped=$((skipped+1))
            printf ' skipped   %-24s not selected by --collect\n' "${M_NAME[$i]}" >> "$SUPPORT_LOG"
            i=$((i+1)); continue
        fi
        if [ "${M_NA[$i]}" = "1" ]; then
            na=$((na+1))
            printf ' n/a       %-24s line is for another CPU class (%s), this CPU is %s\n' \
                "${M_NAME[$i]}" "${M_CPU[$i]}" "$CPU_CLASS" >> "$SUPPORT_LOG"
            i=$((i+1)); continue
        fi
        bad_ev=""; fit_ev=""
        for f in "${M_SRC1[$i]}" "${M_SRC2[$i]}"; do
            case "$f" in
                perf:*) ev_state "${f#perf:}"
                        case "$RV" in
                            bad) bad_ev="${bad_ev:+$bad_ev, }${f#perf:}" ;;
                            fit) fit_ev="${fit_ev:+$fit_ev, }${f#perf:}" ;;
                        esac ;;
            esac
        done
        if [ -n "$bad_ev" ]; then
            M_ACTIVE[$i]="0"; dropped=$((dropped+1))
            disabled_names="${disabled_names:+$disabled_names, }${M_NAME[$i]}"
            printf ' excluded  %-24s cause: %s unsupported\n' "${M_NAME[$i]}" "$bad_ev" >> "$SUPPORT_LOG"
        elif [ -n "$fit_ev" ]; then
            M_ACTIVE[$i]="0"; fitn=$((fitn+1))
            fit_names="${fit_names:+$fit_names, }${M_NAME[$i]}"
            printf ' excluded  %-24s cause: --perf-fit removed %s (no free hardware counter)\n' "${M_NAME[$i]}" "$fit_ev" >> "$SUPPORT_LOG"
        else
            kept=$((kept+1))
            printf ' collected %s\n' "${M_NAME[$i]}" >> "$SUPPORT_LOG"
        fi
        i=$((i+1))
    done

    {
        echo ""
        echo "[Summary]"
        echo " perf events : supported ${PERF_OK_N} / unsupported ${PERF_BAD_N} / in use ${EV_OK_N}"
        echo " metrics     : collected ${kept} / excluded ${dropped} unsupported + ${fitn} by --perf-fit / not selected ${skipped} / other CPU class ${na}"
        [ -n "$disabled_names" ] && echo " excluded, unsupported event : ${disabled_names}"
        [ -n "$fit_names" ] && echo " excluded by --perf-fit       : ${fit_names}"
        echo "========================================================"
    } >> "$SUPPORT_LOG"

    PROBE_KEPT="$kept"; PROBE_DROPPED=$(( dropped + fitn )); PROBE_SKIPPED="$skipped"; PROBE_NA="$na"; PROBE_FIT="$fitn"
    PROBE_DISABLED="$disabled_names"
    [ -n "$fit_names" ] && PROBE_DISABLED="${PROBE_DISABLED:+$PROBE_DISABLED, }${fit_names}"
    return 0
}
run_support_probe


# ----------------------------------------------------------
# 6. Termination handling
# ----------------------------------------------------------
cleanup() {
    # stop perf and what it waits for, then every other child (sleep, background curl)
    perf_stop
    pkill -TERM -P $$ 2>/dev/null
    rm -f "${PERF_TMPFILE}" "${PERF_TMPFILE}.win" "${PERF_TMPFILE}.cal" "${PERF_TMPFILE}.ivt" "${REAUTH_FLAG}"
    # Only remove the PID file if this process created it. A --dry-run instance
    # used to delete a live collector's PID file here, which broke --stop.
    [ "$PID_OWNED" -eq 1 ] && rm -f "${PID_FILE}"
    echo ""
    if [ "$CSV_MODE" -eq 1 ]; then
        echo "Stopped: $(date '+%Y-%m-%d %H:%M:%S')  [${LOOP} collections / ${PUSH_TRY} pushes / ${CSV_ROWS} CSV rows]"
        echo "Last CSV: ${CSV_PATH}"
    else
        echo "Stopped: $(date '+%Y-%m-%d %H:%M:%S')  [${LOOP} collections / ${PUSH_TRY} pushes]"
    fi
    exit 0
}
trap cleanup SIGTERM SIGINT

# Prevent duplicate runs + record PID. Every collecting mode (ops/file/both)
# takes the PID file, so --stop works and PMU contention between two
# collectors is blocked. --list exits earlier; --dry-run only warns, to keep
# its established behaviour.
if [ "$DRY_RUN" -eq 0 ] || [ "$CSV_MODE" -eq 1 ]; then
    if [ -f "$PID_FILE" ]; then
        OLD_PID=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
            echo "[ERROR] Already running [PID ${OLD_PID}]." >&2
            echo "        Stop with: bash $0 --stop" >&2
            exit 1
        fi
    fi
    if echo "$$" > "$PID_FILE" 2>/dev/null; then
        PID_OWNED=1
    else
        echo "[WARN] failed to write PID file (${PID_FILE})" >&2
    fi
elif [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        echo "[WARN] A collector is already running [PID ${OLD_PID}]." >&2
        echo "       Two perf collectors at once cause PMU contention and skew both sides." >&2
    fi
fi


# ----------------------------------------------------------
# 7. Ops utilities
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
    local s code
    for s in OpsToken vRealizeOpsToken; do
        code=$(curl -s $CURL_TLS -o /dev/null -w '%{http_code}' --max-time 15 -G \
            "${OPS_BASE}/suite-api/api/resources" \
            --data-urlencode "pageSize=1" --data-urlencode "_no_links=true" \
            -H "Authorization: ${s} ${OPS_TOKEN}" -H 'Accept: application/json' 2>/dev/null)
        [ "$code" = "200" ] && { AUTH_SCHEME="$s"; return 0; }
    done
    echo "[ERROR] auth header rejected [OpsToken/vRealizeOpsToken, HTTP ${code}]" >&2; return 1
}

# Look the push target up by name.
#   scope=vm  : VMWARE VirtualMachine only            [v3 behaviour]
#   scope=any : every adapter kind, so an object this script created earlier --
#               or a real host object carrying that name -- is found
# Sets OPS_RESOURCE_ID / OPS_FOUND_KIND and stays silent when nothing matches:
# the caller decides whether a miss is an error or the cue to create the object.
lookup_resource() {
    local scope="$1" resp out cnt rest
    if [ "$scope" = "vm" ]; then
        resp=$(curl -s $CURL_TLS --max-time 20 -G "${OPS_BASE}/suite-api/api/resources" \
            --data-urlencode "adapterKindKey=VMWARE" --data-urlencode "resourceKind=VirtualMachine" \
            --data-urlencode "name=${OPS_VM_NAME}" --data-urlencode "_no_links=true" \
            -H "Authorization: ${AUTH_SCHEME} ${OPS_TOKEN}" -H 'Accept: application/json' 2>&1)
    else
        resp=$(curl -s $CURL_TLS --max-time 20 -G "${OPS_BASE}/suite-api/api/resources" \
            --data-urlencode "name=${OPS_VM_NAME}" --data-urlencode "_no_links=true" \
            -H "Authorization: ${AUTH_SCHEME} ${OPS_TOKEN}" -H 'Accept: application/json' 2>&1)
    fi
    if [ "$JSON_TOOL" = "python3" ]; then
        out=$(printf '%s' "$resp" | python3 -c '
import sys,json
name=sys.argv[1]
try: d=json.load(sys.stdin)
except Exception: print("||0"); sys.exit(0)
rl=d.get("resourceList") or []
def rk(r): return r.get("resourceKey") or {}
def nm(r): return rk(r).get("name") or ""
ex=[r for r in rl if nm(r)==name]
if not ex:  # case-insensitive match (corrects user typos)
    ex=[r for r in rl if nm(r).lower()==name.lower()]
print("%s|%s|%d"%(ex[0].get("identifier","") if ex else "",
                  (rk(ex[0]).get("resourceKindKey") or "") if ex else "", len(ex)))
' "$OPS_VM_NAME" 2>/dev/null)
    else
        out=$(printf '%s' "$resp" | jq -r --arg n "$OPS_VM_NAME" '
            (.resourceList//[]) as $rl
            |([$rl[]|select(.resourceKey.name==$n)]) as $e
            |(if ($e|length)>0 then $e
              else [$rl[]|select((.resourceKey.name|ascii_downcase)==($n|ascii_downcase))] end) as $ex
            |"\(($ex[0].identifier)//"")|\(($ex[0].resourceKey.resourceKindKey)//"")|\($ex|length)"' 2>/dev/null)
    fi
    OPS_RESOURCE_ID="${out%%|*}"
    rest="${out#*|}"
    OPS_FOUND_KIND="${rest%%|*}"
    cnt="${rest##*|}"
    [ -z "$OPS_RESOURCE_ID" ] && return 1
    [ -n "$cnt" ] && [ "$cnt" -gt 1 ] 2>/dev/null && \
        echo "[WARN] ${cnt} objects share the name '${OPS_VM_NAME}' -> using the first. Otherwise use --resource-id." >&2
    return 0
}

suggest_vm_names() {
    local resp key; key=$(printf '%s' "$HOSTNAME_S" | cut -c1-6)
    resp=$(curl -s $CURL_TLS --max-time 30 -G "${OPS_BASE}/suite-api/api/resources" \
        --data-urlencode "adapterKindKey=VMWARE" --data-urlencode "resourceKind=VirtualMachine" \
        --data-urlencode "pageSize=2000" --data-urlencode "_no_links=true" \
        -H "Authorization: ${AUTH_SCHEME} ${OPS_TOKEN}" -H 'Accept: application/json' 2>/dev/null)
    echo "        Candidates containing '${key}' [max 20]:" >&2
    if [ "$JSON_TOOL" = "python3" ]; then
        printf '%s' "$resp" | python3 -c '
import sys,json
key=sys.argv[1].lower()
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
ns=[(r.get("resourceKey") or {}).get("name","") for r in (d.get("resourceList") or [])]
h=[n for n in ns if key in n.lower()][:20]
[print("          - %s"%n) for n in h]
if not h: print("          (no candidates / %d VMs total)"%len(ns))
' "$key" >&2 2>/dev/null
    else
        printf '%s' "$resp" | jq -r --arg k "$key" '
            [.resourceList[]?.resourceKey.name|select(ascii_downcase|contains($k|ascii_downcase))]
            |.[0:20][]|"          - \(.)"' >&2 2>/dev/null
    fi
    echo "        Specify exactly with --vm." >&2
}

# Decide which Ops object this run pushes to.
# No object is ever created: in Ops an object exists behind a real adapter, so
# an object pushed in from here would have nothing collecting it. When the
# target has no object at all, --mode file is the collection path.
resolve_target() {
    if lookup_resource vm; then
        OPS_TARGET_DESC="VirtualMachine"
        return 0
    fi
    if [ "$TARGET_KIND" = "vm" ]; then
        echo "[ERROR] VM not found: '${OPS_VM_NAME}'" >&2
        suggest_vm_names
        echo "        Not a VM? --target any matches objects of every adapter kind." >&2
        return 1
    fi
    if lookup_resource any; then
        OPS_TARGET_DESC="${OPS_FOUND_KIND:-kind unknown}"
        return 0
    fi
    echo "[ERROR] No Ops object named '${OPS_VM_NAME}' under any adapter kind." >&2
    echo "        The object has to exist in Ops first -- this script does not create one." >&2
    echo "        Pass the id directly with --resource-id <id>, or collect locally" >&2
    echo "        with --mode file --out <dir>." >&2
    return 1
}

push_stats() {
    local json="$1" ts="$2" attempt=1 out code
    while [ "$attempt" -le 2 ]; do
        out=$(mktemp 2>/dev/null || echo "/tmp/ops_push_resp_$$")
        code=$(curl -s $CURL_TLS -o "$out" -w '%{http_code}' --max-time "$OPS_TIMEOUT" \
            -X POST "${OPS_BASE}/suite-api/api/resources/${OPS_RESOURCE_ID}/stats" \
            -H "Authorization: ${AUTH_SCHEME} ${OPS_TOKEN}" \
            -H 'Content-Type: application/json' -H 'Accept: application/json' -d "$json" 2>/dev/null)
        case "$code" in
            200|201|204) rm -f "$out"; return 0 ;;
            401|403) : > "$REAUTH_FLAG"; echo "[WARN] ${ts} auth rejected [HTTP ${code}] -> re-auth scheduled" >&2; rm -f "$out"; return 1 ;;
        esac
        rm -f "$out"; attempt=$((attempt+1)); [ "$attempt" -le 2 ] && sleep 1
    done
    echo "[WARN] ${ts} push failed [HTTP ${code}] (2 attempts)" >&2; return 1
}


# ----------------------------------------------------------
# 8. Collection utilities
# ----------------------------------------------------------
# /proc values are read once per interval, for every meminfo:/vmstat: source in use.
read_proc() {
    local out src v i
    i=0
    while [ "$i" -lt "$PROC_N" ]; do PROC_VAL[$i]="-1"; i=$((i+1)); done
    [ "$PROC_N" -eq 0 ] && return 0
    out=$(awk -v want="$PROC_WANT" '
        BEGIN { n = split(want, W, " "); for (i = 1; i <= n; i++) need[W[i]] = 1 }
        FNR == 1 { src = (FILENAME ~ /meminfo$/) ? "meminfo" : "vmstat" }
        { k = $1; sub(/:$/, "", k); key = src ":" k
          if ((key in need) && !(key in seen)) { seen[key] = 1; if ($2 ~ /^[0-9]+$/) print key, $2 } }
    ' "${PROC_ROOT}/meminfo" "${PROC_ROOT}/vmstat" 2>/dev/null)
    [ -z "$out" ] && return 0
    while IFS=' ' read -r src v; do
        i=0
        while [ "$i" -lt "$PROC_N" ]; do
            if [ "${PROC_SRC[$i]}" = "$src" ]; then PROC_VAL[$i]="$v"; break; fi
            i=$((i+1))
        done
    done <<EOF
$out
EOF
    return 0
}

resolve_src() {   # $1 = source token -> RV (value, or -1 when there is none)
    local tok="$1" k i
    RV="-1"
    case "$tok" in
        perf:*)
            k="${tok#perf:}"; i=0
            while [ "$i" -lt "$EV_N" ]; do
                if [ "${EV_KEY[$i]}" = "$k" ]; then RV="${EV_VAL[$i]:--1}"; break; fi
                i=$((i+1))
            done ;;
        meminfo:*|vmstat:*)
            i=0
            while [ "$i" -lt "$PROC_N" ]; do
                if [ "${PROC_SRC[$i]}" = "$tok" ]; then RV="${PROC_VAL[$i]:--1}"; break; fi
                i=$((i+1))
            done ;;
    esac
    return 0
}
# Compute. Zero denominator or missing input -> -1
# delta/dspct: compared to the previous cumulative values ($4, $5).
# If no previous value (first collection), returns "SKIP"
compute() {
    local calc="$1" v1="$2" v2="$3" p1="$4" p2="$5" d1 d2
    case "$calc" in
        raw)   echo "$v1" ;;
        ratio) { [ "$v1" = "-1" ] || [ "$v2" = "-1" ]; } && { echo "-1"; return; }
               awk -v n="$v1" -v d="$v2" 'BEGIN{print (d+0>0)?sprintf("%.2f",n/d):"-1"}' ;;
        pct)   { [ "$v1" = "-1" ] || [ "$v2" = "-1" ]; } && { echo "-1"; return; }
               awk -v n="$v1" -v d="$v2" 'BEGIN{print (d+0>0)?sprintf("%.2f",100*n/d):"-1"}' ;;
        spct)  { [ "$v1" = "-1" ] || [ "$v2" = "-1" ]; } && { echo "-1"; return; }
               awk -v a="$v1" -v b="$v2" 'BEGIN{s=a+b;print (s>0)?sprintf("%.2f",100*a/s):"-1"}' ;;
        pti)   { [ "$v1" = "-1" ] || [ "$v2" = "-1" ]; } && { echo "-1"; return; }
               awk -v n="$v1" -v d="$v2" 'BEGIN{print (d+0>0)?sprintf("%.3f",1000*n/d):"-1"}' ;;
        delta)
            [ "$v1" = "-1" ] && { echo "-1"; return; }
            [ -z "$p1" ] && { echo "SKIP"; return; }        # first collection: no previous value
            d1=$(( v1 - p1 ))
            [ "$d1" -lt 0 ] && { echo "SKIP"; return; }      # counter reset detected (reboot etc.)
            echo "$d1"
            ;;
        dspct)
            { [ "$v1" = "-1" ] || [ "$v2" = "-1" ]; } && { echo "-1"; return; }
            { [ -z "$p1" ] || [ -z "$p2" ]; } && { echo "SKIP"; return; }
            d1=$(( v1 - p1 )); d2=$(( v2 - p2 ))
            { [ "$d1" -lt 0 ] || [ "$d2" -lt 0 ]; } && { echo "SKIP"; return; }
            awk -v a="$d1" -v b="$d2" 'BEGIN{s=a+b;print (s>0)?sprintf("%.2f",100*a/s):"-1"}'
            ;;
        *) echo "-1" ;;
    esac
}


# ----------------------------------------------------------
# 9. Pre-start checks
# ----------------------------------------------------------
if [ "$DRY_RUN" -eq 0 ]; then
    echo "[CHECK] ${OPS_BASE}  TLS=${TLS_LABEL}"
    acquire_token || { echo "[ERROR] token acquisition failed -> abort [check LOCAL account/password/address/443]" >&2; exit 1; }
    echo "[CHECK]  1/4 token OK   [expires $(date -d "@${TOKEN_EXP}" '+%m-%d %H:%M' 2>/dev/null || echo '?')]"
    detect_auth_scheme || exit 1
    echo "[CHECK]  2/4 auth header OK [${AUTH_SCHEME}]"
    if [ -n "$OPS_RESOURCE_ID" ]; then
        OPS_TARGET_DESC="given by --resource-id"
    else
        resolve_target || exit 1
    fi
    echo "[CHECK]  3/4 object OK  [${OPS_VM_NAME} -> ${OPS_RESOURCE_ID}]  ${OPS_TARGET_DESC}"
    SMOKE_TS=$(( $(date '+%s') * 1000 ))
    SMOKE_JSON="{\"stat-content\":[{\"statKey\":\"${OPS_STAT_ROOT}|_smoke\",\"timestamps\":[${SMOKE_TS}],\"data\":[1]}]}"
    if push_stats "$SMOKE_JSON" "smoke"; then
        echo "[CHECK]  4/4 push OK    [${OPS_STAT_ROOT}|_smoke sent]"
    else
        echo "[ERROR] dummy push failed -> abort" >&2
        exit 1
    fi
fi


# ----------------------------------------------------------
# 9-1. Open the CSV  [--mode file|both]
#      After the probe, so METRIC_N is final; before the banner, so the
#      path can be shown. The header lists every metric regardless of
#      what the probe excluded.
# ----------------------------------------------------------
if [ "$CSV_MODE" -eq 1 ]; then
    build_csv_header
    csv_open_part
fi


# ----------------------------------------------------------
# 10. Banner
# ----------------------------------------------------------
echo "============================================================"
echo " Ops metric push  v${SCRIPT_VERSION}   [stop: Ctrl+C or kill $$]"
echo " - interval       : ${INTERVAL_SEC}s [aligned to second 00]. A row is stamped with the start of its interval."
echo " - host           : ${HOSTNAME_S}"
echo " - CPU            : ${CPU_MODEL:-unknown}"
echo " - CPU class      : ${CPU_LABEL}"
echo " - collect        : ${COLLECT_LABEL}"
echo " - metrics        : defined ${METRIC_N} / collected ${PROBE_KEPT} / excluded ${PROBE_DROPPED} / not selected ${PROBE_SKIPPED} / other CPU class ${PROBE_NA}"
if [ "$PERF_BASE_OK" -eq 1 ]; then
    echo " - perf           : enabled [supported ${PERF_OK_N} / unsupported ${PERF_BAD_N} / in use ${EV_OK_N} events]"
    if [ "$EV_OK_N" -gt 0 ]; then
        if [ "$PERF_MODE" = "resident" ]; then
            echo " - perf mode      : resident [one perf process, deltas every ${INTERVAL_SEC}s]"
        else
            echo " - perf mode      : window [a new perf run of ${PERF_WIN_SEC}s per interval]${PERF_MODE_WHY:+  <- ${PERF_MODE_WHY}}"
        fi
        echo " - multiplexing   : ${CAL_NOTE}"
        case "$CAL_NOTE" in
            yes*) echo "                    counters are time-shared: the kernel keeps switching them and the counts are estimates."
                  echo "                    --perf-fit counts fewer events without time-sharing." ;;
        esac
    fi
elif [ "$EV_N" -eq 0 ]; then
    echo " - perf           : not used -> ${PERF_REASON}"
    echo "                    no PMU load from this run."
else
    echo " - perf           : disabled -> ${PERF_REASON}"
    echo "                    all perf metrics excluded. THP metrics only."
fi
[ -n "$PROBE_DISABLED" ] && echo " - excluded metrics : ${PROBE_DISABLED}"
echo " - support probe log: ${SUPPORT_LOG}"
echo " - NMI watchdog   : ${NMI_WD}"
case "$OUT_MODE" in
    ops)  [ "$DRY_RUN" -eq 1 ] && echo " - mode           : DRY-RUN [no push]" \
                               || echo " - mode           : ops [push only]" ;;
    file) echo " - mode           : file [CSV only, no Ops connection]" ;;
    both) echo " - mode           : both [push + CSV]" ;;
esac
if [ "$DRY_RUN" -eq 0 ]; then
    echo " - target         : ${TARGET_KIND}"
    echo " - Ops object     : ${OPS_VM_NAME} -> ${OPS_RESOURCE_ID}  [${OPS_TARGET_DESC}]"
    echo " - account        : ${OPS_USER}  [password: ${PASS_SRC}]"
    echo " - config file    : ${OPS_CONFIG} [${CONFIG_STATE}]"
fi
if [ "$CSV_MODE" -eq 1 ]; then
    echo " - CSV file       : ${CSV_PATH}"
    echo " - CSV rollover   : $(( CSV_MAX_BYTES / 1048576 ))MB per part [never overwrites]"
    echo " - CSV columns    : ${METRIC_N} metrics fixed + Timestamp,EpochSec [empty = not collected]"
fi
echo " - Ops tree       : <object> > ${OPS_STAT_ROOT} > <group> > <metric>"
echo " - started        : $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "============================================================"


# ----------------------------------------------------------
# 11. Main loop
# ----------------------------------------------------------
# On every boundary: take the perf result of the interval that just ended, start perf for the
# next one if none is counting, read /proc, and write one row stamped with the START of the ended
# interval. The first boundary only starts perf and takes the /proc baseline of the delta metrics.
PERF_RUN=0
{ [ "$PERF_BASE_OK" -eq 1 ] && [ "$EV_OK_N" -gt 0 ]; } && PERF_RUN=1
echo "[INFO] Waiting for the next ${INTERVAL_SEC}s boundary. The first row is written one interval after it."

# Text form of an epoch second. GNU date takes -d @N, BSD date -r N; without either the
# current time is used (the boundary was at most a second ago).
if date -d "@0" '+%s' >/dev/null 2>&1; then DATE_EPOCH="gnu"
elif date -r 0 '+%s' >/dev/null 2>&1; then DATE_EPOCH="bsd"
else DATE_EPOCH="none"; fi
epoch_txt() {   # $1 = epoch second -> RV = YYYY-mm-ddTHH:MM:SS (local time)
    case "$DATE_EPOCH" in
        gnu) RV=$(date -d "@$1" '+%Y-%m-%dT%H:%M:%S') ;;
        bsd) RV=$(date -r "$1" '+%Y-%m-%dT%H:%M:%S') ;;
        *)   RV=$(date '+%Y-%m-%dT%H:%M:%S') ;;
    esac
}

# Sleeps until the next multiple of INTERVAL_SEC and sets BOUNDARY to that second.
# With a date that prints nanoseconds (%N) the wake-up is within a few ms of the boundary;
# without it, within one second after it.
sleep_to_boundary() {
    local t now_s now_ns whole ms frac
    t=$(date '+%s %N')
    now_s="${t%% *}"; now_ns="${t#* }"
    case "$now_ns" in ''|*[!0-9]*) now_ns=0 ;; esac
    BOUNDARY=$(( (now_s / INTERVAL_SEC + 1) * INTERVAL_SEC ))
    whole=$(( BOUNDARY - now_s ))
    ms=$(( 10#$now_ns / 1000000 ))
    if [ "$ms" -gt 0 ]; then
        whole=$(( whole - 1 ))
        printf -v frac '%03d' $(( 1000 - ms ))
        sleep "${whole}.${frac}"
    else
        sleep "$whole"
    fi
}

FIRST=1
WIN_TXT=""; WIN_S=0
while true; do
    sleep_to_boundary

    # rows and log lines carry the boundary itself, not the moment the script woke up
    WAKE_S="$BOUNDARY"
    epoch_txt "$BOUNDARY"; WAKE_TXT="$RV"

    perf_collect            # result of the interval that ends now
    perf_begin              # perf for the interval that starts now
    read_proc

    if [ "$DRY_RUN" -eq 0 ]; then
        if [ -f "$REAUTH_FLAG" ] || [ "$WAKE_S" -ge $(( TOKEN_EXP - TOKEN_MARGIN_SEC )) ]; then
            acquire_token && echo "[INFO] ${WAKE_TXT} token re-acquired" || echo "[WARN] ${WAKE_TXT} token re-acquisition failed" >&2
        fi
    fi

    # the row belongs to the interval that started at the previous boundary
    TIMESTAMP="$WIN_TXT"
    TS_EPOCH="$WIN_S"
    TS_MS=$(( WIN_S * 1000 ))

    # iterate the table (active metrics only)
    BODY=""; FIRST_STAT=1; SUMMARY=""
    CSV_ROW=()                      # reset: any index left unset prints as an empty cell
    i=0
    while [ "$i" -lt "$METRIC_N" ]; do
        if [ "${M_ACTIVE[$i]}" = "1" ]; then
            resolve_src "${M_SRC1[$i]}"; v1="$RV"
            resolve_src "${M_SRC2[$i]}"; v2="$RV"
            val=$(compute "${M_CALC[$i]}" "$v1" "$v2" "${M_PREV1[$i]}" "${M_PREV2[$i]}")
            # delta/dspct: this boundary's cumulative values are the previous values of the next one
            case "${M_CALC[$i]}" in
                delta|dspct)
                    [ "$v1" != "-1" ] && M_PREV1[$i]="$v1"
                    [ "${M_SRC2[$i]}" != "-" ] && [ "$v2" != "-1" ] && M_PREV2[$i]="$v2"
                    ;;
            esac
            if [ "$val" != "-1" ] && [ "$val" != "SKIP" ]; then
                [ "$FIRST_STAT" -eq 0 ] && BODY="${BODY},"; FIRST_STAT=0
                BODY="${BODY}{\"statKey\":\"${OPS_STAT_ROOT}|${M_GROUP[$i]}|${M_NAME[$i]}\",\"timestamps\":[${TS_MS}],\"data\":[${val}]}"
                # same condition as the push: -1/SKIP stays an empty cell so the
                # CSV shows a gap instead of a misleading 0
                CSV_ROW[$i]="$val"
            fi
            case "${M_NAME[$i]}" in
                IPC_Ratio|ITLB_MissRate_Pct|L2_DTLB_Miss_PTI|Thp_Coverage_Pct) SUMMARY="${SUMMARY} ${M_NAME[$i]}=${val}" ;;
            esac
        fi
        i=$((i+1))
    done

    if [ "$FIRST" -eq 1 ]; then
        # nothing was measured before this boundary: only perf was started and the baseline taken
        FIRST=0
        echo "[${WAKE_TXT}] collection started. First row at the next boundary."
    else
        LOOP=$((LOOP+1))
        JSON="{\"stat-content\":[${BODY}]}"

        [ "$CSV_MODE" -eq 1 ] && csv_write_row

        if [ "$DRY_RUN" -eq 1 ]; then
            # plain --dry-run keeps printing JSON; in --mode file the CSV is the output
            [ "$CSV_MODE" -eq 0 ] && echo "$JSON"
        else
            push_stats "$JSON" "$TIMESTAMP" &
            PUSH_TRY=$((PUSH_TRY+1))
        fi

        if [ "$PERF_RUN" -eq 1 ]; then
            echo "[${TIMESTAMP}] #${LOOP} |${SUMMARY} | perf ${MUX_TXT}"
        else
            echo "[${TIMESTAMP}] #${LOOP} |${SUMMARY}"
        fi
    fi
    WIN_TXT="$WAKE_TXT"; WIN_S="$WAKE_S"
done
