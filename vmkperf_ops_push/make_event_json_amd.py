#!/usr/bin/env python3
"""make_event_json_amd.py - build the AMD event files for vmkperf_ops_push

Reads the Linux kernel perf event list of one AMD Zen generation
(tools/perf/pmu-events/arch/x86/amdzen<N>/*.json, maintained by AMD) and writes
events/<name>.json holding only the core-PMC events this collector uses, with
EventCode / UMask copied verbatim from those files.

Usage (on the analysis machine, not on ESXi):
    python3 make_event_json_amd.py naples /path/to/amdzen1 "source note"
    python3 make_event_json_amd.py rome   /path/to/amdzen2 "source note"
    python3 make_event_json_amd.py milan  /path/to/amdzen3 "source note"
    python3 make_event_json_amd.py genoa  /path/to/amdzen4 "source note"
    python3 make_event_json_amd.py turin  /path/to/amdzen5 "source note"

One file per Zen generation, named after its first EPYC server line:
    naples = Zen 1   rome = Zen 2   milan = Zen 3   genoa = Zen 4   turin = Zen 5
The CPUID family-model values in each file are the ones the Broadcom Compatibility Guide lists
for ESXi 8.0 and later. events/cpu_map.json also holds the model ranges the kernel uses to
choose the list (tools/perf/pmu-events/arch/x86/mapfile.csv).

Event order == counter priority. These CPUs have six core performance counters per logical CPU
and no fixed counters, so cycles and instructions take two of the six. Events past the sixth
are started only when a counter is free.

The same key can be a different AMD event name, or a different unit mask, per generation:
  l2_dtlb_miss  PMCx045 0xf0 everywhere; named l2_dtlb_misses (recommended.json) in Zen 1-3
  l2_itlb_miss  PMCx085, all page sizes: 0x0f (.all) in Zen 4-5, 0xff in Zen 2-3; the Zen 1 list
                has no unit mask on the event and AMD's recommended l2_itlb_misses (0x07) is used
  dc_fill_mem / dc_fill_all  PMCx044 (any L1D fill by data source) is listed from Zen 3 on.
                The Zen 1 file has no such event; the metrics that need it stay empty.
  dmnd_fill_mem / dmnd_fill_all  Zen 2 only. Its list has PMCx043 (demand L1D fill by data
                source) with one unit-mask bit per source and no combined event, so the unit
                masks of the named sub-events are OR-ed: DRAM/IO = 0x08 | 0x40, every listed
                source = 0x01 | 0x02 | 0x08 | 0x10 | 0x40. Demand fills only: prefetch fills
                are separate events in that list. rome.json uses metrics_amd_zen2.json.
"""
import json, sys, os, glob, datetime

DESC = {
    "cycles":       "core cycles not in halt",
    "instr":        "retired instructions",
    "l2_dtlb_miss": "L1 DTLB misses that also missed the L2 DTLB (page walks)",
    "dc_fill_mem":  "L1 data cache fills from DRAM or MMIO (any NUMA node)",
    "l2_miss":      "core-to-L2 requests that missed L2 (data + instruction, no prefetch)",
    "dc_fill_all":  "L1 data cache fills from every source",
    "dmnd_fill_mem": "L1 data cache demand fills from DRAM or IO (this die + another die)",
    "dmnd_fill_all": "L1 data cache demand fills from every listed source",
    "l1_dtlb_miss": "L1 DTLB misses, all page sizes",
    "l2_itlb_miss": "instruction fetches that missed the L1 and L2 ITLB (page walks)",
}
# key order = counter priority
ORDER = ["cycles", "instr", "l2_dtlb_miss", "dc_fill_mem", "dmnd_fill_mem", "l2_miss", "dc_fill_all", "dmnd_fill_all",
         "l1_dtlb_miss", "l2_itlb_miss"]

# AMD event name per key in each generation's list. A key that is absent is not used for that
# generation. A tuple = sub-events of one event code whose unit masks are OR-ed.
ZEN2_SRC = "ls_refills_from_sys.ls_mabresp_"
ZEN123 = {"cycles": "ls_not_halted_cyc", "instr": "ex_ret_instr", "l2_dtlb_miss": "l2_dtlb_misses",
          "l2_miss": "l2_cache_req_stat.ic_dc_miss_in_l2", "l1_dtlb_miss": "ls_l1_d_tlb_miss.all"}
ZEN45 = {"cycles": "ls_not_halted_cyc", "instr": "ex_ret_instr", "l2_dtlb_miss": "ls_l1_d_tlb_miss.all_l2_miss",
         "dc_fill_mem": "ls_any_fills_from_sys.dram_io_all", "l2_miss": "l2_cache_req_stat.ic_dc_miss_in_l2",
         "dc_fill_all": "ls_any_fills_from_sys.all", "l1_dtlb_miss": "ls_l1_d_tlb_miss.all",
         "l2_itlb_miss": "bp_l1_tlb_miss_l2_tlb_miss.all"}

def with_(base, **more):
    d = dict(base); d.update(more); return d

GENERATIONS = {
    "naples": {"list": "amdzen1", "family_model": ["23-1", "23-17"],
               "label": "AMD Zen 1: EPYC 7001 Series (CPUID 17.01), Ryzen Embedded V1000 Series (17.11)",
               "names": with_(ZEN123, l2_itlb_miss="l2_itlb_misses"),
               "absent": ["dc_fill_mem", "dc_fill_all"],
               "log_keys": ["IPC", "L2_DTLB_Miss_PTI", "L2_Miss_PTI", "L1_DTLB_Miss_PTI"]},
    "rome":   {"list": "amdzen2", "family_model": ["23-49"],
               "label": "AMD Zen 2: EPYC 7002/7Fx2/7Hx2 Series (CPUID 17.31)",
               "metrics_file": "metrics_amd_zen2.json",
               "names": with_(ZEN123, l2_itlb_miss="bp_l1_tlb_miss_l2_tlb_miss",
                              dmnd_fill_mem=(ZEN2_SRC + "lcl_dram", ZEN2_SRC + "rmt_dram"),
                              dmnd_fill_all=(ZEN2_SRC + "lcl_l2", ZEN2_SRC + "lcl_cache", ZEN2_SRC + "lcl_dram",
                                             ZEN2_SRC + "rmt_cache", ZEN2_SRC + "rmt_dram"))},
    "milan":  {"list": "amdzen3", "family_model": ["25-1"],
               "label": "AMD Zen 3: EPYC 7003/7003X Series (CPUID 19.01)",
               "names": with_(ZEN123, l2_itlb_miss="bp_l1_tlb_miss_l2_tlb_miss",
                              dc_fill_mem="l1_data_cache_fills_from_memory", dc_fill_all="l1_data_cache_fills_all")},
    "genoa":  {"list": "amdzen4", "family_model": ["25-17", "25-160"],
               "label": "AMD Zen 4: EPYC 9004 Series (CPUID 19.11, 19.A0), EPYC 8004 Series (19.A0)",
               "names": ZEN45},
    "turin":  {"list": "amdzen5", "family_model": ["26-2", "26-17"],
               "label": "AMD Zen 5: EPYC 9005 Series (CPUID 1A.2, 1A.11)",
               "names": ZEN45},
}
GP_COUNTERS = 6          # core PMCs per logical CPU (kernel: AMD64_NUM_COUNTERS_CORE)

def main():
    if len(sys.argv) < 3 or sys.argv[1] not in GENERATIONS:
        print(__doc__); sys.exit(1)
    cpu, src = sys.argv[1], sys.argv[2]
    note = sys.argv[3] if len(sys.argv) > 3 else ""
    gen = GENERATIONS[cpu]
    byname = {}
    for f in sorted(glob.glob(os.path.join(src, "*.json"))):
        for e in json.load(open(f)):
            if "EventName" in e and e.get("Unit", "core") == "core":
                byname[e["EventName"]] = (e, os.path.basename(f))
    ctrs = ",".join(str(i) for i in range(GP_COUNTERS))
    out = {
        "cpu": cpu,
        "vendor": "amd",
        "label": gen["label"],
        "family_model": gen["family_model"],
        "source": "Linux kernel tools/perf/pmu-events/arch/x86/%s %s" % (gen["list"], note),
        "generated": datetime.date.today().isoformat(),
        "gp_counters": GP_COUNTERS,
        "fixed_cycles": False,
        "metrics_file": gen.get("metrics_file", "metrics_amd.json"),
        "events": [],
    }
    if gen.get("log_keys"):
        out["log_keys"] = gen["log_keys"]
    missing, absent = [], list(gen.get("absent", []))
    for key in ORDER:
        name = gen["names"].get(key)
        if name is None:
            continue
        parts = [name] if isinstance(name, str) else list(name)
        lost = [n for n in parts if n not in byname]
        if lost:
            missing += lost; continue
        e, fn = byname[parts[0]]
        code = int(e["EventCode"], 16)
        if code > 0xFF:
            raise SystemExit("event %s has a 12-bit code %s; vmkperf -e takes 8 bits here" % (parts[0], e["EventCode"]))
        umask = 0
        for n in parts:                     # one name: its unit mask. several: the same code, unit masks OR-ed
            pe = byname[n][0]
            if int(pe["EventCode"], 16) != code:
                raise SystemExit("sub-events of %s have different event codes" % key)
            umask |= int(pe.get("UMask", "0x0") or "0x0", 16)
        if len(parts) > 1:
            name = parts[0] + "".join(" + " + n.split(".", 1)[1] for n in parts[1:])
        out["events"].append({
            "key": key, "name": name,
            "event": "0x%02x" % code, "umask": "0x%02x" % umask,
            "cmask": 0,
            "counters": ctrs,
            "restricted": False,
            "desc": DESC[key],
            "file": fn,
        })
    if absent:
        out["no_event_in_list"] = absent
    dst = os.path.join(os.path.dirname(os.path.abspath(__file__)), "events", cpu + ".json")
    json.dump(out, open(dst, "w"), indent=2)
    print("wrote", dst, "events", len(out["events"]), "not in this list", absent, "missing", missing)
    if missing:
        sys.exit(1)

if __name__ == "__main__":
    main()
